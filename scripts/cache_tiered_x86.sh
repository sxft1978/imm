#!/bin/bash
# 三层缓存脚本（修订版 · 与 Build_OpenWrt_TieredCache_fixed2.yml 严格配套）
# 用法: cache_tiered_x86.sh <fp|gate|pack|restore|image> <tier1|tier2|tier3|auto|clean> [args...]
#
# 本版相对原脚本的修复（与上一轮排查逐条对应）：
#   A. 删除文件末尾误粘贴的游离 YAML（原 175-181 行），避免每次调用以非 0 收尾。
#   B. cmd_fp   把结果写入 $GITHUB_OUTPUT（fp_tierN=...），不再只 echo，工作流的
#      actions/cache key 才能拿到真实指纹。
#   C. cmd_gate 改为始终 return 0 + 写 $GITHUB_OUTPUT(changed_tierN=0|1)，并用
#      base_compilation_marker 的 mtime 判定"本层是否被重新编译过"；解决两条 gate
#      同放一个 run: 时 -e 在"未变化返回1"处中断、tier3 不被判定的问题。
#   D. OUTPUT_DIR 对齐到 CACHE_ROOT/tiered（与工作流 actions/cache 的 path 同一目录），
#      pack 的第二参数被真正用作归档输出目录（原脚本忽略它）。
#   E. 所有路径相对 SRC_DIR(openwrt) 解析：脚本内部 cd "$SRC_DIR" 后再 find/tar，
#      解决"步骤在仓库根目录跑、路径却是裸相对 openwrt 内子目录"导致全部落空。
#   F. TIER1_PATHS 默认 dl（下载包），补上工作流从未定义、原脚本却当 staging 用的错配。
#   G. restore 新增 clean 语义（force_rebuild 传 clean 时跳过还原），不再报"缺归档路径"。
#   H. cmd_image 由"假 echo"改为真正 docker build+push，并额外打 :latest。

set -uo pipefail

# ---------- 可配置项（工作流 env 覆盖） ----------
CACHE_ROOT="${CACHE_ROOT:-${GITHUB_WORKSPACE:-.}/.cache_tiered}"
SRC_DIR="${SRC_DIR:-${GITHUB_WORKSPACE:-.}/openwrt}"
# 归档目录与工作流 actions/cache 的 path 对齐：CACHE_ROOT/tiered/tierN
OUTPUT_DIR="${OUTPUT_DIR:-${CACHE_ROOT}/tiered}"
# 缓存镜像仓库前缀（与 DOCKER_IMAGE 同 owner；工作流 env 会覆盖）
REPO_PREFIX="${REPO_PREFIX:-ghcr.io/${GITHUB_REPOSITORY_OWNER:-local}/immortalwrt-tier3-cache}"

# 三层路径（相对 SRC_DIR）。工作流 env 提供 TIER2/TIER3，此处给一致兜底并补 TIER1。
TIER1_PATHS="${TIER1_PATHS:-dl}"
TIER2_PATHS="${TIER2_PATHS:-build_dir/host build_dir/hostpkg staging_dir/host staging_dir/hostpkg}"
TIER3_PATHS="${TIER3_PATHS:-build_dir/target-x86_64_* staging_dir/target-x86_64_*}"

# ---------- 工具函数 ----------
# 把 key=value 写入 GitHub Actions output（本地无 GITHUB_OUTPUT 时静默跳过）
emit_output() {
  [ -n "${GITHUB_OUTPUT:-}" ] && echo "$1=$2" >> "$GITHUB_OUTPUT"
  return 0
}

# 取某层的路径变量（相对 SRC_DIR 的 glob 串）
resolve_paths() {
  local tier="$1" var
  case "$tier" in
    tier1|1) var="TIER1_PATHS" ;;
    tier2|2) var="TIER2_PATHS" ;;
    tier3|3) var="TIER3_PATHS" ;;
    *) echo ""; return 1 ;;
  esac
  echo "${!var-}"
}

ensure_zstd() {
  command -v zstd >/dev/null 2>&1 || { echo "::error::zstd 未安装，无法进行 tier 打包/还原"; return 1; }
  return 0
}

# ---------- 指纹计算（cd 到 SRC_DIR 后基于真实文件） ----------
cmd_fp() {
  local tier="${1:-}"
  [ -n "$tier" ] || { echo "::error::fp 缺少 tier 参数"; return 1; }

  local paths; paths="$(resolve_paths "$tier")" || { echo "::error::fp 非法 tier: $tier"; return 1; }
  [ -n "$paths" ] || { emit_output "fp_${tier}" ""; echo ""; return 0; }

  [ -d "$SRC_DIR" ] || { emit_output "fp_${tier}" ""; echo ""; return 0; }
  cd "$SRC_DIR" || { emit_output "fp_${tier}" ""; echo ""; return 0; }

  local fp_input=""
  for p in $paths; do            # 不加引号 -> 触发 glob 展开（target-x86_64_* 等）
    if [ -e "$p" ]; then
      fp_input+="$(find "$p" -type f -exec md5sum {} \; 2>/dev/null | sort | md5sum | cut -d' ' -f1)"
    fi
  done

  local fpval
  fpval="$(printf '%s' "$fp_input" | md5sum | cut -d' ' -f1)"
  emit_output "fp_${tier}" "$fpval"
  echo "$fpval"
}

# ---------- 门控判定：本层是否有比 marker 更新的产物 ----------
# 始终 return 0；把 changed_tierN=1/0 写进 output，供 save 步骤的 if 使用。
cmd_gate() {
  local tier="${1:-}"
  local marker="${2:-}"
  [ -n "$tier" ] || { echo "::error::gate 缺少 tier 参数"; return 0; }

  local paths; paths="$(resolve_paths "$tier")" || { emit_output "changed_${tier}" "1"; return 0; }

  # marker 不存在（首次/纯净编译）-> 保守判"已变化"，确保存一次缓存
  if [ -z "$marker" ] || [ ! -e "$marker" ]; then
    echo "changed (no marker)"; emit_output "changed_${tier}" "1"; return 0
  fi

  [ -d "$SRC_DIR" ] || { echo "changed (no src)"; emit_output "changed_${tier}" "1"; return 0; }
  cd "$SRC_DIR" || { emit_output "changed_${tier}" "1"; return 0; }

  local changed=0
  for p in $paths; do
    [ -e "$p" ] || continue
    if [ -n "$(find "$p" -type f -newer "$marker" -print -quit 2>/dev/null)" ]; then
      changed=1; break
    fi
  done

  if [ "$changed" = "1" ]; then
    echo "changed"; emit_output "changed_${tier}" "1"
  else
    echo "unchanged"; emit_output "changed_${tier}" "0"
  fi
  return 0
}

# ---------- 打包：归档写到 outdir（默认 OUTPUT_DIR/tierN） ----------
cmd_pack() {
  ensure_zstd || return 1
  local tier="${1:-}"
  local outdir="${2:-${OUTPUT_DIR}/${tier}}"
  [ -n "$tier" ] || { echo "::error::pack 缺少 tier 参数"; return 1; }

  local paths; paths="$(resolve_paths "$tier")" || { echo "::error::pack 非法 tier: $tier"; return 1; }
  [ -n "$paths" ] || { echo "::warning::${tier} 无路径配置，跳过打包"; return 0; }

  [ -d "$SRC_DIR" ] || { echo "::warning::SRC_DIR 不存在，跳过打包"; return 0; }
  cd "$SRC_DIR" || return 0

  local existing=""
  for p in $paths; do
    [ -e "$p" ] && existing+=" $p"
  done
  [ -n "$existing" ] || { echo "::warning::${tier} 路径全不存在，跳过打包"; return 0; }

  local fp; fp="$(cmd_fp "$tier")"
  mkdir -p "$outdir"
  local arch="${outdir}/${tier}-${fp:-nomd5}.tar.zst"

  if ! tar -I zstd -cf "$arch" $existing; then
    echo "::error::打包失败: $arch"; return 1
  fi
  echo "$arch"
}

# ---------- 还原（指定归档） ----------
cmd_restore() {
  ensure_zstd || return 1
  local archive="${1:-}"
  [ -n "$archive" ] || { echo "::error::restore 缺少归档路径参数"; return 1; }
  [ -f "$archive" ] || { echo "::error::归档不存在: $archive"; return 1; }
  cd "$SRC_DIR" || { echo "::error::无法进入 SRC_DIR: $SRC_DIR"; return 1; }
  tar -I zstd -xf "$archive" -C .
}

# ---------- 自动还原：扫描 OUTPUT_DIR 下各 tier 的最新归档 ----------
cmd_restore_auto() {
  ensure_zstd || return 1
  local dir="$OUTPUT_DIR"
  [ -d "$dir" ] || { echo "::warning::$dir 不存在，冷启动编译"; return 0; }
  [ -d "$SRC_DIR" ] || { echo "::warning::SRC_DIR 不存在，跳过还原"; return 0; }
  cd "$SRC_DIR" || return 0

  local found=0
  for tier in tier1 tier2 tier3; do
    local arch
    arch="$(ls -t "$dir"/${tier}/${tier}-*.tar.zst 2>/dev/null | head -n1)"
    if [ -n "$arch" ] && [ -f "$arch" ]; then
      echo "还原 $arch ..."
      tar -I zstd -xf "$arch" -C . || { echo "::error::还原失败: $arch"; return 1; }
      found=1
    fi
  done

  [ "$found" = "1" ] || echo "::warning::未发现任何 tier 归档，冷启动编译"
  return 0
}

# ---------- clean：force_rebuild 纯净重编，不还原任何缓存 ----------
cmd_restore_clean() {
  echo "force_rebuild=clean：跳过缓存还原，执行纯净编译"
  return 0
}

# ---------- 真推送：把 tierN 归档封装成 scratch 镜像 build+push ----------
cmd_image() {
  local tier="${1:-}"
  [ -n "$tier" ] || { echo "::error::image 缺少 tier 参数"; return 1; }

  local arch
  arch="$(ls -t "${OUTPUT_DIR}/${tier}/${tier}-"*.tar.zst 2>/dev/null | head -n1)"
  [ -n "$arch" ] || { echo "::warning::未找到 ${tier} 归档，跳过镜像推送"; return 0; }

  local fp; fp="$(basename "$arch" .tar.zst)"; fp="${fp#${tier}-}"
  local pkg="${REPO_PREFIX}-${tier}"
  local ctx; ctx="$(mktemp -d)"
  cp "$arch" "$ctx/archive.tar.zst"
  printf 'FROM scratch\nCOPY archive.tar.zst /%s\n' "$tier" > "$ctx/Dockerfile"

  echo "构建并推送 ${pkg}:${fp} 与 ${pkg}:latest"
  docker build -t "${pkg}:${fp}" -t "${pkg}:latest" "$ctx" || { echo "::error::镜像构建失败"; rm -rf "$ctx"; return 1; }
  docker push "${pkg}:${fp}"   || { echo "::error::镜像推送失败(指定标签)"; rm -rf "$ctx"; return 1; }
  docker push "${pkg}:latest"  || { echo "::warning::镜像推送失败(latest)"; }
  rm -rf "$ctx"
  echo "${pkg}:${fp}"
}

# ---------- 入口（参数全部给默认值，set -u 下不再因 $2/$3 未传而崩） ----------
cmd_name="${1:-}"
arg1="${2:-}"
arg2="${3:-}"

case "$cmd_name" in
  fp)      cmd_fp "$arg1" ;;
  gate)    cmd_gate "$arg1" "$arg2" ;;
  pack)    cmd_pack "$arg1" "$arg2" ;;
  restore)
    case "$arg1" in
      auto)  cmd_restore_auto ;;
      clean) cmd_restore_clean ;;
      *)     cmd_restore "$arg1" "$arg2" ;;
    esac
    ;;
  image)   cmd_image "$arg1" ;;
  *)
    echo "用法: $0 <fp|gate|pack|restore|image> <tier1|tier2|tier3|auto|clean> [args...]"
    exit 1
    ;;
esac
