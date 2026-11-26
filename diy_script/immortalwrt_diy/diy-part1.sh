#!/bin/bash

# ==========================================================
# diy-part1.sh   Feeds注入 + 插件克隆（修正版）
# 思路：第一步把仓库固定文件(FEEDS_CONF)里的源去重追加进【克隆下来的源码】
#       第二步克隆指定第三方插件到源码 package/custom_packages
# ==========================================================

# ---- 路径变量 ----
# 仓库里你固定的那个 feeds 源清单（FEEDS_CONF 在 .yml 里定义）
SRC="${GITHUB_WORKSPACE}/${FEEDS_CONF}"
# clone 下来的源码目录（优先用 SOURCE_DIR 变量，没定义则退回 openwrt）
OPENWRT_DIR="${GITHUB_WORKSPACE}/${SOURCE_DIR:-openwrt}"
# 写入目标：源码自带的 feeds 默认配置
DST="${OPENWRT_DIR}/feeds.conf.default"

echo ">>> 仓库 feeds 清单 : $SRC"
echo ">>> 目标(源码)文件 : $DST"

if [ -z "$FEEDS_CONF" ]; then
    echo "❌ 错误：.yml 里没有定义 FEEDS_CONF 变量"
    exit 1
fi
if [ ! -f "$SRC" ]; then
    echo "❌ 错误：仓库 feeds 文件不存在: $SRC"
    exit 1
fi
if [ ! -f "$DST" ]; then
    echo "❌ 错误：源码 feeds.conf.default 不存在: $DST"
    exit 1
fi

# ==========================================================
# 第一步：把仓库 feeds 注入到【克隆下来的源码】(不污染仓库)
# ==========================================================
echo ">>> 注入前 feeds.conf.default <<<"
cat "$DST"; echo ""

while IFS= read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue
    [[ "$line" =~ ^# ]] && continue
    if grep -qF "$line" "$DST"; then
        echo "  >> [跳过] 已存在: $line"
    else
        echo "$line" >> "$DST"
        echo "  >> [注入] $line"
    fi
done < "$SRC"

echo ">>> 注入后 feeds.conf.default <<<"
cat "$DST"; echo ""

# 同步到真正生效的 feeds.conf
cp "$DST" "${OPENWRT_DIR}/feeds.conf"
echo ">>> feeds.conf 已同步 <<<"

# ==========================================================
# 第二步：克隆指定插件到源码 package/custom_packages
# ==========================================================
cd "$OPENWRT_DIR" || { echo "❌ 无法进入源码目录: $OPENWRT_DIR"; exit 1; }
mkdir -p package/custom_packages

clone_pkg() {
    local repo=$1 branch=$2 dir=$3
    if [ -d "$dir" ]; then
        echo "  >> [跳过] 目录已存在: $dir"
    else
        echo "  >> [克隆] $repo (分支:$branch)"
        git clone --depth 1 -b "$branch" "$repo" "$dir"
    fi
}

# ---------------- 🎨 主题美化类 ----------------
# clone_pkg "https://github.com/itsma1Ge/luci-theme-7dollar.git"      "main"   "package/custom_packages/luci-theme-7dollar"
# clone_pkg "https://github.com/jerrykuku/luci-theme-argon.git"       "master" "package/custom_packages/luci-theme-argon"
# clone_pkg "https://github.com/mrjoechen/luci-theme-carbon.git"      "main"   "package/custom_packages/luci-theme-carbon"
# clone_pkg "https://github.com/sirpdboy/luci-theme-kucat.git"        "main"   "package/custom_packages/luci-theme-kucat"
# clone_pkg "https://github.com/sirpdboy/luci-app-kucat-config.git"   "main"   "package/custom_packages/luci-app-kucat-config"
# clone_pkg "https://github.com/eamonxg/luci-theme-aurora.git"        "main"   "package/custom_packages/luci-theme-aurora"
# clone_pkg "https://github.com/derisamedia/luci-theme-arwi.git"      "master" "package/custom_packages/luci-theme-arwi"
# clone_pkg "https://github.com/derisamedia/luci-theme-alpha.git"     "master" "package/custom_packages/luci-theme-alpha"
# clone_pkg "https://github.com/animegasan/luci-app-alpha-config.git" "main"   "package/custom_packages/luci-app-alpha-config"
# clone_pkg "https://github.com/AngelaCooljx/luci-theme-material3.git" "main"  "package/custom_packages/luci-theme-material3"
# clone_pkg "https://github.com/anothaDev/luci-theme-vantage.git"     "master" "package/custom_packages/luci-theme-vantage"

# ---------------- 📊 网络测速类 ----------------
clone_pkg "https://github.com/sirpdboy/netspeedtest.git" "main" "package/custom_packages/netspeedtest"

# ---------------- 🌐 高级网络工具类 ----------------
clone_pkg "https://github.com/sbwml/luci-app-mosdns"     "v5"   "package/custom_packages/mosdns"
clone_pkg "https://github.com/pymumu/luci-app-smartdns.git"  "master" "package/custom_packages/luci-app-smartdns"
clone_pkg "https://github.com/timsaya/openwrt-bandix.git"     "main"   "package/custom_packages/openwrt-bandix"
clone_pkg "https://github.com/timsaya/luci-app-bandix.git"    "main"   "package/custom_packages/luci-app-bandix"
clone_pkg "https://github.com/timsaya/openwrt-bandix-plus.git" "main"  "package/custom_packages/openwrt-bandix-plus"
clone_pkg "https://github.com/timsaya/luci-app-bandix-plus.git" "main" "package/custom_packages/luci-app-bandix-plus"

# 自动修复 MosDNS 的 Makefile 路径（用 $(TOPDIR) 绝对定位，避免层级迷路）
if [ -f "package/custom_packages/mosdns/Makefile" ]; then
    sed -i 's#../../luci.mk#$(TOPDIR)/feeds/luci/luci.mk#g' "package/custom_packages/mosdns/Makefile"
fi

# ==========================================================
# 第三步：修改固件默认 LAN IP（按你的要求改为 192.168.1.129）   
#   - 想换成 192.168.1.130，把下面 LAN_IP 的值改一下即可
#   - 改的是【克隆下来的源码】里的默认配置，不动你仓库本身
# ==========================================================
# LAN_IP="192.168.1.129"        # 这里填 192.168.1.129 或 192.168.1.130
# IP_FILE="package/base-files/files/bin/config_generate"

# echo ">>> [第三步] 正在修改默认 LAN IP 为: $LAN_IP"
# if [ -f "$IP_FILE" ]; then
    # ImmortalWrt/OpenWrt 默认网关地址写在 config_generate 的 lanip 变量里
    # 精确匹配被引号/空格包裹的完整 192.168.1.1，避免误改成 129 后再叠成 12929
 #    sed -i -E "s#([\"' ])192\.168\.1\.1([\"' ])#\1$LAN_IP\2#g" "$IP_FILE"
 #    echo "  >> [完成] 已写入 $IP_FILE"
 #    grep -n "$LAN_IP" "$IP_FILE" | head -n 5 || true
# else
#     echo "  ⚠️ 未找到 $IP_FILE（源码目录结构可能不同），请手动确认默认 IP 文件路径。"
# fi

# echo ""
echo "🎉 diy-part1.sh 全部执行完毕！本地编译环境已就绪。"
