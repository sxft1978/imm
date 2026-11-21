#!/bin/bash
# 三层缓存脚本：指纹计算 / 门控判断 / 打包 / 还原
# 用法: cache_tiered_x86.sh <fp|gate|pack|restore|image> <tier1|tier2|tier3> [args...]
#
# 【FIX-1】所有间接引用 ${!var} 统一改为 ${!var-}，兼容 set -u，
#          避免 "unbound variable" 致命退出（原 fp/pack 均会崩）。
# 【FIX-2】TIER*_PATHS 顶层显式赋默认值，确保间接引用一定有目标。
# 【FIX-3】cmd_fp 空指纹时输出空串并 return 0，不阻断流水线。
# 【FIX-4】ensure_zstd 守卫，zstd 缺失时明确报错而非静默失败。

set -uo pipefail

# ---------- 可配置项（工作流可用 env 覆盖） ----------
OUTPUT_DIR="${OUTPUT_DIR:-$GITHUB_WORKSPACE/cache_out}"
REPO_PREFIX="${REPO_PREFIX:-ghcr.io/sxft1978/immortalwrt-x86-64}"

# 【FIX-2】三层路径定义：必须在此处顶层赋值，
#          否则 cmd_fp/cmd_pack 的间接引用会取到未定义变量。
TIER1_PATHS="${TIER1_PATHS:-staging_dir/target-* staging_dir/host}"
TIER2_PATHS="${TIER2_PATHS:-build_dir/package-*}"
TIER3_PATHS="${TIER3_PATHS:-ccache}"

# ---------- zstd 守卫 ----------
ensure_zstd() {
  if ! command -v zstd >/dev/null 2>&1; then
    echo "::error::zstd 未安装，无法进行 tier 打包/还原"
    return 1
  fi
}

# ---------- 指纹计算 ----------
cmd_fp() {
  local tier="$1"
  local paths_var="TIER${tier}_PATHS"
  # 【FIX-1】set -u 安全间接引用：目标变量不存在时用空串，不致命
  local paths="${!paths_var-}"
  # 【FIX-3】无路径配置时输出空指纹，不阻断
  [ -n "$paths" ] || { echo ""; return 0; }

  local fp_input=""
  for p in $paths; do
    if [ -e "$p" ]; then
      fp_input+="$(find "$p" -type f -exec md5sum {} \; 2>/dev/null | sort | md5sum | cut -d' ' -f1)"
    fi
  done
  echo "$fp_input" | md5sum | cut -d' ' -f1
}

# ---------- 门控判断：指纹是否变化 ----------
cmd_gate() {
  local tier="$1"
  local fp_file="$OUTPUT_DIR/.tier${tier}_fp"
  local new_fp
  new_fp="$(cmd_fp "$tier")"
  mkdir -p "$OUTPUT_DIR"

  if [ -f "$fp_file" ] && [ "$(cat "$fp_file")" = "$new_fp" ]; then
    echo "unchanged"
    return 1   # 未变化，调用方据此跳过 pack
  fi
  echo "changed"
  echo "$new_fp" > "$fp_file"
  return 0
}

# ---------- 打包 ----------
cmd_pack() {
  ensure_zstd || return 1
  local tier="$1"
  local paths_var="TIER${tier}_PATHS"
  # 【FIX-1】同样补上 '-'，这是上次漏改、会在 pack 阶段崩溃的地方
  local paths="${!paths_var-}"
  [ -n "$paths" ] || { echo "::warning::tier${tier} 无路径配置，跳过打包"; return 0; }

  local fp
  fp="$(cmd_fp "$tier")"
  mkdir -p "$OUTPUT_DIR"

  # 只打包实际存在的路径，避免 tar 因缺失路径报错
  local existing=""
  for p in $paths; do
    [ -e "$p" ] && existing+=" $p"
  done
  [ -n "$existing" ] || { echo "::warning::tier${tier} 路径均不存在，跳过打包"; return 0; }

  tar -I zstd -cf "$OUTPUT_DIR/tier${tier}-${fp}.tar.zst" $existing
  echo "$OUTPUT_DIR/tier${tier}-${fp}.tar.zst"
}

# ---------- 还原 ----------
cmd_restore() {
  ensure_zstd || return 1
  local tier="$1"
  local archive="$2"
  [ -f "$archive" ] || { echo "::error::归档不存在: $archive"; return 1; }
  tar -I zstd -xf "$archive" -C .
}

# ---------- 推送 tier 镜像（可选，用于跨分支共享） ----------
cmd_image() {
  local tier="$1"
  local pkg="${REPO_PREFIX}-tier${tier}"
  local fp
  fp="$(cmd_fp "$tier")"
  [ -n "$fp" ] || { echo "::warning::tier${tier} 指纹为空，跳过镜像推送"; return 0; }
  echo "$pkg:$fp"
}

# ---------- 入口 ----------
case "${1:-}" in
  fp)      cmd_fp      "$2" ;;
  gate)    cmd_gate    "$2" ;;
  pack)    cmd_pack    "$2" ;;
  restore) cmd_restore "$2" "$3" ;;
  image)   cmd_image   "$2" ;;
  *)
    echo "用法: $0 <fp|gate|pack|restore|image> <tier1|tier2|tier3> [args...]"
    exit 1
    ;;
esac
