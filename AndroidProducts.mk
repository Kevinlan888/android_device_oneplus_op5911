#
# Copyright (C) 2026 The LineageOS Project
# SPDX-License-Identifier: Apache-2.0
#

PRODUCT_MAKEFILES := \
    $(LOCAL_DIR)/aosp_op5911.mk

# lineage_op5911 only exists when building inside a LineageOS tree.
ifneq ($(wildcard vendor/lineage/config/common_full_phone.mk),)
PRODUCT_MAKEFILES += \
    $(LOCAL_DIR)/lineage_op5911.mk
endif

COMMON_LUNCH_CHOICES := \
    aosp_op5911-trunk_staging-userdebug
