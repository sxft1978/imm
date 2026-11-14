# 1. 注入基础依赖包
inject_feed "https://github.com/openwrt/packages.git" "feeds/packages/lang"

# 2. 更新并精准安装 lang 目录下的 golang 和 rust 组件
./scripts/feeds update lang
./scripts/feeds install -p lang golang rust
