#!/bin/bash
# Stage the small first-install bootstrap set. The full OTA rebuilds every
# dynamic partition on the target slot, so no whole-super raw image is needed.
set -eo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
DEV=$(dirname "$HERE")
TOP=$(cd "$DEV/../../.." && pwd)

[ -f "$HERE/local.env" ] && . "$HERE/local.env"
for v in OP5911_STOCK_FIRMWARE OP5911_STOCK_BOOT OP5911_STOCK_VBMETA OP5911_OTA_OUT; do
    [ -n "${!v}" ] || { echo "$v not set (ota/local.env)" >&2; exit 1; }
done

RECOVERY=$TOP/vendor/oneplus/op5911/images/vendor_boot-recovery.img
for f in "$OP5911_STOCK_FIRMWARE/boot.img" "$OP5911_STOCK_FIRMWARE/dtbo.img" \
         "$OP5911_STOCK_FIRMWARE/SHA256SUMS" "$OP5911_STOCK_VBMETA" "$RECOVERY"; do
    [ -f "$f" ] || { echo "missing bootstrap input: $f" >&2; exit 1; }
done

( cd "$OP5911_STOCK_FIRMWARE" && sha256sum --quiet -c SHA256SUMS ) \
    || { echo "stock firmware sha256 mismatch" >&2; exit 1; }
cmp -s "$OP5911_STOCK_FIRMWARE/boot.img" "$OP5911_STOCK_BOOT" \
    || { echo "firmware boot.img != OP5911_STOCK_BOOT" >&2; exit 1; }

AVB=$TOP/external/avb/avbtool.py
[ -f "$AVB" ] || { echo "missing $AVB" >&2; exit 1; }
python3 "$AVB" info_image --image "$OP5911_STOCK_VBMETA" \
    | grep -q "Public key (sha1):        1a130f9ac8720d5c66e8b62c92505173633166f6" \
    || { echo "vbmeta is not stock-signed" >&2; exit 1; }
python3 "$AVB" info_image --image "$OP5911_STOCK_VBMETA" | grep -qE '^Flags: +3$' \
    || { echo "vbmeta flags != 3" >&2; exit 1; }

mkdir -p "$OP5911_OTA_OUT"
STAGE=$(mktemp -d "$OP5911_OTA_OUT/.bootstrap.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
cp -f "$OP5911_STOCK_FIRMWARE/boot.img" "$STAGE/boot.img"
cp -f "$OP5911_STOCK_FIRMWARE/dtbo.img" "$STAGE/dtbo.img"
cp -f "$RECOVERY" "$STAGE/vendor_boot-recovery.img"
cp -f "$OP5911_STOCK_VBMETA" "$STAGE/vbmeta.img"

DEST=$OP5911_OTA_OUT/bootstrap
rm -rf "$DEST"
mv "$STAGE" "$DEST"
trap - EXIT

echo "bootstrap ready: $DEST"
du -h "$DEST"/*.img | sed 's/^/   /'
printf '   total: %s\n' "$(du -sh "$DEST" | cut -f1)"
