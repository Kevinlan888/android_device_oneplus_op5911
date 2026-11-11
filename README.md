# LineageOS 22.2 device tree: OnePlus Ace (PGZ110 / OP5911, MT6895)

> **Build, OTA packaging and flashing: see [BUILD.md](BUILD.md)** (current, verified procedure).
> The flashing notes further down in this README describe the stage-1 bring-up and are kept for history.

## Stage 1: what is built and what stays stock

| Partition | Source |
|---|---|
| system, system_ext, product | built from source by this tree |
| vendor | stock ColorOS `PGZ110_15.0.0.1101` vendor, patched by `vendor-patch/patch-vendor-image.sh` |
| vendor_boot | stock, with the AOSP recovery grafted in (`vendor_boot-patch/build-recovery.sh`) |
| boot, dtbo + 19 firmware partitions (gpueb, lk, tee, md1img, ...) | stock slot-B set (`OP5911_STOCK_FIRMWARE`), shipped in every OTA since 2026-11-10 so both slots run the kernel/firmware that matches the vendor |
| odm, vendor_dlkm, odm_dlkm, my_* | stock, left on the phone (odm and my_* are verified with the OPLUS AVB key) |

What the vendor patch replaces from the old GSI build (which used bind mounts plus a plat cil hack):

- **Call audio:** "Voice Call In" is removed from the two audio policy XMLs, so the audio policy manager (APM) uses legacy call routing.
- **SurfaceFlinger cpuset:** `task_profiles.json` sets SFMainPolicy and SFRenderEnginePolicy to the foreground cpuset.
- **SurfaceFlinger screenshots:** `debug.renderengine.backend` is switched from the stock `skiagl` to `skiaglthreaded`. On Android 15 the non-threaded backend defers `present()` past the screenshot RenderArea's lifetime and SIGSEGVs on every capture, which took the whole UI down in a loop. (Verified: skiagl crashes on the first `screencap`, skiaglthreaded 25/25 clean.)
- **Fingerprint:** the patched fingerprint HAL is installed at `/vendor/bin/hw`, and `init.op5911.vendor.rc` overrides the `fps_hal` service so it runs that copy.
- **Double-tap-to-wake:** `/vendor/usr/keylayout/touchpanel.kl` maps the panel's gesture scancode 62 (reported as `KEY_F4` on a screen-off double tap) to `WAKEUP`. `init.op5911.vendor.rc` arms `/proc/touchpanel/double_tap_enable` at `sys.boot_completed`, and `vendor_sepolicy_append.cil` lets `init` write that `proc_touchpanel_file` node. DT2W is armed unconditionally — a `persist.op5911.dt2w` default in build.prop does not survive (no property_contexts type for `persist.op5911.*`); the runtime `setprop persist.op5911.dt2w 0|1` triggers still work within a session. A Settings toggle would need a type for that prop plus a bridge from `Settings.Secure.DOUBLE_TAP_TO_WAKE`.
- **Launch performance:** `powerscntbl.xml` is bind-mounted over `/odm/etc/powerhal/`.
- **SELinux file contexts:** the repack feeds `mkfs.erofs` a merge of the generic `/vendor` rules from the platform `plat_file_contexts` plus the stock `vendor_file_contexts`. `vendor_file_contexts` alone only has vendor-specific rules, so most files would be unlabeled and `apexd --bootstrap` fails (`reboot,bootloader,bootstrap-apexd-failed`). The image is packed at `lz4hc,12` so it still fits `vendor_b` (1056784384 bytes).
- **SELinux rules:** rules are appended to `vendor_sepolicy.cil` so radio can set the MTK IMS props and init can mount on `vendor_configs_file`.
- **Log spam:** `ro.oplus.backlight.*` and `ro.oplus.bl.*` are labelled `vendor_mtk_pq_ro_prop` in `vendor_property_contexts`, which stops the PQ HAL's "Access denied finding property" warnings.

The equivalent build-side parts are:

- `overlay/` holds runtime resource overlays (RROs) for the fingerprint sensor config, power-key wake, IMS settings and CarrierConfig VoLTE.
- `ims/` holds MtkIms, which is re-signed with the build's platform key.
- `doze/` holds OplusDoze, the pick-up bridge for ambient display (see "Doze" below).

### Doze (tested live on device 2026-11-10, before the build)

- **DeviceIdle:** `config_enableAutoPowerModes=true` (AOSP default is false, so light and deep doze never ran). It uses MTK's `significant` motion sensor. With it enabled at runtime, `dumpsys deviceidle step deep` goes IDLE_PENDING → SENSING → IDLE → IDLE_MAINTENANCE.
- **AOD:** `config_dozeAlwaysOnDisplayAvailable=true` (the toggle is offered; `config_dozeAlwaysOnEnabled=false` keeps it off until the user turns it on), and SystemUIOverlayOP5911 sets `doze_display_state_supported=true`. SurfaceFlinger goes `powerMode=Doze`, the kernel logs `[DISP]enter AOD`, and the clock shows correctly.
- **DOZE_SUSPEND does not work:** HWC accepts `powerMode=DozeSuspend`, but the panel goes black. `doze_suspend_display_state_supported` stays false, so the CPU does not suspend while AOD is shown.
- **Lift to check phone:** SystemUI only looks up `TYPE_PICK_UP_GESTURE` (25). This device has the oplus `pickup` sensor instead (`android.sensor.pickup_detect`, type 65611, wake-up, special-trigger. Measured: `values[0]` = `0` when the phone is **lifted** and `1` when it is **put back down**; `values[1]` is just a running counter). `config_dozePulsePickup=true` makes Settings show the "Lift to check phone" toggle (SystemUI skips its missing sensor safely). OplusDoze (system uid, persistent, started on boot) listens to the oplus sensor while the screen is off and sends `com.android.systemui.doze.pulse`. SystemUI still runs its proximity check before pulsing, so the phone doesn't pulse in a pocket. Debug with `setprop log.tag.OplusDoze DEBUG`.
- **Pulse brightness:** a pulse puts the display in `STATE_ON` at `config_screenBrightnessDoze` (capped by the current screen brightness). The default 5/255 was barely visible, so the overlay sets 15 (25 and 40 were too bright). AOD itself (`STATE_DOZE`) uses the panel's own low-power brightness and ignores this value.
- **Notifications from the AOSP SMS and clock apps (sleep test 2026-11-10):** calls and kernel suspend/resume were fine, but three app-level bugs looked like the phone "sleeping too deep":
  - Messaging never notified, even awake: it wasn't requesting `RECEIVE_WAP_PUSH`/`READ_CELL_BROADCASTS`, so `SmsApplication` didn't treat it as the default SMS app (`patches/packages_apps_Messaging`).
  - In deep idle, Messaging's SMS processing job waited for the next wake. Fixed by putting it on the power-save allowlist (`configs/sysconfig/op5911-power-whitelist.xml`).
  - DeskClock had no `POST_NOTIFICATIONS`, so the alarm only played sound (`configs/default-permissions`). Its alarm is a `PendingIntent.getService()`, which is refused once the app is idle (`Background start not allowed`), so the alarm never fired. Fixed with the power-save allowlist.
- **`lux_aod` not used:** as `doze_brightness_sensor_type` it reported a single value (1) and didn't change when the light changed, so it's not wired in.

### Board/product fixes found during first-boot bring-up (verified booting on AOSP 15 r36, 2026-11-08)

These are the non-obvious things that have to be set or the build boot-loops before any UI:

- **`BoardConfig.mk`: `BOARD_USES_METADATA_PARTITION := true`.** Without it there is no `/metadata` directory in the system root, so first-stage init aborts in `switch_root` right after mounting `/system` (black screen, reboots to bootloader, no logcat — read `/sys/fs/pstore/console-ramoops-0` from recovery to see it).
- **`BoardConfig.mk`: `SYSTEM_EXT_PRIVATE_SEPOLICY_DIRS += $(DEVICE_PATH)/sepolicy/private`,** which adds `sepolicy/private/service_contexts` labelling `mtkIms` / `mwis` / `wfo` as `radio_service`. The system-side MtkIms app registers these and `addService` throws `SELinux denied for service` otherwise, crash-looping `com.mediatek.ims`.
- **`device.mk`: copy `android.hardware.fingerprint.xml` into `product/etc/permissions`.** The stock feature declaration lives in `my_product`, which an AOSP build does not read, so `FingerprintService` never starts and `dumpsys fingerprint` is empty.
- **FRP.** The stock `frp` partition can hold a non-default FRP secret whose matching `/data` file is wiped when you erase userdata. On Android 15 (frp_enforcement on) this blocks setting a PIN — and therefore enrolling a fingerprint — with `enforceFrpNotActive`. Zeroing the 40-byte FRP magic+secret region in the `frp` partition makes the next boot self-heal (it writes the default all-zero secret and deactivates FRP). The OEM-unlock-allowed byte and everything else are left untouched; back the partition up first.

## Getting the tree into the source

```bash
# in the LineageOS 22.2 source root
mkdir -p device/oneplus vendor/oneplus
cp -r <op5911_tree>/device/oneplus/op5911 device/oneplus/
cp -r <op5911_tree>/vendor/oneplus/op5911 vendor/oneplus/
```

## Building

```bash
source build/envsetup.sh
breakfast op5911 userdebug

# 1) host tools for the vendor patch
m fsck.erofs mkfs.erofs

# 2) patched vendor image -> vendor/oneplus/op5911/images/vendor.img
device/oneplus/op5911/vendor-patch/patch-vendor-image.sh <op5911_tree>/extract/images/vendor.img

# 3) images
m systemimage systemextimage productimage vendorimage
ls out/target/product/op5911/{system,system_ext,product,vendor}.img
```

### Plain AOSP 15 tree

The same tree builds as `aosp_op5911` (without vendor/lineage):

```bash
source build/envsetup.sh
lunch aosp_op5911-trunk_staging-userdebug   # or the release of your AOSP tag, see build/release/release_configs/
m fsck.erofs mkfs.erofs
device/oneplus/op5911/vendor-patch/patch-vendor-image.sh <op5911_tree>/extract/images/vendor.img
m systemimage systemextimage productimage vendorimage
```

## Flashing (slot b, from the current GSI install)

> **Warning:** entering fastbootd switches the active slot to **a**. Slot a holds a stale super layout.
> Always run `fastboot set_active b` first, and check `fastboot getvar current-slot` before writing anything.
> **Never** flash `super_empty.img` or run `fastboot flashall`/`update`: that would delete odm and my_*, and the phone would not boot.

```bash
adb reboot fastboot
fastboot set_active b
fastboot getvar current-slot              # must say b
fastboot getvar snapshot-update-status    # must be none; if "merging", boot Android once and wait

O=out/target/product/op5911
fastboot flash system_b     $O/system.img
fastboot create-logical-partition system_ext_b 4096   # deleted during the GSI install
fastboot flash system_ext_b $O/system_ext.img
fastboot create-logical-partition product_b 4096
fastboot flash product_b    $O/product.img
fastboot flash vendor_b     $O/vendor.img

fastboot erase userdata    # different platform key from the GSI, so data must be wiped
fastboot reboot
```

The super partition has about 3.3 GB free for system, system_ext and product combined. A vanilla build is well under that.
If you add GApps, check the sizes before flashing.

> **Note (2026-11-08):** during bring-up the logical partitions were written with `dd` to
> `/dev/block/mapper/<p>_b` from a debug Lineage Recovery (root adb) instead of fastbootd,
> because the debug `vendor_boot` overlay used for pstore capture breaks userspace fastboot.
> `dd` only works when the new image fits the existing partition size; the vendor image is
> packed at `lz4hc,12` specifically to stay under `vendor_b`. For a normal install use the
> fastbootd flow above.

## Custom vendor_boot / recovery (Stage 2 — graft AOSP recovery userspace)

**Status: working.** `adb reboot recovery` boots a clean AOSP recovery with
`adb sideload` (via `minadbd`) that trusts our OTA cert. OPPO's `phoenix_recovery`
(whose UI had no sideload entry) is gone. The only gap is the recovery **display**
(headless — screen stays off; sideload is driven entirely over USB and does not need it).

### How it is built — graft, not a from-scratch recovery

The stock `vendor_boot` is one **combined** ramdisk (header v4, single ramdisk of
type `platform`/0x1) that carries three things: the device **first-stage** bits
(`first_stage_ramdisk/`, 270 vendor modules in `lib/modules` with
`modules.load`/`modules.load.recovery`, `init.recovery.mt6895.rc` with the MTK
preloader symlinks), the `my_*` mountpoints, and a `/system` that is used **only in
recovery mode**. OPPO's `/system` ships `phoenix_recovery`. We keep every
device/first-stage byte and replace exactly the recovery userspace:

- `/system` → the **AOSP recovery `/system`** (`m .../ramdisk-recovery.img` builds it
  at `out/target/product/op5911/recovery/root/`). Brings a clean init.rc that starts
  the `recovery` service (not phoenix), the `recovery` + **`minadbd`** binaries with
  their 61 matching libs, and — for free — our **testkey `otacerts.zip`**, so the OTA
  cert swap of the old route 1 is subsumed.
- `/res` → AOSP recovery `/res` (minui UI resources matching this recovery).
- append `ro.recovery.usb.vid/adb.pid/fastboot.pid` (18D1/D001/4EE0) to `prop.default`
  — **stock had none** (OPPO drove USB differently), and without them the ConfigFS
  gadget's idVendor is empty and the port never enumerates for sideload.

Everything else stays stock, so normal boot is untouched (it runs boot.img's generic
`/init`, `switch_root`s to the real `/system`, and never reads the vendor ramdisk's
`/system`), the 270 modules still load, and stock SELinux still labels `lib/modules`,
`my_*` and the device nodes. AOSP init.rc does `import /init.recovery.${ro.hardware}.rc`
== the stock `init.recovery.mt6895.rc` we keep.

`vendor_boot-patch/build-recovery.sh` does it (run after
`m out/target/product/op5911/ramdisk-recovery.img`, which needs
`PRODUCT_BUILD_RECOVERY_IMAGE := true` in `device.mk` — see below):

```bash
device/oneplus/op5911/vendor_boot-patch/build-recovery.sh \
    <op5911_tree>/stock_backup_b/vendor_boot_b.img \
    <op5911_tree>/stock_backup_b/boot_b.img
# -> vendor/oneplus/op5911/images/vendor_boot-recovery.img  (~37.6 MB, partition 64 MB)
# -> vendor/oneplus/op5911/images/recovery-fastboot.img     (standalone, for `fastboot boot`)
```

It keeps the exact stock vendor_boot geometry (base 0, kernel 0x40000000, ramdisk
0x66f00000, tags/dtb 0x47c80000, pagesize 4096, cmdline `bootopt=64S3,32N2,64N2
buildvariant=user`), re-unpacks the result and asserts the dtb is unchanged, and
checks `recovery`+`minadbd` are present and `phoenix_recovery` is gone.

### Flashing and the slot/entry rules learned the hard way

Flash from **bootloader** fastboot (not fastbootd) to the slot you boot (b):

```bash
adb reboot bootloader
fastboot getvar current-slot          # must say b (see rule 2)
fastboot flash vendor_boot_b vendor/oneplus/op5911/images/vendor_boot-recovery.img
adb reboot            # reboot normally FIRST, do not fastboot reboot recovery (rule 1)
```

**Rule 1 — enter recovery only with `adb reboot recovery` from the running OS, never
`fastboot reboot recovery` from the bootloader.** This OPPO bootloader hardwires the
*bootloader* recovery command to **slot a**'s stock vendor_boot (it never even tries
slot b — `slot-retry-count:b` stays 7) **and resets the active slot to a**. BCB-triggered
recovery from the OS honours the active slot and boots our slot-b recovery. Verified:
`adb reboot recovery` → `ro.boot.slot_suffix=_b`, `/system/bin/minadbd` present, no
`phoenix_recovery`, otacert `testkey.x509.pem`. Then `adb reboot sideload` →
`adb devices` shows `sideload`, gadget enumerates as `18d1:d001`.

**Rule 2 — `fastboot`/fastbootd keep flipping active to a.** `fastboot reboot recovery`,
entering fastbootd, and some bootloader paths all reset active→a. The bootloader's
immediate `getvar current-slot` after `set_active` is **stale** — it reports the old slot
until a full reboot. (Originally the super only held AOSP partitions for slot b, so this
bootlooped; since 2026-11-10 both slots carry the identical full set — system, stock
dynamic partitions, kernel and firmware — so either slot boots.) Recovery when stuck:

```bash
# device bootloops, then drops into fastboot on its own (or force it with keys)
fastboot --set-active=b
fastboot reboot                        # ~26 s back to AOSP on slot b
```

`bootctl` and `update_engine_client` are in the build: `bootctl get-active-boot-slot` /
`get-current-slot` show the slots, and an OTA can be applied from the running OS (BUILD.md 5.1).

**Not done yet:** recovery **display** (needs the MTK DRM/panel path wired into minui —
first version is headless, which is enough for `adb sideload`). `recovery.fstab` still
carries the GSI AVB keys (fine while AVB is disabled). Its `formattable` flags and the
`/cache` (= oplusreserve2) and calibration-partition entries were removed after recovery
auto-formatted oplusreserve2 on 2026-11-10 - see BUILD.md.

## Things to check on first boot

- `adb shell getprop ro.vendor.build.fingerprint` still shows the stock fingerprint, and `adb shell getenforce` shows Enforcing.
- **Fingerprint:** `dumpsys fingerprint` shows sensor id 0.
- **Init override:** `adb logcat -b all | grep fps_hal` shows "ignored duplicate" for the odm copy.
- **Audio:** make a test call and confirm two-way audio.
- **VoLTE:** `dumpsys telephony.registry` shows IMS registered; a call shows the VoLTE/HD icon with data still up. The CarrierConfig overlay now has an unfiltered global `<carrier_config>` bundle on top of the per-carrier ones — this device's SIMs stay `carrierId=-1` and the config is fetched before mcc/mnc are known, so the filtered bundles never match (also `aapt2` compiles `mnc="03"` to integer `3`, so `"3" != "03"` at runtime). The global bundle sidesteps both.
- **Power key:** a short press wakes the screen.
- **Doze:** `dumpsys deviceidle | grep Enabled` shows `mLightEnabled=true mDeepEnabled=true`. `ps -A | grep op5911.doze` shows the process running. With the screen off, picking up the phone briefly shows the ambient display. Turning on AOD in Settings gives `dumpsys SurfaceFlinger | grep powerMode` = Doze.
- **PIN / fingerprint:** both only work once FRP is cleared (see the FRP note above).

## Known gaps vs. the TrebleDroid GSI

The GSI carried TrebleDroid framework patches for MediaTek devices, and a plain Lineage build doesn't have them.
If something regresses, the fix will most likely be one of those patches. The likely areas are:

- signal bars and 5G
- brightness curve
- refresh-rate switching
- MTK radio indications

## Borrowed from LineageOS MT6895 (xaga) / hardware/mediatek

Already applied in this tree:

- 5G SA/NSA flags and the MediaTek TCP buffers, in FrameworksResOverlayOP5911.
- Default peak refresh rate 120 Hz, in FrameworksResOverlayOP5911. The stock vendor overlay sets 90.
- SettingsOverlayOP5911 shows the "Smooth display" toggle.
- `configs/vendor_logtag.mk` silences the MTK RIL/IMS log tags, and sets the noisy OPLUS HAL tags to W.

Not taken over:

- **Brightness curve, cutout, status bar height, rounded corners.** These already come from the stock vendor and odm overlays (`com.mediatek.frameworkresoverlay`, `android.frameworkres.overlay.display.product`). The xaga values are for a different panel.
- **`mediatek-common` / `-telephony-common` / `-telecom-common`.** These are the open-source MTK frameworks, and they only exist in lineage-24.0.
- **Stock MTK ImsService plus `mediatek-*-base.jar` as boot jars.** xaga uses these, but they need MTK-patched frameworks. On 22.2 we stay with ims-mtk-u.

Stage 2 candidates from LineageOS `hardware/oplus` (lineage-22.2). These are vendor-side HALs, so they need our own vendor build:

- ~~`aidl/touch`: double-tap-to-wake~~ — **done** without the HAL, via a key layout (see the DT2W bullet above). The panel reports a screen-off double tap as `KEY_F4`; the full oplus touch HAL (`vendor.oplus.hardware.touch@V2`, already on the device) is only needed for the other gestures (swipe letters) that return a gesture coordinate.
- Other touch gestures (swipe-to-X), `nrmodeswitcher`, `aidl/livedisplay`. (`doze` is done without the HAL — see the Doze section.)

Observed on the GSI:

- **Wi-Fi off:** on NR SA the phone reports `NR_SA` and the display type is `network=NR`, which is correct.
- **Wi-Fi on:** the data RAT shows as IWLAN (`mIsIwlanPreferred=true`). This doesn't matter, because the status bar shows Wi-Fi then.

## Stage 2 (later)

- ~~Custom vendor_boot / recovery~~ — **done** by grafting the AOSP recovery userspace
  (`/system` + `/res`) into the stock combined vendor_boot ramdisk (see the "Custom
  vendor_boot / recovery" section above). Clean AOSP recovery + `adb sideload` via
  `minadbd`, trusting our testkey OTA cert; phoenix_recovery gone. Enter with
  `adb reboot recovery` from the OS (never `fastboot reboot recovery` — rule 1). Headless
  (no display yet).
- Recovery **display**: wire the MTK DRM/panel into minui so the recovery UI is visible
  (currently headless; sideload works without it).
- ~~Our own fstab that drops my_stock, my_preload and my_bigball~~ - **done** (first-stage fstab in
  vendor_boot + /vendor/etc/fstab.mt6895); frees about 5.6 GB of super so a full A/B OTA fits.
- ~~OTA packages~~ - **done**: full and incremental A/B OTAs carrying all 14 dynamic partitions,
  applied by the ENFORCING recovery, verified both directions. See BUILD.md.
- ~~Same kernel/firmware on both slots~~ - **done** (2026-11-10): the slots came with different
  ColorOS versions (22 partitions differed, boot_a = 5.10.236). On slot A our vendor ran on the
  other version's kernel, gpueb, tee etc.: GPU frames took ~5 s and UFS runtime-PM warned every
  few seconds. OTAs now carry the 21 stock slot-B kernel/firmware partitions; slot A's originals
  are backed up in `ace/stock_backup_a_firmware/`.
- ~~Install updates without recovery~~ - **done**: `update_engine_client` from the running OS
  (BUILD.md 5.1), ~1 min for an incremental, ~7 min for a full package.
- Still open: other touch gestures, `nrmodeswitcher`, livedisplay, recovery display, a vendor
  built from source, and a first build with `BUILD_NUMBER` set.
