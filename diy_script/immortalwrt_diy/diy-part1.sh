# 确保 cd 到了克隆下来的源码目录下
        cd openwrt

        # 第一行：打印源码里原始的 feeds 内容（方便你排查）
        echo ">>> [检查] 正在查看 clone 后的源码 feeds.conf.default <<<"
        cat feeds.conf.default

        # 第二行：核心注入代码！直接把仓库变量的文件内容追加写入
        echo ">>> [注入] 开始追加自定义插件源 <<<"
        cat "${GITHUB_WORKSPACE}/${FEEDS_CONF}" >> feeds.conf.default

        # 第三行：验证注入结果（看看是不是多了几行）
        echo ">>> [结果] 注入后的 feeds.conf.default 内容 <<<"
        cat feeds.conf.default
