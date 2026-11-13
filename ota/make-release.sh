#!/bin/bash
# Build a clean, user-facing release directory. Keep this whitelist strict:
# target-files, debug recovery images and whole-super images stay in the build
# output and must never be uploaded to users.
#
# usage: make-release.sh [--build-number TAG] [--output-root DIR] [--incremental FILE] [--force]
set -eo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
DEV=$(dirname "$HERE")
TOP=$(cd "$DEV/../../.." && pwd)

usage() {
    cat <<'EOF'
usage: make-release.sh [options]
  --build-number TAG     release to package (default: newest full OTA)
  --output-root DIR      parent directory for release dirs
  --incremental FILE     also include this incremental OTA
  --force                replace an existing release directory
  -h, --help             show this help
EOF
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

[ -f "$HERE/local.env" ] || die "missing $HERE/local.env"
. "$HERE/local.env"
[ -n "${OP5911_OTA_OUT:-}" ] || die "OP5911_OTA_OUT not set in $HERE/local.env"

BUILD_NUMBER=
OUT_ROOT=$OP5911_OTA_OUT/release
INCR=
FORCE=false
while [ $# -gt 0 ]; do
    case $1 in
        --build-number) [ $# -ge 2 ] || die "--build-number needs a value"; BUILD_NUMBER=$2; shift 2 ;;
        --output-root)  [ $# -ge 2 ] || die "--output-root needs a value"; OUT_ROOT=$(readlink -m "$2"); shift 2 ;;
        --incremental)  [ $# -ge 2 ] || die "--incremental needs a file"; INCR=$(readlink -f "$2" 2>/dev/null) || die "cannot resolve $2"; shift 2 ;;
        --force)        FORCE=true; shift ;;
        -h|--help)      usage; exit 0 ;;
        *)              die "unknown argument: $1 (use --help)" ;;
    esac
done

if [ -z "$BUILD_NUMBER" ]; then
    LATEST=$(find "$OP5911_OTA_OUT" -maxdepth 1 -type f -name 'op5911-ota-full-*.zip' \
        -printf '%T@ %p\n' | LC_ALL=C sort -nr | head -n1 | cut -d' ' -f2-)
    [ -n "$LATEST" ] || die "no full OTA found in $OP5911_OTA_OUT"
    BUILD_NUMBER=${LATEST##*/}
    BUILD_NUMBER=${BUILD_NUMBER#op5911-ota-full-}
    BUILD_NUMBER=${BUILD_NUMBER%.zip}
fi
case $BUILD_NUMBER in
    ''|*[!A-Za-z0-9._-]*) die "invalid build number: $BUILD_NUMBER" ;;
esac

FULL=$OP5911_OTA_OUT/op5911-ota-full-$BUILD_NUMBER.zip
TARGET_FILES=$OP5911_OTA_OUT/target_files-$BUILD_NUMBER.zip
BOOTSTRAP=$OP5911_OTA_OUT/bootstrap
[ -f "$FULL" ] || die "missing full OTA: $FULL"
for f in boot.img dtbo.img vendor_boot-recovery.img vbmeta.img; do
    [ -f "$BOOTSTRAP/$f" ] || die "missing bootstrap/$f (run make-bootstrap.sh)"
done
unzip -p "$FULL" META-INF/com/android/metadata \
    | grep -qx "post-build-incremental=$BUILD_NUMBER" \
    || die "full OTA build number does not match $BUILD_NUMBER"
if [ -f "$TARGET_FILES" ]; then
    for pair in boot:boot dtbo:dtbo vendor_boot:vendor_boot-recovery vbmeta:vbmeta; do
        img=${pair%%:*}
        name=${pair##*:}
        unzip -p "$TARGET_FILES" "IMAGES/$img.img" | cmp -s - "$BOOTSTRAP/$name.img" \
            || die "bootstrap/$name.img does not match target-files IMAGES/$img.img"
    done
else
    echo "WARNING: $TARGET_FILES is missing; bootstrap/OTA consistency was not checked" >&2
fi

# add_img_to_target_files / sign_target_files_apks may regenerate vbmeta when AVB
# is enabled. Check the payload itself, not only target_files, so a future build
# cannot ship a bootstrap vbmeta that differs from what the OTA writes.
OTA_EXTRACTOR=$TOP/out/host/linux-x86/bin/ota_extractor
[ -x "$OTA_EXTRACTOR" ] || die "missing $OTA_EXTRACTOR (run: m otatools)"
PAYLOAD_OFFSET=$(unzip -p "$FULL" META-INF/com/android/metadata \
    | sed -n 's/^ota-property-files=.*payload\.bin:\([0-9][0-9]*\):[0-9][0-9]*.*/\1/p')
[ -n "$PAYLOAD_OFFSET" ] || die "cannot find payload.bin offset in OTA metadata"
PAYLOAD_CHECK=$(mktemp -d "${TMPDIR:-/tmp}/op5911-payload.XXXXXX")
trap 'rm -rf "$PAYLOAD_CHECK"' EXIT
if ! PAYLOAD_EXTRACT_LOG=$("$OTA_EXTRACTOR" --payload="$FULL" --payload_offset="$PAYLOAD_OFFSET" \
        --output_dir="$PAYLOAD_CHECK" --partitions=boot,dtbo,vendor_boot,vbmeta 2>&1); then
    printf '%s\n' "$PAYLOAD_EXTRACT_LOG" >&2
    die "cannot extract verification images from OTA payload"
fi
for pair in boot:boot.img dtbo:dtbo.img vendor_boot:vendor_boot-recovery.img vbmeta:vbmeta.img; do
    img=${pair%%:*}
    name=${pair##*:}
    cmp -s "$PAYLOAD_CHECK/$img.img" "$BOOTSTRAP/$name" \
        || die "bootstrap/$name does not match OTA payload partition $img"
done
rm -rf "$PAYLOAD_CHECK"
trap - EXIT

[ -f "$DEV/FLASHING.md" ] || die "missing $DEV/FLASHING.md"
if [ -n "$INCR" ]; then
    [ -f "$INCR" ] || die "missing incremental OTA: $INCR"
    case ${INCR##*/} in
        op5911-ota-incr-*.zip) ;;
        *) die "not an OP5911 incremental OTA: $INCR" ;;
    esac
fi

DEST=$OUT_ROOT/op5911-$BUILD_NUMBER
[ ! -e "$DEST" ] || [ "$FORCE" = true ] || die "release exists: $DEST (use --force)"
mkdir -p "$OUT_ROOT"
STAGE=$(mktemp -d "$OUT_ROOT/.release.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT

cp -f "$FULL" "$STAGE/"
mkdir -p "$STAGE/bootstrap"
for f in boot.img dtbo.img vendor_boot-recovery.img vbmeta.img; do
    cp -f "$BOOTSTRAP/$f" "$STAGE/bootstrap/$f"
done
cp -f "$DEV/FLASHING.md" "$STAGE/"
[ -n "$INCR" ] && cp -f "$INCR" "$STAGE/"

BAD=$(find "$STAGE" -type f \( -iname 'super*.raw' -o -iname 'super*.img' \
    -o -iname '*target_files*' -o -iname '*debug*' \) -print -quit)
[ -z "$BAD" ] || die "forbidden file in release staging: $BAD"

{
    echo "OP5911 AOSP 15"
    echo "build: $BUILD_NUMBER"
    echo "full OTA: ${FULL##*/}"
    [ -n "$INCR" ] && echo "incremental OTA: ${INCR##*/}"
    echo "bootstrap: boot.img, dtbo.img, vendor_boot-recovery.img, vbmeta.img"
    echo
    echo "First install uses bootstrap + full OTA. No whole-super image is included."
    echo "See FLASHING.md and verify SHA256SUMS before flashing."
} > "$STAGE/RELEASE.txt"

(
    cd "$STAGE"
    find . -type f ! -name SHA256SUMS -printf '%P\0' \
        | LC_ALL=C sort -z \
        | while IFS= read -r -d '' f; do sha256sum -- "$f"; done > SHA256SUMS
    sha256sum --quiet -c SHA256SUMS
)

if [ -e "$DEST" ]; then
    rm -rf "$DEST"
fi
mv "$STAGE" "$DEST"
trap - EXIT

echo "release ready: $DEST"
printf '   total: %s\n' "$(du -sh "$DEST" | cut -f1)"
find "$DEST" -type f -printf '   %P\n' | LC_ALL=C sort
