#!/bin/bash

# ==========================================
# 第一部分：替换 grub2 编译脚本为大雕稳定版
# ==========================================
echo ">>> 正在替换 grub2 编译脚本为大雕稳定版..."

if [ -f package/boot/grub2/Makefile ]; then
  cp -f package/boot/grub2/Makefile package/boot/grub2/Makefile.bak
else
  echo ">>> 警告：package/boot/grub2/Makefile 不存在，跳过 grub2 替换。"
fi

wget -O package/boot/grub2/Makefile \
  https://raw.githubusercontent.com/coolsnowwolf/lede/master/package/boot/grub2/Makefile \
  || { echo ">>> grub2 Makefile 下载失败"; exit 1; }

echo ">>> grub2 脚本替换完成。"

# ==========================================
# 第二部分：更新 lang 语言包依赖
# ==========================================
echo ">>> 正在注入 lang 语言包源..."

echo "src-git lang_packages https://github.com/openwrt/packages.git;lang" >> feeds.conf.default

echo ">>> 正在更新并安装 lang/golang 和 lang/rust..."

./scripts/feeds update lang_packages
./scripts/feeds install -p lang_packages lang/golang lang/rust

echo ">>> 全部准备工作完成。"
# 强制取消勾选 gn 包
sed -i '/CONFIG_PACKAGE_gn=y/d' .config
