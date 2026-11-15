#!/bin/bash
#
# Copyright (c) 2019-2025 SmallProgram <https://github.com/smallprogram>
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#
# https://github.com/smallprogram/OpenWrtAction
# File name: diy-part2.sh
# Description: OpenWrt DIY script part 2 (After Update feeds)
#

# Add patches
if [ "$GITHUB_ACTIONS" = "true" ] && [ -n "$GITHUB_RUN_ID" ] && [ -n "$GITHUB_WORKFLOW" ]; then
    PATCHES_SRC_DIR="$GITHUB_WORKSPACE"
else
    PATCHES_SRC_DIR="../mm"
fi


#------------------------------------------------------移植包---------------------------------------------------------# --- 拉取上游仓库 rm -rf temp_resp

# =================================================================
# 极速拉取并注入 Feeds 树的函数
# =================================================================
inject_feed() {
    local repo_url="$1"
    local feed_dir="$2"
    shift 2
    local paths=("$@")

    echo "🚀 正在从 $repo_url 极速拉取至 $feed_dir ..."

    # 使用稀疏检出极速下载（不会拉取无关代码）
    git clone --filter=blob:none --sparse --depth=1 "$repo_url" temp_repo > /dev/null 2>&1
    cd temp_repo
    git sparse-checkout set "${paths[@]}" > /dev/null 2>&1

    # 提取上游最新的 Commit 时间戳 (作为兜底时间)
    local fallback_time=$(git log -1 --format=%cd --date=unix 2>/dev/null)
    cd ..

    for p in "${paths[@]}"; do
        if [ -d "temp_repo/$p" ]; then
            local pkg_name=$(basename "$p")
            local dest_path="$feed_dir/$pkg_name"

            # 1. 动态清理 OpenWrt 软链接 (防止文件类型冲突)
            local feed_name=$(echo "$feed_dir" | cut -d'/' -f2)
            local symlink_path="package/feeds/$feed_name/$pkg_name"
            if [ -h "$symlink_path" ] || [ -d "$symlink_path" ]; then
                rm -rf "$symlink_path"
            fi

            # 2. 旧目录存在则改名加后缀备份，不存在则直接注入
            if [ -d "$dest_path" ]; then
                mv "$dest_path" "${dest_path}.old"
                echo "📦 旧版 ${pkg_name} 已备份为 ${pkg_name}.old"
            fi

            # 3. 注入新包
            cp -r "temp_repo/$p" "$dest_path"

            # 4. 尝试提取文件真实时间戳，如果失败则使用整个库的 commit 时间
            local file_time=$(cd temp_repo && git log -1 --format=%cd --date=unix -- "$p" 2>/dev/null)
            [ -z "$file_time" ] && file_time="$fallback_time"
            touch -d "@$file_time" "$dest_path" 2>/dev/null || true

            echo "✅ 已注入 $pkg_name -> $dest_path"
        fi
    done

    # 验证注入结果
    echo "📂 $feed_dir 目录内容："
    ls -la "$feed_dir"

    # 清理临时仓库
    rm -rf temp_repo
}

# --- 注入 OpenWrt 官方 golang 和 rust 包 inject_feed "https://github.com/openwrt/packages.git" "feeds/packages" "lang/golang" "lang/rust"
