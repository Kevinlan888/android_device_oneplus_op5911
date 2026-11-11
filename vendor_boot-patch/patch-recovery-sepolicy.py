#!/usr/bin/env python3
"""Make the grafted AOSP recovery work with the `recovery` domain ENFORCING.

The route-2 graft keeps the STOCK OPPO ramdisk root, including its precompiled
/sepolicy. That policy predates the AOSP 15 recovery userspace we put in
/system, so under Enforcing servicemanager and the AIDL boot HAL can't run and
update_engine can't apply an OTA. This patches the stock policy and contexts in
place (no debug/diagnostic access is added):

  * servicemanager: rootfs read access (AOSP recovery's r_dir_file), and the
    servicemanager_prop type + `servicemanager.ready` mapping that the older
    policy lacks.
  * AIDL boot HAL (android.hardware.boot-service.default_recovery): exec label,
    hal_bootctl_service type and Binder registration/call permissions.
  * Grafted files start out labelled rootfs; init restorecons them before
    starting servicemanager.
  * Extra rules in EXTRA_RULES, found from avc denials of a real OTA apply.

The stock policy also ships init/kernel/ueventd/vendor_init permissive; that is
OPPO's own recovery behaviour and is left unchanged. `recovery` must stay
enforced - asserted below.

usage: patch-recovery-sepolicy.py <ramdisk-root> <android-top>
"""
from pathlib import Path
import struct
import subprocess
import sys
import tempfile

rd = Path(sys.argv[1]).resolve()
top = Path(sys.argv[2]).resolve()
host = top / 'out/host/linux-x86/bin'

# Rules added after observing denials during a real Enforcing OTA apply.
EXTRA_RULES = '''
'''


def run(*args, **kw):
    return subprocess.run([str(a) for a in args], check=True, **kw)


policy = rd / 'sepolicy'
header = policy.read_bytes()
name_len = struct.unpack_from('<I', header, 4)[0]
version = struct.unpack_from('<I', header, 8 + name_len)[0]

with tempfile.TemporaryDirectory() as tmp:
    cil = Path(tmp) / 'policy.cil'
    run(host / 'checkpolicy', '-M', '-b', '-C', '-o', cil, policy)
    text = cil.read_text()
    if '; OP5911 recovery Enforcing compat' in text:
        raise SystemExit('policy already patched')
    # Stock OPPO policy ships the recovery domain itself permissive.
    assert text.count('(typepermissive recovery)\n') == 1, 'stock recovery permissive stmt'
    text = text.replace('(typepermissive recovery)\n', '')
    r = ['', '; OP5911 recovery Enforcing compat']
    # AOSP recovery: r_dir_file(servicemanager, rootfs)
    r += ['(allow servicemanager rootfs (dir (ioctl read getattr lock open search)))',
          '(allow servicemanager rootfs (file (ioctl read getattr lock map open)))',
          '(allow servicemanager rootfs (lnk_file (ioctl read getattr lock map open)))']
    # servicemanager.ready
    r += ['(type servicemanager_prop)', '(roletype object_r servicemanager_prop)']
    for a in ('property_type', 'system_property_type', 'system_internal_property_type'):
        r.append(f'(typeattributeset {a} (servicemanager_prop))')
    r.append('(allow servicemanager servicemanager_prop (property_service (set)))')
    for d in ('servicemanager', 'init', 'hal_bootctl_default', 'recovery', 'update_engine'):
        r.append(f'(allow {d} servicemanager_prop (file (read getattr map open)))')
    # AIDL boot HAL
    r += ['(type hal_bootctl_service)', '(roletype object_r hal_bootctl_service)']
    for a in ('service_manager_type', 'protected_service'):
        r.append(f'(typeattributeset {a} (hal_bootctl_service))')
    r += ['(allow hal_bootctl_default hal_bootctl_service (service_manager (add find)))',
          '(allow recovery hal_bootctl_service (service_manager (find)))',
          '(allow hal_bootctl_default servicemanager (binder (call transfer)))',
          '(allow servicemanager hal_bootctl_default (binder (transfer)))',
          '(allow servicemanager hal_bootctl_default (dir (search)))',
          '(allow servicemanager hal_bootctl_default (file (read open)))',
          '(allow servicemanager hal_bootctl_default (process (getattr)))',
          '(allow recovery servicemanager (binder (call transfer)))',
          '(allow recovery hal_bootctl_default (binder (call transfer)))',
          '(allow hal_bootctl_default recovery (binder (transfer)))']
    text += '\n'.join(r) + '\n' + EXTRA_RULES
    cil.write_text(text)
    run(host / 'secilc', '-D', '-M', 'true', '-c', version, '-o', policy,
        '-f', Path(tmp) / 'fc.unused', cil)

permissive = subprocess.check_output(
    [str(host / 'sepolicy-analyze'), str(policy), 'permissive'], text=True).split()
assert 'recovery' not in permissive, permissive
print('   permissive domains (stock):', ' '.join(permissive))

with (rd / 'plat_file_contexts').open('a') as f:
    f.write('\n/system/bin/hw/android\\.hardware\\.boot-service\\.default_recovery'
            ' u:object_r:hal_bootctl_default_exec:s0\n')
with (rd / 'plat_property_contexts').open('a') as f:
    f.write('\nservicemanager.ready u:object_r:servicemanager_prop:s0 exact bool\n')

rc = rd / 'system/etc/init/hw/init.rc'
t = rc.read_text()
assert t.count('    start servicemanager') == 1, 'init.rc: start servicemanager anchor'
t = t.replace('    start servicemanager',
              '    restorecon /system/bin/servicemanager /system/bin/linker64'
              ' /system/bin/hw/android.hardware.boot-service.default_recovery\n'
              '    restorecon_recursive /system/lib64 /system/lib /system/etc/selinux\n'
              '    restorecon /plat_service_contexts /system_ext_service_contexts'
              ' /product_service_contexts /vendor_service_contexts\n'
              '    start servicemanager', 1)
rc.write_text(t)
print('   sepolicy patched, contexts appended, init.rc restorecon added')
