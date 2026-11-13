# OP5911 编译、打包与刷机

OnePlus Ace（PGZ110 / OP5911，MT6895）AOSP 15 移植的完整构建流程：从源码编译，到生成 OTA 卡刷包，再到首次安装和后续升级。设备树做了哪些改动、各项 bring-up 经验见 [README.md](README.md)。

> 面向其他用户的刷入说明见 [FLASHING.md](FLASHING.md)；本文保留构建、打包和开发调试细节。

本文所有命令都在 AOSP 源码根目录执行。除非特别说明，`D` 指 target-files 暂存目录：

```
out/target/product/op5911/obj/PACKAGING/target_files_intermediates/aosp_op5911-target_files
```

## 1. 总览

### 1.1 哪些分区自己编，哪些用原厂

| 分区 | 来源 | 是否在 OTA 里 |
|---|---|---|
| system、system_ext、product | 本设备树从源码编译 | 是 |
| vendor | 原厂 vendor，经 `vendor-patch/patch-vendor-image.sh` 打补丁 | 是 |
| vendor_boot | 原厂 vendor_boot，嫁接 AOSP recovery（`vendor_boot-patch/build-recovery.sh`） | 是 |
| vbmeta | 原厂 vbmeta（OPPO 签名），只改 flags=3 | 是 |
| odm、vendor_dlkm、odm_dlkm | 原厂镜像原样 | 是 |
| my_product、my_engineering、my_company、my_carrier、my_region、my_heytap、my_manifest | 原厂镜像原样 | 是 |
| my_stock、my_preload、my_bigball | **不再使用**，已从两份 fstab 里删除 | 否 |
| boot、dtbo、gpueb、lk、tee、gz、scp、sspm、mcupm、spmfw、dpm、vcp、ccu、apusys、audio_dsp、mvpu_algo、pi_img、md1img、mcf_ota、vbmeta_system、vbmeta_vendor | 原厂 B 槽原样（和 vendor 同一版本 PGZ110_15.0.0.1101） | 是（2026-11-10 起） |
| preloader、nvram/nvdata、protect、persist 等不分 A/B 的分区 | 原厂，留在手机上不动 | 否 |

### 1.2 必须知道的几条规则

这些规则都是踩坑踩出来的，违反任何一条都可能导致无法开机或数据丢失：

1. **OTA 必须包含 first-stage fstab 要求的全部动态分区。** 完整 OTA 会按 payload 的分区列表重写目标槽的分区表，不在包里的分区会被直接删除，first-stage 找不到必需分区就重启进 bootloader。`ota/make-ota.sh` 已经把 14 个动态分区全部打进包里。
2. **vbmeta 必须保持原厂 OPPO 签名**（公钥 sha1 `1a130f9a…`），只把 flags 改成 3。KeyMint 把 /data 的加密密钥绑定在 vbmeta 的 root of trust 上。换成无签名的 vbmeta，vold 解不开密钥，/data 挂不上，rec 会提示清除数据。**这时不要清数据**，换回原厂签名的 vbmeta 即可恢复。
3. **recovery 的 fstab 里不能有 `formattable`。** 原厂 fstab 把 `/cache` 指向 `oplusreserve2`，`nvdata`、`nvcfg`、`protect1`、`protect2`（IMEI、射频校准）也都带 `formattable`。AOSP recovery 挂载失败时会直接格式化这些分区：2026-11-10 的一次测试就这样把 oplusreserve2 格式化了。`vendor_boot-patch/sanitize-recovery-fstab.sh` 负责去掉这些条目，`make-ota.sh` 出包前也会再检查一次。
4. **正常使用 rec 只能用 `adb reboot recovery` 或 `adb reboot sideload`，不要用 `fastboot reboot recovery`。** 这台机器的 bootloader 在 fastboot 下进 recovery 时固定走 A 槽的 vendor_boot，还会把活动槽改成 A。唯一例外是 5.2 节首装：A 槽已经主动写入我们的正式 recovery，此时正好利用 bootloader 的这个行为进入临时 recovery。
5. **安全补丁级别（SPL）不能回退。** 系统一旦用较新的 SPL 开过机，KeyMint 就会把密钥升级到这个级别，之后再用旧 SPL 的系统开机，/data 解不开。所有构建都固定把 SPL 写成 `2025-07-01`（`OP5911_SPL` 可以改，但只能往后调）。
6. **内核和固件必须和 vendor 同一版本。** A、B 两个槽原来装的是不同版本的 ColorOS，有 22 个分区不一样。早先的 OTA 只写系统和 vendor，落到 A 槽时内核（5.10.236）和 gpueb、tee 等固件还是 A 槽的旧版本，配上 B 槽版本的 vendor 和内核模块：能开机，但 GPU 每帧要几秒、整机很卡，内核每隔几秒打一次 UFS runtime-suspend 的 WARN。现在 `make-ota.sh` 会把 B 槽的 21 个内核/固件分区一起打进包里，不管落到哪个槽都是同一套。
7. **改 `device.mk`、`BoardConfig.mk` 或任何 `.bp`/`.mk` 后，下一次 `m` 会触发 soong 重新分析，在这台机器上要约 1 小时。** 改动尽量攒在一起。本文第 4 节以后的步骤全部只用 host 工具，不会触发重新分析。

## 2. 准备工作

### 2.1 源码与编译目标

- 源码：AOSP 15（`android-15.0.0_r36`），设备树放在 `device/oneplus/op5911`，预编译文件放在 `vendor/oneplus/op5911`。
- lunch 目标：`aosp_op5911-bp1a-userdebug`。
- 设备树以外的源码补丁在 `patches/`，`repo sync` 之后要先打上（见 `patches/README.md`）。目前只有一个：AOSP 短信不补这个就永远不弹通知。

### 2.2 原厂输入文件

这些文件都是从手机上 dd 出来的，路径写在 `ota/local.env` 里：

| 变量 | 内容 | 获取方式 |
|---|---|---|
| `OP5911_STOCK_IMAGES` | 原厂动态分区镜像目录：`vendor.img`、`odm.img`、`vendor_dlkm.img`、`odm_dlkm.img`、各个 `my_*.img` | 在原厂系统或 root rec 里，从 `/dev/block/mapper/<分区>_b` dd 出来，并校验 sha256 |
| `OP5911_STOCK_VENDOR_BOOT` | 原厂 `vendor_boot_b.img` | `dd if=/dev/block/by-name/vendor_boot_b` |
| `OP5911_STOCK_BOOT` | 原厂 `boot_b.img` | `dd if=/dev/block/by-name/boot_b` |
| `OP5911_STOCK_FIRMWARE` | 原厂 B 槽内核和固件：`boot dtbo gpueb lk tee gz scp sspm mcupm spmfw dpm vcp ccu apusys audio_dsp mvpu_algo pi_img md1img mcf_ota vbmeta_system vbmeta_vendor` 各一个 `.img`，外加 `SHA256SUMS` | root 下逐个 `dd if=/dev/block/by-name/<分区>_b`，对照手机上的 sha1 校验，再生成 `SHA256SUMS`。其中 `boot.img` 必须和 `OP5911_STOCK_BOOT` 完全一致（脚本会检查） |
| `OP5911_STOCK_VBMETA` | 原厂签名、flags=3 的 vbmeta | 原厂 `vbmeta_b.img` 用 `fastboot --disable-verity --disable-verification flash vbmeta_b` 刷入后再 dd 出来；或者直接把原厂镜像偏移 120 处 4 字节大端 flags 改成 3 |
| `OP5911_OTA_OUT` | OTA 和 target-files 存档的输出目录 | 至少留 10 GB。`/tmp` 太小，`ota_from_target_files` 会写满 |

> 在别的机器上编译时，只需改 `ota/local.env` 里的路径。

### 2.3 可选：GApps（MindTheGapps）

system、system_ext、product 都是 erofs（只读），所以 MindTheGapps 的卡刷 zip 在 rec 里刷不进去，只能编进镜像。

- 位置：`vendor/gapps/`，内容是 `MindTheGapps-15.0.0-arm64-20260915_032013.zip` 里的 `product/` 和 `system_ext/` 两个目录（没有 VelvetTitan，那个只给 tangorpro 平板用），外加 `Android.bp` 和 `gapps-vendor.mk`。
- `device.mk` 用 `inherit-product-if-exists` 引入它：**目录不存在就是纯 AOSP，编译不报错**；目录存在时可以用 `WITH_GAPPS=false m ...` 临时关掉。
- APK 用 `android_app_import` + `preprocessed: true` 原样拷贝，不重签、不 dexpreopt，所以 Google 的 v2/v3 签名保持有效。这版 zip 里的 APK 全部满足 preprocessed 的检查（4 字节对齐、so 和 priv-app 的 dex 都不压缩），所以**不要**加 `skip_preprocessed_apk_checks`：APK 没有问题时加了反而报错。换新版 zip 后可以用下面的命令先检查（要在 bash 里跑，zsh 不会拆分 `$priv`，会得到假的失败）：
  ```bash
  bash -c 'for f in $(find vendor/gapps -name "*.apk"); do p=""; case $f in *priv-app*) p="--privileged --uncompress-priv-app-dex";; esac; python3 build/soong/scripts/check_prebuilt_presigned_apk.py --zipalign out/host/linux-x86/bin/zipalign $p --preprocessed $f /dev/null || echo "需要 skip: $f"; done'
  ```
- SetupWizard 会覆盖掉 `Provision`，Velvet 会覆盖掉 `QuickSearchBox`。
- 换新版 zip：把 `product/` 和 `system_ext/` 替换掉；增删了 APK 的话，要同步修改 `Android.bp` 和 `gapps-vendor.mk` 里的列表。
- 带 GApps 和不带 GApps 的版本之间切换时，`/data` 里会留下 GMS 的数据。从不带 GApps 升到带 GApps 一般可以直接升级（记得带 `BUILD_NUMBER`），反方向建议清空数据。

## 3. 编译系统镜像

```bash
source build/envsetup.sh
lunch aosp_op5911-bp1a-userdebug

# 第一次需要的 host 工具
m fsck.erofs mkfs.erofs otatools

# 系统镜像 + target-files 暂存目录。每次都带一个新的 BUILD_NUMBER（见下面的说明）
m target-files-package BUILD_NUMBER=$(date +%Y%m%d%H%M)

# recovery 嫁接需要的内容：AOSP recovery 的 /system，以及 AIDL boot HAL
m android.hardware.boot-service.default_recovery out/target/product/op5911/ramdisk-recovery.img
```

**一定要带 `BUILD_NUMBER`。** 不带时每个构建的版本号都是 `eng.<用户名>`，system/product 的 fingerprint 永远不变。PackageManager 的包解析缓存（`/data/system/package_cache/<fingerprint 的哈希>`）就不会失效，而 erofs 镜像里的文件时间戳又是固定的，结果刷完 OTA 后系统应用的 manifest 还是旧的：新加的权限、组件都不生效（2026-11-10 短信 app 的修复就因此第一次没生效）。已经出现这种情况时，root 下 `rm -rf /data/system/package_cache/*` 再重启即可。

`m target-files-package` 最后会在打包 vendor_boot 时报错（`mkbootimg --vendor_boot not compatible with given header version`）。**这是预期行为**：因为 vendor_boot 是我们自己嫁接的，BoardConfig 没有设置 boot header 版本。报错时暂存目录 `D` 已经生成好了，后面的脚本直接使用它。

## 4. 生成 OTA 卡刷包

从源码/资源改动到 OTA 一次完成：

```bash
device/oneplus/op5911/ota/build-ota.sh
# 同时生成增量包（源 target_files 必须是手机当前版本的）：
device/oneplus/op5911/ota/build-ota.sh \
  --incremental-from "$OP5911_OTA_OUT/target_files-<旧版本>.zip"
```

脚本自动生成新的 `BUILD_NUMBER`，依次刷新 host 工具、target-files 和 recovery 前置目标，再调用 `make-ota.sh`。`target-files-package` 已知的 vendor_boot 报错会被识别并继续；如果暂存树没有更新，或其中的 overlay APK 与 `PRODUCT_OUT` 不一致，脚本会停止，避免把旧内容打进包。最后会生成一个只含用户所需文件的 `release/op5911-<版本>/`。构建日志在 `$OP5911_OTA_OUT/build-<版本>.log`。需要固定版本号时加 `--build-number <值>`。

手动分步打包（target-files 和 recovery 前置目标已经就绪时）：

```bash
device/oneplus/op5911/ota/make-ota.sh
# 同时生成从某个旧版本出发的增量包：
device/oneplus/op5911/ota/make-ota.sh --incremental-from $OP5911_OTA_OUT/target_files-<旧版本>.zip
```

脚本只用 host 工具，按下面 8 步执行，每一步都会检查结果，出错就停。在本机全程约 25 分钟，大部分时间花在重建镜像和 `ota_from_target_files` 上。2026-11-10 实测：用它生成的增量包，在 Enforcing rec 里从 A 刷到 B 成功，B 槽正常开机。

1. **改 `misc_info.txt`**：跳过 vendor_boot 和 recovery.img 的打包。
2. **改写 build.prop 以通过 rec 的检查**。rec 运行时用的是原厂 vendor 的属性环境，会核对设备代号和构建标签，所以要做三处改动：
   - 所有分区的 `ro.product.<分区>.device` 改成 `ossi`
   - `test-keys` 改成 `release-keys`
   - SPL 改成 `2025-07-01`
3. **重建 system、system_ext、product 镜像**（`add_img_to_target_files`），让镜像里的属性和上一步一致。
4. **打 vendor 镜像**：`vendor-patch/patch-vendor-image.sh`。补丁内容见 README，此外 fstab 里的 `my_stock`、`my_preload`、`my_bigball` 会被删掉。
5. **打 recovery（vendor_boot）**：按 OTA 工具同样的规则计算这个版本的指纹，写进 `recovery-build-<版本>.props`，再交给 `build-recovery.sh`。rec 会报告这个版本的指纹、版本号、编译时间和 SPL，否则增量包会因为「源版本不符」被拒。
6. **组装 payload**：14 个动态分区，加上 vbmeta（会校验确实是原厂签名且 flags=3）、vendor_boot，以及 `OP5911_STOCK_FIRMWARE` 里的 21 个内核/固件分区（先按 `SHA256SUMS` 校验，并确认 `boot.img` 就是 recovery 嫁接用的那个内核）。同时检查两个槽加起来放得进 super（每槽约 3.74 GB，super 组上限 12.34 GB）。
7. **安全检查**：从将要发出去的 vendor_boot 里解出 recovery.fstab，确认没有 `formattable` 和 `/cache`；同时确认 rec 的指纹和这次构建一致。
8. **出包**：`ota_from_target_files`，并核对包里 `post-build` 与 rec 的指纹一致。

输出（都在 `$OP5911_OTA_OUT`）：

| 文件 | 用途 |
|---|---|
| `op5911-ota-full-<版本>.zip` | 完整包，约 3.2 GB |
| `op5911-ota-incr-<旧>-to-<新>.zip` | 增量包，只有传了 `--incremental-from` 才生成 |
| `target_files-<版本>.zip` | **请保留**，下次做增量包时作为源 |
| `recovery-build-<版本>.props` | 写进 rec 的版本身份，留作记录 |
| `bootstrap/` | 首装用的 `boot.img`、`dtbo.img`、`vendor_boot-recovery.img`、`vbmeta.img`；约 116 MB，不含 super raw |
| `release/op5911-<版本>/` | **给用户的发布目录**：完整/增量 OTA、`bootstrap/`、`FLASHING.md`、`SHA256SUMS`；不含 target-files、调试 recovery 或 super raw |

本地编译没设 `BUILD_NUMBER` 时版本号都是 `eng.<用户名>`，脚本会在文件名后加 `-月日时分`，避免新 target_files 覆盖作为增量源的旧文件。

`build-ota.sh` 会自动调用 `make-release.sh` 生成发布目录。手动重打发布目录时：

```bash
device/oneplus/op5911/ota/make-release.sh --build-number <版本>
# -> $OP5911_OTA_OUT/release/op5911-<版本>/
```

发布脚本只复制白名单文件，并在生成 `SHA256SUMS` 前拒绝 `super*.raw`、`super*.img`、`target_files` 和 debug 镜像。上传时只上传这个目录，不要直接打包整个 `$OP5911_OTA_OUT`。

发布脚本还会从完整 OTA 的 payload 中抽出 `boot`、`dtbo`、`vendor_boot`、`vbmeta`，与 `bootstrap/` 逐字节比较。原因是标准 AVB 构建里的 `add_img_to_target_files`（或 `sign_target_files_apks`）可能重新生成、重签 vbmeta；这个设备树虽然关闭 AVB 并保留原厂签名、flags=3 的 vbmeta，但校验能防止以后改配置后把不一致的 bootstrap 发出去。当前完整包的 payload vbmeta 与 `bootstrap/vbmeta.img` 哈希一致。

> `<版本>` 是 `ro.build.version.incremental`，也就是编译时的 `BUILD_NUMBER`。没设时是 `eng.<用户名>`，`make-ota.sh` 会给出警告（原因见第 3 节）。

### 4.1 单独重打 vendor 或 recovery

```bash
# vendor -> vendor/oneplus/op5911/images/vendor.img
device/oneplus/op5911/vendor-patch/patch-vendor-image.sh $OP5911_STOCK_IMAGES/vendor.img

# 正式版 recovery（Enforcing）-> vendor/oneplus/op5911/images/vendor_boot-recovery.img
RECOVERY_BUILD_PROPS=$OP5911_OTA_OUT/recovery-build-<版本>.props \
  device/oneplus/op5911/vendor_boot-patch/build-recovery.sh $OP5911_STOCK_VENDOR_BOOT $OP5911_STOCK_BOOT

# 调试版 recovery（Permissive + root adb）-> vendor_boot-recovery-debug.img
RECOVERY_BUILD_PROPS=... device/oneplus/op5911/vendor_boot-patch/build-recovery-debug.sh $OP5911_STOCK_VENDOR_BOOT $OP5911_STOCK_BOOT
```

正式版和调试版的区别：

| | 正式版 `build-recovery.sh` | 调试版 `build-recovery-debug.sh` |
|---|---|---|
| SELinux | `recovery` 域 Enforcing（`patch-recovery-sepolicy.py`） | 整机 Permissive（vendor cmdline 带 `androidboot.selinux=permissive`） |
| adb | shell 权限 | `adb root` 可用 |
| 日志 | 只能事后从系统里读 | 每秒写到 `/metadata/rec/` |
| 对正常系统的影响 | 无 | **正常开机也会变成 Permissive**，因为 vendor_boot 的 cmdline 两种启动共用 |

调试版只用来排查问题，不要打进要发布的 OTA。

recovery 有界面。启动后可能先显示 `No command`，按**电源键 + 音量上键**即可打开菜单；这不
影响 `adb sideload`、A/B OTA 或 boot HAL，也不需要为了首屏继续 debug recovery。调试版只在
需要 root adb 的整盘 super 救援（5.3 节）和需要 `/metadata/rec/` 持久化 recovery 日志排障时
使用。正常首装和日常升级都使用正式版，不要让调试版长期留在设备上。

### 4.2 recovery 嫁接做了什么

原厂 vendor_boot 是一个合并的 ramdisk，里面有 first-stage 的东西（270 个内核模块、`fstab.mt6895`、`init.recovery.mt6895.rc`）和一个只在 recovery 模式下使用的 `/system`。`build-recovery.sh` 保留 first-stage 部分，把 `/system` 和 `/res` 换成 AOSP recovery 的，然后做以下修补：

| 修补 | 原因 |
|---|---|
| 追加 `ro.recovery.usb.*` | 原厂没有这些属性，没有它们 USB 枚举不出来，无法侧载 |
| `sanitize-recovery-fstab.sh` | 去掉 `/cache`（oplusreserve2）和校准分区，去掉所有 `formattable` |
| `set-recovery-build-props.sh` | rec 报告当前版本的指纹和版本号（增量包需要） |
| 删掉 first-stage fstab 里的 `my_stock`、`my_preload`、`my_bigball` | 腾出 super 空间，否则 OTA 装不下 |
| 复制 4 个 `*_service_contexts`，boot HAL 自启 | 没有它们 servicemanager 起不来，update_engine 找不到 IBootControl |
| `patch-recovery-sepolicy.py` | 原厂策略连 `recovery` 域本身都是 permissive；去掉这一点，并补上 servicemanager 和 AIDL boot HAL 的规则。`init`、`kernel`、`ueventd`、`vendor_init` 原厂就是 permissive，保持不变 |

## 5. 安装

> 普通用户 OTA 升级请看 [FLASHING.md](FLASHING.md)；首次安装看本节。

### 5.1 日常升级（手机上已经是本系统）

```bash
adb reboot sideload
adb sideload $OP5911_OTA_OUT/op5911-ota-full-<版本>.zip     # 或增量包
# 等 adb 状态回到 recovery；首屏 No command 时可按电源键 + 音量上键看菜单：
adb wait-for-recovery
adb reboot
```

- 刷入目标是**当前槽的另一个槽**，成功后自动切过去。
- 完整包约 11 分钟（先完整读一遍做签名校验，再读一遍写入）；增量包约 35 秒（实测）。
- `adb sideload` 返回 0 只代表文件传完了，不代表刷入成功。确认方法：重启后看 `getprop ro.boot.slot_suffix` 是否换了槽；或者在系统里用 root 读 `/data/misc/recovery/last_log`，找 `Install from ADB complete (status: 0)`。
- 开机后快照合并在后台自动完成，可以用 `adb shell snapshotctl dump`（需要 root）确认 `Update state: none`。**合并完成后旧槽的数据就被覆盖了**，不能再切回去当备份。

#### 不进 rec，在开机状态下更新

系统里的 `update_engine` 在后台写另一个槽，期间手机照常可用，不经过 recovery。需要 userdebug 和 `adb root`；`update_engine_client` 由 `device.mk` 打进系统（这个改动之前的版本里没有，要从 `out/target/product/op5911/system/bin/` 推到 `/data/local/tmp` 运行）。

```bash
Z=$OP5911_OTA_OUT/op5911-ota-incr-<旧>-to-<新>.zip     # 或完整包
adb root
adb push "$Z" /data/ota_package/update.zip
adb shell 'chown system:cache /data/ota_package/update.zip; chmod 644 /data/ota_package/update.zip; restorecon /data/ota_package/update.zip'

# payload.bin 在 zip 里是不压缩存放的，算出它的偏移和大小，再取 payload_properties.txt
read OFF SIZE < <(python3 -I - "$Z" <<'PY'
import sys, zipfile, struct
z = zipfile.ZipFile(sys.argv[1]); i = z.getinfo('payload.bin'); f = open(sys.argv[1], 'rb')
f.seek(i.header_offset); h = f.read(30); n, e = struct.unpack('<HH', h[26:30])
print(i.header_offset + 30 + n + e, i.file_size)
PY
)
HEADERS=$(unzip -p "$Z" payload_properties.txt)

adb shell update_engine_client --update --follow \
    --payload=file:///data/ota_package/update.zip --offset=$OFF --size=$SIZE \
    --headers="\"$HEADERS\""
# 最后应输出 onPayloadApplicationComplete(ErrorCode::kSuccess (0)) 和 UPDATED_NEED_REBOOT
adb shell bootctl get-active-boot-slot      # 已切到另一个槽（0=a，1=b）
adb reboot
```

- 实测（2026-11-10）：513 KB 的增量包 72 秒写完，重启后进入新槽、Enforcing，合并自动完成。
- 写入过程中出错不会动当前槽；没执行 `adb reboot` 之前，可以用 `update_engine_client --cancel` 放弃。

### 5.2 首次安装（从原厂 ColorOS 或 GSI）

原厂 rec 不认我们的 OTA 签名，但正式版 recovery 认。首装正确做法不是整盘写 super，而是：

1. 把 B 槽同版本的 `boot`、`dtbo`、正式版 recovery 和原厂签名 `vbmeta` 写到 A 槽，作为临时启动环境；
2. 从 A 槽 recovery 侧载完整 OTA，让 `update_engine` 删除 B 槽旧分区并重建全部 14 个动态分区；
3. 清 `/data`，从 B 槽启动。

`super-b.raw` 只是维护者救砖镜像，**不是发布件，也不是首装前置条件**。

> 验证状态：完整 OTA 在目标槽从空分区创建 14 个动态分区已经验证；A 槽 bootstrap 到 B 槽首装这条完整链路还没有从原厂 ColorOS 开始逐项实机走完。第一次操作时请保留可进入 bootloader 的手段。

1. 生成 OTA 和首装 bootstrap 文件：

   ```bash
   device/oneplus/op5911/ota/make-ota.sh
   # 输出：$OP5911_OTA_OUT/op5911-ota-full-<版本>.zip
   #       $OP5911_OTA_OUT/bootstrap/{boot,dtbo,vendor_boot-recovery,vbmeta}.img
   # 发布目录：device/oneplus/op5911/ota/make-release.sh --build-number <版本>
   #       -> $OP5911_OTA_OUT/release/op5911-<版本>/
   ```

2. 解锁 bootloader，在 fastboot 下写入 A 槽。必须用 B 槽版本的 `boot`/`dtbo`：recovery 是从 B 槽 vendor_boot 嫁接的，而原厂 A/B 两槽的内核版本可能不同。

   ```bash
   fastboot flash boot_a         $OP5911_OTA_OUT/bootstrap/boot.img
   fastboot flash dtbo_a         $OP5911_OTA_OUT/bootstrap/dtbo.img
   fastboot flash vendor_boot_a  $OP5911_OTA_OUT/bootstrap/vendor_boot-recovery.img
   fastboot flash vbmeta_a       $OP5911_OTA_OUT/bootstrap/vbmeta.img
   fastboot --set-active=a
   fastboot reboot recovery
   ```

   这里是 `fastboot reboot recovery` 的唯一例外：A 槽现在装的是我们的正式 recovery，而这台 bootloader 固定从 A 槽进入 recovery，正好用来做首装引导。正常 OTA 场景仍按 1.2 节第 4 条，不要使用它。

3. 在 recovery 中侧载完整 OTA（不能用增量包）：

   ```bash
   adb devices                 # recovery
   adb reboot sideload
   adb devices                 # sideload
   adb sideload $OP5911_OTA_OUT/op5911-ota-full-<版本>.zip
   ```

   当前槽是 A，OTA 写入 B。recovery sideload 是 Virtual A/B 的非快照路径；空间不足时 `update_engine` 会删除 A 槽动态分区来腾空间，正在运行的 recovery 不受影响。终端必须出现 `status: 0` 或 `Install from ADB complete`。

4. 清旧数据并从 B 启动：

   ```bash
   adb reboot bootloader
   fastboot erase userdata
   fastboot --set-active=b
   fastboot reboot
   ```

   开机后确认 `adb shell getprop ro.boot.slot_suffix` 为 `_b`。如果希望 A 槽也完整，再从 B 做一次完整 OTA；它会重建 A 槽的全部分区。

### 5.3 救援：整盘写入 super（不是发布流程）

仅当已有机器的 super metadata/动态分区彻底损坏、recovery 无法侧载，或需要离线救砖时才使用整盘 `super` 镜像。它和正常首装是两条路径，发布包不得包含该镜像。

```bash
device/oneplus/op5911/ota/make-ota.sh
device/oneplus/op5911/ota/make-super.sh raw      # -> $OP5911_OTA_OUT/super-b.raw（12.3 GB）
```

救援时把调试版 rec 写到要启动的槽，进入 rec 后：

```bash
adb root
adb exec-in 'dd of=/dev/block/by-name/super bs=4194304' < $OP5911_OTA_OUT/super-b.raw
adb shell 'dd if=/dev/zero of=/dev/block/by-name/misc bs=2048 count=1'
adb reboot bootloader
```

然后在 bootloader 中写回正式版 rec、清除 userdata，并把活动槽设到刚写入的槽。整盘写 super 约 20 分钟，中途不要打断。`make-super.sh sparse` 生成的镜像只能用于 `fastboot flash super`，这条路径尚未验证，不能代替上面的滴灌救援流程。

## 6. 排查

| 现象 | 去哪里看 | 已知原因 |
|---|---|---|
| 开机几秒就回到 bootloader | 进 rec 读 `/sys/fs/pstore/console-ramoops-0`（失败的启动是热复位，日志还在；长按电源强制关机会清掉它） | 缺必需的动态分区（第 1.2 节第 1 条） |
| 开机后自动进 rec，提示清除数据（`init_user0_failed`） | 同上，搜 `vold`、`keystore2` | vbmeta 签名被换掉（第 1.2 节第 2 条）或 SPL 回退（第 5 条）。**先别清数据** |
| 侧载后 `status: 1` | 系统里 root 读 `/data/misc/recovery/last_log` | `Package is for source build …`：rec 的版本身份和增量包的源版本不一致；`failed to set up expected mounts`：rec fstab 有问题 |
| 侧载卡在 47% | 调试版 rec，看 update_engine 的 stderr | servicemanager 或 boot HAL 没起来 |
| 增量包提示源分区哈希不对 | `last_log` | 手机当前槽的内容和 `--incremental-from` 用的 target-files 不一致。注意 vendor_boot 也在比对范围内 |
| 刷完换到另一个槽后整机很卡 | `dumpsys gfxinfo com.android.launcher3`：`50th gpu percentile` 达到几秒；`dmesg` 里每隔几秒一条 `ufs_mtk_pltfrm_runtime_suspend` 的 WARN | 这个槽的内核和固件不是 vendor 那个版本（第 1.2 节第 6 条）。用带固件的完整包刷一次；对比两槽：root 下 `sha1sum /dev/block/by-name/<分区>_a` 和 `_b` |
| 刷完 OTA 后，系统应用的改动（新权限、新组件）没生效 | `dumpsys package <包名>` 看不到新声明的权限，但手机上的 APK 里已经有 | 没带 `BUILD_NUMBER` 编译，包解析缓存没失效（第 3 节）。root 下 `rm -rf /data/system/package_cache/*` 再重启 |
| 短信不弹通知 | `setprop log.tag.MessagingAppNotif VERBOSE` 后看 logcat，出现 `Notifications disabled` | 没打 `patches/` 里的短信补丁，短信 app 不被当作默认短信应用 |
| 闹钟只响不亮屏，或者干脆不响 | `dumpsys notification` 里时钟是 `importance=NONE`；logcat 里 `Background start not allowed ... deskclock` | 没有通知权限或不在 Doze 白名单：检查 `configs/default-permissions` 和 `configs/sysconfig` 是否进了 product |

rec 里每次启动都会把日志留在 pstore 中；回到系统后，`/data/misc/recovery/` 下的 `last_log*`、`last_kmsg*` 是之前几次 rec 的记录。

## 7. 文件索引

| 路径 | 作用 |
|---|---|
| `FLASHING.md` | 面向用户的首次安装和 OTA 刷入指南 |
| `ota/build-ota.sh` | 一键从源码到 OTA（第 4 节） |
| `ota/make-ota.sh` | 出 OTA 整包和增量包（第 4 节） |
| `ota/make-super.sh` | 救援用的完整 super 镜像（不进入发布包） |
| `ota/local.env` | 本机原厂镜像的路径 |
| `vendor-patch/patch-vendor-image.sh` | 原厂 vendor 打补丁并重打 erofs |
| `vendor_boot-patch/build-recovery.sh` | 正式版 rec（Enforcing） |
| `vendor_boot-patch/build-recovery-debug.sh` | 调试版 rec（Permissive、root adb、日志写 /metadata） |
| `vendor_boot-patch/patch-recovery-sepolicy.py` | rec 的 SELinux 补丁 |
| `vendor_boot-patch/sanitize-recovery-fstab.sh` | 去掉 rec fstab 里的危险条目 |
| `vendor_boot-patch/set-recovery-build-props.sh` | 写入 rec 的版本身份 |
| `recovery/recovery.fstab` | rec 的 fstab 源文件（已去掉 `formattable`） |
