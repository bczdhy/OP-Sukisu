#!/usr/bin/env bash
set -euo pipefail

echo "::group::Fix SukiSU SELinux-hide backup_sepolicy"

fix_file() {
    local f="$1"
    [ -f "$f" ] || return 0

    if ! grep -q 'backup_sepolicy' "$f"; then
        echo "No backup_sepolicy usage: $f"
        return 0
    fi

    if grep -qE '^[[:space:]]*static[[:space:]]+struct[[:space:]]+selinux_policy[[:space:]]*\\*[[:space:]]*backup_sepolicy[[:space:]]*;' "$f"; then
        echo "Already declared: $f"
        return 0
    fi

    python3 - "$f" <<'PY'
from pathlib import Path
import re
import sys

p = Path(sys.argv[1])
s = p.read_text()
decl = "static struct selinux_policy *backup_sepolicy;"

if re.search(
    r'^[ \t]*static[ \t]+struct[ \t]+selinux_policy[ \t]*\*[ \t]*backup_sepolicy[ \t]*;',
    s, re.MULTILINE
):
    raise SystemExit(0)

lines = s.splitlines(True)
last_include = -1
for i, line in enumerate(lines):
    if re.match(r'^[ \t]*#[ \t]*include[ \t]+', line):
        last_include = i

if last_include >= 0:
    lines.insert(last_include + 1, "\n" + decl + "\n\n")
else:
    lines.insert(0, decl + "\n\n")

p.write_text("".join(lines))
print(f"Added: {decl}")
print(f"File: {p}")
PY
}

# This is the exact path shown by the OP13R compiler error.
fix_file "${COMMON_KERNEL_FOLDER:?}/drivers/kernelsu/feature/selinux_hide.c"

# Support alternate KernelSU layouts too.
if [ -n "${KSU_FOLDER:-}" ]; then
    fix_file "$KSU_FOLDER/kernel/feature/selinux_hide.c"
    fix_file "$KSU_FOLDER/drivers/kernelsu/feature/selinux_hide.c"
fi

echo "Verification:"
grep -n 'backup_sepolicy'     "${COMMON_KERNEL_FOLDER}/drivers/kernelsu/feature/selinux_hide.c" || true

echo "Only backup_sepolicy declaration was added"
echo "SUSFS was not modified"
echo "SELinux-hide implementation was not rewritten"
echo "::endgroup::"
