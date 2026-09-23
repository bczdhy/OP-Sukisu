#!/usr/bin/env bash
set -euo pipefail

echo "::group::Apply SukiSU SELinux-hide fix"

required_env=(KERNEL_PLATFORM_FOLDER COMMON_KERNEL_FOLDER KSU_FOLDER ANDROID_VER_LOCAL KERNEL_VER_LOCAL)
for v in "${required_env[@]}"; do
  if [ -z "${!v:-}" ]; then
    echo "::error::Required environment variable '$v' is not set"
    exit 1
  fi
done

# The SELinux-hide API/backup-state fix is independent of SUSFS and is
# needed on any kernel tree whose SukiSU selinux_hide.c references
# backup_sepolicy without declaring it.  Keep the LSM/KCFI compatibility
# work below restricted to Android 14/6.1.

fix_selinux_hide_api() {
  local target="$1"
  [ -f "$target" ] || return 0
  echo "Checking SukiSU SELinux-hide compatibility in: $target"

  # Do not rewrite the SELinux-hide implementation generically. Different
  # SukiSU revisions use different API/linkage layouts. The only universal
  # compatibility fix here is the missing backup_sepolicy declaration.
  if grep -q 'backup_sepolicy' "$target" && \
     ! grep -Eq '^[[:space:]]*(static[[:space:]]+)?struct[[:space:]]+selinux_policy[[:space:]]*\*[[:space:]]*backup_sepolicy[[:space:]]*;' "$target"; then
    python3 - "$target" <<'PY2'
from pathlib import Path
import re, sys
p = Path(sys.argv[1]); s = p.read_text()
if not re.search(r'^\s*(?:static\s+)?struct\s+selinux_policy\s*\*\s*backup_sepolicy\s*;', s, re.M):
    lines=s.splitlines(True); last=-1
    for i,line in enumerate(lines):
        if re.match(r'^\s*#\s*include\b', line): last=i
    decl='static struct selinux_policy *backup_sepolicy;\n\n'
    if last >= 0: lines.insert(last+1, '\n'+decl); s=''.join(lines)
    else: s=decl+s
    p.write_text(s)
    print(f"Restored missing backup_sepolicy declaration in: {p}")
else:
    print(f"backup_sepolicy declaration already present in: {p}")
PY2
  else
    echo "No missing backup_sepolicy declaration detected in: $target"
  fi
}

ensure_lsm_hook_kbuild() {
  local kbuild="$1"
  [ -f "$kbuild" ] || return 0
  grep -q 'hook/lsm_hook\.o' "$kbuild" || {
    echo 'kernelsu-objs += hook/lsm_hook.o' >> "$kbuild"
    echo "Added hook/lsm_hook.o to $kbuild"
  }
}

fix_lsm_hook_state_and_kcfi() {
  local target="$1"
  [ -f "$target" ] || return 0
  echo "Applying SukiSU KCFI/LTO SELinux-hook compatibility to: $target"

  python3 - "$target" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()

# Preserve the hook tracking state even when a SukiSU/SUSFS integration
# changes its preprocessor guards.
lock = 'static DEFINE_MUTEX(ksu_lsm_hook_lock);'
entry = 'static struct ksu_lsm_hook_entry ksu_lsm_hook_entries[16];'
count = 'static int ksu_lsm_hook_count;'
for line in (lock, entry, count):
    s = s.replace(line + '\n', '')
anchor = '};\n'
pos = s.find(anchor)
if pos >= 0:
    pos += len(anchor)
else:
    incs = list(__import__('re').finditer(r'^#include[^\n]*\n', s, __import__('re').M))
    pos = incs[-1].end() if incs else 0
state = '\n\n' + lock + '\n' + entry + '\n' + count + '\n'
s = s[:pos] + state + s[pos:]

# Android 14/6.1 GKI can register an LTO-local alias in the LSM hlist.
# Match the hook pointer inside the resolved symbol's address range rather
# than requiring exact equality with the bare kallsyms symbol address.
if 'static bool ksu_lsm_hook_target_matches' not in s:
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
'''
    anchor = 'static DEFINE_MUTEX(ksu_lsm_hook_lock);'
    if anchor not in s:
        raise SystemExit('SukiSU lsm_hook state anchor not found')
    s = s.replace(anchor, helper + '\n' + anchor, 1)

old = 'if (current_origin == target) {'
if old in s:
    n = s.count(old)
    s = s.replace(old, 'if (ksu_lsm_hook_target_matches(current_origin, target)) {')
    print(f'KCFI/LTO address-range matcher applied ({n} comparison(s))')
else:
    print('KCFI/LTO comparison already converted or newer SukiSU lsm_hook API; no rewrite needed')

p.write_text(s)
PY
}

# KernelSU's own tree. The SELinux-hide API fix is universal; the LSM/KCFI
# resolver changes remain limited to Android 14/6.1.
fix_selinux_hide_api "$KSU_FOLDER/kernel/feature/selinux_hide.c"
fix_selinux_hide_api "$COMMON_KERNEL_FOLDER/drivers/kernelsu/feature/selinux_hide.c"

if [ "$ANDROID_VER_LOCAL" = "android14" ] && [ "$KERNEL_VER_LOCAL" = "6.1" ]; then
  # These symbol/API visibility changes are specific to the OP Android 14/6.1
  # SukiSU implementation. Do not apply them to 5.15/5.4/etc. kernels.
  for _selinux_target in \
    "$KSU_FOLDER/kernel/feature/selinux_hide.c" \
    "$COMMON_KERNEL_FOLDER/drivers/kernelsu/feature/selinux_hide.c"; do
    [ -f "$_selinux_target" ] || continue
    sed -i \
      -e 's/^static int security_context_to_sid_with_policy(/int security_context_to_sid_with_policy(/' \
      -e 's/^static int security_sid_to_context_with_policy(/int security_sid_to_context_with_policy(/' \
      -e 's/^static void security_compute_av_user_with_policy(/void security_compute_av_user_with_policy(/' \
      -e 's/^static bool ksu_selinux_hide_running/bool ksu_selinux_hide_running/' \
      "$_selinux_target" || true
    perl -0pi -e 's/^[ \t]*static[ \t]+(const[ \t]+)?struct[ \t]+selinux_state[ \t]+fake_state([ \t]*[=;])/${1}struct selinux_state fake_state$2/mg' "$_selinux_target" || true
    perl -0pi -e 's/^[ \t]*static[ \t]+(const[ \t]+)?struct[ \t]+selinux_state[ \t]+\*fake_state([ \t]*[=;])/${1}struct selinux_state *fake_state$2/mg' "$_selinux_target" || true
  done

  ensure_lsm_hook_kbuild "$KSU_FOLDER/kernel/Kbuild"
  fix_lsm_hook_state_and_kcfi "$KSU_FOLDER/kernel/hook/lsm_hook.c"
  ensure_lsm_hook_kbuild "$COMMON_KERNEL_FOLDER/drivers/kernelsu/Kbuild"

  # This is SukiSU's Android 14/6.1 compatibility, not a SUSFS patch.
  sed -i \
    -e 's/![[:space:]]*ksu_late_loaded/1/g' \
    -e 's/\bksu_late_loaded\b/0/g' \
    "$KSU_FOLDER/kernel/feature/selinux_hide.c" \
    "$COMMON_KERNEL_FOLDER/drivers/kernelsu/feature/selinux_hide.c" 2>/dev/null || true

  if [ -f "$COMMON_KERNEL_FOLDER/drivers/kernelsu/hook/lsm_hook.c" ]; then
  # Keep the KernelSU LSM registered as its own LSM id on this 6.1 tree.
  sed -i \
    's/security_add_hooks(ksu_hooks, ARRAY_SIZE(ksu_hooks), "ksu");/security_add_hooks(ksu_hooks, ARRAY_SIZE(ksu_hooks), \&ksu_lsmid);/' \
    "$COMMON_KERNEL_FOLDER/drivers/kernelsu/hook/lsm_hook.c" || true
  grep -q 'static struct lsm_id ksu_lsmid' "$COMMON_KERNEL_FOLDER/drivers/kernelsu/hook/lsm_hook.c" || \
    sed -i '/security_add_hooks.*ksu_lsmid/i\    static struct lsm_id ksu_lsmid = { .name = "ksu", .id = LSM_ID_UNDEF };' \
    "$COMMON_KERNEL_FOLDER/drivers/kernelsu/hook/lsm_hook.c" || true
    fix_lsm_hook_state_and_kcfi "$COMMON_KERNEL_FOLDER/drivers/kernelsu/hook/lsm_hook.c"
  fi
fi

# Do not patch SUSFS files here. This step only modifies SukiSU's SELinux-hide
# implementation and its LSM hook resolver.
echo "✅ SukiSU SELinux-hide compatibility applied; SUSFS files were not modified by this step"
echo "::endgroup::"
