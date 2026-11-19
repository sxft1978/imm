#!/bin/bash
# ============================================================
# cache_tiered.sh
# 三级缓存管理脚本 —— 负责指纹计算、变动检测、镜像打包与还原
#
# 三级缓存体系：
#   Tier1 (dl)        : 源码包下载目录，变化最少，通过 actions/cache 存储
#   Tier2 (toolchain) : 交叉编译工具链，架构+分支维度复用，通过 actions/cache 存储
#   Tier3 (target)    : 目标设备编译产物，通过 Docker 镜像存储到 GHCR
#
# 用法：
#   cache_tiered.sh fp tier1|tier2|tier3   # 计算指纹，输出到 GITHUB_OUTPUT
#   cache_tiered.sh gate tier2|tier3       # 检测变动，输出 changed_tierN 到 GITHUB_OUTPUT
#   cache_tiered.sh pack tier3             # 打包 Tier3 产物为 Docker 镜像并推送
#   cache_tiered.sh restore auto           # 从 Tier3 镜像中还原编译进度
# ============================================================

set -uo pipefail

# ---------- 初始化环境变量 ----------
# 工作目录，与 YAML 中 env.WORKSPACE 保持一致
WORKSPACE=${WORKSPACE:-/workdir}
# 当前源码目录名（即 DEVICE 值，通过 pwd 获取）
SOURCE_DIR=$(basename "$(pwd)")
# 目标架构标识，优先从环境变量 ARCH 传入（由矩阵提供），回退到默认值
ARCH=${ARCH:-x86_64}

# 源码根目录和缓存目录
ROOT_DIR=$(pwd)
CACHE_DIR="${WORKSPACE}/cache"
mkdir -p "${CACHE_DIR}"

# ---------- 辅助函数 ----------

# 计算当前目录下所有文件的 SHA-256 短指纹（16位）
# 基于文件名+文件大小生成哈希，用于快速判断目录内容是否变化
calc_fp() {
  find . -not -path './.git/*' -type f -printf '%P %s\n' 2>/dev/null | sort | sha256sum | cut -c1-16
}

# 仅针对 stamp 目录计算指纹（用于判断 Tier3 变动）
# stamp 文件记录了每个软件包的编译完成状态，是最精准的变动检测依据
calc_fp_tier3() {
  find ./build_dir/target-* ./staging_dir/target-* -path "*/stamp/*" -type f 2>/dev/null \
    | xargs -r basename 2>/dev/null \
    | sort \
    | sha256sum \
    | cut -c1-16
}

# ---------- 子命令实现 ----------

# 1. fingerprint (fp) —— 计算指定层级的指纹并输出到 GITHUB_OUTPUT
fingerprint() {
  local tier=$1
  local fp

  if [ "$tier" = "tier1" ]; then
    # Tier1: 进入 dl 目录计算源码包指纹
    cd "${WORKSPACE}/${SOURCE_DIR}/dl"
    fp=$(calc_fp)
  elif [ "$tier" = "tier2" ]; then
    # Tier2: 在源码根目录，计算 host 工具链相关目录的指纹
    cd "${WORKSPACE}/${SOURCE_DIR}"
    fp=$(find ./build_dir/host ./build_dir/hostpkg ./staging_dir/host ./staging_dir/hostpkg \
          -type f -printf '%P %s\n' 2>/dev/null | sort | sha256sum | cut -c1-16)
  elif [ "$tier" = "tier3" ]; then
    # Tier3: 在源码根目录，计算目标设备 stamp 文件的指纹
    cd "${WORKSPACE}/${SOURCE_DIR}"
    fp=$(calc_fp_tier3)
  fi

  # 将指纹写入 GITHUB_OUTPUT，供后续步骤读取（key 命名）
  echo "fp_${tier}=${fp}" >> "$GITHUB_OUTPUT"
  echo "Fingerprint for ${tier}: ${fp}"
}

# 2. gate —— 检测指定层级是否有变动（通过 stamp 文件对比基准标记）
gate() {
  local tier=$1
  local stamp_dir
  # 基准时间标记文件，在编译工具链之前创建，用于区分新旧文件
  local marker="${WORKSPACE}/${SOURCE_DIR}/.compile_marker_base"
  local changed_count=0

  # 如果没有基准标记（首次编译），直接返回 0（无变动）
  if [ ! -f "$marker" ]; then
    echo "changed_${tier}=0" >> "$GITHUB_OUTPUT"
    exit 0
  fi

  # 根据层级确定要检测的 stamp 目录
  if [ "$tier" = "tier2" ]; then
    # Tier2 检测 host 工具链的 stamp
    stamp_dir="${WORKSPACE}/${SOURCE_DIR}/staging_dir/host/stamp"
  elif [ "$tier" = "tier3" ]; then
    # Tier3 检测目标设备的 stamp
    stamp_dir="${WORKSPACE}/${SOURCE_DIR}/build_dir/target-*/stamp"
  fi

  # 如果 stamp 目录存在，查找比基准标记更新的文件
  if [ -d "$(dirname "${stamp_dir}")" ]; then
    # 过滤掉编译过程中的噪声文件（锁文件、压缩临时文件等）
    local IGNORE_PATTERN="\.flock|\.xz|\.zstd|\.patch|\.tools_compile|\.target_prereq|\.prepare|\.configure"
    # 统计新增/更新的 stamp 文件数量（find 通配符不加引号以允许展开）
    changed_count=$(find ${stamp_dir} -newer "$marker" -type f 2>/dev/null \
      | grep -vE "${IGNORE_PATTERN}" 2>/dev/null \
      | wc -l)
  fi

  # 将变动数量写入 GITHUB_OUTPUT
  echo "changed_${tier}=${changed_count}" >> "$GITHUB_OUTPUT"

  if [ "$changed_count" -gt 0 ]; then
    echo "Tier ${tier} has ${changed_count} changed stamp(s) - will update cache"
  else
    echo "Tier ${tier} unchanged - skip cache save"
  fi
}

# 3. pack —— 将 Tier3 编译产物打包为 Docker 镜像推送到 GHCR
pack() {
  local tier=$1
  if [ "$tier" != "tier3" ]; then
    echo "pack only supports tier3" >&2
    exit 1
  fi

  cd "${WORKSPACE}/${SOURCE_DIR}"

  # 从环境变量或矩阵中读取镜像标识，回退到源码目录名
  local IMAGE="${TIER3_IMAGE:-ghcr.io/${GITHUB_REPOSITORY:-immortalwrt-cache}/${SOURCE_DIR}}"
  # 用当前提交 SHA 作为镜像标签，确保可追溯
  local TAG="${GITHUB_SHA:-$(git rev-parse HEAD 2>/dev/null || echo latest)}"

  # 打包编译产物目录（bin/packages 和 staging_dir/target-* 下的产物）
  # 这样下次恢复后，已编译的 .ipk 可以直接复用，make 会跳过这些包
  local TMPDIR
  TMPDIR=$(mktemp -d)

  # 复制 bin/packages 目录（包含所有编译好的 .ipk 包）
  if [ -d "./bin/packages" ]; then
    cp -a ./bin/packages "${TMPDIR}/bin_packages"
  fi

  # 复制 staging_dir/target-* 下的关键产物（头文件、库文件等）
  for target_dir in ./staging_dir/target-*; do
    if [ -d "$target_dir" ]; then
      local target_name
      target_name=$(basename "$target_dir")
      mkdir -p "${TMPDIR}/staging_dir/${target_name}"
      # 只复制 stamp、usr、lib、include 等关键子目录，避免体积过大
      for subdir in stamp usr lib include; do
        if [ -d "${target_dir}/${subdir}" ]; then
          cp -a "${target_dir}/${subdir}" "${TMPDIR}/staging_dir/${target_name}/"
        fi
      done
    fi
  done

  # 构建 Dockerfile，将产物目录打包进镜像
  cat > "${TMPDIR}/Dockerfile" <<'DOCKERFILE'
FROM scratch
COPY bin_packages /bin_packages
COPY staging_dir /staging_dir
DOCKERFILE

  echo "Packing Tier3 image: ${IMAGE}:${TAG}"
  docker build -t "${IMAGE}:${TAG}" "${TMPDIR}"

  # 推送镜像到 GHCR
  docker push "${IMAGE}:${TAG}"

  # 同时打 latest 标签，方便后续 pull 回退
  docker tag "${IMAGE}:${TAG}" "${IMAGE}:latest"
  docker push "${IMAGE}:latest"

  rm -rf "${TMPDIR}"
  echo "Tier3 image pushed: ${IMAGE}:${TAG}"
}

# 4. restore —— 还原自动编译进度（从 Tier3 镜像中恢复产物）
restore() {
  local mode=$1
  if [ "$mode" != "auto" ]; then
    echo "restore only supports 'auto' mode" >&2
    exit 1
  fi

  cd "${WORKSPACE}/${SOURCE_DIR}"

  # 尝试从 Tier3 镜像中恢复编译产物
  local IMAGE="${TIER3_IMAGE:-ghcr.io/${GITHUB_REPOSITORY:-immortalwrt-cache}/${SOURCE_DIR}}"
  local TAG="${GITHUB_SHA:-latest}"

  # 先尝试拉取当前 SHA 标签的镜像，失败则回退到 latest
  if ! docker pull "${IMAGE}:${TAG}" 2>/dev/null; then
    echo "Tier3 image ${TAG} not found, trying latest..."
    docker pull "${IMAGE}:latest" 2>/dev/null || {
      echo "No Tier3 image available, skipping restore"
      return 0
    }
    TAG="latest"
  fi

  # 从镜像中提取产物文件到对应目录
  local TMPDIR
  TMPDIR=$(mktemp -d)
  docker create --name cache_extract "${IMAGE}:${TAG}" >/dev/null 2>&1
  docker cp cache_extract:/bin_packages "${TMPDIR}/bin_packages" 2>/dev/null || true
  docker cp cache_extract:/staging_dir "${TMPDIR}/staging_dir" 2>/dev/null || true
  docker rm cache_extract >/dev/null 2>&1

  # 将 bin/packages 还原到对应位置
  if [ -d "${TMPDIR}/bin_packages" ]; then
    mkdir -p ./bin/packages
    cp -a "${TMPDIR}/bin_packages"/* ./bin/packages/ 2>/dev/null || true
  fi

  # 将 staging_dir/target-* 还原到对应位置
  if [ -d "${TMPDIR}/staging_dir" ]; then
    for target_dir in "${TMPDIR}/staging_dir"/*; do
      if [ -d "$target_dir" ]; then
        local target_name
        target_name=$(basename "$target_dir")
        mkdir -p "./staging_dir/${target_name}"
        cp -a "${target_dir}"/* "./staging_dir/${target_name}/" 2>/dev/null || true
      fi
    done
  fi

  rm -rf "${TMPDIR}"
  echo "Tier3 products restored from ${IMAGE}:${TAG}"
}

# ---------- 主入口 ----------
case "${1:-}" in
  fp)       fingerprint "$2" ;;
  gate)     gate "$2" ;;
  pack)     pack "$2" ;;
  restore)  restore "$2" ;;
  *)
    echo "Usage: $0 {fp|gate|pack|restore} {tier1|tier2|tier3|auto}" >&2
    exit 1
    ;;
esac
