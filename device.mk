#
# Copyright (C) 2026 The LineageOS Project
# SPDX-License-Identifier: Apache-2.0
#

DEVICE_PATH := device/oneplus/op5911

# Launched with Android 12 (vendor API 31), Virtual A/B with compression
PRODUCT_SHIPPING_API_LEVEL := 31
$(call inherit-product, $(SRC_TARGET_DIR)/product/virtual_ab_ota/launch_with_vendor_ramdisk.mk)

# The Android 12 vendor still links against VNDK v31
PRODUCT_EXTRA_VNDK_VERSIONS := 31

# Dynamic partitions (super image is NOT built: the device keeps odm/my_* etc.)
PRODUCT_USE_DYNAMIC_PARTITIONS := true
PRODUCT_BUILD_SUPER_PARTITION := false

# Recovery (stage 2): force BUILDING_RECOVERY_IMAGE even though TARGET_NO_KERNEL is set,
# so the recovery root/ramdisk rules exist. We only ever build the ramdisk target
# (recovery.img itself would need the kernel we don't build):
#   m out/target/product/op5911/ramdisk-recovery.img
# The root is then grafted into the stock vendor_boot ramdisk by vendor_boot-patch/.
# Do NOT run a full `m` with this on - it would try to build recovery.img and fail on the kernel.
PRODUCT_BUILD_RECOVERY_IMAGE := true

# Kernel is not part of this build (stage 1)
PRODUCT_OTA_ENFORCE_VINTF_KERNEL_REQUIREMENTS := false

PRODUCT_SOONG_NAMESPACES += $(DEVICE_PATH)

# A/B
AB_OTA_POSTINSTALL_CONFIG += \
    RUN_POSTINSTALL_system=true \
    POSTINSTALL_PATH_system=system/bin/otapreopt_script \
    FILESYSTEM_TYPE_system=erofs \
    POSTINSTALL_OPTIONAL_system=true

PRODUCT_PACKAGES += \
    bootctl \
    checkpoint_gc \
    otapreopt_script \
    update_engine \
    update_engine_client \
    update_engine_sideload \
    update_verifier

# Display
TARGET_SCREEN_DENSITY := 480
TARGET_SCREEN_HEIGHT := 2412
TARGET_SCREEN_WIDTH := 1080

# Overlays
PRODUCT_ENFORCE_RRO_TARGETS := *
PRODUCT_PACKAGES += \
    CarrierConfigOverlayOP5911 \
    FrameworksResOverlayOP5911 \
    SettingsOverlayOP5911 \
    SystemUIOverlayOP5911 \
    TelephonyOverlayOP5911

# Doze: oplus pickup sensor -> ambient display pulse
PRODUCT_PACKAGES += \
    OplusDoze

# IMS (MediaTek, TrebleDroid ims-mtk-u)
PRODUCT_PACKAGES += \
    MtkIms \
    privapp-permissions-com.mediatek.ims.xml

# Fingerprint: stock declares this in my_product, which AOSP does not read.
# SystemServer only starts FingerprintService when the feature is present.
PRODUCT_COPY_FILES += \
    frameworks/native/data/etc/android.hardware.fingerprint.xml:$(TARGET_COPY_OUT_PRODUCT)/etc/permissions/android.hardware.fingerprint.xml

# Log tags: silence MediaTek RIL/IMS chatter on user/userdebug
include $(DEVICE_PATH)/configs/vendor_logtag.mk

# Inherit the proprietary side (currently only the patched vendor image)
$(call inherit-product-if-exists, vendor/oneplus/op5911/op5911-vendor.mk)

# Debug: pre-authorize this PC's adb key (userdebug only), so adb works on the
# first boot after the userdata wipe, even if SystemUI never comes up.
# Replace configs/adb_keys with your own ~/.android/adbkey.pub.
ifneq ($(TARGET_BUILD_VARIANT),user)
ifneq ($(wildcard $(DEVICE_PATH)/configs/adb_keys),)
PRODUCT_ADB_KEYS := $(DEVICE_PATH)/configs/adb_keys
endif
endif
