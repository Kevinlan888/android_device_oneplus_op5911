#
# Copyright (C) 2026 The LineageOS Project
# SPDX-License-Identifier: Apache-2.0
#
# OnePlus Ace (PGZ110 / OP5911), MediaTek Dimensity 8100 (MT6895)
#
# Stage 1 layout:
#   - built here:        system, system_ext, product
#   - prebuilt patched:  vendor   (vendor-patch/patch-vendor-image.sh)
#   - left untouched on device: boot, vendor_boot (stock recovery + fastbootd),
#     dtbo, odm, vendor_dlkm, odm_dlkm, my_* (ColorOS stock fstab requires them)
#

DEVICE_PATH := device/oneplus/op5911

BUILD_BROKEN_DUP_RULES := true
BUILD_BROKEN_ELF_PREBUILT_PRODUCT_COPY_FILES := true

# Architecture
TARGET_ARCH := arm64
TARGET_ARCH_VARIANT := armv8-2a-dotprod
TARGET_CPU_ABI := arm64-v8a
TARGET_CPU_VARIANT := generic
TARGET_CPU_VARIANT_RUNTIME := cortex-a55

TARGET_2ND_ARCH := arm
TARGET_2ND_ARCH_VARIANT := armv8-2a
TARGET_2ND_CPU_ABI := armeabi-v7a
TARGET_2ND_CPU_ABI2 := armeabi
TARGET_2ND_CPU_VARIANT := generic
TARGET_2ND_CPU_VARIANT_RUNTIME := cortex-a55

# Platform
TARGET_BOARD_PLATFORM := mt6895
TARGET_BOOTLOADER_BOARD_NAME := mt6895
TARGET_NO_BOOTLOADER := true

# Kernel / boot images: stage 1 keeps the stock boot + vendor_boot on the device.
TARGET_NO_KERNEL := true
BOARD_USES_RECOVERY_AS_BOOT := false
BOARD_BOOT_HEADER_VERSION := 4

# Recovery (stage 2): we build the AOSP recovery root here and graft it into the stock
# vendor_boot ramdisk's /system via vendor_boot-patch/. Recovery is the ONLY user of the
# vendor ramdisk's /system: normal boot runs the static first-stage /init from the stock
# boot.img generic ramdisk (loaded last, so it wins) and only reads the stock first_stage
# fstab + /lib/modules from the vendor ramdisk, never its /system. So replacing /system
# with AOSP recovery cannot affect normal boot. The stock OPPO recovery is AOSP recovery
# wrapped by phoenix_recovery, whose UI exposes no adb sideload; a clean AOSP recovery does.
TARGET_NO_RECOVERY := false
TARGET_RECOVERY_FSTAB := $(DEVICE_PATH)/recovery/recovery.fstab
TARGET_RECOVERY_PIXEL_FORMAT := RGBX_8888
BOARD_RECOVERYIMAGE_PARTITION_SIZE := 100663296

# A/B
AB_OTA_UPDATER := true
AB_OTA_PARTITIONS := \
    system \
    system_ext \
    product \
    vendor

# Partitions
BOARD_FLASH_BLOCK_SIZE := 262144
BOARD_BOOTIMAGE_PARTITION_SIZE := 67108864
BOARD_VENDOR_BOOTIMAGE_PARTITION_SIZE := 67108864
BOARD_DTBOIMG_PARTITION_SIZE := 8388608

# Super: 12348030976 bytes, single group "main" (same as stock lpdump).
# The stock layout also holds odm, vendor_dlkm, odm_dlkm and ten my_* partitions
# that this build does not produce, so NEVER flash super_empty.img / `fastboot flashall`.
BOARD_SUPER_PARTITION_SIZE := 12348030976
BOARD_SUPER_PARTITION_GROUPS := main
BOARD_MAIN_SIZE := 12343836672
BOARD_MAIN_PARTITION_LIST := system system_ext product vendor

BOARD_SYSTEMIMAGE_FILE_SYSTEM_TYPE := erofs
BOARD_SYSTEM_EXTIMAGE_FILE_SYSTEM_TYPE := erofs
BOARD_PRODUCTIMAGE_FILE_SYSTEM_TYPE := erofs
BOARD_VENDORIMAGE_FILE_SYSTEM_TYPE := erofs
BOARD_EROFS_COMPRESSOR := lz4hc,9
BOARD_EROFS_PCLUSTER_SIZE := 262144

TARGET_COPY_OUT_SYSTEM_EXT := system_ext
TARGET_COPY_OUT_PRODUCT := product
TARGET_COPY_OUT_VENDOR := vendor
TARGET_COPY_OUT_ODM := odm
TARGET_COPY_OUT_VENDOR_DLKM := vendor_dlkm
TARGET_COPY_OUT_ODM_DLKM := odm_dlkm

# odm / vendor_dlkm / odm_dlkm stay stock on the device. The fs types (same as
# stock) only make the build create the /odm, /vendor_dlkm and /odm_dlkm
# mount points in the system root; these images are never built or flashed.
BOARD_ODMIMAGE_FILE_SYSTEM_TYPE := erofs
BOARD_VENDOR_DLKMIMAGE_FILE_SYSTEM_TYPE := ext4
BOARD_ODM_DLKMIMAGE_FILE_SYSTEM_TYPE := ext4

# Patched stock vendor (see vendor-patch/README.md)
BOARD_PREBUILT_VENDORIMAGE := vendor/oneplus/op5911/images/vendor.img

# Creates /metadata in the system root. first-stage init mounts it and
# switch_root must move it there, or init aborts right after mounting /system.
BOARD_USES_METADATA_PARTITION := true

TARGET_USERIMAGES_USE_F2FS := true
TARGET_USERIMAGES_USE_EXT4 := true

# AVB: stock vbmeta_b is flashed with --disable-verity --disable-verification,
# odm and my_* stay signed with the OPLUS key, so this build does not sign anything.
BOARD_AVB_ENABLE := false

# Properties
TARGET_SYSTEM_PROP += $(DEVICE_PATH)/system.prop
TARGET_SYSTEM_EXT_PROP += $(DEVICE_PATH)/system_ext.prop

# SELinux: the vendor-side rules (IMS props, init mounton) live in
# vendor-patch/vendor_sepolicy_append.cil, because the platform policy cannot
# reference the vendor_mtk_* types declared by the stock vendor.
# Service names used by the system-side MtkIms app are labelled here.
SYSTEM_EXT_PRIVATE_SEPOLICY_DIRS += $(DEVICE_PATH)/sepolicy/private

-include vendor/oneplus/op5911/BoardConfigVendor.mk
