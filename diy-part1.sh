#!/bin/bash
#
# diy-part1.sh —— 在 feeds 更新之前执行
# 适配 FanchmWrt 最新版（默认分支 fanchmwrt-25.12.4 / OpenWrt 25.12.4）
# 作用（RK3399 / Rockchip 专用，你的板子：ROCK DD）：
#   1. 把你的 rk3399-rockdd.dts 放进内核设备树树的 files 覆盖层
#      target/linux/rockchip/files/arch/arm64/boot/dts/rockchip/
#      （OpenWrt 构建时会把 files/ 整体覆盖到内核源码树，
#        DEVICE_DTS_DIR = $(DTS_DIR)/rockchip 会在这里找到 rk3399-rockdd.dts）
#   2. 向 target/linux/rockchip/image/armv8.mk 追加 Device/rock_rockdd 定义
#   3. 默认烤入 rockpi4a 的 U-Boot，产出可刷 eMMC/SD 的 sysupgrade.img.gz
#
# 25.12.4 关键变化（相比 24.10.x）：
#   - 设备定义用父宏 $(Device/rk3399)（自带 SOC 和 KERNEL_LOADADDR），不再直接写 SOC :=
#   - DEVICE_DTS 自动推导成 "rk3399-rockdd"（去掉了旧的 rockchip/ 前缀）
#
# 用法：把你的 dts 放到仓库的 dts/rk3399-rockdd.dts，通常只需改下面几个变量。

# ===================== 需要修改的变量 =====================
VENDOR="ROCK"               # 厂商名（会被转小写用于设备名）
MODEL="DD"                  # 型号名
BOARD_NAME="rockdd"         # 板子代号（小写，= dts 文件名后缀 rk3399-rockdd）

# 是否产出可刷 eMMC/SD 的完整镜像（含 U-Boot）
#   y = 产出 sysupgrade.img.gz（含 U-Boot，解压后可直接 dd 到 eMMC/SD）← 刷 eMMC 用这个
#   n = 只产出 kernel.itb + rootfs.tar.gz（不带 U-Boot，需自带 bootloader）
BUILD_SD_IMAGE="y"

# 借用的 U-Boot（你的板子和 ROCK Pi 4 系列同为 RK808 PMIC + SYR827/828，DDR 兼容）
#   rockpi4a  → UBOOT_DEVICE_NAME="rock-pi-4-rk3399"   UBOOT_PKG="u-boot-rock-pi-4-rk3399"
#   rockpi4se → UBOOT_DEVICE_NAME="rock-4se-rk3399"    UBOOT_PKG="u-boot-rock-4se-rk3399"
# 切换时把下面两行一起改，脚本会自动同步 config 里的对应包名。
UBOOT_DEVICE_NAME="rock-pi-4-rk3399"
UBOOT_PKG="u-boot-rock-pi-4-rk3399"

# 额外内核包：RTL8822BE(PCIe) 需要「驱动 + 固件」两样都配：
#   kmod-rtw88-8822be     驱动模块 rtw88_8822be.ko（自动拉入 kmod-rtw88-8822b 公共模块）
#   rtl8822be-firmware    固件 /lib/firmware/rtw88/rtw8822b_fw.bin（真实包；驱动不会自动带它，必须手动配）
DEVICE_PACKAGES="kmod-rtw88-8822be rtl8822be-firmware wpad-basic-mbedtls kmod-usb-storage kmod-usb-net-rtl8152"
# =========================================================

set -e

VENDOR_LC=$(echo "$VENDOR" | tr '[:upper:]' '[:lower:]')
DEVICE_NAME="${VENDOR_LC}_${BOARD_NAME}"      # => rock_rockdd
DTS_SRC="$GITHUB_WORKSPACE/dts/rk3399-${BOARD_NAME}.dts"

# 1) 校验 dts 是否存在
if [ ! -f "$DTS_SRC" ]; then
  echo "❌ 找不到 DTS 文件: $DTS_SRC"
  echo "   请把你的 rk3399 设备树放到仓库的 dts/rk3399-${BOARD_NAME}.dts"
  exit 1
fi

# 2) 注入 dts 到内核 files 覆盖层（OpenWrt 会自动覆盖到内核源码树）
DTS_DST="target/linux/rockchip/files/arch/arm64/boot/dts/rockchip/rk3399-${BOARD_NAME}.dts"
mkdir -p "$(dirname "$DTS_DST")"
cp "$DTS_SRC" "$DTS_DST"
echo "✅ 已注入 DTS -> $DTS_DST"

# 3) 追加设备定义到 armv8.mk
IMAGE_MK="target/linux/rockchip/image/armv8.mk"
if [ ! -f "$IMAGE_MK" ]; then
  echo "❌ 找不到 $IMAGE_MK，请确认 SUBTARGET 是否为 armv8"
  exit 1
fi

# 注意：\$(Device/rk3399) 是 make 变量引用，须转义以免被 bash 当成命令替换
cat >> "$IMAGE_MK" <<EOF

define Device/${DEVICE_NAME}
  \$(Device/rk3399)
  DEVICE_VENDOR := ${VENDOR}
  DEVICE_MODEL := ${MODEL}
EOF

if [ "$BUILD_SD_IMAGE" = "y" ]; then
  # 含 U-Boot：直接沿用 Device/Default 的 IMAGE/sysupgrade.img.gz
  # （boot-common | boot-script | pine64-img | gzip），pine64-img 会把 U-Boot 拼进 GPT 镜像。
  cat >> "$IMAGE_MK" <<EOF
  UBOOT_DEVICE_NAME := ${UBOOT_DEVICE_NAME}
  DEVICE_PACKAGES := ${DEVICE_PACKAGES}
endef
TARGET_DEVICES += ${DEVICE_NAME}
EOF
  echo "✅ 已追加设备定义(${DEVICE_NAME})，烤入 U-Boot: ${UBOOT_DEVICE_NAME} → 产出 sysupgrade.img.gz"

  # 4) 同步 config 里的 U-Boot 包名，保证 u-boot 被实际编译进镜像
  CONFIG_FILE="$GITHUB_WORKSPACE/config/fanchmwrt.config"
  if [ -f "$CONFIG_FILE" ]; then
    sed -i "s/^CONFIG_PACKAGE_u-boot-.*rk3399=y$/CONFIG_PACKAGE_${UBOOT_PKG}=y/" "$CONFIG_FILE"
    echo "✅ 已同步 config 的 U-Boot 包 -> ${UBOOT_PKG}"
  fi
else
  # 不含 U-Boot：只出 FIT 内核 + rootfs，用板子自带 bootloader 启动
  # 25.12.4 的 dtb 路径为 $(KDIR)/image-$(DEVICE_DTS).dtb（DEVICE_DTS 不带 rockchip/ 前缀）
  cat >> "$IMAGE_MK" <<EOF
  IMAGES := kernel.itb rootfs.tar.gz
  IMAGE/kernel.itb := kernel-bin | lzma | fit lzma \$\$(KDIR)/image-\$\$(firstword \$\$(DEVICE_DTS)).dtb
  IMAGE/rootfs.tar.gz := rootfs-tar
  DEVICE_PACKAGES := ${DEVICE_PACKAGES}
endef
TARGET_DEVICES += ${DEVICE_NAME}
EOF
  echo "✅ 已追加设备定义(${DEVICE_NAME})，产出 kernel.itb + rootfs.tar.gz（不含 U-Boot）"
fi
