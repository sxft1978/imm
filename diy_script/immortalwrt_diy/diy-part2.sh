#!/bin/bash

# 1. 直接往 feeds 配置文件里追加官方 packages 仓库地址
echo "src-git lang_packages https://github.com/openwrt/packages.git;lang" >> feeds.conf.default

# 2. 更新并精准安装 golang 和 rust 依赖
./scripts/feeds update lang_packages
./scripts/feeds install -p lang_packages lang/golang lang/rust
