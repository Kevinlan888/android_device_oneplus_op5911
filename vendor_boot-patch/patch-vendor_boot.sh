#!/bin/bash
# Build a patched vendor_boot.img from the stock OP5911 vendor_boot image.
#
# Route 1 (surgical repack): the stock vendor_boot already contains a standard
# AOSP recovery (/system/bin/recovery), all 270 vendor kernel modules, and the
# normal-boot first-stage init -- all in one combined ramdisk. We keep every bit
# of that (so normal boot and fastbootd stay byte-identical to stock) and change
# exactly ONE file: /system/etc/security/otacerts.zip, swapping OPPO's OTA cert
# for our build's cert so this recovery will `adb sideload` / apply OUR signed
# OTA packages.
#
# Run from the LineageOS/AOSP source root after `source build/envsetup.sh`,
# `m fsck.erofs mkfs.erofs` (for the vendor patch) and a `m systemimage`
# (so our otacerts.zip exists):
#
#   device/oneplus/op5911/vendor_boot-patch/patch-vendor_boot.sh /path/to/stock/vendor_boot.img
#
# Output: vendor/oneplus/op5911/images/vendor_boot.img
#
# The stock vendor_boot geometry is fixed for this device (MT6895, header v4);
# the script rebuilds with the exact same header and asserts the result matches.
set -euo pipefail

STOCK=${1:?usage: $0 stock-vendor_boot.img}
HERE=$(cd "$(dirname "$0")" && pwd)
TOP=${ANDROID_BUILD_TOP:-$(pwd)}
HOSTBIN=$TOP/out/host/linux-x86/bin
MKTOOLS=$TOP/system/tools/mkbootimg
OUROTA=$TOP/out/target/product/op5911/system/etc/security/otacerts.zip
OUT=$TOP/vendor/oneplus/op5911/images/vendor_boot.img

# --- stock vendor_boot header geometry (verified from the pristine image) ---
HDR_VERSION=4
PAGESIZE=4096
KERNEL_OFFSET=0x40000000
RAMDISK_OFFSET=0x66f00000
TAGS_OFFSET=0x47c80000
DTB_OFFSET=0x47c80000
VENDOR_CMDLINE="bootopt=64S3,32N2,64N2 buildvariant=user"
PART_SIZE=67108864   # BOARD_VENDOR_BOOTIMAGE_PARTITION_SIZE

for t in "$HOSTBIN/lz4" "$HOSTBIN/mkbootfs" "$MKTOOLS/mkbootimg.py" "$MKTOOLS/unpack_bootimg.py"; do
    [ -e "$t" ] || { echo "missing $t (run: m lz4 mkbootfs)" >&2; exit 1; }
done
[ -f "$OUROTA" ] || { echo "missing $OUROTA - run: m systemimage" >&2; exit 1; }

WORK=$(mktemp -d "$TOP/out/op5911-vendor_boot.XXXXXX")   # ramdisk is ~108 MB uncompressed
trap 'rm -rf "$WORK"' EXIT

echo "== unpacking $STOCK"
python3 "$MKTOOLS/unpack_bootimg.py" --boot_img "$STOCK" --out "$WORK/u" >/dev/null
[ -f "$WORK/u/dtb" ] && [ -f "$WORK/u/vendor_ramdisk00" ] || { echo "unexpected stock layout" >&2; exit 1; }

echo "== extracting ramdisk (lz4 legacy)"
"$HOSTBIN/lz4" -d -f "$WORK/u/vendor_ramdisk00" "$WORK/ramdisk.cpio" 2>/dev/null
mkdir -p "$WORK/rd"
( cd "$WORK/rd" && cpio -idm --no-absolute-filenames < "$WORK/ramdisk.cpio" 2>/dev/null )

OTA_IN_RD="$WORK/rd/system/etc/security/otacerts.zip"
[ -f "$OTA_IN_RD" ] || { echo "stock ramdisk has no $OTA_IN_RD" >&2; exit 1; }

echo "== swapping otacerts.zip  (OPPO -> our build cert)"
echo "   stock: $(unzip -Z1 "$OTA_IN_RD" | tr '\n' ' ')"
cp "$OUROTA" "$OTA_IN_RD"
echo "   new:   $(unzip -Z1 "$OTA_IN_RD" | tr '\n' ' ')"

echo "== repacking ramdisk (mkbootfs -> lz4 legacy)"
"$HOSTBIN/mkbootfs" "$WORK/rd" | "$HOSTBIN/lz4" -l -9 -q > "$WORK/ramdisk.new.lz4"

echo "== building vendor_boot.img (v4, stock geometry)"
mkdir -p "$(dirname "$OUT")"
python3 "$MKTOOLS/mkbootimg.py" \
    --header_version "$HDR_VERSION" \
    --pagesize "$PAGESIZE" \
    --base 0x0 \
    --kernel_offset "$KERNEL_OFFSET" \
    --ramdisk_offset "$RAMDISK_OFFSET" \
    --tags_offset "$TAGS_OFFSET" \
    --dtb_offset "$DTB_OFFSET" \
    --vendor_cmdline "$VENDOR_CMDLINE" \
    --board "" \
    --dtb "$WORK/u/dtb" \
    --ramdisk_type platform \
    --ramdisk_name "" \
    --vendor_ramdisk_fragment "$WORK/ramdisk.new.lz4" \
    --vendor_boot "$OUT"

echo "== verifying result"
SZ=$(stat -c%s "$OUT")
[ "$SZ" -le "$PART_SIZE" ] || { echo "image $SZ > partition $PART_SIZE" >&2; exit 1; }
python3 "$MKTOOLS/unpack_bootimg.py" --boot_img "$OUT" --out "$WORK/v" >/dev/null
cmp -s "$WORK/u/dtb" "$WORK/v/dtb" || { echo "dtb mismatch after repack" >&2; exit 1; }
python3 "$MKTOOLS/unpack_bootimg.py" --boot_img "$OUT" --format=info 2>/dev/null \
    | grep -q 'type: 0x1' || { echo "ramdisk type not platform(0x1)" >&2; exit 1; }

echo "done: $OUT  ($SZ bytes, fits ${PART_SIZE})"
