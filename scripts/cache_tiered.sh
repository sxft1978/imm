#!/bin/bash
###############################################################################
# OpenWrt/ImmortalWrt 编译缓存 —— 三层分级版（tiered cache）· x86 适配增强版
#
# 在你原有 workflow（单 job 编 x86 固件）里插桩使用，不改动你的源码树路径：
#   SRC_DIR    = 你克隆出来的 openwrt（默认 $GITHUB_WORKSPACE/openwrt）
#   CACHE_ROOT = 分块/marker 的暂存根目录（默认 $GITHUB_WORKSPACE/.cache_tiered）
#
# 三条腿走路，各用最适合它的后端：
#   tier1 = dl/ + package/           源码包归档，几乎不变   -> Actions Cache
#   tier2 = host/hostpkg/toolchain   编译工具链，较稳定     -> Actions Cache
#   tier3 = target-* 目录(含 stamp)  目标软件包，最易变     -> GHCR 独立镜像(digest 去重)
#
# 本轮相对上一版的两处增强（专为「把你 x86 路径真正跑起来」）：
#   1) 路径解析支持 glob：TIER3_PATHS 可写 `build_dir/target-x86_64_*` 这类通配，
#      自动展开成磁盘上真实存在的目录（fp/gate/pack 统一走 resolve_paths）。
#   2) tier3 指纹「按层 scope」：只对 tier3 自己的目录数 stamp，不再把工具链的
#      stamp 也算进来，真正做到「只改了一个插件 -> 只点亮 tier3、tier2 指纹纹丝不动」。
###############################################################################
set -uo pipefail

# ---------------- 全局配置：env 优先、缺省兜底（workflow 用 env 注入即可，无需改脚本） ----------------
SOURCE_CODE_PLATFORM="${SOURCE_CODE_PLATFORM:-immortalwrt}"
DEVICE="${DEVICE:-xiaoyi_x86}"
ARCH="${ARCH:-x86_64}"                              # 稳定层按 arch 跨设备共享同一缓存键
REPO_PREFIX="${REPO_PREFIX:-openwrt-tiered-cache}"
GHCR="ghcr.io/${GITHUB_REPOSITORY_OWNER:-unknown}/${REPO_PREFIX}"
SRC_DIR="${SRC_DIR:-${GITHUB_WORKSPACE:-.}/openwrt}"
CACHE_ROOT="${CACHE_ROOT:-${GITHUB_WORKSPACE:-.}/.cache_tiered}"
CHUNK_SIZE="${CHUNK_SIZE:-2000M}"
ZSTD_LEVEL="${ZSTD_LEVEL:-10}"

# 工具链层（较稳定）：目录名固定，不含三元组。
TIER2_PATHS="${TIER2_PATHS:-build_dir/host build_dir/hostpkg staging_dir/host staging_dir/hostpkg}"
# 目标包层（最易变）：目录名带「目标三元组」，x86 系列是 x86_64_*，用 glob 兜住完整后缀。
TIER3_PATHS="${TIER3_PATHS:-build_dir/target-x86_64_* staging_dir/target-x86_64_*}"

# ---------------------------------------------------------------------------
# resolve_paths <目录模板串>：把「空格分隔的相对路径 / glob」展开成 SRC_DIR 下
#   真实存在的「相对路径」列表（空格分隔）。glob 命中不到时该项自然被丢弃。
#   这是本轮新增的核心零件：fp/gate/pack 全部复用它，对 x86 通配同样有效。
# ---------------------------------------------------------------------------
resolve_paths() {
    local out=""
    for pat in $1; do
        for p in "$SRC_DIR"/$pat; do
            [ -e "$p" ] && out="$out ${p#"$SRC_DIR"/}"
        done
    done
    echo "$out"
}

# ---------------- 层 -> 目录模板（原始，可能含 glob，交给 resolve_paths 展开） ----------------
tier_paths() {
    case "$1" in
        tier1) echo "dl package" ;;
        tier2) echo "$TIER2_PATHS" ;;
        tier3) echo "$TIER3_PATHS" ;;
        *) echo "" ; return 1 ;;
    esac
}

# ---------------- 层 -> GHCR 镜像名（tier3 才真正用到） ----------------
tier_image() {
    case "$1" in
        tier1) echo "${GHCR}-dl-${ARCH}:latest" ;;
        tier2) echo "${GHCR}-toolchain-${ARCH}:latest" ;;
        tier3) echo "${GHCR}-pkgs-${SOURCE_CODE_PLATFORM}_${DEVICE}:latest" ;;
        *) echo "" ; return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# 内容指纹：决定「要不要重传」的钥匙
#   tier3：只对本层 resolve 后的目录下 */stamp/* 文件名算摘要（按层 scope）。
#   tier1/tier2：用「相对路径|字节大小」清单算摘要。
# ---------------------------------------------------------------------------
fingerprint() {
    tier="$1"
    [ -d "$SRC_DIR" ] || { echo "none"; return 1; }
    resolved="$(resolve_paths "$(tier_paths "$tier")")"
    if [ -z "$resolved" ]; then echo "empty"; return 1; fi
    if [ "$tier" = "tier3" ]; then
        for d in $resolved; do
            [ -d "$SRC_DIR/$d" ] && find "$SRC_DIR/$d" -path '*/stamp/*' -type f 2>/dev/null
        done | LC_ALL=C sort | sed "s#^$SRC_DIR/##" | sha256sum | awk '{print substr($1,1,16)}'
    else
        for d in $resolved; do
            [ -d "$SRC_DIR/$d" ] && find "$SRC_DIR/$d" -printf '%P|%s\n' 2>/dev/null
        done | LC_ALL=C sort | sha256sum | awk '{print substr($1,1,16)}'
    fi
}

# 写 key=value 进 $GITHUB_OUTPUT；本地调试时该变量为空则跳过、仅 print。
out_kv() { if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "$1=$2" >> "$GITHUB_OUTPUT"; fi; }

cmd="${1:-}"; [ $# -gt 0 ] && shift
case "$cmd" in

    # ====================== 计算指纹（供 cache key 使用） ======================
    fp)
        tier="${1:-tier1}"
        v="$(fingerprint "$tier")"
        echo "fp_${tier}=${v}"
        out_kv "fp_${tier}" "$v"
        ;;

    # ====================== 本层自锚点后是否真的变了 ======================
    gate)
        tier="${1:-tier3}"
        marker="${2:-$CACHE_ROOT/base_compilation_marker}"
        if [ ! -f "$marker" ]; then
            echo "changed=1"; out_kv "changed" 1; out_kv "changed_${tier}" 1; exit 0
        fi
        noise='\.zstd$|\.flock$|\.libdeflate$|\.pkgconf$|\.xz$|\.tar$|\.patch$|\.m4_|\.tools_compile_|\.target_prereq|\.prepared'
        roots=()
        for d in $(resolve_paths "$(tier_paths "$tier")"); do roots+=("$SRC_DIR/$d"); done
        n=0
        if [ ${#roots[@]} -gt 0 ]; then
            n=$(find "${roots[@]}" -newer "$marker" -path '*/stamp/*' -type f 2>/dev/null | grep -Ev "$noise" | wc -l | tr -d ' ')
        fi
        c=0; [ "${n:-0}" -gt 0 ] && c=1
        echo "changed_stamp=${n:-0}"; echo "changed=$c"
        out_kv "changed" "$c"; out_kv "changed_${tier}" "$c"
        ;;

    # ====================== 打包 + 分块 ======================
    pack)
        tier="${1:?missing tier}"
        out_dir="${2:-$CACHE_ROOT/tiered/$tier}"
        real="$(resolve_paths "$(tier_paths "$tier")")"
        [ -z "$real" ] && { echo "!! $tier 无可打包内容（glob 未命中，检查 TIER3_PATHS/TIER2_PATHS）"; exit 0; }
        mkdir -p "$out_dir"
        rm -f "$out_dir/${tier}_raw_"* "$out_dir/${tier}.tar"
        ( cd "$SRC_DIR" && tar -I "zstd -T0 -${ZSTD_LEVEL}" -cf "$out_dir/${tier}.tar" $real ) 2>/dev/null
        [ -f "$out_dir/${tier}.tar" ] || { echo "!! $tier 无可打包内容"; exit 0; }
        split -a 3 -d -b "$CHUNK_SIZE" "$out_dir/${tier}.tar" "$out_dir/${tier}_raw_"
        rm -f "$out_dir/${tier}.tar"
        fingerprint "$tier" > "$out_dir/${tier}.fp"
        blocks=$(ls "$out_dir" | grep -c "${tier}_raw_" || true)
        echo "[OK] $tier 打包完成：${blocks} 个分块，指纹 $(cat "$out_dir/${tier}.fp")"
        du -sh "$out_dir" 2>/dev/null || true
        ;;

    # ====================== 构建并推送本层独立镜像（tier3 常用） ======================
    image)
        tier="${1:?missing tier}"
        dir="$CACHE_ROOT/tiered/$tier"
        img="$(tier_image "$tier")"
        ls "$dir"/${tier}_raw_* >/dev/null 2>&1 || { echo "-- $tier 无分块，跳过推送"; exit 0; }
        {
            echo "FROM scratch"
            for f in "$dir"/${tier}_raw_*; do
                name="$(basename "$f")"
                printf 'COPY %s /%s\n' "$name" "$name"
            done
            echo "LABEL io.openwrtcache.tier=${tier}"
            echo "LABEL io.openwrtcache.fp=$(cat "$dir/${tier}.fp" 2>/dev/null || echo none)"
        } > "$dir/Dockerfile"
        echo "==> 推送 $img"
        if docker build -q -t "$img" -f "$dir/Dockerfile" "$dir" && docker push "$img"; then
            echo "[OK] $tier 已推送 $img"
        else
            echo "!! $tier 推送失败"; rm -f "$dir/Dockerfile"; exit 1
        fi
        rm -f "$dir/Dockerfile"
        ;;

    # ====================== 从磁盘分块还原某层（本地测试入口） ======================
    unpack)
        tier="${1:?missing tier}"
        src="${2:-$CACHE_ROOT/tiered/$tier}"
        shopt -s nullglob; parts=("$src"/${tier}_raw_*); shopt -u nullglob
        [ ${#parts[@]} -eq 0 ] && { echo "-- $tier 无缓存"; exit 0; }
        if cat "${parts[@]}" | tar -I "zstd -T0" -xf - -C "$SRC_DIR"; then
            echo "[OK] $tier 还原 ${#parts[@]} 块"
        else
            echo "!! $tier 还原失败"
        fi
        ;;

    # ====================== 编译前逐层还原（缓存命中主入口） ======================
    restore)
        mode="${1:-auto}"
        for tier in tier1 tier2 tier3; do
            dir="$CACHE_ROOT/tiered/$tier"; mkdir -p "$dir"
            if ls "$dir"/${tier}_raw_* >/dev/null 2>&1; then
                echo "== $tier 已由 Actions Cache 命中，零传输"
                cat "$dir"/${tier}_raw_* | tar -I "zstd -T0" -xf - -C "$SRC_DIR" || true
                continue
            fi
            if [ "$mode" = "clean" ]; then echo "-- $tier force_rebuild，跳过还原"; continue; fi
            [ "$tier" != "tier3" ] && { echo "-- $tier 依赖 Actions Cache，本轮未命中，走纯净编译"; continue; }
            img="$(tier_image "$tier")"
            docker pull "$img" >/dev/null 2>&1 || { echo "-- $tier 无镜像缓存，本轮走纯净编译"; continue; }
            cid="$(docker create "$img" /bin/true)"
            for f in $(docker run --rm --entrypoint ls "$img" / 2>/dev/null | grep "${tier}_raw_" || true); do
                docker cp "$cid":/"$f" "$dir/$f" || true
            done
            docker rm -f "$cid" >/dev/null 2>&1 || true
            docker rmi "$img" >/dev/null 2>&1 || true
            ls "$dir"/${tier}_raw_* >/dev/null 2>&1 || { echo "-- $tier 镜像内无内容"; continue; }
            cat "$dir"/${tier}_raw_* | tar -I "zstd -T0" -xf - -C "$SRC_DIR" || true
            echo "[OK] $tier 已从 GHCR 还原"
        done
        df -hT | tail -n +2 || true
        ;;

    *)
        echo "用法: cache_tiered_x86.sh {fp|gate|pack|image|unpack|restore} [tier] [dir]"; exit 2 ;;
esac
