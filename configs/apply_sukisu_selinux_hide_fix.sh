#!/usr/bin/env bash
set -euo pipefail

echo "::group::Apply SukiSU SELinux-hide compatibility"

required_env=(KERNEL_PLATFORM_FOLDER COMMON_KERNEL_FOLDER KSU_FOLDER ANDROID_VER_LOCAL KERNEL_VER_LOCAL)
for v in "${required_env[@]}"; do
  if [ -z "${!v:-}" ]; then
    echo "::error::Required environment variable '$v' is not set"
    exit 1
  fi
done

# This action deliberately does NOT rewrite the SELinux-hide implementation.
# SELinux-hide is independent of SUSFS.
#
# For non-6.1 kernels (including OP11/5.15), the only compatibility change
# made here is restoring backup_sepolicy when the source uses it but does not
# declare it. No fake_state, API-linkage, LSM, KCFI, or ksu_late_loaded
# transformations are performed.
#
# For 6.1 kernels, this action leaves SELinux-hide completely untouched.

restore_backup_sepolicy() {
  local target="$1"
  [ -f "$target" ] || return 0

  if ! grep -qE '\bbackup_sepolicy\b' "$target"; then
    echo "No backup_sepolicy usage in: $target"
    return 0
  fi

  if grep -Eq '^[[:space:]]*(static[[:space:]]+)?struct[[:space:]]+selinux_policy[[:space:]]*\*[[:space:]]*backup_sepolicy[[:space:]]*;' "$target"; then
    echo "backup_sepolicy declaration already present: $target"
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
    r'^[ \t]*(?:static[ \t]+)?struct[ \t]+selinux_policy[ \t]*\*[ \t]*backup_sepolicy[ \t]*;',
    s, re.M
):
    print(f"backup_sepolicy declaration already present: {p}")
    raise SystemExit(0)

lines = s.splitlines(True)
last_include = -1
for i, line in enumerate(lines):
    if re.match(r'^[ \t]*#[ \t]*include\b', line):
        last_include = i

if last_include >= 0:
    lines.insert(last_include + 1, "\n" + decl + "\n")
    s = "".join(lines)
else:
    s = decl + "\n" + s

p.write_text(s)
print(f"Restored missing backup_sepolicy declaration: {p}")
PY
}

if [ "$KERNEL_VER_LOCAL" != "6.1" ]; then
  restore_backup_sepolicy "$KSU_FOLDER/kernel/feature/selinux_hide.c"
  restore_backup_sepolicy "$COMMON_KERNEL_FOLDER/drivers/kernelsu/feature/selinux_hide.c"
else
  echo "Kernel 6.1 detected: leaving SukiSU SELinux-hide implementation untouched"
fi

echo "SUSFS files were not modified by this action"
echo "No SELinux-hide API, fake_state, LSM, KCFI, or ksu_late_loaded rewrites were performed"
echo "✅ SukiSU SELinux-hide compatibility step completed"
echo "::endgroup::"
