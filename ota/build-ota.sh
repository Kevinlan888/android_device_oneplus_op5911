#!/bin/bash
# One-command OP5911 build: refresh target-files, build recovery, then package
# a full (and optionally incremental) sideloadable OTA.
#
# The vendor_boot included in target-files is intentionally not buildable; the
# OTA uses the grafted recovery vendor_boot instead. target-files-package
# therefore ends with a known mkbootimg error after the staging tree has been
# populated. This script accepts only that failure, verifies the staging tree,
# and continues.
#
# usage: device/oneplus/op5911/ota/build-ota.sh [options]
#   --build-number VALUE        use VALUE instead of a timestamp
#   --incremental-from FILE     also build an incremental OTA from target_files-<old>.zip
#   -h, --help                  show this help
#
# The build number may also be set with OP5911_BUILD_NUMBER. Output and logs go
# to OP5911_OTA_OUT from ota/local.env. This script builds only; it never flashes.
set -eo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
DEV=$(dirname "$HERE")
TOP=$(cd "$DEV/../../.." && pwd)
PRODUCT_OUT=$TOP/out/target/product/op5911
OP5911_PRODUCT=${OP5911_PRODUCT:-lineage_op5911}
OP5911_LUNCH=${OP5911_LUNCH:-${OP5911_PRODUCT}-bp4a-userdebug}
D=$PRODUCT_OUT/obj/PACKAGING/target_files_intermediates/${OP5911_PRODUCT}-target_files
RAMDISK_REL=out/target/product/op5911/ramdisk-recovery.img

usage() {
    cat <<'EOF'
usage: device/oneplus/op5911/ota/build-ota.sh [options]
  --build-number VALUE        use VALUE instead of a timestamp
  --incremental-from FILE     also build an incremental OTA from target_files-<old>.zip
  -h, --help                  show this help

The build number may also be set with OP5911_BUILD_NUMBER. Output and logs go
to OP5911_OTA_OUT from ota/local.env. This script builds only; it never flashes.
EOF
}

die() {
    printf '\nERROR: %s\n' "$*" >&2
    [ -n "${LOG:-}" ] && printf 'Build log: %s\n' "$LOG" >&2
    exit 1
}

REQ_BUILD_NUMBER=
INCR_FROM=
while [ $# -gt 0 ]; do
    case $1 in
        --build-number)
            [ $# -ge 2 ] || die "--build-number needs a value"
            REQ_BUILD_NUMBER=$2
            shift 2
            ;;
        --incremental-from)
            [ $# -ge 2 ] || die "--incremental-from needs a target-files zip"
            INCR_FROM=$(readlink -f "$2" 2>/dev/null) \
                || die "cannot resolve incremental source: $2"
            [ -f "$INCR_FROM" ] || die "incremental source not found: $2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "unknown argument: $1 (use --help)"
            ;;
    esac
done

[ -f "$HERE/local.env" ] || die "missing $HERE/local.env"
. "$HERE/local.env"
[ -n "${OP5911_OTA_OUT:-}" ] || die "OP5911_OTA_OUT not set in $HERE/local.env"

BUILD_NUMBER=${REQ_BUILD_NUMBER:-${OP5911_BUILD_NUMBER:-$(date +%Y%m%d%H%M%S)}}
case $BUILD_NUMBER in
    ''|eng.*|*[!A-Za-z0-9._-]*) die "invalid build number: $BUILD_NUMBER" ;;
esac
# Keep HAS_BUILD_NUMBER stable across every m invocation. Otherwise the host
# tools, target-files and recovery steps toggle it (false/true/false), which
# makes Soong regenerate the whole build graph and can add about an hour.
export BUILD_NUMBER

mkdir -p "$OP5911_OTA_OUT"
LOG=$OP5911_OTA_OUT/build-$BUILD_NUMBER.log
: > "$LOG"

printf '============================================================\n'
printf 'OP5911 one-command build\n'
printf '  BUILD_NUMBER: %s\n' "$BUILD_NUMBER"
printf '  source:       %s\n' "$TOP"
printf '  output:       %s\n' "$OP5911_OTA_OUT"
printf '  target-files: %s\n' "$D"
printf '  log:          %s\n' "$LOG"
[ -n "$INCR_FROM" ] && printf '  incremental:  %s\n' "$INCR_FROM"
printf '============================================================\n'

cd "$TOP"
source build/envsetup.sh || die "build/envsetup.sh failed"
lunch "$OP5911_LUNCH" || die "lunch $OP5911_LUNCH failed"
export ANDROID_BUILD_TOP=$TOP

run_m() {
    m "$@" 2>&1 | tee -a "$LOG"
    return "${PIPESTATUS[0]}"
}

printf '\n=== [1/4] build host tools\n'
if ! run_m fsck.erofs mkfs.erofs otatools BUILD_NUMBER="$BUILD_NUMBER"; then
    die "host-tool build failed"
fi

printf '\n=== [2/4] refresh target-files (known vendor_boot error is expected)\n'
if ! run_m target-files-package BUILD_NUMBER="$BUILD_NUMBER"; then
    if ! grep -qE -- '--vendor_boot not compatible with given header version|KeyError: .vendor.' "$LOG"; then
        die "target-files-package failed for an unexpected reason"
    fi
    [ -d "$D/META" ] || die "target-files staging was not populated"
    printf '\n   expected vendor_boot packaging error; staging is ready\n'
fi

[ -f "$D/SYSTEM/build.prop" ] || die "missing $D/SYSTEM/build.prop"
grep -qxF "ro.build.version.incremental=$BUILD_NUMBER" "$D/SYSTEM/build.prop" \
    || die "staging tree is stale (build.prop does not contain $BUILD_NUMBER)"

# Catch the failure mode that caused stale overlay resources to be shipped:
# the target-files tree is a separate snapshot from PRODUCT_OUT.
BUILT_APK=$PRODUCT_OUT/product/overlay/FrameworksResOverlayOP5911.apk
STAGED_APK=$D/PRODUCT/overlay/FrameworksResOverlayOP5911.apk
[ -f "$BUILT_APK" ] || die "missing built overlay: $BUILT_APK"
[ -f "$STAGED_APK" ] || die "missing staged overlay: $STAGED_APK"
BUILT_SHA=$(sha256sum "$BUILT_APK" | cut -d' ' -f1)
STAGED_SHA=$(sha256sum "$STAGED_APK" | cut -d' ' -f1)
[ "$BUILT_SHA" = "$STAGED_SHA" ] \
    || die "staged FrameworksResOverlayOP5911.apk does not match PRODUCT_OUT"
printf '   overlay sha256: %s\n' "$STAGED_SHA"

printf '\n=== [3/4] build recovery prerequisites\n'
if ! run_m android.hardware.boot-service.default_recovery "$RAMDISK_REL" \
        BUILD_NUMBER="$BUILD_NUMBER"; then
    die "recovery prerequisite build failed"
fi
[ -s "$TOP/$RAMDISK_REL" ] || die "missing $TOP/$RAMDISK_REL"

printf '\n=== [4/4] package OTA\n'
ota_args=()
[ -n "$INCR_FROM" ] && ota_args+=(--incremental-from "$INCR_FROM")
if ! "$HERE/make-ota.sh" "${ota_args[@]}" 2>&1 | tee -a "$LOG"; then
    die "OTA packaging failed"
fi

FULL=$OP5911_OTA_OUT/op5911-ota-full-$BUILD_NUMBER.zip
TARGET_FILES=$OP5911_OTA_OUT/target_files-$BUILD_NUMBER.zip
BOOTSTRAP=$OP5911_OTA_OUT/bootstrap
[ -f "$FULL" ] || die "full OTA was not created: $FULL"
[ -f "$TARGET_FILES" ] || die "target-files archive was not created: $TARGET_FILES"
for f in boot.img dtbo.img vendor_boot-recovery.img vbmeta.img; do
    [ -f "$BOOTSTRAP/$f" ] || die "bootstrap/$f was not created"
done

INCR=
if [ -n "$INCR_FROM" ]; then
    OLD=$(basename "$INCR_FROM" .zip)
    OLD=${OLD#target_files-}
    INCR=$OP5911_OTA_OUT/op5911-ota-incr-$OLD-to-$BUILD_NUMBER.zip
    [ -f "$INCR" ] || die "incremental OTA was not created: $INCR"
fi

printf '\n=== release directory (user-facing files only)\n'
RELEASE_ROOT=$OP5911_OTA_OUT/release
release_args=(--build-number "$BUILD_NUMBER" --output-root "$RELEASE_ROOT" --force)
[ -n "$INCR" ] && release_args+=(--incremental "$INCR")
if ! "$HERE/make-release.sh" "${release_args[@]}" 2>&1 | tee -a "$LOG"; then
    die "release packaging failed"
fi
RELEASE=$RELEASE_ROOT/op5911-$BUILD_NUMBER
[ -f "$RELEASE/SHA256SUMS" ] || die "release checksums were not created"

printf '\n============================================================\n'
printf 'BUILD_DONE\n'
printf '  BUILD_NUMBER: %s\n' "$BUILD_NUMBER"
printf '  full OTA:     %s (%s)\n' "$FULL" "$(du -h "$FULL" | cut -f1)"
printf '  bootstrap:    %s\n' "$BOOTSTRAP"
if [ -n "$INCR" ]; then
    printf '  incremental:  %s (%s)\n' "$INCR" "$(du -h "$INCR" | cut -f1)"
fi
printf '  target-files: %s (keep it for the next incremental)\n' "$TARGET_FILES"
printf '  release dir:  %s (%s)\n' "$RELEASE" "$(du -sh "$RELEASE" | cut -f1)"
printf '  log:          %s\n' "$LOG"
printf '============================================================\n'
