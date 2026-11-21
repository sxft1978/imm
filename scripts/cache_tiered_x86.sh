#!/bin/bash
# 三层缓存脚本（修订版2 · 与 Build_OpenWrt_TieredCache_fixed2.yml 严格配套）
# 用法: cache_tiered_x86.sh <fp|gate|pack|restore|image|touchdl> <tier1|tier2|tier3|config|patches|auto|clean> [args...]
#
# 本版相对 fixed 版的四项改动（与本轮敲定的优化清单逐条对应）：
#   I. 输入指纹：新增 fp config（.config+rules.mk+feeds.conf）与 fp_patches
#      （package/target/toolchain 下所有 .patch/.diff）两个子命令。tier2/tier3 的
#      缓存 key 改用 fp_tier1+fp_config+fp_patches 三段输入指纹拼接，机制上保证
#      "恢复的内容严格对应下载的那份源码"：源码/配置/补丁任一处不同 -> key 不同
#      -> 旧缓存不会错配取回。产物哈希 fp_tierN 仅留作归档文件名。
#   J. zstd 满核：pack 用 "zstd -T0 -3"、restore 用 "zstd -T0 -d"，解/打包提速数倍。
#      压缩级别由 ZSTD_LEVEL 控制（工作流 env 默认 3；缓存场景 3 足够，别用 10+）。
#   K. dl 时间戳回拨：restore auto 完成后把 dl/ 全部 touch 回 2000-01-01，
#      防止 Make 因"dl 比 stamp 新"触发无谓重编；make download 之后工作流再调
#      touchdl 把新下载的包也回拨。
#   L. 其余 A-H 修复（output 写回、gate 恒 0、clean 语义、真推镜像等）原样保留。
#
# 上一版（fixed）修复记录（保留备查）：
#   A. 删除文件末尾误粘贴的游离 YAML，避免每次调用以非 0 收尾。
#   B. cmd_fp 把结果写入 $GITHUB_OUTPUT（fp_tierN=...）。
#   C. cmd_gate 始终 return 0 + 写 changed_tierN=0|1。
#   D. OUTPUT_DIR 对齐 CACHE_ROOT/tiered，pack 第二参数为归档输出目录。
#   E. 所有路径相对 SRC_DIR(openwrt) 解析（脚本内部 cd 后 find/tar）。
#   F. TIER1_PATHS 默认 dl。
#   G. restore 支持 clean 语义（force_rebuild）。
#   H. cmd_image 真 docker build+push，并打 :latest。

set -uo pipefail

# ---------- 可配置项（工作流 env 覆盖） ----------
CACHE_ROOT="${CACHE_ROOT:-${GITHUB_WORKSPACE:-.}/.cache_tiered}"
SRC_DIR="${SRC_DIR:-${GITHUB_WORKSPACE:-.}/openwrt}"
# 归档目录与工作流 actions/cache 的 path 对齐：CACHE_ROOT/tiered/tierN
OUTPUT_DIR="${OUTPUT_DIR:-${CACHE_ROOT}/tiered}"
# 缓存镜像仓库前缀（与 DOCKER_IMAGE 同 owner；工作流 env 会覆盖）
REPO_PREFIX="${REPO_PREFIX:-ghcr.io/${GITHUB_REPOSITORY_OWNER:-local}/immortalwrt-tier3-cache}"

# 三层路径（相对 SRC_DIR）。工作流 env 提供 TIER1/TIER2/TIER3，此处给一致兜底。
TIER1_PATHS="${TIER1_PATHS:-dl}"
TIER2_PATHS="${TIER2_PATHS:-build_dir/host build_dir/hostpkg staging_dir/host staging_dir/hostpkg}"
TIER3_PATHS="${TIER3_PATHS:-build_dir/target-x86_64_* staging_dir/target-x86_64_*}"

# zstd 压缩级别（工作流 env 的 ZSTD_LEVEL 覆盖；缓存场景 3 足够）
ZSTD_LEVEL="${ZSTD_LEVEL:-3}"
# dl 回拨目标时间戳：2000-01-01 00:00（GNU touch 格式 [[CC]YY]MMDDhhmm）
DL_EPOCH="200001010000"

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

# dl 时间戳回拨：全部压回 2000 年，Make 不再因 dl 比 stamp 新而误重编
touch_dl() {
  if [ -d "$SRC_DIR/dl" ]; then
    find "$SRC_DIR/dl" -type f -exec touch -t "$DL_EPOCH" {} + 2>/dev/null
    echo "[dl] 时间戳已回拨到 2000-01-01（防止 Make 因 mtime 误判触发重编）"
  fi
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

# ---------- 输入指纹：编译配置（.config + rules.mk + feeds.conf） ----------
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

# ---------- 输入指纹：本地补丁（package/target/toolchain 下所有 .patch/.diff） ----------
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

# ---------- 打包：归档写到 outdir（默认 OUTPUT_DIR/tierN），zstd 满核 ----------
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

  # 【改动 J】-T0 用满所有核心压缩；级别 ZSTD_LEVEL（默认 3，缓存场景足够）
  if ! tar --use-compress-program="zstd -T0 -${ZSTD_LEVEL}" -cf "$arch" $existing; then
    echo "::error::打包失败: $arch"; return 1
  fi
  echo "$arch"
}

# ---------- 还原（指定归档），zstd 满核解压 + dl 回拨 ----------
cmd_restore() {
  ensure_zstd || return 1
  local archive="${1:-}"
  [ -n "$archive" ] || { echo "::error::restore 缺少归档路径参数"; return 1; }
  [ -f "$archive" ] || { echo "::error::归档不存在: $archive"; return 1; }
  cd "$SRC_DIR" || { echo "::error::无法进入 SRC_DIR: $SRC_DIR"; return 1; }
  tar --use-compress-program="zstd -T0 -d" -xf "$archive" -C .
  # 【改动 K】还原后立即回拨 dl 时间戳
  touch_dl
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
      tar --use-compress-program="zstd -T0 -d" -xf "$arch" -C . || { echo "::error::还原失败: $arch"; return 1; }
      found=1
    fi
  done

  # 【改动 K】全部还原完成后把 dl 回拨到 2000 年（在 marker 之前、make 之前，顺序不可反）
  touch_dl

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
  fp)
    case "$arg1" in
      tier1|tier2|tier3) cmd_fp "$arg1" ;;
      config)  cmd_fp_config ;;      # 【改动 I】编译配置输入指纹
      patches) cmd_fp_patches ;;     # 【改动 I】本地补丁输入指纹
      *) echo "用法: $0 fp <tier1|tier2|tier3|config|patches>"; exit 1 ;;
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
  touchdl) touch_dl ;;               # 【改动 K】make download 后回拨新下载包的时间戳
  image)   cmd_image "$arg1" ;;
  *)
    echo "用法: $0 <fp|gate|pack|restore|image|touchdl> <tier1|tier2|tier3|config|patches|auto|clean> [args...]"
    exit 1
    ;;
esac
