#!/bin/bash

# ==========================================
# 第一部分：替换 grub2 编译脚本为大雕稳定版
# ==========================================
#echo ">>> 正在替换 grub2 编译脚本为大雕稳定版..."

#if [ -f package/boot/grub2/Makefile ]; then
#  cp -f package/boot/grub2/Makefile package/boot/grub2/Makefile.bak
#else
#  echo ">>> 警告：package/boot/grub2/Makefile 不存在，跳过 grub2 替换。"
#fi

#wget -O package/boot/grub2/Makefile \
#  https://raw.githubusercontent.com/coolsnowwolf/lede/master/package/boot/grub2/Makefile \
#  || { echo ">>> grub2 Makefile 下载失败"; exit 1; }

#echo ">>> grub2 脚本替换完成。"

echo "========================================="
echo "  开始自动配置并安装 Lang (Golang/Rust)"
echo "========================================="

# 处理 feeds.conf 路径
if [ ! -f "feeds.conf" ]; then
    echo ">>> 未找到 feeds.conf，正在使用 feeds.conf.default 生成..."
    cp feeds.conf.default feeds.conf
    echo ">>> feeds.conf 生成成功。"
else
    echo ">>> 检测到已存在 feeds.conf，直接沿用当前配置。"
fi

# 检查并注入正确的 lang_packages 源（防止重复添加）
if ! grep -q "src-git lang_packages" feeds.conf; then
    echo ">>> 正在向 feeds.conf 注入 lang_packages 源..."
    echo "src-git lang_packages https://github.com/openwrt/packages.git" >> feeds.conf
    echo ">>> 注入完成。"
else
    echo "⚠️ feeds.conf 中已存在 lang_packages 源，跳过重复注入。"
fi
cat -A feeds.conf

# 更新所有软件源（使用 -a 批量更新）
echo ">>> 正在更新所有软件源 (feeds update -a)，请耐心等待..."
./scripts/feeds update -a

# 5. 安装指定的包
echo ">>> 正在安装 lang/golang 和 lang/rust..."
./scripts/feeds install lang/golang lang/rust

echo "========================================="
echo "✅ 全部操作完成！"
echo "========================================="
echo "你现在可以直接运行 ./scripts/feeds install -a 安装所有包，"
echo "或者运行 make menuconfig 并在菜单中搜索 'golang' 和 'rust' 进行勾选编译。"
