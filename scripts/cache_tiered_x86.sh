#!/usr/bin/env bash
# =============================================================
# cache_tiered_x86.sh  -  OpenWrt x86_64 分层编译缓存流水线
#
# 三层分级:
#   tier1 = dl          (上游源码 tarball)
#   tier2 = staging_dir (工具链 / host)
#   tier3 = build_dir   (target 包编译中间产物)
#
# 子命令:
#   fp <tier1|tier2|tier3|config|patches>   计算指纹并打印
#   marker <tierN>                          打/刷新该层基准 marker
#   gate   <tierN>                          判断该层编译后是否真变化 (输出 0/1)
#   pack   <tierN>                          打包该层目录为 tar.zst 归档
#   restore <tier1|tier2|tier3|auto>        还原归档 (auto=三层+dl回拨)
#   image  <tierN>                          把归档推进 GHCR 镜像 (双通道大层用)
#
# 依赖环境变量(有默认值):
#   SRC_DIR     OpenWrt 源码根   默认 //openwrt
#   CACHE_ROOT  缓存工作区       默认 //cache
#   OUTPUT_DIR  归档存放目录     默认 /tiered
#   MARKER_DIR  marker 基准目录  默认 /stamp
#   REGISTRY    GHCR 命名空间    默认 ghcr.io/openwrt-cache
#
# 本轮四项改动已落地:
#   1. 新增 fp config / fp patches (输入指纹, 供工作流拼 key)
#   2. pack/restore 全部 zstd -T0 满核
#   3. restore auto 末尾把 dl 时间戳回拨到 2000-01-01
#   4. ccache 在工作流侧, 已整段注释, 需要时打开
# =============================================================
set -uo pipefail

SRC_DIR="${SRC_DIR:-$PWD/openwrt}"
CACHE_ROOT="${CACHE_ROOT:-$PWD/cache}"
OUTPUT_DIR="${OUTPUT_DIR:-$CACHE_ROOT/tiered}"
MARKER_DIR="${MARKER_DIR:-$CACHE_ROOT/stamp}"
REGISTRY="${REGISTRY:-ghcr.io/openwrt-cache}"

# ---------- tier -> 目录 映射 ----------
tier_dir() {
    case "$1" in
        tier1) echo "$SRC_DIR/dl" ;;
        tier2) echo "$SRC_DIR/staging_dir" ;;
        tier3) echo "$SRC_DIR/build_dir" ;;
        *) echo "" ;;
    esac
}

# ---------- 指纹: 通用两级 md5 汇总 (排除带点/编译噪音文件) ----------
# 用法: _fp <目录> [额外 find 排除参数...]
_fp() {
    local dir="$1"; shift
    [ -d "$dir" ] || { echo "nodir"; return; }
    find "$dir" -type f -not -name '.*' "$@" -print0 2>/dev/null | LC_ALL=C sort -z | xargs -0 -r md5sum 2>/dev/null | awk '{print $1}' | md5sum | awk '{print $1}'
}

fp_tier1() { _fp "$SRC_DIR/dl"          -not -name '*.part' -not -name '*.tmp'; }
fp_tier2() { _fp "$SRC_DIR/staging_dir" -not -path '*/.*/*'; }
fp_tier3() { _fp "$SRC_DIR/build_dir"   -not -path '*/.*/*'; }

# ---------- 新增: 算 .config + rules.mk + feeds.conf 的输入指纹 ----------
fp_config() {
    local src="${1:-$SRC_DIR}"
    local files=()
    [ -f "$src/.config" ] && files+=("$src/.config")
    [ -f "$src/rules.mk" ] && files+=("$src/rules.mk")
    [ -f "$src/feeds.conf" ] && files+=("$src/feeds.conf")
    [ -f "$src/feeds.conf.default" ] && files+=("$src/feeds.conf.default")
    if [ ${#files[@]} -eq 0 ]; then echo "noconfig"; return; fi
    md5sum "${files[@]}" 2>/dev/null | awk '{print $1}' | LC_ALL=C sort | md5sum | awk '{print $1}'
}

# ---------- 新增: 算所有本地补丁的输入指纹 ----------
fp_patches() {
    local src="${1:-$SRC_DIR}"
    local patch_files
    patch_files=$(for sub in package target/linux toolchain; do find "$src/$sub" -type f -name '*.patch' 2>/dev/null; find "$src/$sub" -type f -name '*.diff' 2>/dev/null; done | LC_ALL=C sort)
    if [ -z "$patch_files" ]; then echo "nopatches"; return; fi
    echo "$patch_files" | xargs md5sum 2>/dev/null | awk '{print $1}' | LC_ALL=C sort | md5sum | awk '{print $1}'
}

# ---------- marker: 编译前/还原后打基准 ----------
cmd_marker() {
    local tier="$1"
    mkdir -p "$MARKER_DIR"
    touch "$MARKER_DIR/$tier.marker"
    echo "[marker] $tier 基准已更新: $MARKER_DIR/$tier.marker"
}

# ---------- gate: 编译后判断该层是否真变化 (输出 0=未变 1=已变) ----------
cmd_gate() {
    local tier="$1"
    local dir; dir=$(tier_dir "$tier")
    local marker="$MARKER_DIR/$tier.marker"
    [ -f "$marker" ] || { echo "1"; return; }
    [ -d "$dir" ]     || { echo "1"; return; }
    local newer
    newer=$(find "$dir" -type f -newer "$marker" -not -path '*/.*/*' -print -quit 2>/dev/null)
    [ -n "$newer" ] && echo "1" || echo "0"
}

# ---------- pack: 打包该层 (zstd -T0 -3 满核) ----------
cmd_pack() {
    local tier="$1"
    local dir; dir=$(tier_dir "$tier")
    [ -d "$dir" ] || { echo "[pack] $tier 源目录不存在, 跳过"; return 0; }
    local out="$OUTPUT_DIR/$tier"; mkdir -p "$out"
    local fp; fp=$("$0" fp "$tier")
    local archive="$out/$tier-$fp.tar.zst"
    local base; base=$(basename "$dir")
    tar --use-compress-program="zstd -T0 -3" -cf "$archive" -C "$(dirname $dir)" "$base"
    echo "[pack] $tier -> $archive"
}

# ---------- restore ----------
restore_one() {
    local tier="$1"
    local out="$OUTPUT_DIR/$tier"
    local latest; latest=$(ls -t "$out"/*.tar.zst 2>/dev/null | head -n1)
    [ -n "$latest" ] || { echo "[restore] $tier 无归档, 跳过"; return 0; }
    echo "[restore] $tier 使用 $latest"
    mkdir -p "$SRC_DIR"
    tar --use-compress-program="zstd -T0 -d" -xf "$latest" -C "$SRC_DIR"
}

cmd_restore() {
    local arg="$1"
    if [ "$arg" = "auto" ]; then
        for tier in tier1 tier2 tier3; do restore_one "$tier"; done
        # ---------- dl 时间戳回拨, 防止 Make 因 dl 比 stamp 新 误判重编 ----------
        if [ -d "$SRC_DIR/dl" ]; then
            find "$SRC_DIR/dl" -type f -exec touch -t 200001010000 {} +
            echo "[restore] dl 时间戳已回拨到 2000-01-01"
        fi
    else
        restore_one "$arg"
    fi
}

# ---------- image: 把归档推进 GHCR (FROM scratch + COPY), 双通道大层用 ----------
cmd_image() {
    local tier="$1"
    local out="$OUTPUT_DIR/$tier"
    local latest; latest=$(ls -t "$out"/*.tar.zst 2>/dev/null | head -n1)
    [ -n "$latest" ] || { echo "[image] $tier 无归档, 跳过"; return 0; }
    local fp; fp=$("$0" fp "$tier")
    local ctx="$CACHE_ROOT/imgctx/$tier"; rm -rf "$ctx"; mkdir -p "$ctx"
    cp "$latest" "$ctx/"
    { echo "FROM scratch"; echo "COPY $(basename $latest) /"; } > "$ctx/Dockerfile"
    local img="$REGISTRY/$tier:$fp"
    if docker build -q -t "$img" "$ctx" && docker push "$img"; then
        docker tag "$img" "$REGISTRY/$tier:latest" && docker push "$REGISTRY/$tier:latest"
        echo "[image] 已推送 $img (含 :latest)"
    else
        echo "[image] 推送失败, 保留本地归档即可 (actions/cache 已兜底)"
    fi
}

usage() {
    cat <<'EOF'
用法: cache_tiered_x86.sh <命令> [参数]
  fp <tier1|tier2|tier3|config|patches>
  marker <tierN>
  gate   <tierN>
  pack   <tierN>
  restore <tier1|tier2|tier3|auto>
  image  <tierN>
EOF
}

case "${1:-}" in
    fp)
        case "${2:-}" in
            tier1)   fp_tier1 ;;
            tier2)   fp_tier2 ;;
            tier3)   fp_tier3 ;;
            config)  fp_config ;;
            patches) fp_patches ;;
            *)       usage ;;
        esac
        ;;
    marker)  cmd_marker "${2:-}" ;;
    gate)    cmd_gate   "${2:-}" ;;
    pack)    cmd_pack   "${2:-}" ;;
    restore) cmd_restore "${2:-}" ;;
    image)   cmd_image  "${2:-}" ;;
    *)       usage ;;
esac
