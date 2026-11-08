#!/usr/bin/env python3
"""Compare key kernel struct layouts between a stock and a modified vmlinux.

The OTA build starts from the exact stock config and only adds container
options.  This check fails if a modified struct changes an existing member's
offset/size, or changes the total size, so the boot.img cannot silently break
vendor modules.
"""
import argparse
import re
import subprocess
import sys

DEFAULT_STRUCTS = [
    'task_struct', 'nsproxy', 'cred', 'user_namespace', 'net',
    'pid_namespace', 'ipc_namespace', 'inode', 'file', 'super_block',
    'mount', 'mnt_namespace', 'signal_struct', 'sighand_struct',
    'fs_struct', 'files_struct', 'mm_struct', 'cgroup', 'css_set',
]
DEFAULT_ALLOW_NEW = {'sysvsem', 'sysvshm'}
# The Droidspaces SYSVIPC kABI patch deliberately repurposes the last three
# Android KABI reserve slots for sysvsem/sysvshm.  pahole reports the reserve
# names as offsets inside the anonymous union, so allow exactly those three.
EXPECTED_CHANGES = {
    ('task_struct', 'android_kabi_reserved6'),
    ('task_struct', 'android_kabi_reserved7'),
    ('task_struct', 'android_kabi_reserved8'),
}
SIZE_RE = re.compile(r'/\*\s*size:\s*(\d+)')
MEMBER_RE = re.compile(r'/\*\s*(\d+)(?::\d+)?\s+(\d+)\s*\*/')


def dump(pahole, vmlinux, struct):
    proc = subprocess.run([pahole, '-C', struct, vmlinux],
                          text=True, capture_output=True)
    if proc.returncode != 0:
        return None, None, proc.stderr.strip()
    size = None
    members = {}
    for line in proc.stdout.splitlines():
        m = SIZE_RE.search(line)
        if m:
            size = int(m.group(1))
        m = MEMBER_RE.search(line)
        if not m:
            continue
        decl = line.split('/*', 1)[0].strip().rstrip(';').strip()
        if not decl or decl.endswith('}'):
            continue
        # Keep only the field name: "struct sysv_sem sysvsem" -> "sysvsem",
        # "unsigned int flags:1" -> "flags", "char name[16]" -> "name".
        name = decl.split(':')[0].strip().split()[-1].strip('*')
        name = re.sub(r'\[.*\]$', '', name)
        if not name:
            continue
        members[name] = (int(m.group(1)), int(m.group(2)))
    return size, members, None


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--stock', required=True)
    ap.add_argument('--new', required=True)
    ap.add_argument('--pahole', default='pahole')
    ap.add_argument('--structs', default=','.join(DEFAULT_STRUCTS))
    ap.add_argument('--allow-new-fields', default=','.join(sorted(DEFAULT_ALLOW_NEW)))
    args = ap.parse_args()

    allow_new = {s.strip() for s in args.allow_new_fields.split(',') if s.strip()}
    bad = 0
    for struct in [s.strip() for s in args.structs.split(',') if s.strip()]:
        old_size, old_members, old_err = dump(args.pahole, args.stock, struct)
        new_size, new_members, new_err = dump(args.pahole, args.new, struct)
        if old_err or new_err:
            print(f'[warn] {struct}: {old_err or new_err}')
            continue
        problems = []
        if old_size != new_size:
            problems.append(f'size {old_size} -> {new_size}')
        for name in sorted(set(old_members) | set(new_members)):
            if name in allow_new and name not in old_members:
                continue
            if (struct, name) in EXPECTED_CHANGES:
                print(f'[allow] {struct} {name}: SYSVIPC kABI reserve')
                continue
            if name not in old_members:
                problems.append(f'new field {name} {new_members[name]}')
            elif name not in new_members:
                problems.append(f'lost field {name} {old_members[name]}')
            elif old_members[name] != new_members[name]:
                problems.append(f'{name} {old_members[name]} -> {new_members[name]}')
        if problems:
            bad += 1
            print(f'[FAIL] {struct}')
            for p in problems:
                print('       ' + p)
        else:
            print(f'[ok]   {struct} ({new_size} bytes)')
    if bad:
        print(f'::error::{bad} struct layout(s) changed unexpectedly')
        return 1
    print('kABI struct layout check passed')
    return 0


if __name__ == '__main__':
    sys.exit(main())
