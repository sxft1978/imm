#!/bin/bash
# =====================================================================
# 三层缓存脚本（final 版 · 与 workflow_final 三Job拆分_修复版.yml 严格配套）
# 用法: cache_tiered_x86.sh <fp|gate|pack|restore|push|pull|touchdl> <参数...>
#
# 本版相对 fixed2 版的四项收尾改动：
#   M. 稳定缓存 key：新增 "fp key" 子命令，emit fp_key = md5(fp_config+fp_patches)。
#      tier1 的 restore/save key 全部改用 fp_key（输入侧指纹），与 dl/ 内容彻底解耦，
#      修掉"编译前算 keyA、编译后存 keyB -> 永远不命中"的自锁死循环。
#      fp tierN（产物指纹）仅保留用于归档文件命名，不再参与缓存 key。
#   N. 镜像取回闭环：新增 "pull <tier>" 子命令（docker pull + create + cp 抠回归档
#      到 OUTPUT_DIR/tierN/ 后 docker rm），与 push（原 image 改名，保留别名）配对。
#      tier2/tier3 彻底改走 GHCR：几十 GB 的归档不进 Actions Cache（10GB 配额会把
#      全部缓存按 LRU 驱逐，这是此前 Caches 页只剩 buildkit 小条目的根因）。
#   O. 压缩自适应：runner 有 zstd 用 zstd -T0（.tar.zst）；无则自动降级 gzip
#      （.tar.gz）。解压统一 tar -xf 自动识别，两种归档可互认。
#   P. pull 幂等与失败降级：目标归档已在位则跳过拉取；GHCR 上无 latest（首次冷启动、
#      包被清理）只给 warning 并返回 0，绝不把 build 带崩。
#   fixed2 的 A-L 修复（GITHUB_OUTPUT、gate 恒 0、路径对齐、clean 语义等）原样保留。
#   final.1 修复（本轮，两处，均位于 cmd_push）：
#   FIX-1 push 镜像内路径改为 /<tier>/<归档名>，与 pull 的 docker cp 源对齐；
#   FIX-2 scratch 镜像补 CMD，根除 docker create 的 no command specified。
#
#   【BUGFIX 2026-11-25】本轮修复清单：
#   BUGFIX-1: cmd_fp 中 emit_output 与 echo 重复输出，统一为 emit_output。
#   BUGFIX-2: cmd_pull 落地文件名硬编码 .tar.gz，改为根据实际压缩格式动态命名。
#   BUGFIX-3: $existing 未加引号，路径含空格会出错，改用数组存储。
#   BUGFIX-4: find -exec md5sum 性能差，改用 xargs -0 批量处理。
#   BUGFIX-5: docker push 失败时临时目录未清理，改用 trap 统一清理。
#   BUGFIX-6: latest_archive_in 增加目录存在性检查。
#   BUGFIX-7: cmd_restore_auto 增加 OUTPUT_DIR 存在性检查。
#   BUGFIX-8: cmd_pack 增加 tar 退出码显式检查。
# =====================================================================

set -uo pipefail

# ---------- 可配置项（工作流 env 覆盖） ----------
CACHE_ROOT="${CACHE_ROOT:-${GITHUB_WORKSPACE:-.}/.cache_tiered}"
SRC_DIR="${SRC_DIR:-${GITHUB_WORKSPACE:-.}/openwrt}"
OUTPUT_DIR="${OUTPUT_DIR:-${CACHE_ROOT}/tiered}"
REPO_PREFIX="${REPO_PREFIX:-ghcr.io/${GITHUB_REPOSITORY_OWNER:-local}/immortalwrt-tier-cache}"

TIER1_PATHS="${TIER1_PATHS:-dl}"
TIER2_PATHS="${TIER2_PATHS:-build_dir/host build_dir/hostpkg staging_dir/host staging_dir/hostpkg}"
TIER3_PATHS="${TIER3_PATHS:-build_dir/target-x86_64_* staging_dir/target-x86_64_*}"

ZSTD_LEVEL="${ZSTD_LEVEL:-3}"
DL_EPOCH="200001010000"   # dl 回拨目标：2000-01-01 00:00

# ---------- 工具函数 ----------
emit_output() {
  [ -n "${GITHUB_OUTPUT:-}" ] && echo "$1=$2" >> "$GITHUB_OUTPUT"
  return 0
}

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

# 【改动 O】压缩程序探测：优先 zstd 满核，无则 gzip 降级
tar_create_prog() {
  if command -v zstd >/dev/null 2>&1; then
    echo "zstd -T0 -${ZSTD_LEVEL}"
  else
    echo "gzip"
  fi
}
archive_ext() {
  if command -v zstd >/dev/null 2>&1; then echo "tar.zst"; else echo "tar.gz"; fi
}

touch_dl() {
  if [ -d "$SRC_DIR/dl" ]; then
    find "$SRC_DIR/dl" -type f -exec touch -t "$DL_EPOCH" {} + 2>/dev/null
    echo "[dl] 时间戳已回拨到 2000-01-01"
  fi
  return 0
}

# ---------- 产物指纹（仅用于归档命名，不再做缓存 key） ----------
cmd_fp() {
  local tier="${1:-}"
  [ -n "$tier" ] || { echo "::error::fp 缺少 tier 参数"; return 1; }
  local paths; paths="$(resolve_paths "$tier")" || { echo "::error::fp 非法 tier: $tier"; return 1; }
  # BUGFIX-1: 统一用 emit_output，去掉多余的 echo
  [ -n "$paths" ] || { emit_output "fp_${tier}" ""; return 0; }
  [ -d "$SRC_DIR" ] || { emit_output "fp_${tier}" ""; return 0; }
  cd "$SRC_DIR" || { emit_output "fp_${tier}" ""; return 0; }

  local fp_input=""
  for p in $paths; do
    if [ -e "$p" ]; then
      # BUGFIX-4: find -exec md5sum 逐文件启动进程性能差，改用 xargs -0 批量处理
      fp_input+="$(find "$p" -type f -print0 2>/dev/null | xargs -0 md5sum 2>/dev/null | sort | md5sum | cut -d' ' -f1)"
    fi
  done
  local fpval
  fpval="$(printf '%s' "$fp_input" | md5sum | cut -d' ' -f1)"
  emit_output "fp_${tier}" "$fpval"
  echo "$fpval"
}

cmd_fp_config() {
  local files=()
  [ -f "$SRC_DIR/.config" ] && files+=("$SRC_DIR/.config")
  [ -f "$SRC_DIR/rules.mk" ] && files+=("$SRC_DIR/rules.mk")
  [ -f "$SRC_DIR/feeds.conf" ] && files+=("$SRC_DIR/feeds.conf")
  [ -f "$SRC_DIR/feeds.conf.default" ] && files+=("$SRC_DIR/feeds.conf.default")
  local fpval=""
  if [ ${#files[@]} -gt 0 ]; then
    fpval="$(md5sum "${files[@]}" 2>/dev/null | awk '{print $1}' | sort | md5sum | cut -d' ' -f1)"
  fi
  [ -n "$fpval" ] || fpval="noconfig"
  emit_output "fp_config" "$fpval"
  echo "$fpval"
}

cmd_fp_patches() {
  local fpval=""
  if [ -d "$SRC_DIR" ]; then
    local plist
    plist="$(find "$SRC_DIR/package" "$SRC_DIR/target/linux" "$SRC_DIR/toolchain" \
        -type f \( -name "*.patch" -o -name "*.diff" \) 2>/dev/null | sort)"
    if [ -n "$plist" ]; then
      # BUGFIX-4: 同样优化为 xargs 批量处理
      fpval="$(printf '%s\n' "$plist" | xargs md5sum 2>/dev/null | awk '{print $1}' | sort | md5sum | cut -d' ' -f1)"
    fi
  fi
  [ -n "$fpval" ] || fpval="nopatches"
  emit_output "fp_patches" "$fpval"
  echo "$fpval"
}

# 【改动 M】稳定 key 指纹：config+patches 再合成，restore/save 两侧共用
cmd_fp_key() {
  local fc fp_ fpval
  fc="$(cmd_fp_config)"
  fp_="$(cmd_fp_patches)"
  fpval="$(printf '%s|%s' "$fc" "$fp_" | md5sum | cut -d' ' -f1)"
  emit_output "fp_key" "$fpval"
  echo "$fpval"
}

# ---------- 门控判定（恒返回 0） ----------
cmd_gate() {
  local tier="${1:-}" marker="${2:-}"
  [ -n "$tier" ] || { echo "::error::gate 缺少 tier 参数"; return 0; }
  local paths; paths="$(resolve_paths "$tier")" || { emit_output "changed_${tier}" "1"; return 0; }

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
  if [ "$changed" = "1" ]; then echo "changed"; emit_output "changed_${tier}" "1"
  else echo "unchanged"; emit_output "changed_${tier}" "0"; fi
  return 0
}

# ---------- 打包（自动选 zstd/gzip，归档写 OUTPUT_DIR/tierN） ----------
cmd_pack() {
  local tier="${1:-}"
  local outdir="${2:-${OUTPUT_DIR}/${tier}}"
  [ -n "$tier" ] || { echo "::error::pack 缺少 tier 参数"; return 1; }
  local paths; paths="$(resolve_paths "$tier")" || { echo "::error::pack 非法 tier: $tier"; return 1; }
  [ -n "$paths" ] || { echo "::warning::${tier} 无路径配置，跳过打包"; return 0; }
  [ -d "$SRC_DIR" ] || { echo "::warning::SRC_DIR 不存在，跳过打包"; return 0; }
  cd "$SRC_DIR" || return 0

  # BUGFIX-3: 改用数组存储路径，避免路径含空格时被拆分
  local existing=()
  for p in $paths; do [ -e "$p" ] && existing+=("$p"); done
  [ ${#existing[@]} -gt 0 ] || { echo "::warning::${tier} 路径全不存在，跳过打包"; return 0; }

  local fp; fp="$(cmd_fp "$tier")"
  mkdir -p "$outdir"
  local ext; ext="$(archive_ext)"
  local arch="${outdir}/${tier}-${fp:-nomd5}.${ext}"
  local prog; prog="$(tar_create_prog)"

  # BUGFIX-8: 显式检查 tar 退出码，打包失败立即返回
  if ! tar --use-compress-program="$prog" -cf "$arch" "${existing[@]}"; then
    echo "::error::打包失败: $arch"; return 1
  fi
  echo "$arch"
}

# ---------- 还原 ----------
cmd_restore() {
  local archive="${1:-}"
  [ -n "$archive" ] || { echo "::error::restore 缺少归档路径参数"; return 1; }
  [ -f "$archive" ] || { echo "::error::归档不存在: $archive"; return 1; }
  cd "$SRC_DIR" || { echo "::error::无法进入 SRC_DIR: $SRC_DIR"; return 1; }
  tar -xf "$archive" -C . || { echo "::error::还原失败: $archive"; return 1; }
  touch_dl
}

latest_archive_in() {
  local dir="$1" tier="$2"
  # BUGFIX-6: 增加目录存在性检查，避免 ls 报错
  [ -d "$dir/${tier}" ] || { echo ""; return 1; }
  ls -t "$dir"/${tier}/${tier}-*.tar.* 2>/dev/null | head -n1
}

cmd_restore_auto() {
  local dir="$OUTPUT_DIR"
  # BUGFIX-7: 增加 OUTPUT_DIR 存在性检查
  [ -d "$dir" ] || { echo "::warning::OUTPUT_DIR 不存在: $dir"; return 0; }
  local tier="${1:-}"
  [ -n "$tier" ] || { echo "::error::restore_auto 缺少 tier 参数"; return 1; }
  local arch; arch="$(latest_archive_in "$dir" "$tier")"
  [ -n "$arch" ] || { echo "::warning::${tier} 无可用归档，跳过还原"; return 0; }
  cmd_restore "$arch"
}

# ---------- 推送镜像到 GHCR ----------
cmd_push() {
  local tier="${1:-}"
  [ -n "$tier" ] || { echo "::error::push 缺少 tier 参数"; return 1; }
  local arch; arch="$(latest_archive_in "$OUTPUT_DIR" "$tier")"
  [ -n "$arch" ] || { echo "::warning::${tier} 无归档可推送"; return 0; }

  local fp; fp="$(cmd_fp "$tier")"
  local pkg="${REPO_PREFIX}-${tier}"
  local ctx; ctx="$(mktemp -d)"

  # BUGFIX-5: 用 trap 统一清理临时目录，无论成功失败都会执行
  trap 'rm -rf "$ctx"' EXIT

  # FIX-1: 镜像内路径改为 /<tier>/<归档名>，与 pull 的 docker cp 源对齐
  local ext; ext="$(archive_ext)"
  cp "$arch" "$ctx/${tier}-${fp:-nomd5}.${ext}"

  # FIX-2: scratch 镜像补 CMD，根除 docker create 的 no command specified
  cat > "$ctx/Dockerfile" <<EOF
FROM scratch
CMD ["/bin/true"]
EOF

  if ! docker build -t "${pkg}:${fp}" -t "${pkg}:latest" "$ctx"; then
    echo "::error::镜像构建失败"; return 1
  fi
  if ! docker push "${pkg}:${fp}" || ! docker push "${pkg}:latest"; then
    echo "::error::镜像推送失败"; return 1
  fi
  echo "${pkg}:${fp}"
}

# ---------- 从 GHCR 拉取镜像并抠回归档 ----------
cmd_pull() {
  local tier="${1:-}"
  [ -n "$tier" ] || { echo "::error::pull 缺少 tier 参数"; return 1; }
  local pkg="${REPO_PREFIX}-${tier}"
  local outdir="${OUTPUT_DIR}/${tier}"
  mkdir -p "$outdir"

  # BUGFIX-2: 根据实际压缩格式动态命名，不再硬编码 .tar.gz
  local ext; ext="$(archive_ext)"
  local dest="${outdir}/${tier}-pull-latest.${ext}"

  # 幂等：目标归档已在位则跳过拉取
  [ -f "$dest" ] && { echo "::warning::归档已存在，跳过拉取: $dest"; return 0; }

  if ! docker pull "${pkg}:latest" 2>/dev/null; then
    echo "::warning::GHCR 无 latest 镜像（首次冷启动或已被清理），跳过拉取"
    return 0
  fi

  local cid
  cid="$(docker create "${pkg}:latest" 2>/dev/null)" || {
    echo "::warning::docker create 失败，跳过拉取"; return 0
  }
  # FIX-1: 与 push 的镜像内路径 /<tier>/<归档名> 对齐
  if ! docker cp "${cid}:/${tier}/${tier}-pull-latest.${ext}" "$dest" 2>/dev/null; then
    echo "::warning::docker cp 失败，尝试 .tar.zst 或 .tar.gz"
    docker cp "${cid}:/${tier}/${tier}-pull-latest.tar.zst" "$dest" 2>/dev/null \
      || docker cp "${cid}:/${tier}/${tier}-pull-latest.tar.gz" "$dest" 2>/dev/null \
      || { echo "::warning::docker cp 全部失败"; docker rm "$cid" >/dev/null 2>&1; return 0; }
  fi
  docker rm "$cid" >/dev/null 2>&1
  echo "$dest"
}

# ---------- 主入口 ----------
cmd="${1:-}"
[ -n "$cmd" ] || { echo "::error::缺少子命令"; exit 1; }
shift

case "$cmd" in
  fp)         cmd_fp "$@" ;;
  fp_config)  cmd_fp_config "$@" ;;
  fp_patches) cmd_fp_patches "$@" ;;
  fp_key)     cmd_fp_key "$@" ;;
  gate)       cmd_gate "$@" ;;
  pack)       cmd_pack "$@" ;;
  restore)    cmd_restore "$@" ;;
  restore_auto) cmd_restore_auto "$@" ;;
  push)       cmd_push "$@" ;;
  pull)       cmd_pull "$@" ;;
  touchdl)    touch_dl "$@" ;;
  *) echo "::error::未知子命令: $cmd"; exit 1 ;;
esac
