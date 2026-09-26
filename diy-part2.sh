#!/bin/bash
#
# diy-part2.sh —— 在 feeds 安装之后、编译之前执行
# 作用：做一些通用自定义（默认 IP、主题、主机名等）。按需取消注释。
#

# 修改默认 LAN 口 IP（默认 192.168.1.1）
# sed -i 's/192.168.1.1/192.168.10.1/g' package/base-files/files/bin/config_generate

# 修改默认主机名
# sed -i 's/OpenWrt/MyRouter/g' package/base-files/files/bin/config_generate

# 修改默认主题（需要 feeds 里已包含对应主题包）
# sed -i 's/luci-theme-bootstrap/luci-theme-argon/g' feeds/luci/collections/luci/Makefile

echo "✅ diy-part2.sh 执行完成"
