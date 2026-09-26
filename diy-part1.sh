#!/bin/bash
#
# diy-part1.sh —— 在 feeds 更新之前执行
# 适配 FanchmWrt 最新版（默认分支 fanchmwrt-25.12.4 / OpenWrt 25.12.4）
# 作用（RK3399 / Rockchip 专用，你的板子：ROCK DD，仿 ROCK Pi 4）：
#   1. 向 target/linux/rockchip/image/armv8.mk 追加 Device/rock_rockdd 定义
#   2. DTS 两种来源（见下方 DTS_MODE）
#   3. 烤入 rockpi4a 的 U-Boot，产出可刷 eMMC/SD 的 sysupgrade.img.gz
#
# 25.12.4 关键点：
#   - 设备定义用父宏 $(Device/rk3399)（自带 SOC 和 KERNEL_LOADADDR）
#   - DEVICE_DTS 自动推导为 "rk3399-rockdd"（不带 rockchip/ 前缀）

# ===================== 需要修改的变量 =====================
VENDOR="ROCK"               # 厂商名（会被转小写用于设备名）
MODEL="DD"                  # 型号名
BOARD_NAME="rockdd"         # 板子代号（小写）

# DTS 来源（重要！）：
#   official = 用官方 rk3399-rock-pi-4a 的 dts（官方固件已验证能启动，先用这个排查启动问题）
#   custom   = 用你自己的 dts/rk3399-rockdd.dts（基于 RockPro64 改的，之前起不来，需先修正再切回）
DTS_MODE="official"

# 是否产出可刷 eMMC/SD 的完整镜像（含 U-Boot）
#   y = 产出 sysupgrade.img.gz（含 U-Boot，解压后可直接 dd 到 eMMC/SD）
#   n = 只产出 kernel.itb + rootfs.tar.gz（不带 U-Boot，需自带 bootloader）
BUILD_SD_IMAGE="y"

# 借用的 U-Boot（你的板子和 ROCK Pi 4 系列同为 RK808 PMIC + SYR827/828，DDR 兼容）
#   rockpi4a  → UBOOT_DEVICE_NAME="rock-pi-4-rk3399"   UBOOT_PKG="u-boot-rock-pi-4-rk3399"
#   rockpi4se → UBOOT_DEVICE_NAME="rock-4se-rk3399"    UBOOT_PKG="u-boot-rock-4se-rk3399"
UBOOT_DEVICE_NAME="rock-pi-4-rk3399"
UBOOT_PKG="u-boot-rock-pi-4-rk3399"

# 额外内核包：RTL8822BE(PCIe) 需要「驱动 + 固件」两样都配：
#   kmod-rtw88-8822be     驱动模块（自动拉入 kmod-rtw88-8822b 公共模块）
#   rtl8822be-firmware    固件 /lib/firmware/rtw88/rtw8822b_fw.bin（真实包，必须手动配）
DEVICE_PACKAGES="kmod-rtw88-8822be rtl8822be-firmware wpad-basic-mbedtls kmod-usb-storage kmod-usb-net-rtl8152"
# =========================================================

set -e

VENDOR_LC=$(echo "$VENDOR" | tr '[:upper:]' '[:lower:]')
DEVICE_NAME="${VENDOR_LC}_${BOARD_NAME}"      # => rock_rockdd

# 1) 注入 DTS（仅 custom 模式）
if [ "$DTS_MODE" = "custom" ]; then
  DTS_SRC="$GITHUB_WORKSPACE/dts/rk3399-${BOARD_NAME}.dts"
  if [ ! -f "$DTS_SRC" ]; then
    echo "❌ 找不到 DTS 文件: $DTS_SRC"
    echo "   请把你的 rk3399 设备树放到仓库的 dts/rk3399-${BOARD_NAME}.dts"
    exit 1
  fi
  DTS_DST="target/linux/rockchip/files/arch/arm64/boot/dts/rockchip/rk3399-${BOARD_NAME}.dts"
  mkdir -p "$(dirname "$DTS_DST")"
  cp "$DTS_SRC" "$DTS_DST"
  echo "✅ 已注入自定义 DTS -> $DTS_DST"
else
  echo "ℹ️ 使用官方 rk3399-rock-pi-4a dts（不注入自定义 dts）"
fi

# 2) 追加设备定义到 armv8.mk
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

# official 模式：显式用官方 dts；custom 模式：用自动推导的 rk3399-rockdd
if [ "$DTS_MODE" = "official" ]; then
  echo "  DEVICE_DTS := rk3399-rock-pi-4a" >> "$IMAGE_MK"
fi

if [ "$BUILD_SD_IMAGE" = "y" ]; then
  # 含 U-Boot：直接沿用 Device/Default 的 IMAGE/sysupgrade.img.gz
  cat >> "$IMAGE_MK" <<EOF
  UBOOT_DEVICE_NAME := ${UBOOT_DEVICE_NAME}
  DEVICE_PACKAGES := ${DEVICE_PACKAGES}
endef
TARGET_DEVICES += ${DEVICE_NAME}
EOF
  echo "✅ 已追加设备定义(${DEVICE_NAME})，DTS_MODE=${DTS_MODE}，烤入 U-Boot: ${UBOOT_DEVICE_NAME} → sysupgrade.img.gz"

  # 3) 把我们的设备加进 U-Boot 包的 BUILD_DEVICES，让 u-boot 通过标准机制自动编译
  #    （u-boot 是 HIDDEN 包，手动写 CONFIG_PACKAGE_...=y 会被 defconfig 按 default 值覆盖，
  #     只有出现在对应 U-Boot 的 BUILD_DEVICES 里，default y 才会随设备选中而生效）
  UBOOT_MK="package/boot/uboot-rockchip/Makefile"
  if [ ! -f "$UBOOT_MK" ]; then
    echo "❌ 找不到 $UBOOT_MK"
    exit 1
  fi
  python3 - "$UBOOT_MK" "$UBOOT_DEVICE_NAME" "$DEVICE_NAME" <<'PYEOF'
import sys
path, ubtarget, dev = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(path).read()
anchor = "define U-Boot/%s\n" % ubtarget
idx = s.find(anchor)
if idx < 0:
    print("⚠️ 未找到 %s，跳过 BUILD_DEVICES patch" % anchor)
    sys.exit(0)
end = s.index("endef", idx)
block = s[idx:end]
lines = block.split("\n")
for i in range(len(lines) - 1, -1, -1):
    line = lines[i]
    if line.startswith("    ") and line[4:].strip() and not line[4:].strip().startswith("#"):
        name = line[4:].strip()
        if name == dev:
            print("ℹ️ %s 已在 BUILD_DEVICES 中" % dev)
        else:
            lines[i] = line + " \\"
            lines.insert(i + 1, "    %s" % dev)
            print("✅ 已把 %s 加入 U-Boot/%s 的 BUILD_DEVICES" % (dev, ubtarget))
        s = s[:idx] + "\n".join(lines) + s[end:]
        open(path, "w").write(s)
        break
else:
    print("⚠️ 未找到 BUILD_DEVICES 设备行")
PYEOF
else
  # 不含 U-Boot：只出 FIT 内核 + rootfs，用板子自带 bootloader 启动
  cat >> "$IMAGE_MK" <<EOF
  IMAGES := kernel.itb rootfs.tar.gz
  IMAGE/kernel.itb := kernel-bin | lzma | fit lzma \$\$(KDIR)/image-\$\$(firstword \$\$(DEVICE_DTS)).dtb
  IMAGE/rootfs.tar.gz := rootfs-tar
  DEVICE_PACKAGES := ${DEVICE_PACKAGES}
endef
TARGET_DEVICES += ${DEVICE_NAME}
EOF
  echo "✅ 已追加设备定义(${DEVICE_NAME})，DTS_MODE=${DTS_MODE}，产出 kernel.itb + rootfs.tar.gz（不含 U-Boot）"
fi
