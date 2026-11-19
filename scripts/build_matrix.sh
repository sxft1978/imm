#!/bin/bash
# ============================================================
# build_matrix.sh
# 编译矩阵数据源 —— 定义所有需要编译的设备及其配置
# 输出 JSON 数组，供 GitHub Actions 工作流动态读取（fromJson 解析）
#
# 每个设备对象包含以下字段：
#   name:         编译任务的显示名称（用于日志和产物标识）
#   REPO_URL:     固件源码的 Git 仓库地址
#   REPO_BRANCH:  要克隆的分支名
#   CONFIG_FILE:  相对于配置仓库根目录的 .config 文件路径
#   DEVICE:       源码克隆后的本地目录名（也是工作目录名）
#   ARCH:         目标架构标识（用于缓存 key 区分）
#
# 新增设备：在下方 JSON 数组里追加一个 {} 对象即可，YAML 无需改动
# 删除设备：删掉对应的 {} 对象即可
# ============================================================

cat <<'EOF'
[
  {
    "name": "immortalwrt-xiaoyi-x86",
    "REPO_URL": "https://github.com/immortalwrt/immortalwrt",
    "REPO_BRANCH": "master",
    "CONFIG_FILE": "config/imm_config/xiaoyi_x86.config",
    "DEVICE": "xiaoyi_x86",
    "ARCH": "x86_64"
  },
  {
    "name": "openwrt-x86-64-2410",
    "REPO_URL": "https://github.com/openwrt/openwrt",
    "REPO_BRANCH": "openwrt-24.10",
    "CONFIG_FILE": "config/openwrt/x86_64.config",
    "DEVICE": "openwrt-x86-64",
    "ARCH": "x86_64"
  },
  {
    "name": "lede-x86-64",
    "REPO_URL": "https://github.com/coolsnowwolf/lede",
    "REPO_BRANCH": "master",
    "CONFIG_FILE": "config/lede/x86_64.config",
    "DEVICE": "lede-x86-64",
    "ARCH": "x86_64"
  },
  {
    "name": "openwrt-x86-generic",
    "REPO_URL": "https://github.com/openwrt/openwrt",
    "REPO_BRANCH": "openwrt-24.10",
    "CONFIG_FILE": "config/openwrt/x86_generic.config",
    "DEVICE": "openwrt-x86-generic",
    "ARCH": "x86"
  },
  {
    "name": "immortalwrt-r2s",
    "REPO_URL": "https://github.com/immortalwrt/immortalwrt",
    "REPO_BRANCH": "master",
    "CONFIG_FILE": "config/imm_config/r2s.config",
    "DEVICE": "immortalwrt-r2s",
    "ARCH": "aarch64_cortex-a53"
  },
  {
    "name": "lede-armvirt-64",
    "REPO_URL": "https://github.com/coolsnowwolf/lede",
    "REPO_BRANCH": "master",
    "CONFIG_FILE": "config/lede/armvirt_64.config",
    "DEVICE": "lede-armvirt-64",
    "ARCH": "aarch64_generic"
  }
]
EOF
