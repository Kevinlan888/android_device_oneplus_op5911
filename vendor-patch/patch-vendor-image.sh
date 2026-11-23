#!/bin/bash
# Build a patched vendor.img from the stock OP5911 vendor image.
#
# Run from the root of the AOSP source tree after `source build/envsetup.sh`
# and `m fsck.erofs mkfs.erofs plat_file_contexts`:
#
#   device/oneplus/op5911/vendor-patch/patch-vendor-image.sh /path/to/vendor.img
#
# The input can be the stock vendor image or an already-patched one (for example
# `adb exec-out dd if=/dev/block/dm-11` on a running install); every edit below is
# idempotent, so re-running on a patched image only adds what is missing.
#
# Output: vendor/oneplus/op5911/images/vendor.img (picked up by BOARD_PREBUILT_VENDORIMAGE)
#
# Changes applied to the stock vendor:
#   - audio policy: drop "Voice Call In" so APM uses legacy call routing
#     (fixes audioserver abort / silent calls on Android 15)
#   - task_profiles.json: SFMainPolicy / SFRenderEnginePolicy -> foreground cpuset
#   - patched oplus fingerprint HAL in /vendor/bin/hw + fps_hal override
#   - powerscntbl.xml with launch/interaction boosts (bind-mounted over /odm)
#   - vendor sepolicy: radio may set MTK IMS props, init may mount on vendor_configs_file
#   - vendor sepolicy (Android 16 only): drop the vendor genfscon that conflicts
#     with the platform's proc_dirty label for /sys/vm/dirty_writeback_centisecs,
#     and let vendor_init write that now platform-labelled node
#   - vendor_property_contexts: label ro.oplus.backlight./ro.oplus.bl. for mtk_hal_pq (log spam)
set -euo pipefail

STOCK=${1:?usage: $0 stock-vendor.img}
HERE=$(cd "$(dirname "$0")" && pwd)
TOP=${ANDROID_BUILD_TOP:-$(pwd)}
HOSTBIN=$TOP/out/host/linux-x86/bin
OUT=$TOP/vendor/oneplus/op5911/images/vendor.img
mkdir -p "$TOP/out"
WORK=$(mktemp -d "$TOP/out/op5911-vendor.XXXXXX")   # not /tmp: extraction needs ~2 GB
trap 'rm -rf "$WORK"' EXIT

for t in fsck.erofs mkfs.erofs; do
    [ -x "$HOSTBIN/$t" ] || { echo "missing $HOSTBIN/$t - run: m fsck.erofs mkfs.erofs" >&2; exit 1; }
done

echo "== extracting $STOCK"
"$HOSTBIN/fsck.erofs" --extract="$WORK/vendor" "$STOCK"

V=$WORK/vendor
F=$HERE/files
FSCFG=$WORK/fs_config
# mkfs.erofs looks up the image root as "" -> needs a "/" entry (the rest are "vendor/...")
{ echo "/ 0 2000 755"; cat "$HERE/vendor_fs_config.txt"; } > "$FSCFG"

install_file() {  # src dst-relative-to-vendor mode uid gid
    install -D -m "$3" "$1" "$V/$2"
    grep -q "^vendor/$2 " "$FSCFG" || echo "vendor/$2 $4 $5 $3" >> "$FSCFG"
}

echo "== applying patches"
install_file "$F/etc/audio_policy_configuration.xml"                    etc/audio_policy_configuration.xml 644 0 0
install_file "$F/etc/audio_policy_configuration_a2dp_offload_disabled.xml" etc/audio_policy_configuration_a2dp_offload_disabled.xml 644 0 0
install_file "$F/etc/task_profiles.json"                                etc/task_profiles.json 644 0 0
install_file "$F/etc/op5911/powerscntbl.xml"                            etc/op5911/powerscntbl.xml 644 0 0
install_file "$F/etc/init/init.op5911.vendor.rc"                        etc/init/init.op5911.vendor.rc 644 0 0
install_file "$F/bin/hw/vendor.oplus.hardware.biometrics.fingerprint@2.1-service" \
             bin/hw/vendor.oplus.hardware.biometrics.fingerprint@2.1-service 755 0 2000
install_file "$F/usr/keylayout/touchpanel.kl"                          usr/keylayout/touchpanel.kl 644 0 0
grep -q '^vendor/etc/op5911 ' "$FSCFG" || echo "vendor/etc/op5911 0 2000 755" >> "$FSCFG"
# mkfs.erofs needs a canned fs_config entry for every intermediate dir of a new file.
grep -q '^vendor/usr ' "$FSCFG" || echo "vendor/usr 0 0 755" >> "$FSCFG"
grep -q '^vendor/usr/keylayout ' "$FSCFG" || echo "vendor/usr/keylayout 0 0 755" >> "$FSCFG"

if ! grep -q 'OP5911: allow MTK IMS' "$V/etc/selinux/vendor_sepolicy.cil"; then
    cat "$HERE/vendor_sepolicy_append.cil" >> "$V/etc/selinux/vendor_sepolicy.cil"
fi
# Android 16 platform policy labels /sys/vm/dirty_writeback_centisecs as
# proc_dirty (AOSP commit 6c174897d, first shipped in android-16.0.0_r4). The
# stock vendor policy labels the same path proc_vm_dirty, and secilc refuses to
# compile the combination ("Found conflicting genfscon rules"), which makes init
# reboot to the bootloader while loading policy. Drop the vendor rule so the
# platform label wins, and keep vendor_init able to write the node
# (init.mt6895.rc sets it to 300). The platform source is the reliable version
# probe: genfs_contexts only has this rule on Android 16+.
if grep -q '^genfscon proc /sys/vm/dirty_writeback_centisecs ' "$TOP/system/sepolicy/private/genfs_contexts"; then
    sed -i '\#^(genfscon proc /sys/vm/dirty_writeback_centisecs #d' "$V/etc/selinux/vendor_sepolicy.cil"
    if ! grep -q 'OP5911: vendor_init may write proc_dirty' "$V/etc/selinux/vendor_sepolicy.cil"; then
        cat >> "$V/etc/selinux/vendor_sepolicy.cil" <<'EOF'

;; OP5911: vendor_init may write proc_dirty (/sys/vm/dirty_writeback_centisecs).
;; A16 platform policy labels that node proc_dirty; the vendor proc_vm_dirty
;; genfscon rule was removed above to avoid a genfscon conflict.
(allow vendor_init_31_0 proc_dirty_31_0 (file (ioctl read write getattr lock append map open watch watch_reads)))
EOF
    fi
fi
if ! grep -q '^ro.oplus.backlight\. ' "$V/etc/selinux/vendor_property_contexts"; then
    cat "$HERE/vendor_property_contexts_append" >> "$V/etc/selinux/vendor_property_contexts"
fi
# Android 15 SurfaceFlinger with non-threaded RenderEngine defers present() past
# the lifetime of the screenshot RenderArea and crashes on every capture.
if grep -q '^debug.renderengine.backend=skiagl$' "$V/build.prop"; then
    sed -i 's/^debug.renderengine.backend=skiagl$/debug.renderengine.backend=skiaglthreaded/' "$V/build.prop"
fi
grep -q '^debug.renderengine.backend=skiaglthreaded$' "$V/build.prop" \
    || { echo "unexpected debug.renderengine.backend in vendor build.prop" >&2; exit 1; }

# Drop the ColorOS-only app partitions (my_stock 3.8G, my_preload 1.4G,
# my_bigball 0.3G) - AOSP never reads them, and keeping them makes a full A/B OTA
# (which must carry every dynamic partition the fstab requires) too big for super.
# Must match the first-stage fstab edit in vendor_boot-patch/build-recovery.sh.
if grep -qE '^my_stock ' "$V/etc/fstab.mt6895"; then
    sed -i -E '/^(\/mnt\/vendor\/)?my_(stock|preload|bigball)[ \t]/d' "$V/etc/fstab.mt6895"
fi
! grep -qE 'my_(stock|preload|bigball)' "$V/etc/fstab.mt6895"

echo "== repacking"
mkdir -p "$(dirname "$OUT")"
# vendor_file_contexts only has vendor-specific rules. The generic ones
# (/vendor(/.*)? -> vendor_file, /vendor/etc -> vendor_configs_file, ...) live in
# plat_file_contexts; without them most files get no label and init fails early.
PLAT_FC=$TOP/out/target/product/op5911/system/etc/selinux/plat_file_contexts
[ -f "$PLAT_FC" ] || { echo "missing $PLAT_FC - build systemimage first" >&2; exit 1; }
FC=$WORK/file_contexts
{ grep -E '^/(\(([a-z_/]+\|)*vendor(\|[a-z_/]+)*\)|vendor/)' "$PLAT_FC"
  cat "$V/etc/selinux/vendor_file_contexts"; } > "$FC"
"$HOSTBIN/mkfs.erofs" -zlz4hc,12 -T0 --mount-point=/vendor \
    --fs-config-file="$FSCFG" \
    --file-contexts="$FC" \
    "$OUT" "$V"

"$HOSTBIN/fsck.erofs" "$OUT" >/dev/null
ls -l "$OUT"
echo "done: $OUT"
