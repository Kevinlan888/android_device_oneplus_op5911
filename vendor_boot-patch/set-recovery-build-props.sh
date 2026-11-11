#!/bin/bash
# Make the grafted recovery report the build it ships with, so A/B incremental
# OTAs pass install.cpp CheckAbSpecificMetadata (pre-build-incremental vs
# ro.build.version.incremental, pre-build vs ro.build.fingerprint) and downgrade
# protection uses our ro.build.date.utc. The stock prop.default carries ColorOS 12
# values. vendor_boot is part of every OTA, so recovery always matches the
# installed build.
#   usage: set-recovery-build-props.sh <prop.default> <props-file>
#   props-file: key=value lines (ro.build.fingerprint, ro.build.version.incremental,
#               ro.build.date.utc, ro.build.version.security_patch)
set -euo pipefail
pd=${1:?}; pf=${2:?}
for k in ro.build.fingerprint ro.build.version.incremental ro.build.date.utc ro.build.version.security_patch; do
    v=$(grep -m1 "^$k=" "$pf" | cut -d= -f2-)
    [ -n "$v" ] || { echo "missing $k in $pf" >&2; exit 1; }
    sed -i "/^$(echo $k | sed 's/\./\\./g')=/d" "$pd"
    echo "$k=$v" >> "$pd"
    echo "   $k=$v"
done
