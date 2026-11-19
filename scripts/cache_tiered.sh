#!/bin/bash
###############################################################################
# OpenWrt 编译缓存 —— 三层分级版（tiered cache）
#
# 设计目标：把「最耗时 / 最占上行带宽」的两件事降到最低——
#   (A) 编译前还原缓存（restore）
#   (B) 编译后保存缓存（gate -> pack -> image / actions-cache save）
#
# 核心思想（两条腿走路，各用最适合它的后端）：
#   1) 按「变化频率」把缓存切成三层，稳定层压在底部、易变层单独存放；
#   2) 稳定层走 GitHub Actions Cache —— 命中缓存 key 即「不重新上传、也不重新下载」，
#      因为 cache key 由内容指纹决定，指纹不变 = 键不变 = 完全零传输；
#   3) 易变层走 GHCR 独立镜像 —— registry 按「层 digest（内容哈希）」去重，
#      未变的那些分块（block）push 时秒回、不占上行；分块独立成层，一个包挂掉不牵连其它。
#
# 三层划分：
#   tier1 = dl/ + package/                    源码包归档，几乎不变      -> Actions Cache
#   tier2 = host/hostpkg/toolchain            编译工具链，较稳定        -> Actions Cache
#   tier3 = target 目录（含 stamp 文件）       目标软件包，最易变        -> GHCR 镜像
#
# 两个「独门」点务必理解：
#   - fingerprint：给每层算一个内容摘要，摘要进 cache key，决定「要不要动手」。
#   - gate：以编译前打的 marker 为锚点，只数「真正变化的 stamp」（正则剔掉
#           .zstd/.flock/.xz 等噪声），为 0 就连 tar 都不打，直接省掉整轮上行。
#
# 用法（与 build-cache-tiered.yml 一一对应）：
#   cache_tiered.sh fp      <tier>            计算内容指纹（stdout + $GITHUB_OUTPUT）
#   cache_tiered.sh gate    <tier> [marker]   自锚点后「本层」是否真变（按层路径 scope 数 stamp）
#   cache_tiered.sh pack    <tier> [out_dir]  打成 zstd tar 并按 CHUNK_SIZE 分块
#   cache_tiered.sh image   <tier>            为本层构建 FROM-scratch 独立镜像并推送 GHCR
#   cache_tiered.sh unpack  <tier> [in_dir]   从磁盘分块还原某层
#   cache_tiered.sh restore [auto|clean]      编译前逐层还原（命中 Actions Cache 优先，tier3 回落 GHCR）
###############################################################################

# -u: 引用未定义变量即报错（防手滑）；-o pipefail: 管道中任一环失败整体即失败。
# 注意：这里不启用 -e，因为本脚本要在 GHA 里做大量「探测式」判断，宁可显式处理返回码。
set -uo pipefail

# ---------------------------------------------------------------------------
# 全局配置：一律以「环境变量优先、缺省值兜底」的形式读取，方便 workflow 直接注入
# ---------------------------------------------------------------------------
SOURCE_CODE_PLATFORM="${SOURCE_CODE_PLATFORM:-openwrt}" # 源码平台，决定 tier3 镜像名
DEVICE="${DEVICE:-x86_64}"                              # 设备型号，决定 tier3 镜像名
ARCH="${ARCH:-aarch64_generic}"                         # 体系结构：稳定层(tier1/tier2)按 arch 跨设备共享
REPO_PREFIX="${REPO_PREFIX:-openwrt-tiered-cache}"      # GHCR 仓库名前缀
GHCR="ghcr.io/${GITHUB_REPOSITORY_OWNER:-unknown}/${REPO_PREFIX}" # 自动落到 fork 者自己的 GHCR 名下
CACHE_ROOT="${CACHE_ROOT:-/workdir}"                    # 迁移后的宽敞工作区（对应 Relocate 步骤）
SRC_DIR="${SRC_DIR:-$CACHE_ROOT/openwrt}"               # 源码树根目录
CHUNK_SIZE="${CHUNK_SIZE:-2000M}"                       # 单个分块大小（远小于 GHCR 单层上限，留足余量）
ZSTD_LEVEL="${ZSTD_LEVEL:-10}"                          # zstd 压缩级别，10 兼顾速度与压缩比

# tier2 / tier3 的「实际目录」按目标三元组填实（arm/arm64/x86 各不相同）。
# 留默认值时若目录不存在，pack/gate 会命中「无可打包内容」安全跳过，不会报错。
TIER2_PATHS="${TIER2_PATHS:-build_dir/host build_dir/hostpkg staging_dir/host staging_dir/hostpkg}"
TIER3_PATHS="${TIER3_PATHS:-build_dir/target-aarch64_generic staging_dir/target-aarch64_generic}"

# ---------------------------------------------------------------------------
# 每个层 -> 「目录集合」的映射（供 fingerprint / gate / pack 复用）
# ---------------------------------------------------------------------------
tier_paths() {
    case "$1" in
        tier1) echo "dl package" ;;          # 源码包归档目录
        tier2) echo "$TIER2_PATHS" ;;        # 工具链目录
        tier3) echo "$TIER3_PATHS" ;;        # 目标包目录（stamp 就在这里面）
        *) echo "" ; return 1 ;;             # 未知层：返回空并置非零退出码
    esac
}

# ---------------------------------------------------------------------------
# 每个层 -> 「GHCR 镜像名」的映射
#   tier1/tier2 主用 Actions Cache，这里的镜像名仅作极端情况下的兜底/占位；
#   tier3 是唯一真正推 GHCR 的层，故镜像名里带上「平台_设备」以区分数十个型号。
# ---------------------------------------------------------------------------
tier_image() {
    case "$1" in
        tier1) echo "${GHCR}-dl-${ARCH}:latest" ;;                            # 按 arch 共享
        tier2) echo "${GHCR}-toolchain-${ARCH}:latest" ;;                     # 按 arch 共享
        tier3) echo "${GHCR}-pkgs-${SOURCE_CODE_PLATFORM}_${DEVICE}:latest" ;;# 精确到型号
        *) echo "" ; return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# 内容指纹（fingerprint）——决定「要不要重传」的钥匙
#   tier3：直接用所有 stamp 文件名做摘要。stamp 文件名内嵌 PKG 的 hash，
#          只有包内容真变了、hash 变了，文件名才会变——比 mtime 更贴近「要不要重编」，
#          且天然不受「make 重新下载 tarball 把 mtime 弄新」的干扰。
#   tier1/tier2：用「相对路径|文件大小」清单做摘要（这两层没有可依赖的 stamp 语义）。
#   取 sha256 前 16 位十六进制作为短指纹，写进 cache key 足够去重又不臃肿。
# ---------------------------------------------------------------------------
fingerprint() {
    tier="$1"
    paths="$(tier_paths "$tier")"
    # 源码树都不存在时（极早期步骤），指纹记为 none，让上层逻辑走「无缓存」分支
    if [ -z "$paths" ] || [ ! -d "$SRC_DIR" ]; then echo "none"; return 1; fi
    if [ "$tier" = "tier3" ]; then
        find "$SRC_DIR" -path '*/stamp/*' -type f 2>/dev/null | LC_ALL=C sort | sha256sum
    else
        for d in $paths; do
            # -printf '%P|%s' 打印「相对 SRC_DIR/dir 的路径|字节数」，%P 不带目录前缀，跨机器稳定
            [ -d "$SRC_DIR/$d" ] && find "$SRC_DIR/$d" -printf '%P|%s\n' 2>/dev/null
        done | LC_ALL=C sort | sha256sum
    fi | awk '{print substr($1,1,16)}'
}

# ---------------------------------------------------------------------------
# 把 key=value 写进 $GITHUB_OUTPUT，供 workflow 的 <step>.outputs.<key> 引用。
# 非 GHA 环境（本地调试）时该变量为空，直接跳过，脚本仍可照常 print 到 stdout。
# ---------------------------------------------------------------------------
out_kv() {
    if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "$1=$2" >> "$GITHUB_OUTPUT"; fi
}

# 解析第一个位置参数为子命令，其余参数留给各分支自行取用
cmd="${1:-}"
[ $# -gt 0 ] && shift

case "$cmd" in

    # ====================== 计算指纹（供 cache key 使用） ======================
    fp)
        tier="${1:-tier1}"
        fp_value="$(fingerprint "$tier")"
        # 注意：这里按层输出 fp_tier1 / fp_tier2 / fp_tier3 三个独立 key，
        # 早前版本三次调用都写同名 'fp' 会互相覆盖，已改为带层后缀，避免串值。
        echo "fp_${tier}=${fp_value}"
        out_kv "fp_${tier}" "${fp_value}"
        ;;

    # ====================== 本层自锚点后是否真的变了 ======================
    # 只数「本层路径下」新出现的 stamp（而不是全局），这样 tier2 与 tier3 的判定
    # 才互相独立：改了某个插件只点亮 tier3，没动工具链时 tier2 保持 0、不重传。
    gate)
        tier="${1:-tier3}"
        marker="${2:-$CACHE_ROOT/base_compilation_marker}"
        # 锚点文件不存在 => 本轮是纯净编译，无法判断 => 保守认为「变了」，触发存档
        if [ ! -f "$marker" ]; then
            echo "changed=1"; out_kv "changed" 1; out_kv "changed_${tier}" 1; exit 0
        fi
        # 噪声清单：这些 stamp 每次编译都会「碰一下」但并不代表对应包真重编，
        # 若不剔除，changed 计数几乎恒 >0，缓存永远失效。
        noise='\.zstd$|\.flock$|\.libdeflate$|\.pkgconf$|\.xz$|\.tar$|\.patch$|\.m4_|\.tools_compile_|\.target_prereq|\.prepared'
        # 把 find 的范围限定到「本层的目录」，逐层独立判定
        roots=()
        for d in $(tier_paths "$tier"); do
            [ -d "$SRC_DIR/$d" ] && roots+=("$SRC_DIR/$d")
        done
        n=0
        if [ ${#roots[@]} -gt 0 ]; then
            n=$(find "${roots[@]}" -newer "$marker" -path '*/stamp/*' -type f 2>/dev/null \
                | grep -Ev "$noise" | wc -l | tr -d ' ')
        fi
        if [ "${n:-0}" -gt 0 ]; then c=1; else c=0; fi
        echo "changed_stamp=${n:-0}"
        echo "changed=$c"
        # 同时输出带层后缀的 key，供 workflow 分别 gate tier2 / tier3（修复同名覆盖）
        out_kv "changed" "$c"
        out_kv "changed_${tier}" "$c"
        ;;

    # ====================== 打包 + 分块（供缓存/镜像使用） ======================
    pack)
        tier="${1:?missing tier}"
        out_dir="${2:-$CACHE_ROOT/tiered/$tier}"
        paths="$(tier_paths "$tier")"
        if [ -z "$paths" ]; then echo "!! 未知层 $tier"; exit 2; fi
        mkdir -p "$out_dir"
        # 清掉上一轮残留的分块与中间 tar，保证本轮产物干净（防止新旧块混在一起解错）
        rm -f "$out_dir/${tier}_raw_"* "$out_dir/${tier}.tar"
        # 只保留「真实存在」的目录参与打包，避免 tar 因缺目录而报错
        real=""
        for d in $paths; do [ -e "$SRC_DIR/$d" ] && real="$real $d"; done
        [ -z "$real" ] && { echo "!! $tier 无可打包内容"; exit 0; }
        # 在源码树内打 tar，路径即为相对路径，还原时能精确落回原位；
        # zstd -T0 用满所有核并行压缩，-10 是速度与体积的甜点。
        ( cd "$SRC_DIR" && tar -I "zstd -T0 -${ZSTD_LEVEL}" -cf "$out_dir/${tier}.tar" $real ) 2>/dev/null
        if [ ! -f "$out_dir/${tier}.tar" ]; then echo "!! $tier 无可打包内容"; exit 0; fi
        # 按 CHUNK_SIZE 切片。切成多块有两个好处：
        #   a) 每块单独成为 GHCR 镜像的一层，digest 去重只在「变过的那一块」上传；
        #   b) 避开 GHCR / registry 对单个 blob 体积的隐性上限。
        split -a 3 -d -b "$CHUNK_SIZE" "$out_dir/${tier}.tar" "$out_dir/${tier}_raw_"
        rm -f "$out_dir/${tier}.tar"
        # 顺手把指纹落到磁盘，供 image 子命令写进镜像 LABEL 做可追溯标记
        fingerprint "$tier" > "$out_dir/${tier}.fp"
        blocks=$(ls "$out_dir" | grep -c "${tier}_raw_" || true)
        echo "[OK] $tier 打包完成：${blocks} 个分块，指纹 $(cat "$out_dir/${tier}.fp")"
        du -sh "$out_dir" 2>/dev/null || true
        ;;

    # ====================== 构建并推送本层独立镜像（仅 tier3 真正常用） ======================
    image)
        tier="${1:?missing tier}"
        dir="$CACHE_ROOT/tiered/$tier"
        img="$(tier_image "$tier")"
        # 磁盘上没有分块 => 本层没内容可推（多半是 gate=0 没 pack），安全退出而非报错
        if ! ls "$dir"/${tier}_raw_* >/dev/null 2>&1; then
            echo "-- $tier 无分块，跳过推送"; exit 0
        fi
        # 优化：不再把分块 cp 到临时目录，直接以「分块所在目录」当 build context，
        # 省掉一次多 GB 的磁盘拷贝，也让 docker 只从本地目录读、不重复搬运。
        {
            echo "FROM scratch"               # 空基镜像：整层体积=我们的数据体积，无系统层冗余
            for f in "$dir"/${tier}_raw_*; do
                name="$(basename "$f")"
                # COPY 的路径相对 context 根（即 $dir），故直接用文件名，不带目录前缀
                printf 'COPY %s /%s\n' "$name" "$name"
            done
            # LABEL 只加元信息、不占数据层；把层名/指纹写进去，便于事后核对「这镜像是哪层、什么内容」
            echo "LABEL io.openwrtcache.tier=${tier}"
            echo "LABEL io.openwrtcache.fp=$(cat "$dir/${tier}.fp" 2>/dev/null || echo none)"
        } > "$dir/Dockerfile"
        echo "==> 推送 $img"
        # 逐块 COPY = 每个分块是独立 layer = registry 端按 digest 去重：
        # 未变的分块 push 会返回 "Layer already exists" 秒过，只上传真正改过的块。
        if docker build -q -t "$img" -f "$dir/Dockerfile" "$dir" && docker push "$img"; then
            echo "[OK] $tier 已推送 $img"
        else
            echo "!! $tier 推送失败"; rm -f "$dir/Dockerfile"; exit 1
        fi
        rm -f "$dir/Dockerfile"
        ;;

    # ====================== 从磁盘分块还原某层 ======================
    unpack)
        tier="${1:?missing tier}"
        src="${2:-$CACHE_ROOT/tiered/$tier}"
        shopt -s nullglob          # 无匹配时数组为空，而非把字面量塞进数组
        parts=("$src"/${tier}_raw_*)
        shopt -u nullglob
        if [ ${#parts[@]} -eq 0 ]; then
            echo "-- $tier 无缓存"; exit 0
        fi
        # 按序 cat 所有分块 -> 还原成原始 tar 流 -> 直接解压进源码树。
        # 关键：这里不用 docker export（它把所有层拍平成一个巨型文件、必须整体拉回），
        # 而是让「每块独立解压合并」，IO 更省、也天然只搬运变化的块。
        if cat "${parts[@]}" | tar -I "zstd -T0" -xf - -C "$SRC_DIR"; then
            echo "[OK] $tier 还原 ${#parts[@]} 块"
        else
            echo "!! $tier 还原失败"
        fi
        ;;

    # ====================== 编译前逐层还原（缓存命中的主入口） ======================
    # 还原路径按「贵贱」排序，越便宜越先试：
    #   1) Actions Cache 若命中，YAML 已把 tier1/tier2 的分块 restore 到磁盘 -> 这里直接本地解压，零网络；
    #   2) tier3 磁盘没有 -> 去 GHCR 拉镜像，用 docker cp 逐块取出（同样不 export）；
    #   3) clean 模式（force_rebuild）= 什么都不还原，纯净重编译。
    restore)
        mode="${1:-auto}"
        for tier in tier1 tier2 tier3; do
            dir="$CACHE_ROOT/tiered/$tier"
            mkdir -p "$dir"
            # —— 路径①：磁盘上已有分块（稳定层多来自 Actions Cache 命中）——
            if ls "$dir"/${tier}_raw_* >/dev/null 2>&1; then
                echo "== $tier 已由 Actions Cache 命中，零传输"
                cat "$dir"/${tier}_raw_* | tar -I "zstd -T0" -xf - -C "$SRC_DIR" || true
                continue
            fi
            if [ "$mode" = "clean" ]; then
                echo "-- $tier force_rebuild，跳过还原"; continue
            fi
            # —— 稳定层（tier1/tier2）设计上主走 Actions Cache，不往 GHCR 推，
            #    磁盘没有即视为未命中，直接进入纯净路径，不再空拉镜像（省一次无谓 pull）——
            if [ "$tier" != "tier3" ]; then
                echo "-- $tier 依赖 Actions Cache，本轮未命中，走纯净编译"; continue
            fi
            # —— 路径②：tier3 回落 GHCR 镜像 ——
            img="$(tier_image "$tier")"
            if ! docker pull "$img" >/dev/null 2>&1; then
                echo "-- $tier 无镜像缓存，本轮走纯净编译"; continue
            fi
            cid="$(docker create "$img" /bin/true)"
            # 逐块 docker cp 取出（只拷我们需要的 _raw_ 分块，不 export 整镜像）
            for f in $(docker run --rm --entrypoint ls "$img" / 2>/dev/null | grep "${tier}_raw_" || true); do
                docker cp "$cid":/"$f" "$dir/$f" || true
            done
            docker rm -f "$cid" >/dev/null 2>&1 || true
            docker rmi "$img" >/dev/null 2>&1 || true   # 用完即删，把 /workdir 空间腾给后续编译
            if ! ls "$dir"/${tier}_raw_* >/dev/null 2>&1; then
                echo "-- $tier 镜像内无内容"; continue
            fi
            cat "$dir"/${tier}_raw_* | tar -I "zstd -T0" -xf - -C "$SRC_DIR" || true
            echo "[OK] $tier 已从 GHCR 还原"
        done
        df -hT | tail -n +2 || true
        ;;

    *)
        echo "用法: cache_tiered.sh {fp|gate|pack|image|unpack|restore} [tier] [dir]"
        exit 2
        ;;
esac
