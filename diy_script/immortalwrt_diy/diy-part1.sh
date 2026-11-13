# 1. 拼接绝对路径（系统根目录 + yml传过来的变量）
SOURCE_FILE="${GITHUB_WORKSPACE}/${FEEDS_CONF}"
TARGET_FILE="feeds.conf.default"

echo ">>> [检查前] 当前源码里的 feeds.conf.default 内容如下 <<<"
# ========== 注入前，打印源码里的原始 feeds ==========
cat "$TARGET_FILE"
echo "========================================================="

# 2. 执行注入逻辑（带去重）
if [ -f "$SOURCE_FILE" ]; then
    while IFS= read -r line; do
        grep -qF "$line" "$TARGET_FILE" || echo "$line" >> "$TARGET_FILE"
    done < "$SOURCE_FILE"
    
    echo ">>> [注入后] 追加插件源后的 feeds.conf.default 内容如下 <<<"
    # ========== 注入后，打印现在的 feeds 列表 ==========
    cat "$TARGET_FILE"
    echo "========================================================="
    
    echo "✅ 插件源注入完成！"
else
    echo ">>> ⚠️ 警告：未找到注入源文件 [ $SOURCE_FILE ] <<<"
fi
