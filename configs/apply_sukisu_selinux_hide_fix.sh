#!/usr/bin/env bash
set -euo pipefail
echo "::group::Apply SukiSU SELinux-hide fix (SukiSU only; independent of SUSFS)"

required_env=(KERNEL_PLATFORM_FOLDER COMMON_KERNEL_FOLDER KSU_FOLDER ANDROID_VER_LOCAL KERNEL_VER_LOCAL)
for v in "${required_env[@]}"; do
  if [ -z "${!v:-}" ]; then
    echo "::error::Required environment variable '$v' is not set"
    exit 1
  fi
done

if [[ "$ANDROID_VER_LOCAL" != "android14" || "$KERNEL_VER_LOCAL" != "6.1" ]]; then
  echo "SukiSU SELinux-hide fix: not Android 14 / 6.1; skipping"
  echo "::endgroup::"
  exit 0
fi

fix_selinux_hide_api() {
  local target="$1"
  [ -f "$target" ] || return 0
  echo "Checking SukiSU SELinux-hide API: $target"
  sed -i \
    -e 's/^static int security_context_to_sid_with_policy(/int security_context_to_sid_with_policy(/' \
    -e 's/^static int security_sid_to_context_with_policy(/int security_sid_to_context_with_policy(/' \
    -e 's/^static void security_compute_av_user_with_policy(/void security_compute_av_user_with_policy(/' \
    -e 's/^static bool ksu_selinux_hide_running/bool ksu_selinux_hide_running/' \
    "$target"
  perl -0pi -e 's/^[ \t]*static[ \t]+(const[ \t]+)?struct[ \t]+selinux_state[ \t]+fake_state([ \t]*[=;])/${1}struct selinux_state fake_state$2/mg' "$target"
  perl -0pi -e 's/^[ \t]*static[ \t]+(const[ \t]+)?struct[ \t]+selinux_state[ \t]+\*fake_state([ \t]*[=;])/${1}struct selinux_state *fake_state$2/mg' "$target"
}

ensure_lsm_hook_kbuild() {
  local kbuild="$1"
  [ -f "$kbuild" ] || return 0
  if ! grep -q 'hook/lsm_hook\.o' "$kbuild"; then
    echo 'kernelsu-objs += hook/lsm_hook.o' >> "$kbuild"
    echo "Added hook/lsm_hook.o to $kbuild"
  fi
}

patch_lsm_hook() {
  local target="$1"
  [ -f "$target" ] || return 0
  echo "Patching ACTUAL SukiSU LSM hook implementation: $target"

  python3 - "$target" <<'PY'
from pathlib import Path
import re, sys

p = Path(sys.argv[1])
s = p.read_text()

helper = r'''
static bool ksu_lsm_hook_target_matches(void *current_origin, void *target)
{
    unsigned long start;
    unsigned long size = 0;
    unsigned long current_addr;

    if (!current_origin || !target)
        return false;

    if (current_origin == target)
        return true;

    start = (unsigned long)target;
    current_addr = (unsigned long)current_origin;

    if (!kallsyms_lookup_size_offset(start, &size, NULL) || !size)
        return false;

    return current_addr >= start && current_addr < start + size;
}
'''.strip()

if 'ksu_lsm_hook_target_matches' not in s:
    m = re.search(r'\nint\s+ksu_lsm_hook\s*\(\s*struct\s+ksu_lsm_hook\s*\*hook\s*\)\s*\{', s)
    if not m:
        raise SystemExit(
            f"ERROR: cannot locate ksu_lsm_hook() in {p}. "
            "Refusing to make an unrelated LSM change."
        )
    s = s[:m.start()] + "\n" + helper + "\n" + s[m.start():]
    print("  inserted ksu_lsm_hook_target_matches()")

pat = r'if\s*\(\s*current_origin\s*==\s*target\s*\)\s*\{'
s2, n = re.subn(pat, 'if (ksu_lsm_hook_target_matches(current_origin, target)) {', s)
if n:
    s = s2
    print(f"  converted {n} exact target comparison(s) to address-range matching")
elif 'if (ksu_lsm_hook_target_matches(current_origin, target))' in s:
    print("  target comparison already uses address-range matching")
else:
    m = re.search(r'int\s+ksu_lsm_hook\s*\(', s)
    snippet = s[m.start():m.start()+5000] if m else s[:5000]
    print("ERROR: SukiSU lsm_hook API does not contain the expected 6.1 target comparison.")
    print("---- lsm_hook() diagnostic ----")
    print(snippet)
    print("---- end diagnostic ----")
    raise SystemExit(1)

p.write_text(s)
PY
}

fix_selinux_hide_api "$KSU_FOLDER/kernel/feature/selinux_hide.c"
ensure_lsm_hook_kbuild "$KSU_FOLDER/kernel/Kbuild"
patch_lsm_hook "$KSU_FOLDER/kernel/hook/lsm_hook.c"

fix_selinux_hide_api "$COMMON_KERNEL_FOLDER/drivers/kernelsu/feature/selinux_hide.c"
ensure_lsm_hook_kbuild "$COMMON_KERNEL_FOLDER/drivers/kernelsu/Kbuild"
patch_lsm_hook "$COMMON_KERNEL_FOLDER/drivers/kernelsu/hook/lsm_hook.c"

COMMON_LSM="$COMMON_KERNEL_FOLDER/drivers/kernelsu/hook/lsm_hook.c"
if ! grep -q 'ksu_lsm_hook_target_matches(current_origin, target)' "$COMMON_LSM"; then
  echo "::error::SELinux-hide LSM matcher was not installed in the common-tree source"
  exit 1
fi

echo "✅ SukiSU SELinux-hide LSM matcher installed in the ACTUAL compiled common tree"
echo "   $COMMON_LSM"
echo "   SUSFS files were not modified by this step"
echo "::endgroup::"
