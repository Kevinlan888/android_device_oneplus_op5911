# OP5911 刷入指南

本文面向拿到发布包、不参与编译的用户。适用于一加 Ace（PGZ110 / OP5911，MT6895）。**不要刷到其他机型。** 本文覆盖从 ColorOS/GSI 首次安装，以及已经运行本系统后的 OTA 升级。

首次安装只需要完整 OTA 和约 116 MB 的 bootstrap 启动镜像。完整 OTA 会在目标槽重建全部分区，**不需要整盘 super 镜像，发布目录也不包含它**；全部文件合计约 3.4 GB。

> 这是 AOSP 16 userdebug 社区构建，使用 test-keys，不是官方 ColorOS。刷机、解锁和清数据都有风险；请先完整阅读本文，并确认自己能够接受数据丢失和无法回退的情况。

## 0. 先选路径

| 手机当前状态 | 使用哪一节 |
|---|---|
| 还是 ColorOS / GSI，第一次安装 | 第 3 节，首次安装 |
| 已经在运行本系统，只是升级 | 第 4 节，OTA 升级 |
| 已经刷入但无法开机或侧载失败 | 第 5 节，常见问题 |

## 1. 先确认设备和环境

在电脑上安装 Android Platform Tools，确认 `adb`、`fastboot` 可用。手机需要：

- 已按一加官方流程解锁 bootloader；解锁本身也会清空数据；
- 电量至少 50%，最好接电源；
- 使用可靠的数据线，直接连接电脑，不经过 USB Hub；
- 首次安装或恢复出厂都会清除 `/data`，请先备份。

连接手机后检查：

```bash
adb devices
fastboot devices
adb shell getprop ro.product.device
adb shell getprop ro.product.model
```

本系统的 `ro.product.device` 应为 `ossi`。从 ColorOS/GSI 首次安装时，如果系统无法启动，至少要通过型号确认手机确实是一加 Ace（PGZ110 / OP5911）；型号或代号不对时立刻停止。

同时只连接一台 Android 设备。`adb devices` 显示 `unauthorized` 时，先在手机上允许 USB 调试。

## 2. 发布包应该包含什么

发布者应提供以下文件，并在同一目录放一份 `SHA256SUMS`：

| 文件 | 用途 | 何时需要 |
|---|---|---|
| `op5911-ota-full-<版本>.zip` | 完整 OTA；负责写入全部动态分区、内核和固件 | 首装和升级 |
| `op5911-ota-incr-<旧>-to-<新>.zip` | 增量 OTA，只能从指定旧版本升级 | 与当前版本完全匹配时 |
| `bootstrap/vendor_boot-recovery.img` | 正式版 recovery，Enforcing，shell adb | 首装或 recovery 修复 |
| `bootstrap/boot.img` | 与 recovery vendor_boot 匹配的启动内核 | 首装 |
| `bootstrap/dtbo.img` | 与上述内核匹配的 dtbo | 首装 |
| `bootstrap/vbmeta.img` | 原厂 OPPO 签名、flags=3 的 vbmeta | 首装 |
| `FLASHING.md` | 本刷入指南 | 始终 |
| `SHA256SUMS` | 上述文件的 SHA-256 校验和 | 始终 |

发布目录应保持下面的结构；`RELEASE.txt` 只是版本说明，不是刷机输入：

```text
op5911-<版本>/
├── op5911-ota-full-<版本>.zip
├── bootstrap/
│   ├── boot.img
│   ├── dtbo.img
│   ├── vendor_boot-recovery.img
│   └── vbmeta.img
├── FLASHING.md
├── RELEASE.txt
└── SHA256SUMS
```

**首装不写整盘 super。** 完整 OTA 的 `update_engine` 会删除目标槽旧动态分区，再按 payload 创建全部分区，所以不需要 `super-b.raw`/`super-b.img`。发布目录也不应包含 `target_files`、调试 recovery 或整盘镜像；维护者的 `make-release.sh` 会拒绝这些文件。

下载后先校验：

```bash
sha256sum -c SHA256SUMS
```

任何一项显示 `FAILED` 都不要继续，重新下载。

macOS 可用 `shasum -a 256 -c SHA256SUMS`。Windows 没有 `sha256sum` 时，可以用 7-Zip 或 PowerShell 的 `Get-FileHash -Algorithm SHA256` 逐个对照。

正式版 recovery 有界面。启动后可能先显示 `No command`，按**电源键 + 音量上键**即可打开 recovery 菜单；`adb reboot sideload` 则会直接进入侧载模式。`No command` 不是故障。

## 3. 首次安装（从 ColorOS / GSI）

首装固定使用 **A 槽的临时 recovery**，把完整 OTA 写入 **B 槽**。安装完成后手机从 B 槽启动。

> 首装会清除 `/data`。如果 A 槽原本是 ColorOS/GSI，刷入匹配 B 槽的内核后不要再从 A 槽启动旧系统；只按本节进入 recovery。OTA 在空间不足时可能删除 A 槽的动态系统分区，这是正常的：首装首先保证 B 槽可用。

### 3.1 写入 A 槽启动环境

进入 bootloader：

```bash
adb reboot bootloader
# 如果系统已经无法启动，用按键进入 bootloader
fastboot devices
```

写入与正式 recovery 同一套的启动镜像和 vbmeta：

```bash
fastboot flash boot_a         bootstrap/boot.img
fastboot flash dtbo_a         bootstrap/dtbo.img
fastboot flash vendor_boot_a  bootstrap/vendor_boot-recovery.img
fastboot flash vbmeta_a       bootstrap/vbmeta.img
fastboot --set-active=a
fastboot reboot recovery
```

这里的 `fastboot reboot recovery` 是**首装特例**：A 槽的 vendor_boot 刚被换成我们的正式 recovery，而这台机器的 bootloader 固定从 A 槽进入 recovery，所以正好进入临时 recovery。日常升级时仍然不要使用这个命令。

等手机显示 `No command`，按**电源键 + 音量上键**打开菜单，或者直接执行下一步的 `adb reboot sideload`。

### 3.2 侧载完整 OTA

先确认手机处于 recovery：

```bash
adb devices
```

状态应为 `recovery`，然后进入 sideload：

```bash
adb reboot sideload
adb devices
```

状态应变为 `sideload`。执行：

```bash
adb sideload op5911-ota-full-<版本>.zip
```

当前活动槽是 A，因此完整 OTA 会写入 B 槽，并在成功后把 B 设为活动槽。不要使用增量包做首次安装。

刷入期间不要拔线、不要执行其他 adb/fastboot 命令。完整包通常需要约 10–15 分钟，以终端出现 `status: 0` 或 `Install from ADB complete` 为准。

### 3.3 清除旧数据并启动 B 槽

侧载成功后进入 bootloader：

```bash
adb reboot bootloader
fastboot erase userdata
fastboot --set-active=b
fastboot reboot
```

`fastboot erase userdata` 会清空全部用户数据。首次开机较慢，请耐心等待。

> 刚执行 `--set-active=b` 后，bootloader 立即返回的 `current-slot` 可能是旧值；以重启后系统里的 `ro.boot.slot_suffix` 为准。

### 3.4 升级后确认

```bash
adb shell getprop ro.boot.slot_suffix
adb shell getprop ro.build.version.incremental
adb shell getprop ro.build.version.security_patch
```

`ro.boot.slot_suffix` 应为 `_b`。

此时 A 槽可能不是一套完整系统。若希望 A 槽也可启动，再从 B 槽执行一次**完整 OTA**；它会写入 A 槽并重建 A 的全部分区。是否执行不影响 B 槽日常使用。

## 4. 已有本系统：OTA 升级

适用于手机已经在运行本系统的情况。此方式保留 `/data`。

### 4.1 选择包

- 不确定当前版本，或跨版本升级：用 **full** 完整包。
- 增量包必须和手机当前版本完全匹配；不确定时不要用增量包。

### 4.2 侧载

先确认设备在线：

```bash
adb devices
```

进入 sideload 模式并等待手机重新出现：

```bash
adb reboot sideload
adb devices
```

`adb devices` 应显示状态 `sideload`。然后执行：

```bash
adb sideload op5911-ota-full-<版本>.zip
# 或者使用已经确认匹配当前版本的增量包：
# adb sideload op5911-ota-incr-<旧>-to-<新>.zip
```

recovery 首屏可能显示 `No command`，这是正常的；按**电源键 + 音量上键**可以打开菜单。执行 `adb reboot sideload` 时通常不需要操作菜单，直接以 `adb devices` 显示 `sideload` 和终端输出为准。

刷入期间：

- 不要断开 USB；
- 不要执行 `fastboot reboot recovery`；
- 不要同时运行其他 adb/fastboot 命令；
- `adb sideload` 返回 0 只代表文件传输完成，必须等终端出现 `status: 0` 或 `Install from ADB complete`。

完成后重启：

```bash
adb devices
adb reboot
```

如果没有安装成功标志，先不要重启，按第 5 节排查。

### 4.3 升级后确认

```bash
adb shell getprop ro.boot.slot_suffix
adb shell getprop ro.build.version.incremental
adb shell getprop ro.build.version.security_patch
```

OTA 会写入当前槽的另一个槽，成功后从新槽启动。一次 OTA 完成后，旧槽会在快照合并后被新数据覆盖，**不能把它当成可随时切回的备份**。

## 5. 常见问题

### recovery 显示 `No command`

正常现象，不是刷入失败。按**电源键 + 音量上键**即可打开 recovery 菜单；侧载时也可以用 `adb devices` 和终端输出判断状态。

### 首装时 `fastboot reboot recovery` 进入了原厂 recovery

说明 A 槽的 recovery 没有写入成功，或者命令执行前活动槽不是 A。重新确认使用的是 `vendor_boot-recovery.img`，并重新执行第 3.1 节。不要在首装时把正式 recovery 只写到 B 槽后再用 `fastboot reboot recovery`。

### `adb sideload` 返回 0，但系统没有变化

返回 0 只代表传输完成。检查终端是否出现 `status: 0` 或 `Install from ADB complete`；开机后用 `adb shell getprop ro.boot.slot_suffix` 看槽位是否改变。没有成功标志时不要反复刷同一个包。

### `status: 1`

常见原因是增量包的源版本与手机当前版本不一致，或 recovery 与包不匹配。先用**完整包**重试。不要直接清 `/data`。如果完整包仍然失败，保留终端完整输出，并记录当前系统版本和所用包的完整文件名。

### 开机几秒回到 bootloader

通常是动态分区或固件不完整。先尝试：

```bash
fastboot devices
fastboot getvar current-slot
fastboot --set-active=b
fastboot reboot
```

仍然失败时，不要反复清数据。记录 `fastboot getvar current-slot` 的输出，并联系维护者；恢复时需要匹配的完整 OTA 和正确版本的 vendor_boot。

### 开机自动进入 recovery，提示清除数据

先不要确认清除。常见原因是 vbmeta 不是原厂 OPPO 签名、SPL 回退或版本不匹配。恢复对应的 vbmeta/完整包后再试；清数据可能无法解决，反而会丢失恢复所需的数据。

### 设置 PIN 时被 FRP 拦住

不要未经备份就清 `frp` 分区或改写 FRP magic/secret。先保留完整分区备份并联系维护者；写到错误位置会让 FRP 状态更难恢复。

### 手机很卡，GPU 每帧耗时异常

通常是另一个槽的内核和固件与 vendor 不匹配。用带完整固件的**完整 OTA** 再刷一次，不要继续用旧增量包。

## 6. 回退和注意事项

- **没有可靠的一键回退。** OTA 的另一个槽在合并后会被覆盖；要回退只能重新刷匹配的旧完整包或恢复原厂系统。
- **SPL 不能回退。** 当前构建固定使用 `2025-07-01`；用更低 SPL 的旧系统启动可能导致 `/data` 无法解密。不要在没有备份的情况下尝试降级。
- **不要重新锁 bootloader。** 自定义签名和 AVB 状态不满足官方回锁条件，重新上锁可能导致设备无法启动。
- **不要混用其他机型的镜像。** 本指南只适用于 PGZ110 / OP5911。
- **发行包应保留校验和。** 传输大文件时优先使用能校验完整性的方式，避免把损坏的 OTA 写入手机。

如果仍然无法启动，保留以下信息再求助：

```bash
fastboot getvar current-slot
adb devices
adb shell getprop ro.boot.slot_suffix
```

以及失败时的完整终端输出、手机当前版本、所用完整包的文件名和发生问题前的操作步骤。
