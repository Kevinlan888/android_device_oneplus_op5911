#!/bin/bash
# Build a sideloadable A/B OTA for OP5911 from an already-built target-files
# staging directory. Runs host tools only - no soong analysis.
#
# Prerequisite (see BUILD.md):
#   m target-files-package otatools          # dies at vendor_boot, staging is populated
#   m android.hardware.boot-service.default_recovery \
#     out/target/product/op5911/ramdisk-recovery.img
#
# usage: device/oneplus/op5911/ota/make-ota.sh [--incremental-from OLD_TARGET_FILES.zip]
#
# Output ($OP5911_OTA_OUT):
#   op5911-ota-full-<tag>.zip             full OTA (sideload to install / update)
#   op5911-ota-incr-<old>-to-<tag>.zip    incremental, only with --incremental-from
#   target_files-<tag>.zip                keep it: source for the next incremental
#   bootstrap/                            first-install images, no super raw
# <tag> = ro.build.version.incremental, plus -MMDDhhmm for eng.* builds.
set -eo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
DEV=$(dirname "$HERE")
TOP=$(cd "$DEV/../../.." && pwd)
INCR_FROM=
while [ $# -gt 0 ]; do
    case $1 in
        --incremental-from) INCR_FROM=$(readlink -f "$2"); shift 2 ;;
        *) echo "unknown arg $1" >&2; exit 2 ;;
    esac
done

[ -f "$HERE/local.env" ] && . "$HERE/local.env"
for v in OP5911_STOCK_IMAGES OP5911_STOCK_FIRMWARE OP5911_STOCK_VENDOR_BOOT OP5911_STOCK_BOOT OP5911_STOCK_VBMETA OP5911_OTA_OUT; do
    [ -n "${!v}" ] || { echo "$v not set (ota/local.env)" >&2; exit 1; }
done

cd "$TOP"
set +e; source build/envsetup.sh >/dev/null 2>&1; lunch aosp_op5911-trunk_staging-userdebug >/dev/null 2>&1; set -e
export ANDROID_BUILD_TOP=$TOP
export PATH="$ANDROID_HOST_OUT/bin:$PATH"

D=out/target/product/op5911/obj/PACKAGING/target_files_intermediates/aosp_op5911-target_files
IM=vendor/oneplus/op5911/images
OUT=$OP5911_OTA_OUT
SPL=${OP5911_SPL:-2025-07-01}
STOCK_PARTS="odm vendor_dlkm odm_dlkm my_product my_engineering my_company my_carrier my_region my_heytap my_manifest"
DYN="system system_ext product vendor $STOCK_PARTS"
# Per-slot kernel + firmware. The OTA must write the SAME set the stock vendor
# came from (slot B dump, PGZ110_15.0.0.1101): a slot left with another ColorOS
# version's boot/gpueb/tee/... boots, but runs with a GPU taking seconds per
# frame and UFS runtime-PM WARNs (seen on slot A, 2026-11-10).
FW_PARTS="boot dtbo gpueb lk tee gz scp sspm mcupm spmfw dpm vcp ccu apusys audio_dsp mvpu_algo pi_img md1img mcf_ota vbmeta_system vbmeta_vendor"
SUPER_GROUP=12343836672
[ -d "$D/META" ] || { echo "no target-files staging at $D - run: m target-files-package otatools" >&2; exit 1; }
mkdir -p "$OUT"

echo "=== [1/8] misc_info: no vendor_boot/recovery image build (we graft our own)"
MI=$D/META/misc_info.txt
[ -f "$MI.orig" ] || cp "$MI" "$MI.orig"
cp "$MI.orig" "$MI"
sed -i '/^vendor_boot=true$/d; /^vendor_boot_size=/d; /^no_recovery=/d' "$MI"
echo "no_recovery=true" >> "$MI"

echo "=== [2/8] build.prop identity for this device's recovery checks"
# The recovery runs with the STOCK vendor's ro.product.device (ossi) and checks
# ro.build.tags (release-keys) and SPL (must not go below the device's 2025-07-01).
for p in SYSTEM/build.prop SYSTEM_EXT/etc/build.prop PRODUCT/etc/build.prop ODM/etc/build.prop \
         ODM_DLKM/etc/build.prop VENDOR_DLKM/etc/build.prop SYSTEM/system_dlkm/etc/build.prop; do
    [ -f "$D/$p" ] || continue
    sed -i 's/test-keys/release-keys/g' "$D/$p"
    sed -i -E 's/^(ro\.product\.[a-z_]+\.device)=.*/\1=ossi/' "$D/$p"
done
sed -i -E "s/^ro\.build\.version\.security_patch=.*/ro.build.version.security_patch=$SPL/" "$D/SYSTEM/build.prop"
grep -E '^ro\.build\.(tags|version\.security_patch)=|^ro\.product\.system\.device=' "$D/SYSTEM/build.prop" | sed 's/^/   /'

echo "=== [3/8] (re)build system/system_ext/product images from the edited tree"
rm -f "$D"/IMAGES/{system,system_ext,product}.{img,map} "$D"/META/care_map.{pb,txt}
add_img_to_target_files -a "$D"

echo "=== [4/8] vendor image (stock vendor + vendor-patch)"
"$DEV/vendor-patch/patch-vendor-image.sh" "$OP5911_STOCK_IMAGES/vendor.img" | tail -1

echo "=== [5/8] recovery vendor_boot with this build's identity"
prop() { grep -m1 "^$1=" "$2" | cut -d= -f2-; }
# Fingerprint exactly as ota_from_target_files computes it: brand/name/device are
# resolved in ro.product.property_source_order (product, odm, vendor, system_ext, system).
pprop() {
    local k=$1 f v
    for f in PRODUCT/etc/build.prop ODM/etc/build.prop VENDOR/build.prop SYSTEM_EXT/etc/build.prop SYSTEM/build.prop; do
        [ -f "$D/$f" ] || continue
        v=$(grep -m1 -E "^ro\.product\.[a-z_]+\.$k=" "$D/$f" | cut -d= -f2-)
        [ -n "$v" ] && { echo "$v"; return; }
    done
}
S=$D/SYSTEM/build.prop
INCR=$(prop ro.build.version.incremental "$S")
FP="$(pprop brand)/$(pprop name)/$(pprop device):$(prop ro.build.version.release_or_codename "$S")/$(prop ro.build.id "$S")/$INCR:$(prop ro.build.type "$S")/$(prop ro.build.tags "$S")"
PF=$OUT/recovery-build-$INCR.props
{
    echo "ro.build.fingerprint=$FP"
    echo "ro.build.version.incremental=$INCR"
    echo "ro.build.date.utc=$(prop ro.build.date.utc "$S")"
    echo "ro.build.version.security_patch=$(prop ro.build.version.security_patch "$S")"
} > "$PF"
sed 's/^/   /' "$PF"
RECOVERY_BUILD_PROPS=$PF "$DEV/vendor_boot-patch/build-recovery.sh" \
    "$OP5911_STOCK_VENDOR_BOOT" "$OP5911_STOCK_BOOT" | grep -E 'permissive|sanitized|vendor_boot-recovery.img'

# First install boots a temporary recovery from slot A, then sideloads the full
# OTA into slot B. This small bootstrap set (~116 MB) replaces the old 12.3 GB
# whole-super image; the full OTA recreates every target dynamic partition.
"$HERE/make-bootstrap.sh" | sed 's/^/   /'

echo "=== [6/8] assemble the payload partition set"
cp -f "$IM/vendor.img" "$D/IMAGES/vendor.img"
for p in $STOCK_PARTS; do cp -f "$OP5911_STOCK_IMAGES/$p.img" "$D/IMAGES/$p.img"; rm -f "$D/IMAGES/$p.map"; done
cp -f "$IM/vendor_boot-recovery.img" "$D/IMAGES/vendor_boot.img"
for p in $FW_PARTS; do cp -f "$OP5911_STOCK_FIRMWARE/$p.img" "$D/IMAGES/$p.img"; done
python3 external/avb/avbtool.py info_image --image "$OP5911_STOCK_VBMETA" \
    | grep -q "Public key (sha1):        1a130f9ac8720d5c66e8b62c92505173633166f6" \
    || { echo "vbmeta is not stock-signed" >&2; exit 1; }
python3 external/avb/avbtool.py info_image --image "$OP5911_STOCK_VBMETA" | grep -qE '^Flags: +3$' \
    || { echo "vbmeta flags != 3" >&2; exit 1; }
cp -f "$OP5911_STOCK_VBMETA" "$D/IMAGES/vbmeta.img"
for p in $STOCK_PARTS $FW_PARTS vbmeta vendor_boot; do
    grep -qx "$p" "$D/META/ab_partitions.txt" || echo "$p" >> "$D/META/ab_partitions.txt"
done
for f in "$D/META/dynamic_partitions_info.txt" "$MI"; do
    sed -i -E "s/^dynamic_partition_list=.*/dynamic_partition_list=$DYN/; s/^super_main_partition_list=.*/super_main_partition_list=$DYN/" "$f"
done
tot=0; for p in $DYN; do tot=$((tot + $(stat -c %s "$D/IMAGES/$p.img"))); done
echo "   payload: $(tr '\n' ' ' < "$D/META/ab_partitions.txt")"
echo "   dynamic size per slot $tot, x2 = $((tot*2)) (super group $SUPER_GROUP)"
[ $((tot*2)) -le $SUPER_GROUP ] || { echo "two slots do not fit in super" >&2; exit 1; }

echo "=== [7/8] safety: recovery in this vendor_boot must never auto-format"
W=$(mktemp -d "$TOP/out/op5911-ota-check.XXXXXX"); trap 'rm -rf "$W"' EXIT
python3 system/tools/mkbootimg/unpack_bootimg.py --boot_img "$D/IMAGES/vendor_boot.img" --out "$W" >/dev/null
lz4 -d -q "$W/vendor_ramdisk00" "$W/rd.cpio"
( cd "$W" && cpio -i --quiet --to-stdout system/etc/recovery.fstab < rd.cpio ) > "$W/recovery.fstab"
if grep -vE '^\s*#' "$W/recovery.fstab" | grep -qE 'formattable|[[:space:]]/cache[[:space:]]'; then
    echo "recovery.fstab in vendor_boot still has formattable or /cache - refusing" >&2; exit 1
fi
( cd "$W" && cpio -i --quiet --to-stdout prop.default < rd.cpio ) | grep -qxF "ro.build.fingerprint=$FP" \
    || { echo "recovery prop.default fingerprint != $FP" >&2; exit 1; }
echo "   ok"

echo "=== [8/8] ota_from_target_files"
mkdir -p "$OUT/tmp"; export TMPDIR=$OUT/tmp
# File-name tag. Local builds without BUILD_NUMBER are all "eng.<user>", so add a
# timestamp - otherwise the new target_files would overwrite the old one that
# --incremental-from is reading (and the incremental would be old-to-old).
TAG=$INCR
case $INCR in eng.*)
    TAG=$INCR-$(date +%m%d%H%M)
    echo "   WARNING: built without BUILD_NUMBER ($INCR): the system fingerprint is the same as the" >&2
    echo "   previous build, so PackageManager keeps its stale package cache after this OTA" >&2
    echo "   (manifest changes of system apps are ignored). Rebuild with BUILD_NUMBER=..., or" >&2
    echo "   rm -rf /data/system/package_cache/* on the device and reboot. See BUILD.md section 3." >&2
    ;;
esac
TF=$OUT/target_files-$TAG.zip
[ "$(readlink -f "$TF")" != "$INCR_FROM" ] || { echo "refusing to overwrite --incremental-from $INCR_FROM" >&2; exit 1; }
rm -f "$TF"
PROPS=$(cd "$D" && ls -d SYSTEM/build.prop SYSTEM_EXT/etc/build.prop PRODUCT/etc/build.prop \
    ODM/etc/build.prop ODM_DLKM/etc/build.prop VENDOR_DLKM/etc/build.prop 2>/dev/null)
echo "   target-files props: $(echo $PROPS)"
case " $(echo $PROPS) " in *" SYSTEM/build.prop "*) ;; *) echo "SYSTEM/build.prop missing" >&2; exit 1 ;; esac
( cd "$D" && zip -q -0 -r "$TF" META IMAGES OTA $PROPS )
FULL=$OUT/op5911-ota-full-$TAG.zip
rm -f "$FULL"
ota_from_target_files "$TF" "$FULL"
check_meta() {
    local z=$1 post
    post=$(unzip -p "$z" META-INF/com/android/metadata | sed -n 's/^post-build=//p')
    [ "$post" = "$FP" ] || { echo "post-build $post != recovery fingerprint $FP" >&2; exit 1; }
    unzip -p "$z" META-INF/com/android/metadata | grep -E '^(ota-type|pre-device|pre-build|post-build|post-security-patch-level)=' | sed 's/^/   /'
    ls -la "$z"
}
check_meta "$FULL"
if [ -n "$INCR_FROM" ]; then
    OLD=$(basename "$INCR_FROM" .zip); OLD=${OLD#target_files-}
    INC=$OUT/op5911-ota-incr-$OLD-to-$TAG.zip
    rm -f "$INC"
    ota_from_target_files -i "$INCR_FROM" "$TF" "$INC"
    check_meta "$INC"
fi
rm -rf "$OUT/tmp"
echo "=== DONE_OK  keep $TF for the next incremental"
echo "   user release: device/oneplus/op5911/ota/make-release.sh --build-number $TAG"
