#!/bin/bash
# Build a complete super image for RESCUE ONLY (slot b only, 14 partitions).
# Normal first install uses a full-OTA sideload; this 12.3 GB raw image is NOT a
# release artifact and must not be shipped to users.
# our system/system_ext/product/vendor + stock odm/vendor_dlkm/odm_dlkm/my_*.
# Layout = stock super geometry (3 metadata slots, Virtual A/B, 512K alignment).
# Takes the images from the target-files staging that ota/make-ota.sh prepared,
# so run make-ota.sh first.
#
# usage: device/oneplus/op5911/ota/make-super.sh [raw|sparse]   (default raw)
#   raw    -> $OP5911_OTA_OUT/super-b.raw  (12.3 GB; write with root recovery dd)
#   sparse -> $OP5911_OTA_OUT/super-b.img  (for fastboot flash super - untested here)
set -eo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
TOP=$(cd "$HERE/../../../.." && pwd)
[ -f "$HERE/local.env" ] && . "$HERE/local.env"
MODE=${1:-raw}
OP5911_PRODUCT=${OP5911_PRODUCT:-lineage_op5911}
D=$TOP/out/target/product/op5911/obj/PACKAGING/target_files_intermediates/${OP5911_PRODUCT}-target_files
LPMAKE=$TOP/out/host/linux-x86/bin/lpmake
PARTS="system system_ext product vendor odm vendor_dlkm odm_dlkm my_product my_engineering my_company my_carrier my_region my_heytap my_manifest"
args=()
for p in $PARTS; do
    img=$D/IMAGES/$p.img
    [ -f "$img" ] || { echo "missing $img - run ota/make-ota.sh first" >&2; exit 1; }
    args+=(-p "${p}_b:readonly:$(stat -c %s "$img"):main_b" -i "${p}_b=$img")
done
case $MODE in
    raw)    OUTIMG=$OP5911_OTA_OUT/super-b.raw; extra=() ;;
    sparse) OUTIMG=$OP5911_OTA_OUT/super-b.img; extra=(--sparse) ;;
    *) echo "mode must be raw or sparse" >&2; exit 2 ;;
esac
"$LPMAKE" --metadata-size 65536 --super-name super --metadata-slots 3 --virtual-ab \
    --device-size 12348030976 --alignment 524288 --block-size 4096 \
    --group main_b:12343836672 "${args[@]}" "${extra[@]}" --output "$OUTIMG" 2>&1 \
    | grep -vE 'Invalid sparse|will resize from' || true
ls -la "$OUTIMG"
