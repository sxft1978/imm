#!/bin/bash
# =========================================
# 自动配置并安装 Lang (Golang/Rust)
# =========================================
echo "========================================="
echo "  开始自动配置并安装 Lang (Golang/Rust)"
echo "========================================="

# 确保 feeds.conf 存在
if [ ! -f "feeds.conf" ]; then
    echo ">>> 未找到 feeds.conf，正在使用 feeds.conf.default 生成..."
    cp "feeds.conf.default" "feeds.conf"
    echo ">>> feeds.conf 生成成功。"
else
    echo ">>> 检测到已存在 feeds.conf，直接沿用当前配置。"
fi

# 确保 packages 源存在（golang 和 rust 都在这个仓库中）
if ! grep -q "src-git packages" feeds.conf; then
    echo "src-git packages https://github.com/openwrt/packages.git" >> feeds.conf
    echo ">>> 已添加 packages 源。"
else
    echo ">>> packages 源已存在，跳过。"
fi

# 移除错误的 my_golang / my_rust 源（如果存在）
sed -i '/my_golang/d; /my_rust/d' feeds.conf

# =========================================
# 注入函数：从指定仓库拉取并注入包
# =========================================
inject_feed() {
    local feed_name="$1"
    local feed_url="$2"
    local feed_dir="feeds/$feed_name"
    local fallback_time=$(date +%s)

    echo ""
    echo ">>> 开始处理 $feed_name 源..."

    # 清理旧目录
    rm -rf temp_repo
    mkdir -p temp_repo

    # 克隆仓库（浅克隆，只拉最新）
    git clone --depth 1 "$feed_url" temp_repo 2>/dev/null || {
        echo "❌ 克隆 $feed_url 失败，跳过 $feed_name。"
        return 1
    }

    # 确保目标目录存在
    mkdir -p "$feed_dir"

    # 遍历仓库中的 lang 目录
    for p in lang/*/; do
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

        # 4. 提取文件实时时间戳，失败则用仓库 log -1 commit 时间
        local file_time=$(cd temp_repo && git log -1 --format=%cd --date=unix -- "$p" 2>/dev/null)
        [ -z "$file_time" ] && file_time="$fallback_time"
        touch -d "@$file_time" "$dest_path" 2>/dev/null || true

        echo "✅ 已注入 $pkg_name -> $dest_path"
    done

    # 验证注入结果
    echo "📂 $feed_dir 目录内容："
    ls -la "$feed_dir"

    # 清理临时仓库
    rm -rf temp_repo
}

# --- 注入 OpenWrt 官方 golang 和 rust 包
inject_feed "packages" "https://github.com/openwrt/packages.git"

echo ""
echo "========================================="
echo "  Lang (Golang/Rust) 注入完成！"
echo "========================================="
