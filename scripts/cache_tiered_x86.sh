#!/bin/bash
set -uo pipefail

# ── 环境变量（带默认值，本地不会 unbound）──
REPO_PREFIX="${REPO_PREFIX:-ghcr.io/sxft1978/immortalwrt-x86-64}"
DOCKER_IMAGE="${DOCKER_IMAGE:-ghcr.io/sxft1978/immortalwrt-xiaoyi}"
TIER1_PATHS="${TIER1_PATHS:-staging_dir/target-* staging_dir/host}"
TIER2_PATHS="${TIER2_PATHS:-build_dir/package-*}"
TIER3_PATHS="${TIER3_PATHS:-ccache}"
OUTPUT_DIR="${OUTPUT_DIR:-/tmp/tier_cache}"

# ── zstd 守卫：pack/image/unpack/restore 前必须确保可用 ──
ensure_zstd() {
  command -v zstd >/dev/null 2>&1 && return 0
  echo "zstd 缺失，尝试安装..." >&2
  sudo -E apt-get -qq install -y zstd >/dev/null 2>&1 || true
  command -v zstd >/dev/null 2>&1 || { echo "zstd 仍不可用，tier 操作中止" >&2; return 1; }
}

# ── 指纹计算 ──
cmd_fp() {
  local tier="$1"
  local paths_var="TIER${tier}_PATHS"
  local paths="${!paths_var}"
  local fp_input=""
  for p in $paths; do
    if [ -e "$p" ]; then
      fp_input+="$(find "$p" -type f -exec md5sum {} \; 2>/dev/null | sort | md5sum | cut -d' ' -f1)"
    fi
  done
  echo "$fp_input" | md5sum | cut -d' ' -f1
}

# ── 门控判断：指纹是否变化 ──
cmd_gate() {
  local tier="$1"
  local fp_file="$OUTPUT_DIR/.tier${tier}_fp"
  local new_fp
  new_fp="$(cmd_fp "$tier")"
  mkdir -p "$OUTPUT_DIR"
  if [ -f "$fp_file" ] && [ "$(cat "$fp_file")" = "$new_fp" ]; then
    echo "unchanged"
    return 1  # 未变化，跳过
  fi
  echo "$new_fp" > "$fp_file"
  echo "changed"
  return 0
}

# ── 打包 ──
cmd_pack() {
  ensure_zstd || return 1
  local tier="$1"
  local paths_var="TIER${tier}_PATHS"
  local paths="${!paths_var}"
  local fp
  fp="$(cmd_fp "$tier")"
  local out="$OUTPUT_DIR/tier${tier}_${fp}.tar.zst"
  mkdir -p "$OUTPUT_DIR"
  # shellcheck disable=SC2086
  tar -I "zstd -T0" -cf "$out" $paths 2>/dev/null || tar -cf - $paths 2>/dev/null | zstd -T0 -o "$out"
  echo "$out"
}

# ── 构建镜像（用于 tier3 ccache 等）──
cmd_image() {
  ensure_zstd || return 1
  local tier="$1"
  local tarball
  tarball="$(cmd_pack "$tier")"
  local tag="${REPO_PREFIX}:tier${tier}-$(basename "$tarball" .tar.zst)"
  docker build -t "$tag" - <<EOF
FROM scratch
ADD $(basename "$tarball") /
EOF
  echo "$tag"
}

# ── 解包 ──
cmd_unpack() {
  ensure_zstd || return 1
  local tarball="$1"
  [ -f "$tarball" ] || { echo "文件不存在: $tarball" >&2; return 1; }
  zstd -dc "$tarball" | tar -xf -
}

# ── 还原指定 tier ──
cmd_restore() {
  ensure_zstd || return 1
  local tier="$1"
  local fp
  fp="$(cmd_fp "$tier")"
  local tarball="$OUTPUT_DIR/tier${tier}_${fp}.tar.zst"
  if [ -f "$tarball" ]; then
    cmd_unpack "$tarball"
    echo "已还原 tier${tier}: $tarball"
  else
    echo "未找到 tier${tier} 缓存: $tarball" >&2
    return 1
  fi
}

# ── 入口 ──
case "${1:-}" in
  fp)       cmd_fp "${2:?需要 tier 编号}" ;;
  gate)     cmd_gate "${2:?需要 tier 编号}" ;;
  pack)     cmd_pack "${2:?需要 tier 编号}" ;;
  image)    cmd_image "${2:?需要 tier 编号}" ;;
  unpack)   cmd_unpack "${2:?需要 tarball 路径}" ;;
  restore)  cmd_restore "${2:?需要 tier 编号}" ;;
  *)        echo "用法: $0 {fp|gate|pack|image|unpack|restore} [args]" >&2; exit 1 ;;
esac
