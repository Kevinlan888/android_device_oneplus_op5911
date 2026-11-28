#
# Copyright (C) 2026 The LineageOS Project
# SPDX-License-Identifier: Apache-2.0
#

$(call inherit-product, $(SRC_TARGET_DIR)/product/core_64_bit.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/full_base_telephony.mk)

$(call inherit-product, device/oneplus/op5911/device.mk)

$(call inherit-product, vendor/lineage/config/common_full_phone.mk)

PRODUCT_NAME := lineage_op5911
PRODUCT_DEVICE := op5911
PRODUCT_MANUFACTURER := OnePlus
PRODUCT_BRAND := OnePlus
PRODUCT_MODEL := PGZ110

PRODUCT_GMS_CLIENTID_BASE := android-oneplus

# Match the stock vendor (ColorOS PGZ110_15.0.0.1101)
PRODUCT_BUILD_PROP_OVERRIDES += \
    BuildDesc="PGZ110-user 15 AP3A.240617.008 S.1ebee3f-1-75b3d release-keys" \
    BuildFingerprint=OnePlus/PGZ110/OP5911:15/AP3A.240617.008/S.1ebee3f-1-75b3d:user/release-keys \
    DeviceName=OP5911 \
    DeviceProduct=PGZ110

# Allow prebuilt vendor/gms APKs with mismatched uses-library declarations
PRODUCT_BROKEN_VERIFY_USES_LIBRARIES := true

# Keep ro.debuggable=1 on userdebug so adb root / Rooted debugging works during bring-up
PRODUCT_NOT_DEBUGGABLE_IN_USERDEBUG :=
