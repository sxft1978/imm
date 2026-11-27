#!/bin/bash
# ============================================================
# diy-part2.sh — OpenWrt 构建流程增强脚本（最终版）
# 功能：
#   1. 极速拉取并注入 golang / rust 包。
#   2. 清理冲突包 open-app-filter
#   3. 注入 banIP 世界地图数据
#   4. 配置 SSH 双端口（Dropbear 2222 / OpenSSH 22）
# ============================================================

set -euo pipefail

# ---------- 路径配置 ----------
# 补丁源目录：GitHub Actions 环境使用工作区，本地编译回退到上级目录

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
/etc/init.d/dropbear start
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
#inject_feed "https://github.com/openwrt/packages.git" "feeds/packages/lang" \
  #  "lang/golang" \
   # "lang/rust"

# 2. 清理冲突包 open-app-filter
echo "🧹 清理冲突包 open-app-filter ..."
rm -rf ./feeds/packages/net/open-app-filter
echo "  ✅ 冲突包已清理"

# 3. 注入 banIP 世界地图数据
inject_banip

# 4. 配置 SSH 双端口
configure_ssh

chmod +x files/etc/uci-defaults/99-custom-settings


# ============================================================
# 修改编译源码而配置
# ============================================================

#if [ -f .config ]; then
 #   sed -i 's/CONFIG_TARGET_SQUASHFS_BLOCK_READERS=4/CONFIG_TARGET_SQUASHFS_BLOCK_READERS=2/' .config
#    sed -i 's/CONFIG_TARGET_SQUASHFS_SMALL_READERS=4/CONFIG_TARGET_SQUASHFS_SMALL_READERS=2/' .config
#fi
#make defconfig

# 2. 改压缩算法
#COMP=zstd
#sed -i "s/SQUASHFSCOMP := gzip.*/SQUASHFSCOMP := ${COMP}/" include/image.mk
#sed -i "s/SQUASHFSCOMP := xz.*/SQUASHFSCOMP := ${COMP}/" include/image.mk

# 3. 验证是否改成功
#echo "--- 当前 SQUASHFSCOMP 设置 ---"
#grep -n "SQUASHFSCOMP" include/image.mk

#if grep -q "SQUASHFSCOMP := zstd" include/image.mk; then
  #  echo "[OK] SQUASHFSCOMP 已改为 zstd"
#else
#    echo "[ERROR] 修改失败！当前内容：" >&2
#    grep -n "SQUASHFSCOMP" include/image.mk >&2
#    exit 1
#fi

echo "✅ 全部构建增强配置完成"
