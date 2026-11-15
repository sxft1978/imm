#!/bin/bash
# ============================================================
# diy-part2.sh — OpenWrt 构建流程增强脚本（最终版）
# 功能：
#   1. 极速拉取并注入 golang / rust 包
#   2. 清理冲突包 open-app-filter
#   3. 注入 banIP 世界地图数据
#   4. 配置 SSH 双端口（Dropbear 2222 / OpenSSH 22）
# ============================================================

set -euo pipefail

# ---------- 路径配置 ----------
# 补丁源目录：GitHub Actions 环境使用工作区，本地编译回退到上级目录
if [ "$GITHUB_ACTIONS" = "true" ] && [ -n "$GITHUB_RUN_ID" ]; then
    PATCHES_SRC_DIR="$GITHUB_WORKSPACE"
else
    PATCHES_SRC_DIR="../OpenWrtAction"
fi

# ---------- 工具函数：注入 feed 包 ----------
# 用法：inject_feed <仓库URL> <feed目录名> <路径1> ["路径2"] ...
inject_feed() {
    # 参数校验：至少需要 仓库URL + feed目录名
    if [ $# -lt 2 ]; then
        echo "❌ 用法错误：inject_feed <repo_url> <feed_dir> <paths...>"
        return 1
    fi

    local repo_url="$1"
    local feed_dir="$2"
    shift 2
    local paths=("$@")

    local temp_repo="temp_repo"
    local fallback_time

    echo "🚀 正在从 ${repo_url} 极速拉取至 ${feed_dir} ..."

    # 清理可能残留的临时仓库
    rm -rf "$temp_repo"

    # 稀疏克隆：仅拉取目标路径，大幅减少下载量
    # --filter=blob:none 延迟下载文件内容，--depth=1 只取最新提交
    if ! git clone --filter=blob:none --sparse --depth=1 \
        "$repo_url" "$temp_repo" > /dev/null 2>&1; then
        echo "❌ 克隆 ${repo_url} 失败，请检查网络后重试"
        return 1
    fi

    # 设置稀疏检出范围，仅保留需要的路径
    git -C "$temp_repo" sparse-checkout set "${paths[@]}" > /dev/null 2>&1

    # 兜底时间戳：取仓库最近一次提交时间，防止 git log 无结果时 touch 报错
    fallback_time="$(git -C "$temp_repo" log -1 --format=%cd --date=unix 2>/dev/null || true)"
    fallback_time="${fallback_time:-$(date +%s)}"

    # 逐个注入路径
    for p in "${paths[@]}"; do
        # 仅处理稀疏检出中实际存在的路径
        if [ -d "$temp_repo/$p" ]; then
            local pkg_name
            pkg_name="$(basename "$p")"
            local dest_path="$feed_dir/$pkg_name"
            local feed_name
            feed_name="$(echo "$feed_dir" | cut -d'/' -f2)"
            local symlink_path="package/feeds/$feed_name/$pkg_name"

            echo "📦 处理 ${pkg_name} ..."

            # 清理旧软链接：package/feeds 下的链接指向旧目录，需先移除
            if [ -h "$symlink_path" ] || [ -d "$symlink_path" ]; then
                rm -rf "$symlink_path"
            fi

            # 旧目录存在则备份为 .old（带时间戳，避免覆盖上次备份）
            if [ -d "$dest_path" ]; then
                mv "$dest_path" "${dest_path}.old.$(date +%s)"
                echo "  旧版 ${pkg_name} 已备份"
            fi

            # 拷贝新包到目标目录
            cp -r "$temp_repo/$p" "$dest_path"

            # 还原文件时间戳：取该路径最近一次提交时间，保证增量编译正确
            local file_time
            file_time="$(git -C "$temp_repo" log -1 --format=%cd \
                --date=unix -- "$p" 2>/dev/null || true)"
            file_time="${file_time:-$fallback_time}"
            find "$dest_path" -exec touch -m -d "@$file_time" {} + 2>/dev/null || true

            echo "  ✅ ${pkg_name} 注入完成"
        fi
    done

    # 清理临时仓库
    rm -rf "$temp_repo"
    echo "🎉 ${feed_dir} 注入完毕"
}

# ---------- 注入 banIP 世界地图数据 ----------
# 将 world-50m.json 拷贝到 banIP LuCI 前端静态资源目录
inject_banip() {
    local banip_ui_dir="./feeds/luci/applications/luci-app-banip/htdocs/luci-static/resources/view/banip/"
    local source_file="$PATCHES_SRC_DIR/diy_script/custom_packages/banip/world-50m.json"

    echo "🌍 注入 banIP 世界地图数据..."

    if [ -f "$source_file" ]; then
        mkdir -p "$banip_ui_dir"
        cp -a "$source_file" "$banip_ui_dir"
        echo "  ✅ banIP 世界地图数据注入完成"
    else
        echo "  ⚠️ world-50m.json 不存在，跳过 banIP 数据注入"
    fi
}

# ---------- 配置 SSH 双端口 ----------
# 生成 uci-defaults 脚本：Dropbear 监听 2222，OpenSSH 监听 22
configure_ssh() {
    local uci_dir="files/etc/uci-defaults"

    echo "🔐 配置 SSH 双端口..."

    mkdir -p "$uci_dir"

    cat << 'EOF' > "$uci_dir/99-custom-ssh-config"
#!/bin/sh

# --- 1. 停止 OpenSSH 服务（避免端口冲突） ---
/etc/init.d/sshd stop 2>/dev/null

# --- 2. 配置 Dropbear 监听 2222 端口 ---
uci set dropbear.@dropbear[0].Port='2222'
uci commit dropbear

# --- 3. 配置 OpenSSH 监听 22 端口并允许 root 登录 ---
SSHD_CONFIG="/etc/ssh/sshd_config"
if [ -f "$SSHD_CONFIG" ]; then
    sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' "$SSHD_CONFIG"
    sed -i 's/^#*Port.*/Port 22/' "$SSHD_CONFIG"
fi

# --- 4. 按顺序启动 OpenSSH 服务 ---
/etc/init.d/sshd enable
/etc/init.d/sshd start

exit 0
EOF

    chmod +x "$uci_dir/99-custom-ssh-config"
    echo "  ✅ SSH 双端口配置完成"
}

# ============================================================
# 主流程
# ============================================================

# 1. 注入 golang / rust 包
inject_feed "https://github.com/openwrt/packages.git" "feeds/packages/lang" \
    "lang/golang" \
    "lang/rust"

# 2. 清理冲突包 open-app-filter
echo "🧹 清理冲突包 open-app-filter ..."
rm -rf ./feeds/packages/net/open-app-filter
echo "  ✅ 冲突包已清理"

# 3. 注入 banIP 世界地图数据
inject_banip

# 4. 配置 SSH 双端口
configure_ssh

echo "✅ 全部构建增强配置完成"

