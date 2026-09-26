#!/bin/bash
#
# diy-part1.sh —— 在 feeds 更新之前执行
# 适配 FanchmWrt 最新版（默认分支 fanchmwrt-25.12.4 / OpenWrt 25.12.4）
# 作用（RK3399 / Rockchip 专用，你的板子：ROCK DD，仿 ROCK Pi 4）：
#   1. 准备 U-Boot：默认用你自己编译好的 u-boot-rockchip.bin（自动下载 + 预编译包）
#   2. 向 target/linux/rockchip/image/armv8.mk 追加 Device/rock_rockdd 定义
#   3. 产出可刷 eMMC/SD 的 sysupgrade.img.gz
#
# 镜像打包机制：pine64-img 会执行
#   dd if=$(STAGING_DIR_IMAGE)/<UBOOT_DEVICE_NAME>-u-boot-rockchip.bin of=<img> seek=64
# 所以只要 staging 里有对应名字的 u-boot-rockchip.bin 即可，U-Boot 从哪来都行。

# ===================== 需要修改的变量 =====================
VENDOR="ROCK"               # 厂商名（会被转小写用于设备名）
MODEL="DD"                  # 型号名
BOARD_NAME="rockdd"         # 板子代号（小写）

# DTS 来源：
#   official = 用官方 rk3399-rock-pi-4a 的 dts
#   custom   = 用你自己的 dts/rk3399-rockdd.dts
DTS_MODE="official"

# 是否产出可刷 eMMC/SD 的完整镜像（含 U-Boot）
BUILD_SD_IMAGE="y"

# U-Boot 来源：
#   prebuilt = 用你自己编译好的 U-Boot（推荐！自动从下面 URL 下载，OpenWrt 不再编译 U-Boot）
#   openwrt  = 用 OpenWrt 源码编译 U-Boot（借 rockpi4a 的 defconfig）
UBOOT_SOURCE="prebuilt"

# prebuilt 模式：你自己编译好的 u-boot-rockchip.bin 下载地址
# （idbloader + u-boot 合一，dd 到 sector 64 即可启动；已验证约 9.2MB，格式正确）
PREBUILT_UBOOT_URL="https://raw.githubusercontent.com/atlanticdg/u-boot/main/u-boot/rockchip/rockdd/u-boot-rockchip.bin"
# 镜像里引用的 U-Boot 名（决定 staging 文件名 rockdd-u-boot-rockchip.bin）
PREBUILT_UBOOT_NAME="rockdd"

# openwrt 模式：借用的 U-Boot（rockpi4a / rockpi4se）
OPENWRT_UBOOT_DEVICE_NAME="rock-pi-4-rk3399"

# 额外包：RTL8822BE(PCIe) 需要「驱动 + 固件」两样都配
DEVICE_PACKAGES="kmod-rtw88-8822be rtl8822be-firmware wpad-basic-mbedtls kmod-usb-storage kmod-usb-net-rtl8152"
# =========================================================

set -e

VENDOR_LC=$(echo "$VENDOR" | tr '[:upper:]' '[:lower:]')
DEVICE_NAME="${VENDOR_LC}_${BOARD_NAME}"      # => rock_rockdd

# ============ 1) 准备 U-Boot ============
if [ "$UBOOT_SOURCE" = "prebuilt" ]; then
  UBOOT_DEVICE_NAME="$PREBUILT_UBOOT_NAME"
  PKG_DIR="package/boot/uboot-rockdd-prebuilt"
  mkdir -p "$PKG_DIR/files"
  echo "⬇️  下载预编译 U-Boot ..."
  curl -fL --retry 3 --connect-timeout 30 "$PREBUILT_UBOOT_URL" -o "$PKG_DIR/files/u-boot-rockchip.bin"
  SIZE=$(wc -c < "$PKG_DIR/files/u-boot-rockchip.bin")
  if [ "$SIZE" -lt 1048576 ]; then
    echo "❌ 下载的 u-boot-rockchip.bin 只有 $SIZE 字节，异常！请检查 PREBUILT_UBOOT_URL / 分支名"
    exit 1
  fi
  echo "✅ 预编译 U-Boot 已就位（$SIZE 字节）"
  # 生成一个小的「预编译包」：构建时把 U-Boot 放到镜像打包需要的位置
  # （u-boot 包的 InstallDev 机制，与官方 u-boot-rockchip 完全一致）
  cat > "$PKG_DIR/Makefile" <<MKEOF
# 预编译 U-Boot 包（由 diy-part1.sh 自动生成，请勿手动编辑）
include \$(TOPDIR)/rules.mk

PKG_NAME:=uboot-rockdd-prebuilt
PKG_VERSION:=1.0
PKG_RELEASE:=1
PKGARCH:=all

include \$(INCLUDE_DIR)/package.mk

define Package/uboot-rockdd-prebuilt
  SECTION:=boot
  CATEGORY:=Boot Loaders
  TITLE:=Prebuilt U-Boot binary for ROCK DD (user-built)
  DEPENDS:=@TARGET_rockchip_armv8
endef

define Build/Prepare
	mkdir -p \$(PKG_BUILD_DIR)
	\$(CP) \$(CURDIR)/files/u-boot-rockchip.bin \$(PKG_BUILD_DIR)/
endef

define Build/Compile
endef

define Build/InstallDev
	\$(INSTALL_DIR) \$(STAGING_DIR_IMAGE)
	\$(CP) \$(PKG_BUILD_DIR)/u-boot-rockchip.bin \$(STAGING_DIR_IMAGE)/${UBOOT_DEVICE_NAME}-u-boot-rockchip.bin
endef

define Package/uboot-rockdd-prebuilt/install
endef

\$(eval \$(call BuildPackage,uboot-rockdd-prebuilt))
MKEOF
  echo "✅ 已生成预编译 U-Boot 包: $PKG_DIR"
  # 通过 DEVICE_PACKAGES 让该包随设备自动选中（标准机制，无需手动写 config）
  DEVICE_PACKAGES="$DEVICE_PACKAGES uboot-rockdd-prebuilt"
else
  UBOOT_DEVICE_NAME="$OPENWRT_UBOOT_DEVICE_NAME"
  echo "ℹ️ 使用 OpenWrt 源码编译 U-Boot: $UBOOT_DEVICE_NAME"
fi

# ============ 2) 注入 DTS（仅 custom 模式） ============
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

# ============ 3) 追加设备定义到 armv8.mk ============
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
  cat >> "$IMAGE_MK" <<EOF
  UBOOT_DEVICE_NAME := ${UBOOT_DEVICE_NAME}
  DEVICE_PACKAGES := ${DEVICE_PACKAGES}
endef
TARGET_DEVICES += ${DEVICE_NAME}
EOF
  echo "✅ 已追加设备定义(${DEVICE_NAME})，U-Boot: ${UBOOT_DEVICE_NAME}（来源 ${UBOOT_SOURCE}）→ sysupgrade.img.gz"

  # openwrt 模式：把设备加进对应 U-Boot 包的 BUILD_DEVICES，让它随设备自动编译
  # （u-boot 是 HIDDEN 包，手动写 CONFIG_PACKAGE_...=y 会被 defconfig 覆盖，必须走 BUILD_DEVICES）
  if [ "$UBOOT_SOURCE" = "openwrt" ]; then
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
  fi
else
  # 不含 U-Boot：只出 FIT 内核 + rootfs
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
