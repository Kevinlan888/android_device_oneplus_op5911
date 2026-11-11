#
# Copyright (C) 2026 The Android Open Source Project
# SPDX-License-Identifier: Apache-2.0
#
# Plain AOSP product for OP5911. Same device config as lineage_op5911,
# without vendor/lineage (no Lineage apps/settings, no PRODUCT_BUILD_PROP_OVERRIDES).
#
#   lunch aosp_op5911-trunk_staging-userdebug
#

$(call inherit-product, $(SRC_TARGET_DIR)/product/core_64_bit.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/aosp_base_telephony.mk)

$(call inherit-product, device/oneplus/op5911/device.mk)

PRODUCT_NAME := aosp_op5911
PRODUCT_DEVICE := op5911
PRODUCT_MANUFACTURER := OnePlus
PRODUCT_BRAND := OnePlus
PRODUCT_MODEL := PGZ110
