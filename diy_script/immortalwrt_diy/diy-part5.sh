#!/usr/bin/env bash
set -euo pipefail

# 仓库里的 feeds 文件
SRC="${GITHUB_WORKSPACE}/${FEEDS_CONF:-a}"

# clone 后的源码目录
OPENWRT_DIR="${GITHUB_WORKSPACE}/openwrt"
DST="${OPENWRT_DIR}/feeds.conf.default"

echo ">>> 仓库 feeds 文件: $SRC"
echo ">>> 目标文件: $DST"

if [ ! -f "$SRC" ]; then
    echo "错误: 仓库 feeds 文件不存在: $SRC"
    exit 1
fi

if [ ! -f "$DST" ]; then
    echo "错误: 源码 feeds.conf.default 不存在: $DST"
    exit 1
fi

echo ">>> 注入前 feeds.conf.default <<<"
cat "$DST"

echo ""
echo ">>> 开始注入仓库 feeds <<<"

while IFS= read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue
    [[ "$line" =~ ^# ]] && continue

    if grep -qF "$line" "$DST"; then
        echo "已存在，跳过: $line"
    else
        echo "$line" >> "$DST"
        echo "已注入: $line"
    fi
done < "$SRC"

echo ""
echo ">>> 注入后 feeds.conf.default <<<"
cat "$DST"

cp "$DST" "${OPENWRT_DIR}/feeds.conf"

echo ">>> feeds.conf 已同步 <<<"
