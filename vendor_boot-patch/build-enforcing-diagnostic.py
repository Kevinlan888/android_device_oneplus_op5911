#!/usr/bin/env python3
"""Build a diagnostic vendor_boot with recovery enforced and shell dmesg access.

Other stock permissive domains remain unchanged. This is not a release image.
Input defaults to the existing production vendor_boot; never overwrites it.
"""
from pathlib import Path
import hashlib
import shutil
import struct
import subprocess
import sys

TOP = Path(__file__).resolve().parents[4]
HOST = TOP / 'out/host/linux-x86/bin'
MK = TOP / 'system/tools/mkbootimg'
WORK = TOP / 'out/recovery-enforcing-diagnostic-build'
BASE = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else TOP / 'vendor/oneplus/op5911/images/vendor_boot-recovery.img'
OUT = TOP / 'vendor/oneplus/op5911/images/vendor_boot-recovery-enforcing-diag-v9.img'

def run(*args, **kwargs):
    return subprocess.run([str(x) for x in args], check=True, **kwargs)

if WORK.exists():
    shutil.rmtree(WORK)
(WORK / 'rd').mkdir(parents=True)
run(sys.executable, MK / 'unpack_bootimg.py', '--boot_img', BASE, '--out', WORK / 'unpacked')
run(HOST / 'lz4', '-d', '-f', WORK / 'unpacked/vendor_ramdisk00', WORK / 'ramdisk.cpio')
with (WORK / 'ramdisk.cpio').open('rb') as source:
    run('cpio', '-idm', '--no-absolute-filenames', stdin=source, cwd=WORK / 'rd')
rd = WORK / 'rd'
probe = TOP / 'out/target/product/op5911/recovery/root/system/bin/op5911-boot-hal-probe'
if not probe.is_file():
    raise SystemExit('Build op5911-boot-hal-probe before making the diagnostic image')
shutil.copy2(probe, rd / 'system/bin/op5911-boot-hal-probe')
policy = rd / 'sepolicy'
header = policy.read_bytes()
name_length = struct.unpack_from('<I', header, 4)[0]
version = struct.unpack_from('<I', header, 8 + name_length)[0]
cil = WORK / 'policy.cil'
run(HOST / 'checkpolicy', '-M', '-b', '-C', '-o', cil, policy)
text = cil.read_text()
text = text.replace('(typepermissive recovery)\n', '')
text += '\n; Diagnostic only: permit shell to collect kernel audit messages.\n'
text += '(allow shell kernel (system (syslog_read)))\n'
# Match current AOSP recovery's r_dir_file(servicemanager, rootfs).
text += '(allow servicemanager rootfs (dir (ioctl read getattr lock open search)))\n'
text += '(allow servicemanager rootfs (file (ioctl read getattr lock map open)))\n'
text += '(allow servicemanager rootfs (lnk_file (ioctl read getattr lock map open)))\n'
# The older stock policy predates servicemanager.ready and its dedicated type.
text += '(type servicemanager_prop)\n(roletype object_r servicemanager_prop)\n'
for attribute in ('property_type', 'system_property_type', 'system_internal_property_type'):
    text += f'(typeattributeset {attribute} (servicemanager_prop))\n'
text += '(allow servicemanager servicemanager_prop (property_service (set)))\n'
# Match AOSP domain.te get_prop({domain -hwservicemanager -vndservicemanager}, servicemanager_prop).
for domain in ('servicemanager', 'init', 'shell', 'hal_bootctl_default', 'recovery', 'update_engine'):
    text += f'(allow {domain} servicemanager_prop (file (read getattr map open)))\n'
# Adapt the older HIDL boot HAL domain for the grafted AIDL service.
text += '(type hal_bootctl_service)\n(roletype object_r hal_bootctl_service)\n'
for attribute in ('service_manager_type', 'protected_service'):
    text += f'(typeattributeset {attribute} (hal_bootctl_service))\n'
text += '(allow hal_bootctl_default hal_bootctl_service (service_manager (add find)))\n'
text += '(allow recovery hal_bootctl_service (service_manager (find)))\n'
text += '(allow hal_bootctl_default servicemanager (binder (call transfer)))\n'
text += '(allow servicemanager hal_bootctl_default (binder (transfer)))\n'
text += '(allow servicemanager hal_bootctl_default (dir (search)))\n'
text += '(allow servicemanager hal_bootctl_default (file (read open)))\n'
text += '(allow servicemanager hal_bootctl_default (process (getattr)))\n'
text += '(allow recovery servicemanager (binder (call transfer)))\n'
text += '(allow recovery hal_bootctl_default (binder (call transfer)))\n'
text += '(allow hal_bootctl_default recovery (binder (transfer)))\n'
# Diagnostic shell can only find/call the HAL; probe implements no setters.
text += '(allow shell hal_bootctl_service (service_manager (find)))\n'
text += '(allow shell servicemanager (binder (call transfer)))\n'
text += '(allow shell hal_bootctl_default (binder (call transfer)))\n'
text += '(allow hal_bootctl_default shell (binder (transfer)))\n'
# Diagnostic log has its own label, avoiding shell access to arbitrary tmpfs files.
text += '(type recovery_diagnostic_log)\n(roletype object_r recovery_diagnostic_log)\n'
text += '(typeattributeset file_type (recovery_diagnostic_log))\n'
text += '(allow recovery recovery_diagnostic_log (file (read write append open getattr setattr)))\n'
text += '(allow shell recovery_diagnostic_log (file (read open getattr)))\n'
text += '(allow shell tmpfs (dir (search)))\n'
cil.write_text(text)
with (rd / 'plat_file_contexts').open('a') as f:
    f.write('\n/system/bin/hw/android\\.hardware\\.boot-service\\.default_recovery u:object_r:hal_bootctl_default_exec:s0\n')
with (rd / 'plat_property_contexts').open('a') as f:
    f.write('\nservicemanager.ready u:object_r:servicemanager_prop:s0 exact bool\n')
run(HOST / 'secilc', '-D', '-M', 'true', '-c', version, '-o', policy, '-f', WORK / 'file_contexts.unused', cil)
permissive = subprocess.check_output([str(HOST / 'sepolicy-analyze'), str(policy), 'permissive'], text=True).split()
assert 'recovery' not in permissive, permissive
rc = rd / 'system/etc/init/hw/init.rc'
# Grafted cpio files start as rootfs; the service has an explicit domain.
# Restore its existing platform file_contexts label before the first exec.
rc_text = rc.read_text()
assert '    mount tmpfs tmpfs /tmp' in rc_text
rc_text = rc_text.replace('    mount tmpfs tmpfs /tmp',
    '    mount tmpfs tmpfs /tmp\n'
    '    write /tmp/recovery.log ""\n'
    '    chcon u:object_r:recovery_diagnostic_log:s0 /tmp/recovery.log\n'
    '    chmod 0644 /tmp/recovery.log', 1)
assert '    start servicemanager' in rc_text
rc.write_text(rc_text.replace('    start servicemanager',
    '    restorecon /system/bin/servicemanager /system/bin/linker64 /system/bin/hw/android.hardware.boot-service.default_recovery\n'
    '    restorecon_recursive /system/lib64 /system/lib /system/etc/selinux\n'
    '    restorecon /plat_service_contexts /system_ext_service_contexts /product_service_contexts /vendor_service_contexts\n'
    '    start servicemanager', 1))
with rc.open('a') as f:
    f.write('\n# Diagnostic only: shell dmesg access, recovery domain stays enforced.\non init\n    write /proc/sys/kernel/dmesg_restrict 0\n    setprop ro.recovery.diagnostic enforcing-recovery-v9\n')
with (rd / 'prop.default').open('a') as f:
    f.write('\n# Diagnostic image: keep shell ADB for Enforcing USB compatibility.\nro.debuggable=0\nro.secure=1\nservice.adb.root=0\n')
with (WORK / 'ramdisk.cpio').open('wb') as target:
    run(HOST / 'mkbootfs', rd, stdout=target)
run(HOST / 'lz4', '-l', '-9', '-f', WORK / 'ramdisk.cpio', WORK / 'ramdisk.lz4')
run(sys.executable, MK / 'mkbootimg.py', '--header_version', '4', '--pagesize', '4096',
    '--base', '0x0', '--kernel_offset', '0x40000000', '--ramdisk_offset', '0x66f00000',
    '--tags_offset', '0x47c80000', '--dtb_offset', '0x47c80000',
    '--vendor_cmdline', 'bootopt=64S3,32N2,64N2 buildvariant=user', '--board', '',
    '--dtb', WORK / 'unpacked/dtb', '--ramdisk_type', 'platform', '--ramdisk_name', '',
    '--vendor_ramdisk_fragment', WORK / 'ramdisk.lz4', '--vendor_boot', OUT)
assert OUT.stat().st_size <= 67108864
print('Diagnostic image:', OUT)
print('Remaining stock permissive domains:', ', '.join(permissive))
print('SHA256:', hashlib.sha256(OUT.read_bytes()).hexdigest())
