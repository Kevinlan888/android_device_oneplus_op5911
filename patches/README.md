# Source patches outside the device tree

Apply after `repo sync` (each directory = one repo project, `_` = `/`):

```bash
cd $ANDROID_BUILD_TOP
git -C packages/apps/Messaging am $PWD/device/oneplus/op5911/patches/packages_apps_Messaging/*.patch
git -C frameworks/opt/telephony am $PWD/device/oneplus/op5911/patches/frameworks_opt_telephony/*.patch
git -C frameworks/native am $PWD/device/oneplus/op5911/patches/frameworks_native/*.patch
```

- `packages_apps_Messaging/0001`: request RECEIVE_WAP_PUSH and READ_CELL_BROADCASTS. Without them
  Android 15+ does not treat AOSP Messaging as the default SMS app, and it never shows an SMS
  notification.
- `frameworks_opt_telephony/0001`: add a minimal `TelephonyMetrics` no-op stub (removed in
  Android 16) so prebuilt `MtkIms.apk` starts cleanly for VoLTE and SIM-less 112 emergency calls.
- `frameworks_native/0001`: use `BpfMap::init()` instead of the aborting `BpfMap(path)` constructor
  in `GpuWork::getBpfMap()` so `/system/bin/gpuservice` does not crash-loop every 30 s on the 5.10
  kernel without `gpu_work_period` BPF maps.
