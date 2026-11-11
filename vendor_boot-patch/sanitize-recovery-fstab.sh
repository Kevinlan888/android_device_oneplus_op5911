#!/bin/bash
# Make the recovery fstab safe: recovery must never auto-format anything.
# 2026-11-10 the AOSP recovery failed to mount /cache (= oplusreserve2) and, because
# of `formattable`, fs_mgr FORMATTED oplusreserve2. protect1/protect2/nvdata/nvcfg
# (IMEI + RF calibration) carried the same flag. Drop entries recovery never needs
# and strip `formattable` from everything else (format_volume() doesn't need it).
set -euo pipefail
f=${1:?usage: $0 recovery.fstab}
sed -i -E '/^[^#]*[[:space:]]\/(cache|opporeserve)[[:space:]]/d;
           /^\/dev\/block\/by-name\/(protect1|protect2|nvdata|nvcfg)[[:space:]]/d' "$f"
sed -i -E '/^[^#]/ s/(,formattable\b|\bformattable,|\bformattable\b)//g' "$f"
if grep -vE '^\s*#' "$f" | grep -qE 'formattable|oplusreserve|protect[12]|nvdata|nvcfg|[[:space:]]/cache[[:space:]]'; then
    echo "recovery fstab still unsafe: $f" >&2; exit 1
fi
echo "   recovery fstab sanitized: $(grep -cvE '^\s*(#|$)' "$f") entries, no formattable"
