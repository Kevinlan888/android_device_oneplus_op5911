# Source patches outside the device tree

Apply after `repo sync` (each directory = one repo project, `_` = `/`):

```bash
cd $ANDROID_BUILD_TOP
git -C packages/apps/Messaging am $PWD/device/oneplus/op5911/patches/packages_apps_Messaging/*.patch
```

- `packages_apps_Messaging/0001`: request RECEIVE_WAP_PUSH and READ_CELL_BROADCASTS. Without them
  Android 15 does not treat AOSP Messaging as the default SMS app, and it never shows an SMS
  notification.
