#!/bin/bash

# ===========================
# 高级脚本：带备份的稀疏克隆与注入
# ===========================

# 判断运行环境，设置补丁源目录
if [ "$GITHUB_ACTIONS" = "true" ] && [[ -n "$GITHUB_RUN_ID" ]] && [[ -n "$GITHUB_WORKFLOW" ]]; then
    PATCHES_SRC_DIR="$GITHUB_WORKSPACE"
else
    PATCHES_SRC_DIR="../OpenWrtoAction"
fi

# 清理可能存在的临时残留
rm -rf temp_repo

# 定义核心注入函数
inject_feed() {
    local repo_url="$1"
    local feed_dir="$2"
    shift 2
    local paths=("$@")

    echo "⚡ 正在从 $repo_url 极速拉取至 $feed_dir ..."

    # 1. 使用稀疏检出极速下载 (不会拉取无关代码)
    git clone --filter=blob:none --sparse --depth=1 "$repo_url" temp_repo > /dev/null 2>&1
    cd temp_repo
    git sparse-checkout set "${paths[@]}" > /dev/null 2>&1

    # 提取上游最新的 Commit 时间戳 (作为兜底时间)
    local fallback_time=$(git log -1 --format=%cd --date=unix 2>/dev/null)
    cd ..

    # 开始处理每一个指定的路径
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

            # 2. 【核心修改】清理目标目录：将旧目录重命名为 .CLOD 结尾
            if [ -d "$dest_path" ]; then
                echo "⚠️ 检测到旧目录 $dest_path，正在重命名为 .CLOD 进行备份..."
                mv "$dest_path" "${dest_path}.CLOD"
            fi

            # 3. 复制新插件到目标目录
            cp -r "temp_repo/$p" "$dest_path"

            # 4. 尝试提取文件真实时间戳，如果失败则使用整个库的 commit 时间
            local file_time=$(cd temp_repo && git log -1 --format=%cd --date=unix -- "$p" 2>/dev/null)
            if [ -z "$file_time" ]; then
                file_time=$fallback_time
            fi

            # 5. 修改时间戳，欺骗 OpenWrt 编译缓存
            find "$dest_path" -exec touch -m -d "@$file_time" {} +

            echo "✅ 已成功注入并伪装时间戳: $pkg_name (旧目录已备份为 ${pkg_name}.CLOD)"
        fi
    done

    # 清理临时中转站
    rm -rf temp_repo
}

# ===========================
# 执行注入
# ===========================

# # 1. 注入基础依赖包
inject_feed "https://github.com/openwrt/packages.git" "feeds/packages/lang" \
    "lang/golang" \
    "lang/rust"

# # 2. 注入自定义插件 (示例：注入一个第三方主题)
# inject_feed "https://github.com/jerrykuku/luci-theme-argon.git" "feeds/luci/themes" \
#     "luci-theme-argon"

echo "🎉 注入完毕，备份目录后缀为 .CLOD"
