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



#
# 功能：从 OpenWrt 官方仓库借用最新 Golang / Rust 包
#       替换 ImmortalWrt 自带的旧版本
# 用法：放到 ImmortalWrt 源码根目录，执行 ./inject_golang_rust.sh
#

inject_feed() {
    local repo_url="$1"        # OpenWrt 官方 packages 仓库
    local feed_dir="$2"        # 注入目标目录
    shift 2
    local paths=("$@")         # 要拉取的子目录

    echo "🚀 从 $repo_url 拉取最新包，替换 ImmortalWrt 原有版本..."

    # 第 1 步：稀疏检出，只拉需要的目录
    git clone --filter=blob:none --sparse --depth=1 "$repo_url" temp_repo > /dev/null 2>&1
    cd temp_repo
    git sparse-checkout set "${paths[@]}" > /dev/null 2>&1
    cd ..

    # 第 2 步：逐个替换目标目录
    for p in "${paths[@]}"; do
        if [ -d "temp_repo/$p" ]; then
            local pkg_name=$(basename "$p")
            local dest_path="$feed_dir/$pkg_name"

            # ① 删除 ImmortalWrt 原有的软链接（feeds update 生成的）
            local feed_name=$(echo "$feed_dir" | cut -d'/' -f2)
            local symlink_path="package/feeds/$feed_name/$pkg_name"
            if [ -h "$symlink_path" ] || [ -d "$symlink_path" ]; then
                rm -rf "$symlink_path"
            fi

            # ② 删除 ImmortalWrt 原有包目录，用 OpenWrt 最新版覆盖
            rm -rf "$dest_path"
            cp -r "temp_repo/$p" "$dest_path"

            echo "✅ 已用 OpenWrt 最新版替换: $p -> $dest_path"
        else
            echo "⚠️  未找到目录: $p，跳过。"
        fi
    done

    # 第 3 步：清理临时仓库
    rm -rf temp_repo
}

echo "========================================="
echo "  用 OpenWrt 最新 Golang/Rust 替换 ImmortalWrt 原有包"
echo "========================================="

inject_feed \
    "https://github.com/openwrt/packages.git" \
    "feeds/packages" \
    "lang/golang" \
    "lang/rust"

echo "========================================="
echo "✅ 替换完成！运行 make menuconfig 勾选编译即可。"
echo "========================================="
