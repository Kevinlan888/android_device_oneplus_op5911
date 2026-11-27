#!/bin/bash
# Build a recovery-capable vendor_boot (and a standalone recovery.img for
# `fastboot boot`) by grafting the clean AOSP recovery userspace into the stock
# OP5911 combined vendor_boot ramdisk.
#
# Why a graft and not a from-scratch recovery:
#   The stock vendor_boot ramdisk is a COMBINED ramdisk: it carries the device
#   first-stage bits (first_stage_ramdisk/, /lib/modules with 270 vendor .ko,
#   init.recovery.mt6895.rc with the MTK preloader symlinks) AND a /system that
#   is used ONLY in recovery mode. OPPO's /system ships phoenix_recovery, whose
#   UI has no `adb sideload`. We keep every device/first-stage bit byte-for-byte
#   and replace exactly the recovery userspace:
#       /system  -> AOSP recovery /system  (clean `recovery` + minadbd sideload,
#                                            self-contained 61 libs, and our
#                                            testkey otacerts.zip baked in)
#       /res     -> AOSP recovery /res     (minui UI resources for AOSP recovery)
#   and we append the three ro.recovery.usb.* props (VID/PID) the AOSP recovery
#   init.rc needs to bring up the ConfigFS USB gadget -- stock prop.default has
#   no ro.recovery.usb.* (OPPO drove USB differently), so without them the
#   gadget idVendor is empty and the port never enumerates for sideload.
#
# Everything else stays stock, so:
#   - normal boot is untouched (it runs boot.img's generic /init, switch_roots to
#     the real /system, and never reads the vendor ramdisk's /system);
#   - first-stage mounting + the 270 vendor modules + SELinux labelling of
#     /lib/modules, /my_*, device nodes all keep the stock policy that knows them;
#   - AOSP init.rc (now in /system) does `import /init.recovery.${ro.hardware}.rc`
#     == the stock /init.recovery.mt6895.rc we keep, and starts the clean
#     `recovery` service instead of phoenix_recovery.
#
# Run from the AOSP source root after `source build/envsetup.sh`,
# `lunch aosp_op5911-bp1a-userdebug` and
# `m out/target/product/op5911/ramdisk-recovery.img` (populates recovery/root):
#
#   device/oneplus/op5911/vendor_boot-patch/build-recovery.sh \
#       /path/to/stock/vendor_boot_b.img /path/to/stock/boot_b.img
#
# Outputs (under vendor/oneplus/op5911/images/):
#   vendor_boot-recovery.img  -> fastboot flash vendor_boot_b  (persistent, carries dtb)
#   recovery-fastboot.img     -> fastboot boot                 (non-destructive test)
set -euo pipefail

STOCK_VB=${1:?usage: $0 stock-vendor_boot_b.img stock-boot_b.img}
STOCK_BOOT=${2:?usage: $0 stock-vendor_boot_b.img stock-boot_b.img}
HERE=$(cd "$(dirname "$0")" && pwd)
TOP=${ANDROID_BUILD_TOP:-$(pwd)}
HOSTBIN=$TOP/out/host/linux-x86/bin
MK=$TOP/system/tools/mkbootimg
RROOT=$TOP/out/target/product/op5911/recovery/root
OUTDIR=$TOP/vendor/oneplus/op5911/images
OUT_VB=$OUTDIR/vendor_boot-recovery.img
OUT_RI=$OUTDIR/recovery-fastboot.img

# --- stock vendor_boot header geometry (verified from the pristine image) ---
PAGESIZE=4096
KERNEL_OFFSET=0x40000000
RAMDISK_OFFSET=0x66f00000
TAGS_OFFSET=0x47c80000
DTB_OFFSET=0x47c80000
VENDOR_CMDLINE="bootopt=64S3,32N2,64N2 buildvariant=user"
VB_PART_SIZE=67108864    # BOARD_VENDOR_BOOTIMAGE_PARTITION_SIZE

for t in "$HOSTBIN/lz4" "$HOSTBIN/mkbootfs" "$MK/mkbootimg.py" "$MK/unpack_bootimg.py"; do
    [ -e "$t" ] || { echo "missing $t (run: m lz4 mkbootfs)" >&2; exit 1; }
done
[ -d "$RROOT/system" ] || { echo "missing $RROOT (run: m .../ramdisk-recovery.img)" >&2; exit 1; }
[ -f "$RROOT/prop.default" ] || { echo "missing $RROOT/prop.default" >&2; exit 1; }

WORK=$(mktemp -d "$TOP/out/op5911-recovery.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

echo "== unpacking stock vendor_boot: $STOCK_VB"
python3 "$MK/unpack_bootimg.py" --boot_img "$STOCK_VB" --out "$WORK/u" >/dev/null
[ -f "$WORK/u/dtb" ] && [ -f "$WORK/u/vendor_ramdisk00" ] || { echo "unexpected stock vendor_boot layout" >&2; exit 1; }

echo "== extracting stock combined ramdisk (lz4 legacy -> cpio)"
"$HOSTBIN/lz4" -d -f "$WORK/u/vendor_ramdisk00" "$WORK/rd.cpio" 2>/dev/null
mkdir -p "$WORK/rd"
( cd "$WORK/rd" && cpio -idm --no-absolute-filenames < "$WORK/rd.cpio" 2>/dev/null )
[ -d "$WORK/rd/first_stage_ramdisk" ] && [ -d "$WORK/rd/lib/modules" ] \
    || { echo "stock ramdisk missing first_stage_ramdisk/ or lib/modules" >&2; exit 1; }

echo "== grafting AOSP recovery userspace"
echo "   /system : stock $(du -sh "$WORK/rd/system" | cut -f1) -> AOSP $(du -sh "$RROOT/system" | cut -f1)"
rm -rf "$WORK/rd/system"
cp -a "$RROOT/system" "$WORK/rd/system"
# phoenix_recovery lived only in the old /system; it is gone now. The stock
# init.rc that started it is also gone (replaced by AOSP's init.rc inside /system).
rm -rf "$WORK/rd/res"
cp -a "$RROOT/res" "$WORK/rd/res"
rm -f "$WORK/rd/res/Android.bp"

echo "== allowing passwordless adb shell in recovery (ro.adb.secure=0)"
sed -i 's/^ro\.adb\.secure=.*/ro.adb.secure=0/' "$WORK/rd/prop.default"

echo "== appending ro.recovery.usb.* props (AOSP gadget VID/PID)"
# prop.default is the real file; /default.prop is a symlink to it.
if ! grep -q '^ro.recovery.usb.vid=' "$WORK/rd/prop.default"; then
    {
        echo ""
        echo "# AOSP recovery USB gadget (grafted; stock had none)"
        grep -h '^ro.recovery.usb\.' "$RROOT/prop.default"
    } >> "$WORK/rd/prop.default"
fi
grep '^ro.recovery.usb\.' "$WORK/rd/prop.default" | sed 's/^/   /'

echo "== recovery fstab: no auto-format, drop /cache(oplusreserve2) + calibration partitions"
"$HERE"/sanitize-recovery-fstab.sh "$WORK/rd/system/etc/recovery.fstab"

if [ -n "${RECOVERY_BUILD_PROPS:-}" ]; then
    echo "== recovery build identity from $RECOVERY_BUILD_PROPS"
    "$HERE"/set-recovery-build-props.sh "$WORK/rd/prop.default" "$RECOVERY_BUILD_PROPS"
else
    echo "== WARNING: RECOVERY_BUILD_PROPS unset - recovery keeps stock build identity (incremental OTAs will be rejected)"
fi

echo "== first-stage fstab: dropping my_stock/my_preload/my_bigball"
# ColorOS-only app partitions (5.6G) that AOSP never reads. Without them a full
# A/B OTA carrying every fstab-required dynamic partition fits in super. Must
# match the /vendor/etc/fstab.mt6895 edit in vendor-patch/patch-vendor-image.sh.
FS1="$WORK/rd/first_stage_ramdisk/fstab.mt6895"
grep -qE '^my_stock ' "$FS1" || { echo "unexpected stock fstab (no my_stock)" >&2; exit 1; }
sed -i -E '/^(\/mnt\/vendor\/)?my_(stock|preload|bigball)[ \t]/d' "$FS1"
! grep -qE 'my_(stock|preload|bigball)' "$FS1" || { echo "fstab strip failed" >&2; exit 1; }

# NOTE on recovery root: do NOT make adbd run as root here. On this device a root
# adbd (whether via `adb root` restart or via ro.debuggable=1 + service.adb.root=1 at
# boot) fails to bring up the ConfigFS USB gadget UNDER SELINUX ENFORCING (an SELinux
# gadget denial; confirmed fixed by androidboot.selinux=permissive in the debug build).
# Production stays Enforcing + shell adbd: `adb sideload` and the menu work as shell.
#
# ===== A/B OTA APPLY SUPPORT (lets update_engine actually apply the sideloaded OTA) =====
# Without this, update_engine_sideload HANGS (~47%): servicemanager SIGABRTs for want of
# the *_service_contexts (gSehandle==null), so update_engine blocks forever on
# servicemanager.ready; and it then needs an IBootControl HAL. The AOSP recovery /system
# graft already carries (from `m android.hardware.boot-service.default_recovery`) the AIDL
# boot HAL binary at /system/bin/hw/, its init .rc, and its VINTF fragment - all under
# /system. What is missing from the graft: the *_service_contexts (they live at the
# recovery/root ROOT, not under /system) and an explicit start for the HAL (class early_hal,
# which this init never class_starts). This is the full, Enforcing-safe fix.
echo "== A/B OTA: adding service_contexts + boot HAL autostart"
for f in plat_service_contexts system_ext_service_contexts product_service_contexts vendor_service_contexts; do
    [ -f "$RROOT/$f" ] || { echo "missing $RROOT/$f" >&2; exit 1; }
    cp "$RROOT/$f" "$WORK/rd/$f"
    mkdir -p "$WORK/rd/system/etc/selinux"
    cp "$RROOT/$f" "$WORK/rd/system/etc/selinux/$f"
done
[ -x "$WORK/rd/system/bin/hw/android.hardware.boot-service.default_recovery" ] \
    || { echo "boot HAL missing from graft (run: m android.hardware.boot-service.default_recovery)" >&2; exit 1; }
[ -f "$WORK/rd/system/etc/vintf/manifest/android.hardware.boot-service.default.xml" ] \
    || { echo "boot HAL VINTF fragment missing from graft" >&2; exit 1; }
# start the AIDL boot HAL once servicemanager is ready (update_engine looks it up there)
RC="$WORK/rd/system/etc/init/hw/init.rc"
if ! grep -q 'start vendor.boot-default' "$RC"; then
    cat >> "$RC" <<'EOF'

# A/B OTA: start the AIDL boot HAL (IBootControl/default) once servicemanager is ready
on property:servicemanager.ready=true
    start vendor.boot-default
EOF
fi
echo "   service_contexts placed; boot HAL + vintf present; autostart added"

echo "== SELinux: making the grafted recovery work with recovery ENFORCING"
python3 "$HERE/patch-recovery-sepolicy.py" "$WORK/rd" "$TOP"

echo "== verifying graft"
[ -x "$WORK/rd/system/bin/recovery" ] || { echo "no /system/bin/recovery after graft" >&2; exit 1; }
[ -x "$WORK/rd/system/bin/minadbd" ] || { echo "no /system/bin/minadbd after graft" >&2; exit 1; }
[ ! -e "$WORK/rd/system/bin/phoenix_recovery" ] || { echo "phoenix_recovery still present!" >&2; exit 1; }
grep -q '^service recovery /system/bin/recovery' "$WORK/rd/system/etc/init/hw/init.rc" \
    || { echo "AOSP init.rc has no recovery service" >&2; exit 1; }
! grep -q 'phoenix_recovery' "$WORK/rd/system/etc/init/hw/init.rc" \
    || { echo "init.rc still references phoenix_recovery" >&2; exit 1; }
unzip -Z1 "$WORK/rd/system/etc/security/otacerts.zip" | sed 's/^/   otacert: /'

echo "== repacking combined ramdisk (mkbootfs -> lz4 legacy)"
"$HOSTBIN/mkbootfs" "$WORK/rd" | "$HOSTBIN/lz4" -l -9 -q > "$WORK/ramdisk.lz4"
echo "   ramdisk.lz4 $(stat -c%s "$WORK/ramdisk.lz4") bytes"

mkdir -p "$OUTDIR"

echo "== building vendor_boot-recovery.img (v4, stock geometry, carries dtb)"
python3 "$MK/mkbootimg.py" \
    --header_version 4 \
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
    --vendor_ramdisk_fragment "$WORK/ramdisk.lz4" \
    --vendor_boot "$OUT_VB"
VBSZ=$(stat -c%s "$OUT_VB")
[ "$VBSZ" -le "$VB_PART_SIZE" ] || { echo "vendor_boot $VBSZ > partition $VB_PART_SIZE" >&2; exit 1; }
python3 "$MK/unpack_bootimg.py" --boot_img "$OUT_VB" --out "$WORK/v" >/dev/null
cmp -s "$WORK/u/dtb" "$WORK/v/dtb" || { echo "dtb mismatch after repack" >&2; exit 1; }

echo "== building recovery-fastboot.img (stock kernel + hybrid ramdisk, v4 boot)"
# Standalone RAM-bootable image for `fastboot boot`. v4 boot.img carries no dtb;
# on MTK the bootloader pulls dtb from the on-device dtbo at RAM-boot. If the
# device refuses `fastboot boot` or the kernel can't find its dtb, use the
# vendor_boot-recovery.img flash path instead.
python3 "$MK/unpack_bootimg.py" --boot_img "$STOCK_BOOT" --out "$WORK/b" >/dev/null
[ -f "$WORK/b/kernel" ] || { echo "no kernel in stock boot.img" >&2; exit 1; }
python3 "$MK/mkbootimg.py" \
    --header_version 4 \
    --pagesize "$PAGESIZE" \
    --base 0x0 \
    --kernel_offset "$KERNEL_OFFSET" \
    --ramdisk_offset "$RAMDISK_OFFSET" \
    --tags_offset "$TAGS_OFFSET" \
    --cmdline "" \
    --os_version 15.0.0 \
    --os_patch_level 2025-07 \
    --kernel "$WORK/b/kernel" \
    --ramdisk "$WORK/ramdisk.lz4" \
    --output "$OUT_RI"
RISZ=$(stat -c%s "$OUT_RI")

echo
echo "done:"
echo "  $OUT_VB   ($VBSZ bytes, fits ${VB_PART_SIZE})   # fastboot flash vendor_boot_b"
echo "  $OUT_RI   ($RISZ bytes)                          # fastboot boot"
