# Dockerfile.firmware
# 用途：把 OpenWrt 编译产出的 rootfs 封装成 Docker 镜像
# 放置位置：SCRPTS/Dockerfile.firmware
# context：工作流里设为 ${{ github.workspace }}/docker_ctx

FROM scratch

# openwrt-rootfs.tar 是工作流动态生成在 docker_ctx/ 里的，
# 路径相对于 context，不要加 SCRPTS/ 前缀
ADD openwrt-rootfs.tar /

CMD ["/sbin/init"]
