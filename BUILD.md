# OP5911 编译、打包与刷机

OnePlus Ace（PGZ110 / OP5911，MT6895）AOSP 15 移植的完整构建流程：从源码编译，到生成 OTA 卡刷包，再到首次安装和后续升级。设备树做了哪些改动、各项 bring-up 经验见 [README.md](README.md)。

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
4. **进 rec 只能用 `adb reboot recovery` 或 `adb reboot sideload`，不要用 `fastboot reboot recovery`。** 这台机器的 bootloader 在 fastboot 下进 recovery 时固定走 A 槽的 vendor_boot，还会把活动槽改成 A。
5. **安全补丁级别（SPL）不能回退。** 系统一旦用较新的 SPL 开过机，KeyMint 就会把密钥升级到这个级别，之后再用旧 SPL 的系统开机，/data 解不开。所有构建都固定把 SPL 写成 `2025-07-01`（`OP5911_SPL` 可以改，但只能往后调）。
6. **内核和固件必须和 vendor 同一版本。** A、B 两个槽原来装的是不同版本的 ColorOS，有 22 个分区不一样。早先的 OTA 只写系统和 vendor，落到 A 槽时内核（5.10.236）和 gpueb、tee 等固件还是 A 槽的旧版本，配上 B 槽版本的 vendor 和内核模块：能开机，但 GPU 每帧要几秒、整机很卡，内核每隔几秒打一次 UFS runtime-suspend 的 WARN。现在 `make-ota.sh` 会把 B 槽的 21 个内核/固件分区一起打进包里，不管落到哪个槽都是同一套。
7. **改 `device.mk`、`BoardConfig.mk` 或任何 `.bp`/`.mk` 后，下一次 `m` 会触发 soong 重新分析，在这台机器上要约 1 小时。** 改动尽量攒在一起。本文第 4 节以后的步骤全部只用 host 工具，不会触发重新分析。

## 2. 准备工作

### 2.1 源码与编译目标

- 源码：AOSP 15（`android-15.0.0_r36`），设备树放在 `device/oneplus/op5911`，预编译文件放在 `vendor/oneplus/op5911`。
- lunch 目标：`aosp_op5911-bp1a-userdebug`。

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

## 3. 编译系统镜像

```bash
source build/envsetup.sh
lunch aosp_op5911-bp1a-userdebug

# 第一次需要的 host 工具
m fsck.erofs mkfs.erofs otatools

# 系统镜像 + target-files 暂存目录
m target-files-package

# recovery 嫁接需要的内容：AOSP recovery 的 /system，以及 AIDL boot HAL
m android.hardware.boot-service.default_recovery out/target/product/op5911/ramdisk-recovery.img
```

`m target-files-package` 最后会在打包 vendor_boot 时报错（`mkbootimg --vendor_boot not compatible with given header version`）。**这是预期行为**：因为 vendor_boot 是我们自己嫁接的，BoardConfig 没有设置 boot header 版本。报错时暂存目录 `D` 已经生成好了，后面的脚本直接使用它。

## 4. 生成 OTA 卡刷包

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
| `op5911-ota-full-<版本>.zip` | 完整包，约 2.9 GB |
| `op5911-ota-incr-<旧>-to-<新>.zip` | 增量包，只有传了 `--incremental-from` 才生成 |
| `target_files-<版本>.zip` | **请保留**，下次做增量包时作为源 |
| `recovery-build-<版本>.props` | 写进 rec 的版本身份，留作记录 |

本地编译没设 `BUILD_NUMBER` 时版本号都是 `eng.<用户名>`，脚本会在文件名后加 `-月日时分`，避免新 target_files 覆盖作为增量源的旧文件。

> `<版本>` 是 `ro.build.version.incremental`。userdebug 构建默认是 `eng.<用户名>`，不同构建的这个值会重复。要发多个版本的增量包，编译时请设置 `BUILD_NUMBER`，例如 `m target-files-package BUILD_NUMBER=20261110`（这个做法本机还没实测）。

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

### 5.1 日常升级（手机上已经是本系统）

```bash
adb reboot sideload
adb sideload $OP5911_OTA_OUT/op5911-ota-full-<版本>.zip     # 或增量包
# 屏幕不亮（rec 没有显示），等 adb 状态回到 recovery：
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

原厂 rec 不认我们的 OTA 签名，原厂 super 也几乎是满的，所以第一次只能直接写分区。

> 实测情况：第 2 步的 vbmeta、第 4 步的整盘写 super、第 5 步的清 BCB 和换 rec，都在 2026-11-10 救回 B 槽时实测过。但「从原厂 ColorOS 开始」的完整流程（包括清 /data）没有从头完整走过一遍，第一次照做时请逐步确认。

1. 生成镜像：

   ```bash
   device/oneplus/op5911/ota/make-ota.sh                 # 准备好全部镜像和 vendor_boot
   device/oneplus/op5911/ota/make-super.sh raw           # -> $OP5911_OTA_OUT/super-b.raw（12.3 GB）
   ```

2. 解锁 bootloader，在 fastboot 下写入物理分区：

   ```bash
   fastboot flash vendor_boot_b vendor/oneplus/op5911/images/vendor_boot-recovery-debug.img
   fastboot flash vbmeta_b      $OP5911_STOCK_VBMETA
   fastboot --set-active=b
   fastboot reboot bootloader && fastboot getvar current-slot   # 确认是 b
   ```

3. 进 B 槽的调试版 rec（需要 root 才能写 super）。从原厂系统执行 `adb reboot recovery`；如果系统已经起不来，就先把调试版 rec 也写进 `vendor_boot_a`，再用 `fastboot reboot recovery`（这个命令走 A 槽，见第 1.2 节第 4 条）。

4. 整盘写入 super（12.3 GB 走 USB，约 20 分钟；中途不要打断，否则分区表和数据会不一致）：

   ```bash
   adb root
   adb exec-in 'dd of=/dev/block/by-name/super bs=4194304' < $OP5911_OTA_OUT/super-b.raw
   ```

5. 还在 rec 里，清掉 BCB（否则下次开机可能又进 rec），然后进 bootloader：

   ```bash
   adb shell 'dd if=/dev/zero of=/dev/block/by-name/misc bs=2048 count=1'
   adb reboot bootloader
   ```

6. 在 bootloader 的 fastboot 下，把 vendor_boot_b 换成正式版 rec。从 ColorOS 过来时还要清除 /data（加密方式不同；第一阶段 bring-up 时用的是 `fastboot erase userdata`）。然后开机：

   ```bash
   fastboot flash vendor_boot_b vendor/oneplus/op5911/images/vendor_boot-recovery.img
   fastboot erase userdata          # 仅从 ColorOS / GSI 首次切换时需要
   fastboot --set-active=b
   fastboot reboot
   ```

   开机后设置锁屏时如果被 FRP 拦住，见 README 的 FRP 一节。

之后就可以按 5.1 用 OTA 升级。第一次 OTA 会写入 A 槽，并在 A 槽建出全部 14 个分区。

> `make-super.sh sparse` 可以生成给 `fastboot flash super` 用的稀疏镜像，但这条路径在本机**没有测试过**。

## 6. 排查

| 现象 | 去哪里看 | 已知原因 |
|---|---|---|
| 开机几秒就回到 bootloader | 进 rec 读 `/sys/fs/pstore/console-ramoops-0`（失败的启动是热复位，日志还在；长按电源强制关机会清掉它） | 缺必需的动态分区（第 1.2 节第 1 条） |
| 开机后自动进 rec，提示清除数据（`init_user0_failed`） | 同上，搜 `vold`、`keystore2` | vbmeta 签名被换掉（第 1.2 节第 2 条）或 SPL 回退（第 5 条）。**先别清数据** |
| 侧载后 `status: 1` | 系统里 root 读 `/data/misc/recovery/last_log` | `Package is for source build …`：rec 的版本身份和增量包的源版本不一致；`failed to set up expected mounts`：rec fstab 有问题 |
| 侧载卡在 47% | 调试版 rec，看 update_engine 的 stderr | servicemanager 或 boot HAL 没起来 |
| 增量包提示源分区哈希不对 | `last_log` | 手机当前槽的内容和 `--incremental-from` 用的 target-files 不一致。注意 vendor_boot 也在比对范围内 |

rec 里每次启动都会把日志留在 pstore 中；回到系统后，`/data/misc/recovery/` 下的 `last_log*`、`last_kmsg*` 是之前几次 rec 的记录。

## 7. 文件索引

| 路径 | 作用 |
|---|---|
| `ota/make-ota.sh` | 出 OTA 整包和增量包（第 4 节） |
| `ota/make-super.sh` | 首次安装用的完整 super 镜像 |
| `ota/local.env` | 本机原厂镜像的路径 |
| `vendor-patch/patch-vendor-image.sh` | 原厂 vendor 打补丁并重打 erofs |
| `vendor_boot-patch/build-recovery.sh` | 正式版 rec（Enforcing） |
| `vendor_boot-patch/build-recovery-debug.sh` | 调试版 rec（Permissive、root adb、日志写 /metadata） |
| `vendor_boot-patch/patch-recovery-sepolicy.py` | rec 的 SELinux 补丁 |
| `vendor_boot-patch/sanitize-recovery-fstab.sh` | 去掉 rec fstab 里的危险条目 |
| `vendor_boot-patch/set-recovery-build-props.sh` | 写入 rec 的版本身份 |
| `recovery/recovery.fstab` | rec 的 fstab 源文件（已去掉 `formattable`） |
