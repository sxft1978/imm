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
  [ -n "$paths" ] || { emit_output "fp_${tier}" ""; echo ""; return 0; }
  [ -d "$SRC_DIR" ] || { emit_output "fp_${tier}" ""; echo ""; return 0; }
  cd "$SRC_DIR" || { emit_output "fp_${tier}" ""; echo ""; return 0; }

  local fp_input=""
  for p in $paths; do
    if [ -e "$p" ]; then
      fp_input+="$(find "$p" -type f -exec md5sum {} \; 2>/dev/null | sort | md5sum | cut -d' ' -f1)"
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

  local existing=""
  for p in $paths; do [ -e "$p" ] && existing+=" $p"; done
  [ -n "$existing" ] || { echo "::warning::${tier} 路径全不存在，跳过打包"; return 0; }

  local fp; fp="$(cmd_fp "$tier")"
  mkdir -p "$outdir"
  local ext; ext="$(archive_ext)"
  local arch="${outdir}/${tier}-${fp:-nomd5}.${ext}"
  local prog; prog="$(tar_create_prog)"

  if ! tar --use-compress-program="$prog" -cf "$arch" $existing; then
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
  ls -t "$dir"/${tier}/${tier}-*.tar.* 2>/dev/null | head -n1
}

cmd_restore_auto() {
  local dir="$OUTPUT_DIR"
  [ -d "$dir" ] || { echo "::warning::$dir 不存在，冷启动编译"; return 0; }
  [ -d "$SRC_DIR" ] || { echo "::warning::SRC_DIR 不存在，跳过还原"; return 0; }
  cd "$SRC_DIR" || return 0

  local found=0
  for tier in tier1 tier2 tier3; do
    local arch
    arch="$(latest_archive_in "$dir" "$tier")"
    if [ -n "$arch" ] && [ -f "$arch" ]; then
      echo "还原 $arch ..."
      tar -xf "$arch" -C . || { echo "::error::还原失败: $arch"; return 1; }
      found=1
    fi
  done
  touch_dl
  [ "$found" = "1" ] || echo "::warning::未发现任何 tier 归档，冷启动编译"
  return 0
}

cmd_restore_clean() {
  echo "force_rebuild=clean：跳过缓存还原，执行纯净编译"
  return 0
}

# ---------- push：归档封装成 scratch 镜像并推送（原 image，保留别名） ----------
cmd_push() {
  local tier="${1:-}"
  [ -n "$tier" ] || { echo "::error::push 缺少 tier 参数"; return 1; }
  command -v docker >/dev/null 2>&1 || { echo "::error::docker 不可用，无法推送 ${tier} 镜像"; return 1; }

  local arch
  arch="$(latest_archive_in "$OUTPUT_DIR" "$tier")"
  [ -n "$arch" ] || { echo "::warning::未找到 ${tier} 归档，跳过镜像推送"; return 0; }

  local fp pkg ctx
  fp="$(basename "$arch")"; fp="${fp#${tier}-}"; fp="${fp%.tar.*}"
  pkg="${REPO_PREFIX}-${tier}"
  ctx="$(mktemp -d)"
  cp "$arch" "$ctx/archive.tar.zst" 2>/dev/null || cp "$arch" "$ctx/archive.tar.gz"
  local iname="archive.tar.zst"; [ -f "$ctx/archive.tar.gz" ] && iname="archive.tar.gz"
  # [FIX-1] 镜像内文件落地路径必须是 /<tier>/<归档名>，与 cmd_pull 的
  #         docker cp "${cname}:/${tier}/archive.tar.zst" 完全对齐；旧版写成
  #         COPY ... /tierN（文件直接落在根），导致 pull 端 cp 永远取不到归档。
  # [FIX-2] scratch 镜像无 CMD/ENTRYPOINT 时 docker create 报 "no command specified"
  #         （截图里 tier2/3 报错根因）。补 CMD 仅为满足 create 参数校验，不实际执行。
  printf 'FROM scratch\nCOPY %s /%s/%s\nCMD ["/%s/%s"]\n' "$iname" "$tier" "$iname" "$tier" "$iname" > "$ctx/Dockerfile"

  echo "构建并推送 ${pkg}:${fp} 与 ${pkg}:latest"
  docker build -t "${pkg}:${fp}" -t "${pkg}:latest" "$ctx" || { echo "::error::镜像构建失败"; rm -rf "$ctx"; return 1; }
  docker push "${pkg}:${fp}"   || { echo "::error::镜像推送失败(指定标签)"; rm -rf "$ctx"; return 1; }
  docker push "${pkg}:latest"  || echo "::warning::镜像推送失败(latest)"
  rm -rf "$ctx"
  emit_output "pushed_${tier}" "${pkg}:${fp}"
  echo "${pkg}:${fp}"
}

# ---------- 【改动 N】pull：从 GHCR 拉回归档到 OUTPUT_DIR/tierN/ ----------
# 目标归档已在位（同 key 的 Actions Cache 命中、或本次已拉过）则跳过。
# 拉不到（冷启动 / latest 被清理 / 网络抖动）只 warning 返回 0，让编译照常冷启动。
cmd_pull() {
  local tier="${1:-}"
  [ -n "$tier" ] || { echo "::error::pull 缺少 tier 参数"; return 1; }
  command -v docker >/dev/null 2>&1 || { echo "::error::docker 不可用，无法拉取 ${tier} 镜像"; return 1; }

  local pkg="${REPO_PREFIX}-${tier}"
  if [ -n "$(latest_archive_in "$OUTPUT_DIR" "$tier")" ]; then
    echo "${tier} 归档已在位（Actions Cache 命中或已拉取），跳过 GHCR 拉取"
    return 0
  fi

  if ! docker pull "${pkg}:latest" >/dev/null 2>&1; then
    echo "::warning::GHCR 上没有 ${pkg}:latest（首次运行或包被清理），本次冷启动"
    return 0
  fi

  local cname="${tier}-pull-$$"
  docker create --name "$cname" "${pkg}:latest" >/dev/null || { echo "::warning::create 失败，冷启动"; return 0; }
  mkdir -p "${OUTPUT_DIR}/${tier}"
  # 落地名固定为 tierN-pull-latest.tar.gz（扩展名仅占位；push 端 zstd/gzip 皆有可能，
  # restore 端统一用 tar -xf 自动识别，不依赖扩展名）
  local dest="${OUTPUT_DIR}/${tier}/${tier}-pull-latest.tar.gz"
  if docker cp "${cname}:/${tier}/archive.tar.zst" "$dest" 2>/dev/null \
     || docker cp "${cname}:/${tier}/archive.tar.gz" "$dest" 2>/dev/null; then
    docker rm -f "$cname" >/dev/null 2>&1
    echo "${tier} 已从 GHCR 拉回: $dest"
    return 0
  fi
  rm -f "$dest"
  docker rm -f "$cname" >/dev/null 2>&1
  echo "::warning::docker cp 未取到归档，本次冷启动"
  return 0
}

# ---------- 入口 ----------
cmd_name="${1:-}"; arg1="${2:-}"; arg2="${3:-}"

case "$cmd_name" in
  fp)
    case "$arg1" in
      tier1|tier2|tier3) cmd_fp "$arg1" ;;
      config)  cmd_fp_config ;;
      patches) cmd_fp_patches ;;
      key)     cmd_fp_key ;;          # 【改动 M】
      *) echo "用法: $0 fp <tier1|tier2|tier3|config|patches|key>"; exit 1 ;;
    esac
    ;;
  gate)    cmd_gate "$arg1" "$arg2" ;;
  pack)    cmd_pack "$arg1" "$arg2" ;;
  restore)
    case "$arg1" in
      auto)  cmd_restore_auto ;;
      clean) cmd_restore_clean ;;
      *)     cmd_restore "$arg1" "$arg2" ;;
    esac
    ;;
  touchdl) touch_dl ;;
  push)    cmd_push "$arg1" ;;
  image)   cmd_push "$arg1" ;;        # 向后兼容别名
  pull)    cmd_pull "$arg1" ;;        # 【改动 N】
  *)
    echo "用法: $0 <fp|gate|pack|restore|push|pull|touchdl> <参数...>"
    exit 1
    ;;
esac
