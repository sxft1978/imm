#!/bin/bash
set -e

#cd openwrt

# 使用工作流变量（env 里定义的）
#cat   $FEEDS_CONF >>${{ github.workspace }}/${{ env.SOURCE_DIR }}/feeds.conf.default
cat   $FEEDS_CONF >>${{ github.workspace }}/${{ env.SOURCE_DIR }}/feeds.conf.default
cat -A  ${{ github.workspace }}/${{ env.SOURCE_DIR }}/feeds.conf.default
cat -A  
 
