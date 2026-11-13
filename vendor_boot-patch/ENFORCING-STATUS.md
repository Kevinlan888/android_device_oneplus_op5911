# Recovery Enforcing investigation — 2026-11-09 (historical)

> **Status: closed.** The compatibility fixes below were integrated into
> `build-recovery.sh`; this file is retained as bring-up evidence, not as a pending
> debug plan. Current release builds use the grafted recovery with the `recovery`
> domain Enforcing. The remaining permissive domains in the stock policy are
> `init kernel ueventd vendor_init` (the 2026-11-12 build log prints exactly that),
> and no recovery-domain permissive statement remains. A/B OTA sideload verification
> is recorded in README.md/BUILD.md.

## Verified on device

Device X8T4GQCUTKTOF6DU, slot B, diagnostic v8:

```
Boot HAL registered
Binder ping OK
Number of slots: 2
Current slot: 1
Current slot suffix: _b
probe_exit=0
```

Evidence: workspace `recovery-enforcing-v8-probe.txt`. Earlier v7 captured
servicemanager running, servicemanager.ready=true and vendor.boot-default running.
The diagnostic policy explicitly removes recovery from its permissive set.

## Root causes addressed in the diagnostic builder

- Grafted servicemanager was labelled rootfs. With its explicit servicemanager
  process domain, exec was denied entrypoint. Restore its platform executable label.
- Grafted linker and shared libraries also retained rootfs labels. Restore their
  platform labels before starting servicemanager; restore service context labels.
- Older stock policy lacks AOSP recovery's servicemanager rootfs read rules.
- Older stock policy lacks servicemanager_prop and the exact boolean property
  mapping for servicemanager.ready. Add type, mapping, writer and reader permissions.
- Grafted AIDL boot HAL needs its hal_bootctl_default_exec label and the newer
  hal_bootctl_service service type and Binder registration/call permissions.
- HAL must be allowed to read servicemanager.ready; merely running its process
  did not prove registration. The v8 probe validates registration and getter calls.

`build-enforcing-diagnostic.py` rebuilds the current diagnostic image from the
existing base vendor_boot-recovery.img. Build op5911-boot-hal-probe first; its
normal Soong module is under ../recovery-probe. In this sandbox normal Soong
startup failed to open its path-interposer socket; the probe was compiled with
existing recovery compiler/linker parameters. Diagnostic build logs are in out/.

## Validation limits at the time of the investigation

This is NOT a fully Enforcing release. The base image already contained permissive
init, kernel, ueventd, vendor_init and recovery domains despite a global Enforcing
setting. The diagnostic removes recovery permissiveness, but retains the four
other stock permissive domains. Its shell kernel-log access, disabled dontaudit
rules, and probe Binder permissions are diagnostic changes.

No actual OTA apply or slot A boot was performed in this investigation. Slot A
lacks REQUIRED vendor_dlkm_a/odm_dlkm_a/odm_a and super capacity is constrained.
Do not use this device's slot A boot as the acceptance test or flash OTA to it
without separately resolving that explicit constraint. A complete OTA test needs
an appropriate device/partition layout.

The fixes were initially prototyped in the diagnostic builder. They have since been
integrated into `build-recovery.sh`; the diagnostic images and probe are no longer
required for a normal release build. The remaining stock permissive domains above are
unchanged from OPPO's vendor policy and are not a reason to keep debugging recovery for
normal flashing.

## Files

- Diagnostic image: vendor/oneplus/op5911/images/vendor_boot-recovery-enforcing-diag-v8.img
- SHA256: 3f391aa971d2a5c16dc33139143793d956fb0f0c44ea8cefaf73e0e3eeaf9a01
- Probe source: device/oneplus/op5911/recovery-probe/boot_hal_probe.cpp
- Probe intentionally implements only checkService, ping and slot getter calls.

Enter recovery with adb reboot recovery from the running B system. On this
bootloader, fastboot reboot recovery can instead enter slot A's recovery.
