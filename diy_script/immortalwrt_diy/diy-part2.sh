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
# File name: diy-part2.sh
# Description: OpenWrt DIY script part 2 (After Update feeds)
#

#------------------------------------------------------移植包---------------------------------------------------------# --- 拉取上游仓库 rm -rf temp_resp

# Add patches
if [ "$GITHUB_ACTIONS" = "true" ] && [ -n "$GITHUB_RUN_ID" ] && [ -n "$GITHUB_WORKFLOW" ]; then
    PATCHES_SRC_DIR="$GITHUB_WORKSPACE"
else
    PATCHES_SRC_DIR="../imm"
fi

# =================================================================
# 极速拉取并注入 Feeds 树的函数
# =================================================================
inject_feed() {
    local repo_url="$1" feed_dir="$2"
    shift 2
    local paths=("$@")

    echo "🚀 正在从 $repo_url 极速拉取至 $feed_dir ..."

    # 稀疏检出极速下载
    git clone --filter=blob:none --sparse --depth=1 "$repo_url" temp_repo > /dev/null 2>&1
    cd temp_repo
    git sparse-checkout set "${paths[@]}" > /dev/null 2>&1
    local fallback_time=$(git log -1 --format=%cd --date=unix 2>/dev/null)
    cd ..

    local feed_name=$(echo "$feed_dir" | cut -d'/' -f2)

    for p in "${paths[@]}"; do
        [ -d "temp_repo/$p" ] || continue
        local pkg_name=$(basename "$p")
        local dest_path="$feed_dir/$pkg_name"
        local symlink_path="package/feeds/$feed_name/$pkg_name"

        # 1. 清理软链接
        [ -h "$symlink_path" ] || [ -d "$symlink_path" ] && rm -rf "$symlink_path"

        # 2. 旧目录存在则改名加后缀备份，不存在则直接注入
        if [ -d "$dest_path" ]; then
            mv "$dest_path" "${dest_path}.old"
            echo "📦 旧版 ${pkg_name} 已备份为 ${pkg_name}.old"
        fi

        # 3. 注入新包
        cp -r "temp_repo/$p" "$dest_path"

        # 4. 提取文件真实时间戳，失败则用仓库 commit 时间
        local file_time=$(cd temp_repo && git log -1 --format=%cd --date=unix -- "$p" 2>/dev/null)
        [ -z "$file_time" ] && file_time="$fallback_time"
        touch -d "@$file_time" "$dest_path" 2>/dev/null || true

        echo "✅ 已注入 $pkg_name → $dest_path"
    done

    # 验证注入结果
    echo "📂 $feed_dir 目录内容："
    ls -la "$feed_dir"

    # 清理临时仓库
    rm -rf temp_repo
}

# --- 注入 OpenWrt 官方 golang 和 rust 包 inject_feed "https://github.com/openwrt/packages.git" "feeds/packages" "lang/golang" "lang/rust"

echo "========================================="
echo "✅ 替换完成！运行 make menuconfig 勾选编译即可。"
echo "========================================="
