#!/usr/bin/env bash
# ============================================================
# cache_tiered_x86_test.sh —— 三层缓存管理脚本（修复版）
# 子命令: fp / fp_config / fp_patches / fp_key / pull / restore_auto /
#         touchdl / gate / pack / push
# ============================================================
set -euo pipefail

# ---------- 全局配置 -------CACHE_ROOT="${CACHE_ROOT:-$GITHUB_WORKSPACE/.cache_tiered}"
SRC_DIR="${SRC_DIR:-$GITHUB_WORKSPACE/openwrt}"
CHUNK_SIZE="${CHUNK_SIZE:-2000M}"
ZSTD_LEVEL="${ZSTD_LEVEL:-3}"
REPO_PREFIX="${REPO_PREFIX:-ghcr.io/${GITHUB_REPOSITORY_OWNER}/immortalwrt-tier-cache}"
ARCH="${ARCH:-X86_64}"
CACHE_VERSION="${CACHE_VERSION:-v4}"
REF_NAME="${REF_NAME:-${GITHUB_REF_NAME:-unknown}}"

TIER1_PATHS="${TIER1_PATHS:-dl}"
TIER2_PATHS="${TIER2_PATHS:-build_dir/host build_dir/hostpkg staging_dir/host staging_dir/hostpkg}"
TIER3_PATHS="${TIER3_PATHS:-build_dir/target-x86_64_* staging_dir/target-x86_64_*}"

# ---------- 工具函数 -------log()  { echo "[$(date '+%H:%M:%S')] $*"; }
die()  { echo "::error::$*" >&2; exit 1; }

# 解析 tier 对应的路径列表
resolve_paths() {
  local tier="$1"
  case "$tier" in
    tier1) echo "$TIER1_PATHS" ;;
    tier2) echo "$TIER2_PATHS" ;;
    tier3) echo "$TIER3_PATHS" ;;
    *)     return 1 ;;
  esac
}

# 计算目录指纹（mtime + 大小）
calc_fp() {
  local tier="$1"
  local paths
  paths="$(resolve_paths "$tier")" || die "非法 tier: $tier"
  local fp=""
  local p
  for p in $paths; do
    if [ -e "$SRC_DIR/$p" ]; then
      fp+="$(find "$SRC_DIR/$p" -type f -printf '%T@ %s %p\n' 2>/dev/null | md5sum | cut -d' ' -f1)"
    else
      fp+="missing"
    fi
    fp+="|"
  done
  echo -n "$fp" | md5sum | cut -d' ' -f1
}

# ---------- 子命令实现 -------# fp: 计算 tier1 指纹并输出
cmd_fp() {
  local tier="${1:-}"
  fp="$(calc_fp "$2")" || die "fp 非法 tier: $2"
  local fp
  fp="$(calc_fp "$tier")" || die "fp 非法 tier: $tier"
  echo "fp_tier1=$fp"
  echo "fp_tier1=$fp" >> "$GITHUB_OUTPUT"
}

# fp_config: 计算配置文件指纹
cmd_fp_config() {
  local fp=""
  for f in "$GITHUB_WORKSPACE/config/imm_config/test.config" \
           "$GITHUB_WORKSPACE/feeds_config/immortalwrt.feeds.conf.default"; do
    if [ -f "$f" ]; then
      fp+="$(md5sum "$f" | cut -d' ' -f1)"
    else
      fp+="missing"
    fi
  done
  fp="$(echo -n "$fp" | md5sum | cut -d' ' -f1)"
  echo "fp_config=$fp"
  echo "fp_config=$fp" >> "$GITHUB_OUTPUT"
}

# fp_patches: 计算 diy 脚本指纹
cmd_fp_patches() {
  local fp=""
  for f in "$GITHUB_WORKSPACE/diy_script/immortalwrt_diy/diy-part1.sh" \
           "$GITHUB_WORKSPACE/diy_script/immortalwrt_diy/diy-part2.sh"; do
    if [ -f "$f" ]; then
      fp+="$(md5sum "$f" | cut -d' ' -f1)"
    else
      fp+="missing"
    fi
  done
  fp="$(echo -n "$fp" | md5sum | cut -d' ' -f1)"
  echo "fp_patches=$fp"
  echo "fp_patches=$fp" >> "$GITHUB_OUTPUT"
}

# fp_key: 组合稳定指纹 key
cmd_fp_key() {
  local cfg="${fp_config:-}"
  local pat="${fp_patches:-}"
  local arch="$ARCH"
  local ver="$CACHE_VERSION"
  local key="${arch}-${ver}-${cfg}-${pat}"
  key="$(echo -n "$key" | md5sum | cut -d' ' -f1)"
  echo "fp_key=$key"
  echo "fp_key=$key" >> "$GITHUB_OUTPUT"
}

# pull: 从 GHCR 拉取 tier 镜像并解包
cmd_pull() {
  local tier="${1:-}"
  [ -z "$tier" ] && die "pull 缺少 tier 参数"
  local paths
  paths="$(resolve_paths "$tier")" || die "pull 非法 tier: $tier"
  local img="${REPO_PREFIX}-${tier}:${ARCH}-${CACHE_VERSION}-${REF_NAME}"

  log "拉取镜像: $img"
  if ! docker pull "$img" 2>/dev/null; then
    log "镜像不存在，尝试 fallback tag: ${ARCH}-${CACHE_VERSION}"
    img="${REPO_PREFIX}-${tier}:${ARCH}-${CACHE_VERSION}"
    docker pull "$img" || { log "tier${tier} 镜像不存在，跳过"; return 0; }
  fi

  local cid
  cid="$(docker create "$img" true)"
  local p
  for p in $paths; do
    local src="/cache/$p"
    if docker cp "$cid:$src" "$SRC_DIR/$p" 2>/dev/null; then
      log "已恢复: $p"
    else
      log "容器内无 $src，跳过"
    fi
  done
  docker rm "$cid" >/dev/null 2>&1 || true
}

# restore_auto: 自动恢复缓存（tier1 已由 Actions Cache 恢复，这里处理 tier2/3）
cmd_restore_auto() {
  log "restore_auto: tier1 由 Actions Cache 处理，tier2/3 已由 pull 恢复"
  # 无需额外操作，pull 步骤已完成恢复
}

# touchdl: 更新 dl 目录时间戳
cmd_touchdl() {
  log "touchdl: 更新 dl 目录 mtime"
  [ -d "$SRC_DIR/dl" ] && find "$SRC_DIR/dl" -exec touch {} + 2>/dev/null || true
}

# gate: 检查 tier 是否有变化
cmd_gate() {
  local tier="${1:-}"
  local marker="${2:-}"
  [ -z "$tier" ] && die "gate 缺少 tier 参数"
  [ -z "$marker" ] && die "gate 缺少 marker 参数"

  local changed="0"
  if [ -f "$marker" ]; then
    local paths
    paths="$(resolve_paths "$tier")" || die "gate 非法 tier: $tier"
    local p
    for p in $paths; do
      if [ -d "$SRC_DIR/$p" ] && [ "$(find "$SRC_DIR/$p" -newer "$marker" 2>/dev/null | head -n1)" ]; then
        changed="1"
        break
      fi
    done
  else
    changed="1"
  fi

  echo "changed_tier${tier#tier}=$changed"
  echo "changed_tier${tier#tier}=$changed" >> "$GITHUB_OUTPUT"
}

# pack: 打包 tier 到指定目录
cmd_pack() {
  local tier="${1:-}"
  local outdir="${2:-}"
  [ -z "$tier" ] && die "pack 缺少 tier 参数"
  [ -z "$outdir" ] && die "pack 缺少输出目录参数"

  local paths
  paths="$(resolve_paths "$tier")" || die "pack 非法 tier: $tier"

  mkdir -p "$outdir"
  local p
  for p in $paths; do
    if [ -d "$SRC_DIR/$p" ]; then
      local name
      name="$(echo "$p" | tr '/' '_')"
      log "打包 $p -> $outdir/${name}.tar.zst"
      tar -C "$SRC_DIR" -cf - "$p" | zstd -q -$ZSTD_LEVEL -o "$outdir/${name}.tar.zst"
    fi
  done
}

# push: 推送 tier 镜像到 GHCR
cmd_push() {
  local tier="${1:-}"
  [ -z "$tier" ] && die "push 缺少 tier 参数"
  local paths
  paths="$(resolve_paths "$tier")" || die "push 非法 tier: $tier"

  local img="${REPO_PREFIX}-${tier}:${ARCH}-${CACHE_VERSION}-${REF_NAME}"
  local tmpdir
  tmpdir="$(mktemp -d)"

  log "构建镜像: $img"
  local p
  for p in $paths; do
    if [ -d "$SRC_DIR/$p" ]; then
      local name
      name="$(echo "$p" | tr '/' '_')"
      mkdir -p "$tmpdir/cache/$(dirname "$p")"
      cp -a "$SRC_DIR/$p" "$tmpdir/cache/$p"
    fi
  done

  cat > "$tmpdir/Dockerfile" <<EOF
FROM scratch
COPY cache/ /cache/
EOF

  docker build -t "$img" "$tmpdir"
  docker push "$img"
  rm -rf "$tmpdir"
  log "已推送: $img"
}

# ---------- 主入口 -------
cmd="${1:-}"
if [ -z "$cmd" ]; then
  echo "用法: $0 <fp|fp_config|fp_patches|fp_key|pull|restore_auto|touchdl|gate|pack|push> [args...]"
  exit 1
fi
shift

case "$cmd" in
  fp)           cmd_fp "$@" ;;
  fp_config)    cmd_fp_config "$@" ;;
  fp_patches)   cmd_fp_patches "$@" ;;
  fp_key)       cmd_fp_key "$@" ;;
  pull)         cmd_pull "$@" ;;
  restore_auto) cmd_restore_auto "$@" ;;
  touchdl)      cmd_touchdl "$@" ;;
  gate)         cmd_gate "$@" ;;
  pack)         cmd_pack "$@" ;;
  push)         cmd_push "$@" ;;
  *)
    echo "::error::未知子命令: $cmd"
    exit 1
    ;;
esac
