#!/usr/bin/env bash
set -euo pipefail

echo "::group::Apply SukiSU SELinux-hide compatibility"

# Minimal fix only: the current selinux_hide.c uses backup_sepolicy but
# does not declare it. Do not modify SUSFS, fake_state, LSM, KCFI, or
# any other SELinux-hide implementation.

fix_backup_sepolicy() {
    local target="$1"
    [ -f "$target" ] || return 0

    if ! grep -qE '\\bbackup_sepolicy\\b' "$target"; then
        return 0
    fi

    if grep -Eq '^[[:space:]]*static[[:space:]]+struct[[:space:]]+selinux_policy[[:space:]]*\\*[[:space:]]*backup_sepolicy[[:space:]]*;' "$target"; then
        echo "backup_sepolicy already declared: $target"
        return 0
    fi

    python3 - "$target" <<'PY'
from pathlib import Path
import re
import sys

p = Path(sys.argv[1])
s = p.read_text()
decl = "static struct selinux_policy *backup_sepolicy;\n"

if re.search(
    r'^[ \t]*static[ \t]+struct[ \t]+selinux_policy[ \t]*\*[ \t]*backup_sepolicy[ \t]*;',
    s, re.M
):
    print(f"backup_sepolicy already declared: {p}")
    raise SystemExit(0)

lines = s.splitlines(True)
last_include = -1
for i, line in enumerate(lines):
    if re.match(r'^[ \t]*#[ \t]*include\b', line):
        last_include = i

if last_include >= 0:
    lines.insert(last_include + 1, "\n" + decl + "\n")
    p.write_text("".join(lines))
else:
    p.write_text(decl + "\n" + s)

print(f"Added missing backup_sepolicy declaration: {p}")
PY
}

fix_backup_sepolicy "$KSU_FOLDER/kernel/feature/selinux_hide.c"
fix_backup_sepolicy "$COMMON_KERNEL_FOLDER/drivers/kernelsu/feature/selinux_hide.c"

echo "Only backup_sepolicy declaration was changed"
echo "SUSFS was not modified"
echo "SELinux-hide implementation was not rewritten"
echo "::endgroup::"
