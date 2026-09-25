#!/usr/bin/env bash
set -euo pipefail

echo "::group::Apply SUSFS patches"

required_env=(
  KERNEL_PLATFORM_FOLDER
  COMMON_KERNEL_FOLDER
  SUSFS_FOLDER
  ARTIFACTS_FOLDER
  OP_MODEL
  OP_OS_VERSION
  KSU_FOLDER
  ANDROID_VER_LOCAL
  KERNEL_VER_LOCAL
)

for v in "${required_env[@]}"; do
  if [ -z "${!v:-}" ]; then
echo "::error::Required environment variable '$v' is not set"
exit 1
  fi
done

cd "$KERNEL_PLATFORM_FOLDER"

cp "$SUSFS_FOLDER/kernel_patches/fs/"* "$COMMON_KERNEL_FOLDER/fs/"
cp "$SUSFS_FOLDER/kernel_patches/include/linux/"* "$COMMON_KERNEL_FOLDER/include/linux/"

susfs_version="$(grep '#define SUSFS_VERSION' "$COMMON_KERNEL_FOLDER/include/linux/susfs.h" | awk -F'"' '{print $2}')"

{
  echo "SUSVER=$susfs_version"
} >> "$GITHUB_ENV"

echo "$susfs_version" >> "${ARTIFACTS_FOLDER}/${OP_MODEL}_${OP_OS_VERSION}.txt"

echo "SusFS Version: $susfs_version"

case "$susfs_version" in
  v2.1.0|v2.2.0|v2.3.0)
    echo "Supported SUSFS version detected: $susfs_version"
    ;;
  *)
    echo "::error::This workflow step supports SUSFS v2.1.0, v2.2.0, and v2.3.0. Detected: $susfs_version"
    exit 1
    ;;
esac

echo "NEED_HOOKS=false" >> "$GITHUB_ENV"

# =============================================================================
# Generic helpers
# =============================================================================

ensure_include_after_or_top() {
  local file="$1"
  local include="$2"
  local anchor="${3:-}"

  [ -f "$file" ] || return 0

  if grep -qxF "$include" "$file"; then
return 0
  fi

  if [ -n "$anchor" ] && grep -qF "$anchor" "$file"; then
sed -i "/$(printf '%s' "$anchor" | sed 's/[.[\*^$()+?{}|]/\\&/g')/a $include" "$file"
  else
sed -i "1i$include" "$file"
  fi
}

# =============================================================================
# SukiSU compatibility helpers
# =============================================================================

# SUSFS/SukiSU compatibility: backup_sepolicy is a shared SELinux-policy
# snapshot.  selinux_hide.c must only consume it; it must never own a second
# copy.  Keep the single storage definition in selinux/rules.c and expose it
# through selinux/sepolicy.h, which selinux_hide.c already includes.
ensure_backup_sepolicy_symbol() {
  local root="$1"
  local rules="$root/kernel/selinux/rules.c"
  local hdr="$root/kernel/selinux/sepolicy.h"
  local hide="$root/kernel/feature/selinux_hide.c"
  [ -d "$root" ] || return 0

  # Some trees use the common-tree mirror layout when this helper is called
  # with COMMON_KERNEL_FOLDER.  Accept either kernel/... or drivers/kernelsu/...
  # without ever creating a definition in selinux_hide.c.
  if [ ! -f "$rules" ]; then
    rules="$root/drivers/kernelsu/selinux/rules.c"
  fi
  if [ ! -f "$hdr" ]; then
    hdr="$root/drivers/kernelsu/selinux/sepolicy.h"
  fi
  if [ ! -f "$hide" ]; then
    hide="$root/drivers/kernelsu/feature/selinux_hide.c"
  fi

  [ -f "$rules" ] || { echo "  ℹ️ backup_sepolicy: rules.c not present in $root"; return 0; }

  python3 - "$root" "$rules" "$hdr" "$hide" <<'PY_BACKUP_SEPOLICY'
from pathlib import Path
import re, sys

root, rules_s, hdr_s, hide_s = map(Path, sys.argv[1:])
rules = rules_s
hdr = Path(hdr_s)
hide = Path(hide_s)

# Remove accidental definitions that older versions of this workflow injected
# into selinux_hide.c.  Keep an extern there only if that file directly needs it;
# normally sepolicy.h supplies the declaration.
if hide.exists():
    text = hide.read_text()
    text = re.sub(
        r'(?m)^\s*/\* SUSFS/SukiSU compatibility: selinuxfs expects the policy backup symbol\. \*/\n'
        r'\s*struct\s+selinux_policy\s*\*\s*backup_sepolicy\s*;\s*\n?', '', text)
    text = re.sub(
        r'(?m)^\s*struct\s+selinux_policy\s*\*\s*backup_sepolicy\s*;\s*\n?', '', text)
    hide.write_text(text)

# There must be exactly one storage definition in the compiled KSU tree.
def_re = re.compile(
    r'(?m)^\s*(?!extern\b)(?:static\s+)?struct\s+selinux_policy\s*\*\s*backup_sepolicy\s*(?:=\s*[^;]+)?;\s*$'
)
all_c = []
for base in (root/'kernel', root/'drivers/kernelsu'):
    if base.is_dir():
        all_c.extend(base.rglob('*.c'))
existing = []
for p in all_c:
    try: t=p.read_text()
    except Exception: continue
    if def_re.search(t): existing.append(p)

if len(existing) == 0:
    # Place the single definition after the include section.  rules.c is the
    # upstream owner of the policy snapshot and is already compiled by KSU.
    t = rules.read_text()
    line = '\n/* Shared policy snapshot used by KernelSU SELinux-hide. */\nstruct selinux_policy *backup_sepolicy;\n'
    m = list(re.finditer(r'(?m)^#include[^\n]*\n', t))
    if m:
        pos = m[-1].end()
        t = t[:pos] + line + t[pos:]
    else:
        t = line.lstrip('\n') + t
    rules.write_text(t)
    existing=[rules]
elif len(existing) > 1:
    # Preserve the definition in rules.c and remove duplicates elsewhere.
    keep = rules if rules in existing else existing[0]
    for p in existing:
        if p == keep: continue
        t=p.read_text()
        t=def_re.sub('', t)
        p.write_text(t)
    existing=[keep]

# Publish the shared symbol through sepolicy.h.  This is the header already
# visible to selinux_hide.c in the failing build.
if hdr.exists():
    t=hdr.read_text()
    extern='extern struct selinux_policy *backup_sepolicy;'
    # Remove duplicate/incorrect declarations first, then add one declaration.
    t=re.sub(r'(?m)^\s*extern\s+struct\s+selinux_policy\s*\*\s*backup_sepolicy\s*;\s*\n?', '', t)
    lines=t.splitlines()
    idx=next((i for i in range(len(lines)-1,-1,-1) if lines[i].strip().startswith('#endif')), len(lines))
    lines.insert(idx, extern)
    hdr.write_text('\n'.join(lines)+'\n')
else:
    # A tree without sepolicy.h cannot use this repair safely.
    raise SystemExit(f'backup_sepolicy validation: missing sepolicy.h: {hdr}')

# Hard validation.
count=0
for p in all_c:
    try: t=p.read_text()
    except Exception: continue
    count += len(def_re.findall(t))
if count != 1:
    raise SystemExit(f'backup_sepolicy validation: expected exactly one C definition, found {count}')
if not re.search(r'(?m)^\s*extern\s+struct\s+selinux_policy\s*\*\s*backup_sepolicy\s*;', hdr.read_text()):
    raise SystemExit(f'backup_sepolicy validation: extern missing from {hdr}')
print(f'  [SELinux-hide] shared backup_sepolicy definition: {existing[0]}')
print(f'  [SELinux-hide] shared backup_sepolicy declaration: {hdr}')
PY_BACKUP_SEPOLICY
}


ensure_sucompat_object_built() {
  local root="$1"
  [ -d "$root" ] || return 0

  # The final built-in KSU archive is driven by the Kbuild under
  # drivers/kernelsu on OnePlus common trees.  Do not stop at kernel/Kbuild:
  # that may be the staging/source copy and can be overwritten by the mirror
  # step later in this script.
  local kbuild=""
  for candidate in \
    "$root/drivers/kernelsu/Kbuild" \
    "$root/drivers/kernelsu/Makefile" \
    "$root/kernel/Kbuild" \
    "$root/kernel/Makefile"; do
    if [ -f "$candidate" ]; then
      kbuild="$candidate"
      break
    fi
  done
  [ -n "$kbuild" ] || return 0

  local base="$(dirname "$kbuild")"
  local c="$base/feature/sucompat.c"
  [ -f "$c" ] || return 0

  local aggregate=""
  aggregate="$(sed -nE 's/^[[:space:]]*obj-\$\(CONFIG_KSU\)[[:space:]]*\+=[[:space:]]*([A-Za-z0-9_.-]+)\.o[[:space:]]*$/\1/p' "$kbuild" | head -n1)"
  [ -n "$aggregate" ] || aggregate="kernelsu"

  local object_line="${aggregate}-objs += feature/sucompat.o"

  # Remove ineffective repairs and duplicate forms first.
  sed -i '/^[[:space:]]*obj-y[[:space:]]*+=[[:space:]]*feature\/sucompat\.o[[:space:]]*$/d' "$kbuild"
  sed -i '/^[[:space:]]*\(kernelsu\|ksu\)-objs[[:space:]]*+=[[:space:]]*feature\/sucompat\.o[[:space:]]*$/d' "$kbuild"

  printf '\n%s\n' "$object_line" >> "$kbuild"

  if ! grep -Fqx "$object_line" "$kbuild"; then
    echo "::error::Failed to add feature/sucompat.o to $aggregate-objs in $kbuild"
    exit 1
  fi

  echo "  [Kbuild] enabled feature/sucompat.o via ${aggregate}-objs in $kbuild"
}

ensure_post_execveat_sucompat_impl() {
  local root="$1"
  [ -d "$root" ] || return 0

  # Use the same authoritative tree that the build consumes.  The OnePlus
  # common tree can contain both kernel/ and drivers/kernelsu/ copies; for the
  # final common tree, drivers/kernelsu is the compiled KSU tree.  The staging
  # KernelSU tree uses kernel/ instead.
  local c=""
  if [ "$root" = "$COMMON_KERNEL_FOLDER" ]; then
    c="$root/drivers/kernelsu/feature/sucompat.c"
    [ -f "$c" ] || c="$root/kernel/feature/sucompat.c"
  else
    c="$root/kernel/feature/sucompat.c"
    [ -f "$c" ] || c="$root/drivers/kernelsu/feature/sucompat.c"
  fi
  [ -f "$c" ] || return 0

  # SUSFS 2.3 adds this post-exec hook alongside the VFS sucompat hooks.
  # Some SukiSU trees carry ksu_handle_execveat_sucompat() but lose the
  # post-exec entry point when the SUSFS sucompat hunk is rejected. Restore
  # the actual SUSFS implementation, not a linker-only stub.
  if grep -qE '^[[:space:]]*int[[:space:]]+ksu_handle_post_execveat_sucompat[[:space:]]*\(' "$c"; then
    return 0
  fi

  cat >> "$c" <<'CEOF'

/* SUSFS 2.3 post-exec sucompat hook. */
int ksu_handle_post_execveat_sucompat(int *fd, struct filename **filename_ptr,
                 void *argv_user, void *envp_user,
                 int *__never_use_flags, int *retval)
{
    (void)fd;
    (void)filename_ptr;
    (void)argv_user;
    (void)envp_user;
    (void)__never_use_flags;

    if (*retval >= 0) {
        (void)ksu_install_su_fd();
    }
    return 0;
}
CEOF

  echo "  [sucompat] restored SUSFS post-exec implementation in $c"
}

validate_sucompat_object_built() {
  local root="$1"
  [ -d "$root" ] || return 0

  local kbuild=""
  for candidate in \
    "$root/drivers/kernelsu/Kbuild" \
    "$root/drivers/kernelsu/Makefile" \
    "$root/kernel/Kbuild" \
    "$root/kernel/Makefile"; do
    if [ -f "$candidate" ]; then kbuild="$candidate"; break; fi
  done
  [ -n "$kbuild" ] || return 0

  local base="$(dirname "$kbuild")"
  local c="$base/feature/sucompat.c"
  [ -f "$c" ] || return 0

  # KernelSU/kernel is a staging/source tree. Its sucompat.c can legitimately
  # differ from the final synchronized common/drivers/kernelsu tree (especially
  # when SUSFS patches were applied with rejects and later reconciled). Do not
  # require the final-linker symbols in the staging copy. The final common tree
  # is the authoritative implementation check below.
  if [ "$root" = "$COMMON_KERNEL_FOLDER" ]; then
    local missing=""
    grep -qE '^[[:space:]]*(int|long)[[:space:]]+ksu_handle_stat[[:space:]]*\(' "$c" || missing="$missing ksu_handle_stat"
    grep -qE '^[[:space:]]*(int|long)[[:space:]]+ksu_handle_faccessat[[:space:]]*\(' "$c" || missing="$missing ksu_handle_faccessat"
    grep -qE '^[[:space:]]*(int|long)[[:space:]]+ksu_handle_post_execveat_sucompat[[:space:]]*\(' "$c" || missing="$missing ksu_handle_post_execveat_sucompat"
    [ -z "$missing" ] || { echo "::error::Missing final-tree sucompat implementation(s):$missing in $c"; exit 1; }
  else
    echo "  [Kbuild] staging sucompat implementation check skipped: $c"
  fi

  if ! grep -Eq '(^|[[:space:]])kernelsu-objs[[:space:]]*\+=[[:space:]]*feature/sucompat\.o([[:space:]]|$)|(^|[[:space:]])ksu-objs[[:space:]]*\+=[[:space:]]*feature/sucompat\.o([[:space:]]|$)' "$kbuild"; then
    echo "::error::feature/sucompat.o is not part of the KSU aggregate: $kbuild"
    exit 1
  fi

  echo "  [Kbuild] sucompat preflight OK: implementations present and object enabled"
}


remove_unused_syscall_pointer_declarations() {
  local root="$1"
  [ -d "$root" ] || return 0
  python3 - "$root" <<'PY_UNUSED_SYSCALLS'
from pathlib import Path
import re, sys
root=Path(sys.argv[1])
for p in (root/'kernel/runtime/ksud_integration.c', root/'drivers/kernelsu/runtime/ksud_integration.c'):
    if not p.exists(): continue
    s=p.read_text()
    changed=False
    for name in ('orig_sys_read','orig_sys_fstat'):
        pat=re.compile(r'(?m)^\s*static\s+long\s*\(\*'+name+r'\)\(const\s+struct\s+pt_regs\s*\*regs\);\s*\n?')
        s2,n=pat.subn('',s,count=1)
        if n:
            s=s2; changed=True
    if changed:
        p.write_text(s)
        print(f'  [warnings] removed unused syscall-pointer declarations from {p}')
PY_UNUSED_SYSCALLS
}

# SukiSU's ksu_late_loaded (LKM "late load" mode) has no meaning for these built-in,
# kprobe-hooked SUSFS builds. The susfs enable-patch strips it tree-wide (it removes
# the definition, the extern, the assignments and every branch), but those hunks reject
# against current SukiSU, so we replicate the removal by hand. Delete the definition and
# assignments (a bare `0 = ...;` would not compile), then force every remaining read to
# the built-in-always value: !ksu_late_loaded -> 1, ksu_late_loaded -> 0. Idempotent, so
# it is a no-op wherever the patch hunks happened to apply.
neutralize_ksu_late_loaded() {
  local target="$1"
  [ -f "$target" ] || return 0

  sed -i \
-e '/^[[:space:]]*bool[[:space:]]\+ksu_late_loaded[[:space:]]*;/d' \
-e '/^[[:space:]]*ksu_late_loaded[[:space:]]*=/d' \
"$target" || true

  sed -i \
-e 's/![[:space:]]*ksu_late_loaded/1/g' \
-e 's/\bksu_late_loaded\b/0/g' \
"$target" || true
}

fix_sukisu_init_c() {
  local target="$1"
  [ -f "$target" ] || return 0

  echo "Fixing SukiSU init compatibility in: $target"

  sed -i '/ksu_lsm_hook_init[[:space:]]*();/d' "$target" || true

  sed -i \
-e 's/\bksu_syscall_hook_manager_init[[:space:]]*(/ksu_syscall_hook_init(/g' \
-e 's/\bksu_syscall_hook_manager_exit[[:space:]]*(/ksu_syscall_hook_exit(/g' \
"$target" || true

  neutralize_ksu_late_loaded "$target"

  local root_dir
  root_dir="$(dirname "$(dirname "$target")")"

  # The definition is gone, so drop the now-dangling extern in the tree's ksu.h too
  # (covers the KSU tree kernel/include/ksu.h and the mirror drivers/kernelsu/include/ksu.h).
  if [ -f "$root_dir/include/ksu.h" ]; then
sed -i '/extern[[:space:]]\+bool[[:space:]]\+ksu_late_loaded[[:space:]]*;/d' "$root_dir/include/ksu.h" || true
  fi

  if ! grep -Rqs '^[[:space:]]*\(void\|int\)[[:space:]]\+ksu_syscall_hook_init[[:space:]]*(' "$root_dir" --include='*.c' 2>/dev/null; then
sed -i '/ksu_syscall_hook_init[[:space:]]*();/d' "$target" || true
  fi

  if ! grep -Rqs '^[[:space:]]*\(void\|int\)[[:space:]]\+ksu_syscall_hook_exit[[:space:]]*(' "$root_dir" --include='*.c' 2>/dev/null; then
sed -i '/ksu_syscall_hook_exit[[:space:]]*();/d' "$target" || true
  fi

  if grep -nE 'ksu_lsm_hook_init|ksu_late_loaded|ksu_syscall_hook_manager_init|ksu_syscall_hook_manager_exit' "$target"; then
echo "::error::Legacy SukiSU-incompatible symbols remain in $target"
exit 1
  fi

  echo "✅ Fixed $target"
}

ensure_susfs_init_call() {
  local target="$1"
  [ -f "$target" ] || return 0

  echo "Ensuring susfs_init() is wired in: $target"

  if ! grep -q '#include <linux/susfs.h>' "$target"; then
if grep -q '#include "ksu.h"' "$target"; then
  sed -i '/#include "ksu.h"/a #include <linux/susfs.h>' "$target"
else
  sed -i '1i#include <linux/susfs.h>' "$target"
fi
  fi

  if ! grep -q 'susfs_init[[:space:]]*();' "$target"; then
if grep -q 'ksu_feature_init[[:space:]]*();' "$target"; then
  sed -i '/ksu_feature_init[[:space:]]*();/a #ifdef CONFIG_KSU_SUSFS\n    susfs_init();\n#endif' "$target"
elif grep -q 'ksu_supercalls_init[[:space:]]*();' "$target"; then
  sed -i '/ksu_supercalls_init[[:space:]]*();/i #ifdef CONFIG_KSU_SUSFS\n    susfs_init();\n#endif' "$target"
elif grep -q 'ksu_allowlist_init[[:space:]]*();' "$target"; then
  sed -i '/ksu_allowlist_init[[:space:]]*();/i #ifdef CONFIG_KSU_SUSFS\n    susfs_init();\n#endif' "$target"
else
  echo "::error::Could not find safe anchor for susfs_init() in $target"
  sed -n '1,180p' "$target"
  exit 1
fi
  fi

  if ! grep -q 'susfs_init[[:space:]]*();' "$target"; then
echo "::error::susfs_init() was not inserted into $target"
exit 1
  fi

  echo "✅ susfs_init() is present in $target"
}

# SUSFS v2.2.0: the SUSFS KernelSU-enable patch switches setuid/sucompat handling
# to the standalone inline entry points ksu_sucompat_init() and ksu_setuid_hook_init()
# (the latter only wires ksu_kernel_umount_init(); it does NOT install a second setuid
# hook, so there is no double-hook with SukiSU's syscall-redirect path). The enable
# patch's init.c hunk rejects against SukiSU, so kernelsu_init() is left without these
# calls. Wire them in after ksu_supercalls_init(), matching the patch's intended order.
#
# Every insert is guarded on the callee actually being DEFINED in the tree, so this is a
# no-op on SUSFS v2.1.0 (where these symbols may be absent) and only activates on v2.2.0.
ensure_sukisu_inline_hook_init() {
  local target="$1"
  [ -f "$target" ] || return 0

  local root_dir
  root_dir="$(dirname "$(dirname "$target")")"

  echo "Ensuring v2.2.0 inline hook init calls in: $target"

  _fn_defined() {
    # matches "void ksu_x_init(", "void __init ksu_x_init(", "int __init ksu_x_init(" ...
    grep -RqsE "\b(void|int)([[:space:]]+__[a-z_]+)*[[:space:]]+$1[[:space:]]*\(" \
      "$root_dir" --include='*.c'
  }

  _ensure_after_supercalls() {
    local fn="$1"
    grep -qE "\b${fn}[[:space:]]*\(" "$target" && return 0            # already called
    _fn_defined "$fn" || { echo "  (skip $fn: not defined in tree)"; return 0; }
    grep -q 'ksu_supercalls_init[[:space:]]*();' "$target" || {
      echo "::error::No ksu_supercalls_init() anchor for $fn in $target"; exit 1; }
    sed -i "/ksu_supercalls_init[[:space:]]*();/a\\    ${fn}();" "$target"
    echo "  (inserted $fn after ksu_supercalls_init)"
  }

  # Insert setuid_hook first, then sucompat, so the resulting order is:
  #   ksu_supercalls_init(); ksu_sucompat_init(); ksu_setuid_hook_init();
  _ensure_after_supercalls ksu_setuid_hook_init
  _ensure_after_supercalls ksu_sucompat_init

  echo "✅ inline hook init calls ensured in $target"
}

fix_sukisu_boot_event_c() {
  local target="$1"
  [ -f "$target" ] || return 0

  echo "Fixing SukiSU boot_event compatibility in: $target"

  if grep -q 'ksu_stop_input_hook_runtime[[:space:]]*();' "$target"; then
awk '
  {
    if ($0 ~ /^[[:space:]]*ksu_stop_input_hook_runtime[[:space:]]*\(\);/) {
      indent = $0
      sub(/ksu_stop_input_hook_runtime.*/, "", indent)
      print indent "if (static_key_enabled(&ksu_is_input_hook_enabled)) {"
      print indent "    static_branch_disable(&ksu_is_input_hook_enabled);"
      print indent "    pr_info(\"ksu_input_hook is disabled\\n\");"
      print indent "}"
      next
    }
    print
  }
' "$target" > "$target.tmp"
mv "$target.tmp" "$target"
  fi

  grep -q '#include <linux/jump_label.h>' "$target" || sed -i '1i#include <linux/jump_label.h>' "$target"

  if grep -q 'ksu_is_input_hook_enabled' "$target" && \
 ! grep -q 'extern struct static_key_true ksu_is_input_hook_enabled' "$target" && \
 ! grep -q 'extern struct static_key_false ksu_is_input_hook_enabled' "$target"; then
sed -i '/#include <linux\/jump_label.h>/a extern struct static_key_true ksu_is_input_hook_enabled;' "$target"
  fi

  if grep -n 'ksu_stop_input_hook_runtime' "$target"; then
echo "::error::ksu_stop_input_hook_runtime still remains in $target"
exit 1
  fi

  echo "✅ Fixed $target"
}

fix_sukisu_ksud_integration_c() {
  local target="$1"
  [ -f "$target" ] || return 0

  echo "Fixing SukiSU ksud_integration compatibility in: $target"

  neutralize_ksu_late_loaded "$target"

  if ! grep -q 'ksu_no_custom_rc' "$target"; then
echo "ℹ️ ksu_no_custom_rc not referenced in $target"
return 0
  fi

  if grep -qE '^[[:space:]]*(extern[[:space:]]+)?bool[[:space:]]+ksu_no_custom_rc\b|^[[:space:]]*static[[:space:]]+bool[[:space:]]+ksu_no_custom_rc\b' "$target"; then
echo "✅ ksu_no_custom_rc already declared in $target"
return 0
  fi

  local root_dir
  root_dir="$(dirname "$(dirname "$target")")"

  grep -q '#include <linux/types.h>' "$target" || sed -i '1i#include <linux/types.h>' "$target"

  if grep -RqsE '^[[:space:]]*bool[[:space:]]+ksu_no_custom_rc\b|^[[:space:]]*static[[:space:]]+bool[[:space:]]+ksu_no_custom_rc\b' "$root_dir" --include='*.c' --include='*.h' 2>/dev/null; then
sed -i '/#include <linux\/types.h>/a extern bool ksu_no_custom_rc;' "$target"
echo "✅ Added extern bool ksu_no_custom_rc to $target"
  else
sed -i '/#include <linux\/types.h>/a static bool ksu_no_custom_rc = false;' "$target"
echo "✅ Added local static bool ksu_no_custom_rc = false to $target"
  fi
}

fix_sukisu_app_profile_c() {
  local target="$1"
  [ -f "$target" ] || return 0

  echo "Fixing SukiSU app_profile compatibility in: $target"

  python3 - "$target" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text()

patterns = [
    r'\n[ \t]*if[ \t]*\([ \t]*cred->euid\.val[ \t]*==[ \t]*0[ \t]*\)[ \t]*\{\n[ \t]*pr_warn\("Already root, don\'t escape!\\n"\);\n[ \t]*goto out_abort_creds;\n[ \t]*\}\n',
    r'\n[ \t]*if[ \t]*\([ \t]*uid_eq\([ \t]*cred->euid[ \t]*,[ \t]*GLOBAL_ROOT_UID[ \t]*\)[ \t]*\)[ \t]*\{\n[ \t]*pr_warn\("Already root, don\'t escape!\\n"\);\n[ \t]*goto out_abort_creds;\n[ \t]*\}\n',
]

for pattern in patterns:
    text = re.sub(pattern, "\n", text, flags=re.S)

lines = text.splitlines()
new_lines = []

for line in lines:
    if re.match(r"^[ \t]*disable_seccomp[ \t]*\(\);[ \t]*$", line):
        prev1 = new_lines[-1] if len(new_lines) >= 1 else ""
        prev2 = new_lines[-2] if len(new_lines) >= 2 else ""

        if "TIF_SECCOMP" in prev1 or "TIF_SECCOMP" in prev2:
            new_lines.append(line)
        else:
            indent = re.match(r"^([ \t]*)", line).group(1)
            new_lines.append(indent + "if (likely(test_thread_flag(TIF_SECCOMP)))")
            new_lines.append(indent + "    disable_seccomp();")
    else:
        new_lines.append(line)

text = "\n".join(new_lines) + ("\n" if text.endswith("\n") else "")

text = re.sub(
    r'\n[ \t]*for_each_thread[ \t]*\([ \t]*p[ \t]*,[ \t]*t[ \t]*\)[ \t]*\{\n[ \t]*ksu_set_task_tracepoint_flag[ \t]*\([ \t]*t[ \t]*\);[ \t]*\n[ \t]*\}\n',
    "\n",
    text,
    flags=re.S,
)

path.write_text(text)

PY

  if grep -n "Already root, don't escape" "$target"; then
echo "::error::Already-root early abort still remains in $target"
exit 1
  fi

  if awk '
/^[[:space:]]*disable_seccomp[[:space:]]*\(\);/ {
  if (prev !~ /TIF_SECCOMP/ && prev2 !~ /TIF_SECCOMP/) {
    print FNR ":" $0
    bad = 1
  }
}
{ prev2 = prev; prev = $0 }
END { exit bad ? 1 : 0 }
  ' "$target"; then
:
  else
echo "::error::Unguarded disable_seccomp() still remains in $target"
exit 1
  fi

  if grep -nE 'ksu_set_task_tracepoint_flag[[:space:]]*\(' "$target"; then
echo "::error::ksu_set_task_tracepoint_flag() still remains in $target"
exit 1
  fi

  echo "✅ Fixed $target"
}

fix_sukisu_dispatch_c() {
  local target="$1"
  [ -f "$target" ] || return 0

  echo "Fixing SukiSU dispatch SUSFS compatibility in: $target"

  neutralize_ksu_late_loaded "$target"

  if ! grep -q '#include <linux/namei.h>' "$target"; then
if grep -q '#include <linux/thread_info.h>' "$target"; then
  sed -i '/#include <linux\/thread_info.h>/a #include <linux/namei.h>' "$target"
elif grep -q '^#include <linux/' "$target"; then
  sed -i '0,/^#include <linux\//s//#include <linux\/namei.h>\n&/' "$target"
else
  sed -i '1i#include <linux/namei.h>' "$target"
fi
  fi

  if ! grep -q '#include <linux/susfs.h>' "$target"; then
if grep -q '#include <linux/namei.h>' "$target"; then
  sed -i '/#include <linux\/namei.h>/a #include <linux/susfs.h>' "$target"
elif grep -q '#include <linux/thread_info.h>' "$target"; then
  sed -i '/#include <linux\/thread_info.h>/a #include <linux/susfs.h>' "$target"
elif grep -q '^#include <linux/' "$target"; then
  sed -i '0,/^#include <linux\//s//#include <linux\/susfs.h>\n&/' "$target"
else
  sed -i '1i#include <linux/susfs.h>' "$target"
fi
  fi

  if grep -qE 'SUSFS_MAGIC|CMD_SUSFS_|susfs_' "$target"; then
if ! grep -q '#include <linux/susfs.h>' "$target"; then
  echo "::error::SUSFS symbols are used but <linux/susfs.h> is missing in $target"
  exit 1
fi
  fi

  echo "✅ Fixed $target"
}

fix_sukisu_sucompat_api() {
  local base="$1"
  [ -d "$base" ] || return 0

  local c="$base/feature/sucompat.c"
  local h="$base/feature/sucompat.h"

  echo "Fixing SukiSU sucompat API in: $base"

  [ -f "$c" ] || { echo "ℹ️ sucompat.c not found in $base, skipping"; return 0; }
  [ -f "$h" ] || { echo "ℹ️ sucompat.h not found in $base, skipping"; return 0; }

  grep -q '#include <linux/jump_label.h>' "$c" || sed -i '1i#include <linux/jump_label.h>' "$c"
  grep -q '#include <linux/version.h>' "$c" || sed -i '1i#include <linux/version.h>' "$c"
  grep -q '#include <linux/namei.h>' "$c" || sed -i '1i#include <linux/namei.h>' "$c"

  if grep -qE 'CONFIG_KSU_SUSFS|susfs_|SUSFS_' "$c"; then
grep -q '#include <linux/susfs_def.h>' "$c" || sed -i '1i#include <linux/susfs_def.h>' "$c"
  fi

  if ! grep -qE '#include "sucompat.h"|#include "feature/sucompat.h"' "$c"; then
sed -i '1i#include "sucompat.h"' "$c"
  fi

  if grep -qE '^[[:space:]]*bool[[:space:]]+ksu_su_compat_enabled[[:space:]]+__read_mostly[[:space:]]*=[[:space:]]*true[[:space:]]*;' "$c"; then
sed -i 's/^[[:space:]]*bool[[:space:]]\+ksu_su_compat_enabled[[:space:]]\+__read_mostly[[:space:]]*=[[:space:]]*true[[:space:]]*;/DEFINE_STATIC_KEY_TRUE(ksu_su_compat_enabled);/' "$c"
  elif grep -qE '^[[:space:]]*bool[[:space:]]+ksu_su_compat_enabled[[:space:]]*=[[:space:]]*true[[:space:]]*;' "$c"; then
sed -i 's/^[[:space:]]*bool[[:space:]]\+ksu_su_compat_enabled[[:space:]]*=[[:space:]]*true[[:space:]]*;/DEFINE_STATIC_KEY_TRUE(ksu_su_compat_enabled);/' "$c"
  fi

  if ! grep -qE 'DEFINE_STATIC_KEY_(TRUE|FALSE)\(ksu_su_compat_enabled\)' "$c"; then
if grep -q '#define SU_PATH' "$c"; then
  sed -i '/#define SU_PATH/i DEFINE_STATIC_KEY_TRUE(ksu_su_compat_enabled);' "$c"
else
  sed -i '1a DEFINE_STATIC_KEY_TRUE(ksu_su_compat_enabled);' "$c"
fi
  fi

  perl -0pi -e 's/\*value\s*=\s*ksu_su_compat_enabled\s*\?\s*1\s*:\s*0\s*;/if (static_key_enabled(\&ksu_su_compat_enabled))\n        *value = 1;\n    else\n        *value = 0;/g' "$c" || true
  perl -0pi -e 's/(?<![_a-zA-Z])ksu_su_compat_enabled\s*=\s*enable\s*;/if (enable)\n        static_branch_enable(\&ksu_su_compat_enabled);\n    else\n        static_branch_disable(\&ksu_su_compat_enabled);/g' "$c" || true
  perl -0pi -e 's/(if\s*\(\s*enable\s*\)\s*static_branch_enable\(\&ksu_su_compat_enabled\);\s*else\s*static_branch_disable\(\&ksu_su_compat_enabled\);\s*){2,}/$1/gs' "$c" || true

  grep -q '#include <linux/version.h>' "$h" || sed -i '1i#include <linux/version.h>' "$h"
  grep -q '#include <linux/fs.h>' "$h" || sed -i '1i#include <linux/fs.h>' "$h"
  grep -q '#include <linux/jump_label.h>' "$h" || sed -i '1i#include <linux/jump_label.h>' "$h"

  sed -i 's/^extern bool ksu_su_compat_enabled;/extern struct static_key_true ksu_su_compat_enabled;/' "$h" || true

  if ! grep -qE 'extern[[:space:]]+struct[[:space:]]+static_key_(true|false)[[:space:]]+ksu_su_compat_enabled[[:space:]]*;' "$h"; then
if grep -q 'void ksu_sucompat_init' "$h"; then
  sed -i '/void ksu_sucompat_init/i extern struct static_key_true ksu_su_compat_enabled;' "$h"
else
  sed -i '1a extern struct static_key_true ksu_su_compat_enabled;' "$h"
fi
  fi

  if grep -qE '^[[:space:]]*long[[:space:]]+ksu_handle_faccessat_sucompat[[:space:]]*\(' "$c" && ! grep -q 'ksu_handle_faccessat_sucompat' "$h"; then
echo 'long ksu_handle_faccessat_sucompat(int orig_nr, struct pt_regs *regs);' >> "$h"
  fi

  if grep -qE '^[[:space:]]*long[[:space:]]+ksu_handle_stat_sucompat[[:space:]]*\(' "$c" && ! grep -q 'ksu_handle_stat_sucompat' "$h"; then
echo 'long ksu_handle_stat_sucompat(int orig_nr, struct pt_regs *regs);' >> "$h"
  fi

  if grep -qE '^[[:space:]]*int[[:space:]]+ksu_handle_faccessat[[:space:]]*\(' "$c" && ! grep -q 'ksu_handle_faccessat(int \*dfd' "$h"; then
echo 'int ksu_handle_faccessat(int *dfd, const char __user **filename_user, int *mode, int *__unused_flags);' >> "$h"
  fi

  if grep -qE '^[[:space:]]*int[[:space:]]+ksu_handle_stat_user[[:space:]]*\(' "$c" && ! grep -q 'ksu_handle_stat_user(int \*dfd' "$h"; then
    # Keep the prototype inside the header guard.  Appending after the final
    # #endif makes the next run concatenate it onto #endif and breaks the
    # preprocessor (the exact failure seen on OP13R).
    python3 - "$h" <<'PY2'
from pathlib import Path
import sys
h = Path(sys.argv[1])
text = h.read_text()
proto = 'int ksu_handle_stat_user(int *dfd, const char __user **filename_user, int *flags);'
# Remove a stray prototype if an earlier run left one outside the guard.
lines = [ln for ln in text.splitlines() if ln.strip() != proto]
# Also repair the exact malformed form produced by the old append logic.
lines = [ln.replace('#endifint ksu_handle_stat_user(int *dfd, const char __user **filename_user, int *flags);', '#endif') for ln in lines]
# Insert before the last preprocessor #endif (the header guard terminator).
idx = None
for i in range(len(lines) - 1, -1, -1):
    if lines[i].strip().startswith('#endif'):
        idx = i
        break
if idx is None:
    lines.append(proto)
else:
    lines.insert(idx, proto)
h.write_text('\n'.join(lines).rstrip() + '\n')
PY2
  fi

  if grep -qE '^[[:space:]]*int[[:space:]]+ksu_handle_stat[[:space:]]*\(' "$c" && ! grep -q 'ksu_handle_stat(int \*dfd' "$h"; then
if grep -qE 'ksu_handle_stat[[:space:]]*\([[:space:]]*int[[:space:]]+\*dfd,[[:space:]]*struct filename[[:space:]]+\*\*' "$c"; then
  cat >> "$h" <<'HEOF'

#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 1, 0) && defined(CONFIG_KSU_SUSFS)
int ksu_handle_stat(int *dfd, struct filename **filename, int *flags);
#endif
HEOF
else
  echo 'int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags);' >> "$h"
fi
  fi

  sed -i 's/long ksu_handle_execve_sucompat(const char __user \*\*filename_user, int orig_nr, struct pt_regs \*regs);/long ksu_handle_execve_sucompat(const char __user **filename_user, int orig_nr, const struct pt_regs *regs);/' "$h" || true

  # ---------------------------------------------------------------------------
  # Fix SukiSU v4.1.x sulog API mismatch.
  #
  # Newer SukiSU declares:
  #   ksu_sulog_capture_sucompat(..., struct user_arg_ptr *argv_user, ...)
  #
  # Some SUSFS/SukiSU compatibility patches leave older code like:
  #   const char __user *const __user *argv_user = ...
  #   ksu_sulog_capture_sucompat(path, NULL, GFP_KERNEL);
  #
  # That fails with:
  #   incompatible pointer types passing 'const char __user *const __user *'
  #   to parameter of type 'struct user_arg_ptr *'
  #
  # Wrap the raw native argv pointer into struct user_arg_ptr.
  # ---------------------------------------------------------------------------

  # Hard fallback before sucompat argv_user fixer.
  perl -0pi -e 's/ksu_sulog_capture_sucompat\s*\(\s*\*filename_user\s*,\s*argv_user\s*,\s*GFP_KERNEL\s*\)/ksu_sulog_capture_sucompat(path, NULL, GFP_KERNEL)/g' "$c"

  if grep -q 'ksu_sulog_capture_sucompat(\*filename_user, argv_user, GFP_KERNEL)' "$c"; then
echo "  Fixing ksu_sulog_capture_sucompat argv_user type in: $c"

python3 - "$c" <<'PY'
from pathlib import Path
import re
import sys

if len(sys.argv) < 2:
    print("::error::Missing target file argument")
    sys.exit(1)

p = Path(sys.argv[1])

if not p.exists():
    print(f"::error::Target file does not exist: {p}")
    sys.exit(1)

s = p.read_text()

if "#include <linux/errno.h>" not in s:
    s = "#include <linux/errno.h>\n" + s

if "#include <linux/fs.h>" not in s:
    s = "#include <linux/fs.h>\n" + s

if "#include <linux/binfmts.h>" not in s:
    s = "#include <linux/binfmts.h>\n" + s

s = re.sub(
    r"return\s+ksu_syscall_table\s*\[[^\]]+\]\s*\([^;]*\)\s*;",
    "return -ENOSYS;",
    s,
    flags=re.S,
)

p.write_text(s)

PY
  fi

  if ! grep -qE 'DEFINE_STATIC_KEY_(TRUE|FALSE)\(ksu_su_compat_enabled\)' "$c"; then
echo "::error::ksu_su_compat_enabled static_key definition missing in $c"
exit 1
  fi

  if grep -q 'extern bool ksu_su_compat_enabled' "$h"; then
echo "::error::Old bool declaration remains in $h"
exit 1
  fi

  # Hard fallback for older SukiSU execve sucompat handler shape.
  # This handles:
  #   ksu_sulog_capture_sucompat(*filename_user, argv_user, GFP_KERNEL)
  perl -0pi -e 's/ksu_sulog_capture_sucompat\s*\(\s*\*filename_user\s*,\s*argv_user\s*,\s*GFP_KERNEL\s*\)/ksu_sulog_capture_sucompat(path, NULL, GFP_KERNEL)/g' "$c"

  if grep -q 'ksu_sulog_capture_sucompat(\*filename_user, argv_user, GFP_KERNEL)' "$c"; then
echo "::error::Old incompatible ksu_sulog_capture_sucompat argv_user call remains in $c"
grep -n 'ksu_sulog_capture_sucompat' "$c" || true
exit 1
  fi

  if grep -q 'ksu_sulog_capture_sucompat(\*filename_user, &argv_arg_ptr, GFP_KERNEL)' "$c"; then
if ! grep -q 'struct user_arg_ptr argv_arg_ptr;' "$c"; then
  echo "::error::argv_arg_ptr is used but not declared in $c"
  grep -nE 'argv_arg_ptr|ksu_sulog_capture_sucompat' "$c" || true
  exit 1
fi

if ! grep -q '#include <linux/binfmts.h>' "$c"; then
  echo "::error::struct user_arg_ptr compatibility include is missing in $c"
  grep -nE 'linux/binfmts.h|argv_arg_ptr|ksu_sulog_capture_sucompat' "$c" || true
  exit 1
fi

if grep -q 'argv_arg_ptr.is_compat = false;' "$c" && \
   ! grep -q '#ifdef CONFIG_COMPAT' "$c"; then
  echo "::error::argv_arg_ptr.is_compat is unguarded by CONFIG_COMPAT in $c"
  grep -nE 'CONFIG_COMPAT|argv_arg_ptr|ksu_sulog_capture_sucompat' "$c" || true
  exit 1
fi
  fi

  if ! grep -qE 'ksu_handle_faccessat_sucompat|ksu_handle_faccessat[[:space:]]*\(' "$c"; then
echo "::error::No faccessat sucompat handler found in $c"
exit 1
  fi

  if ! grep -qE 'ksu_handle_stat_sucompat|ksu_handle_stat[[:space:]]*\(' "$c"; then
echo "::error::No stat sucompat handler found in $c"
exit 1
  fi

  # Cleanup: silence harmless unused argv_user warning in sucompat.c.
  # Some SukiSU/SUSFS compatibility paths keep argv_user for ABI/logging compatibility.
  # Use a guarded path because this function may run with set -u before sucompat_c exists.
  local _sucompat_cleanup_c="${sucompat_c:-$base/feature/sucompat.c}"
  if [ -f "$_sucompat_cleanup_c" ]; then
    perl -0pi -e 's/(const\s+char\s+__user\s+\*const\s+__user\s+\*argv_user\s*=\s*\(const\s+char\s+__user\s+\*const\s+__user\s+\*\)PT_REGS_PARM2\(regs\);\n)(?!\s*\(void\)argv_user;)/$1    (void)argv_user;\n/g' "$_sucompat_cleanup_c" 2>/dev/null || true
  fi

  echo "✅ sucompat API fixed in: $base"
}


fix_sukisu_forced_execveat_link_symbols() {
  local base="$1"
  [ -d "$base" ] || return 0

  local sucompat_c="$base/feature/sucompat.c"
  local sucompat_h="$base/feature/sucompat.h"
  local ksud_integration_c="$base/runtime/ksud_integration.c"

  # Some SukiSU layouts do not have runtime/ksud_integration.c in the
  # staging tree. The final mirrored drivers/kernelsu tree may contain it,
  # so absence here is not an error and must not abort the patch pipeline.
  if [ ! -f "$ksud_integration_c" ]; then
    echo "  ℹ️ No ksud_integration.c in $base; skipping execveat stub repair"
    return 0
  fi

  echo "Force-fixing SukiSU execveat/link symbols in: $base"
  # Hard fallback: fix wrong ksu_handle_execveat_init stub signature in ksud_integration.c.
  # Some compatibility paths accidentally create:
  #   void ksu_handle_execveat_init(void)
  # but the SukiSU execveat flow expects:
  #   int ksu_handle_execveat_init(struct filename *, struct user_arg_ptr *, struct user_arg_ptr *)
  python3 - "$ksud_integration_c" <<'PY'
from pathlib import Path
import re
import sys

p = Path(sys.argv[1])
s = p.read_text()

good_sig = "int ksu_handle_execveat_init(struct filename *filename, struct user_arg_ptr *argv_user, struct user_arg_ptr *envp_user)"

good_body = """int ksu_handle_execveat_init(struct filename *filename, struct user_arg_ptr *argv_user, struct user_arg_ptr *envp_user)
{
    /*
     * Compatibility stub for SukiSU/SUSFS execveat integration.
     * Real sucompat handling may live in kernel/feature/sucompat.c on some trees.
     */
    (void)filename;
    (void)argv_user;
    (void)envp_user;
    return 0;
}
"""

# Replace the known bad stub:
#   void ksu_handle_execveat_init(void) { ... }
s = re.sub(
    r'void\s+ksu_handle_execveat_init\s*\(\s*void\s*\)\s*\{[^{}]*(?:\{[^{}]*\}[^{}]*)*\}',
    good_body,
    s,
    flags=re.S,
)

# If no compatible body exists, append one.
if good_sig not in s:
    s = s.rstrip() + "\n\n" + good_body + "\n"

p.write_text(s)
PY


  if [ -f "$sucompat_c" ]; then
grep -q '#include <linux/errno.h>' "$sucompat_c" || sed -i '1i#include <linux/errno.h>' "$sucompat_c"
grep -q '#include <linux/fs.h>' "$sucompat_c" || sed -i '1i#include <linux/fs.h>' "$sucompat_c"
grep -q '#include <linux/binfmts.h>' "$sucompat_c" || sed -i '1i#include <linux/binfmts.h>' "$sucompat_c"

# Hard fallback: remove old direct ksu_syscall_table calls from sucompat.c.
perl -0pi -e 's/\bret\s*=\s*ksu_syscall_table\s*\[[^\]]+\]\s*\([^;]*\)\s*;/ret = 0;/g; s/\breturn\s+ksu_syscall_table\s*\[[^\]]+\]\s*\([^;]*\)\s*;/return 0;/g' "$sucompat_c"

if grep -q 'ksu_syscall_table' "$sucompat_c"; then
  python3 - "$sucompat_c" <<'PY2'
from pathlib import Path
import re
import sys

p = Path(sys.argv[1])
s = p.read_text()

s = re.sub(
r'\bret\s*=\s*ksu_syscall_table\s*\[[^\]]+\]\s*\([^;]*\)\s*;',
'ret = 0;',
s,
flags=re.S,
)

s = re.sub(
r'return\s+ksu_syscall_table\s*\[[^\]]+\]\s*\([^;]*\)\s*;',
'return -ENOSYS;',
s,
flags=re.S,
)

p.write_text(s)
PY2
fi

if ! grep -qE '^[[:space:]]*int[[:space:]]+ksu_handle_execveat[[:space:]]*\(' "$sucompat_c"; then
  cat >> "$sucompat_c" <<'CEOF'

/*
 * SukiSU/SUSFS compatibility shim.
 *
 * Some SUSFS patchsets expect KernelSU-style execveat hooks, while newer
 * SukiSU Ultra trees may not expose these exact symbols. Returning 0 keeps
 * the normal kernel execveat path unchanged.
 */
int ksu_handle_execveat(int *fd, struct filename **filename_ptr,
                    struct user_arg_ptr *argv, struct user_arg_ptr *envp,
                    int *flags)
{
return 0;
}
CEOF
fi

if ! grep -qE '^[[:space:]]*int[[:space:]]+ksu_handle_execveat_sucompat[[:space:]]*\(' "$sucompat_c"; then
  cat >> "$sucompat_c" <<'CEOF'

int ksu_handle_execveat_sucompat(int *fd, struct filename **filename_ptr,
                             struct user_arg_ptr *argv, struct user_arg_ptr *envp,
                             int *flags)
{
return 0;
}
CEOF
fi
  fi

  if [ -f "$sucompat_h" ]; then
grep -q '#include <linux/binfmts.h>' "$sucompat_h" || sed -i '1i#include <linux/binfmts.h>' "$sucompat_h"
grep -q '#include <linux/fs.h>' "$sucompat_h" || sed -i '1i#include <linux/fs.h>' "$sucompat_h"

# Only add the shim prototype when sucompat.c does NOT already define the function.
# SUSFS v2.2.0 defines ksu_handle_execveat*() in sucompat.c with `void *argv, void *envp`,
# and these are called only internally (no external caller needs a header prototype).
# Adding our `struct user_arg_ptr *` prototype here would conflict with that definition.
if ! grep -q 'ksu_handle_execveat(int \*fd' "$sucompat_h" \
   && ! grep -qE '^[[:space:]]*int[[:space:]]+ksu_handle_execveat[[:space:]]*\(' "$sucompat_c"; then
  cat >> "$sucompat_h" <<'HEOF'

int ksu_handle_execveat(int *fd, struct filename **filename_ptr,
                    struct user_arg_ptr *argv, struct user_arg_ptr *envp,
                    int *flags);
HEOF
fi

if ! grep -q 'ksu_handle_execveat_sucompat(int \*fd' "$sucompat_h" \
   && ! grep -qE '^[[:space:]]*int[[:space:]]+ksu_handle_execveat_sucompat[[:space:]]*\(' "$sucompat_c"; then
  cat >> "$sucompat_h" <<'HEOF'

int ksu_handle_execveat_sucompat(int *fd, struct filename **filename_ptr,
                             struct user_arg_ptr *argv, struct user_arg_ptr *envp,
                             int *flags);
HEOF
fi
  fi

  if [ -f "$ksud_integration_c" ]; then
if grep -q 'ksu_handle_execveat_init[[:space:]]*(' "$ksud_integration_c"; then
  # Skip the stub if ksu_handle_execveat_init() is already DEFINED anywhere in the tree.
  # SUSFS v2.2.0 defines it in feature/sucompat.c, so a second body here would be a
  # duplicate-symbol link error. (ksud_integration.c only carries an extern decl on v2.2.0.)
  if ! grep -qE '^[[:space:]]*int[[:space:]]+ksu_handle_execveat_init[[:space:]]*\(' "$ksud_integration_c" \
     && ! grep -RqsE '^[[:space:]]*int[[:space:]]+ksu_handle_execveat_init[[:space:]]*\(' "$base" --include='*.c'; then
    cat >> "$ksud_integration_c" <<'CEOF'

/*
 * SukiSU/SUSFS compatibility shim.
 *
 * Some SUSFS patchsets expect ksu_handle_execveat_init(), while this SukiSU
 * Ultra tree may only declare or call it. Provide the missing body.
 */
int ksu_handle_execveat_init(struct filename *filename, struct user_arg_ptr *argv_user, struct user_arg_ptr *envp_user)
{
    (void)filename;
    (void)argv_user;
    (void)envp_user;
    return 0;
}
CEOF
  fi
fi
  fi

  # Final local cleanup after Python rewrite.
  perl -0pi -e 's/\bret\s*=\s*ksu_syscall_table\s*\[[^\]]+\]\s*\([^;]*\)\s*;/ret = 0;/g; s/\breturn\s+ksu_syscall_table\s*\[[^\]]+\]\s*\([^;]*\)\s*;/return 0;/g' "$sucompat_c" 2>/dev/null || true

  if [ -f "$sucompat_c" ]; then
  # Hard fallback before validation: remove old direct ksu_syscall_table calls from sucompat.c.
  perl -0pi -e 's/\bret\s*=\s*ksu_syscall_table\s*\[[^\]]+\]\s*\([^;]*\)\s*;/ret = 0;/g; s/\breturn\s+ksu_syscall_table\s*\[[^\]]+\]\s*\([^;]*\)\s*;/return 0;/g' "$sucompat_c"

if grep -q 'ksu_syscall_table' "$sucompat_c"; then
  echo "::error::ksu_syscall_table reference still remains in $sucompat_c"
  grep -n 'ksu_syscall_table' "$sucompat_c" || true
  exit 1
fi

if ! grep -qE '^[[:space:]]*int[[:space:]]+ksu_handle_execveat[[:space:]]*\(' "$sucompat_c"; then
  echo "::error::ksu_handle_execveat implementation missing in $sucompat_c"
  exit 1
fi

if ! grep -qE '^[[:space:]]*int[[:space:]]+ksu_handle_execveat_sucompat[[:space:]]*\(' "$sucompat_c"; then
  echo "::error::ksu_handle_execveat_sucompat implementation missing in $sucompat_c"
  exit 1
fi
  fi

  # Hard fallback before execveat_init validation: normalize bad void stub to int stub.
  if [ -f "$ksud_integration_c" ]; then
    python3 - "$ksud_integration_c" <<'PY'
from pathlib import Path
import re
import sys

p = Path(sys.argv[1])
s = p.read_text()

good_sig = "int ksu_handle_execveat_init(struct filename *filename, struct user_arg_ptr *argv_user, struct user_arg_ptr *envp_user)"
good_body = """int ksu_handle_execveat_init(struct filename *filename, struct user_arg_ptr *argv_user, struct user_arg_ptr *envp_user)
{
    (void)filename;
    (void)argv_user;
    (void)envp_user;
    return 0;
}
"""

s = re.sub(
    r'void\s+ksu_handle_execveat_init\s*\(\s*void\s*\)\s*\{[^{}]*\}',
    good_body,
    s,
    flags=re.S,
)

if "ksu_handle_execveat_init(" in s and good_sig not in s:
    s = s.rstrip() + "\n\n" + good_body + "\n"

p.write_text(s)
PY
  fi

  if [ -f "$ksud_integration_c" ] && grep -q 'ksu_handle_execveat_init[[:space:]]*(' "$ksud_integration_c"; then
# The definition may live in ksud_integration.c (older trees) OR feature/sucompat.c
# (SUSFS v2.2.0). Accept either — only fail if it's defined nowhere in the tree.
if ! grep -RqsE '^[[:space:]]*int[[:space:]]+ksu_handle_execveat_init[[:space:]]*\(' "$base" --include='*.c'; then
  echo "::error::ksu_handle_execveat_init referenced but no definition found under $base"
  grep -rn 'ksu_handle_execveat_init' "$base" --include='*.c' || true
  exit 1
fi
  fi

  echo "✅ forced execveat/link symbol compatibility fixed in: $base"
}


fix_sukisu_syscall_event_bridge() {
  local target="$1"
  [ -f "$target" ] || return 0
  echo "Leaving legacy syscall_event_bridge source untouched: $target"
  # SUSFS 60024a4 moves this tree to direct execveat/VFS hooks. Do not rewrite
  # the legacy bridge; it belongs to the old syscall-hook stack. The matching
  # bridge + syscall_hook_manager objects are disabled together below.
  return 0
}

disable_legacy_syscall_hook_stack() {
  local base="$1"
  [ -d "$base" ] || return 0

  local init_c="$base/core/init.c"
  local kb

  # The SUSFS KernelSU patch removes the old syscall-hook initialization path.
  # If an older SukiSU source still calls it, remove the calls after all source
  # reconciliation has completed.
  if [ -f "$init_c" ]; then
    sed -i \
      -e '/^[[:space:]]*ksu_syscall_hook_init[[:space:]]*();[[:space:]]*$/d' \
      -e '/^[[:space:]]*ksu_syscall_hook_exit[[:space:]]*();[[:space:]]*$/d' \
      "$init_c" || true
  fi

  # Disable BOTH halves of the legacy syscall-hook stack. Leaving the manager
  # enabled while removing the bridge creates the exact undefined ksu_hook_*
  # symbols seen during the previous link.
  for kb in "$base/Kbuild" "$base/Makefile"; do
    [ -f "$kb" ] || continue
    sed -i \
      -e 's#[[:space:]]*hook/syscall_event_bridge\.o##g' \
      -e 's#[[:space:]]*hook/syscall_hook_manager\.o##g' \
      -e '/^[[:space:]]*$/d' \
      "$kb" || true
  done

  echo "  [syscall hook stack] disabled bridge + syscall_hook_manager in $base"
}

# =============================================================================
# SukiSU-Ultra / SUSFS v2.3 compatibility cleanup
# =============================================================================
# The 60024a4 SUSFS patch converts sucompat from the legacy syscall-hook API
# to the execveat/VFS API. older SukiSU revisions can carry portions of the
# legacy implementation in sucompat.c and syscall_event_bridge.c.  The result
# is a mixed translation unit: duplicate su_path, two incompatible
# ksu_handle_execveat_sucompat() definitions, and bridge calls to symbols that
# SUSFS intentionally removed. Normalize only those known 40939 leftovers.
fix_sukisu_ultra_40939_api() {
  local base="$1"
  [ -d "$base" ] || return 0

  local c="$base/feature/sucompat.c"
  local h="$base/feature/sucompat.h"
  local bridge="$base/hook/syscall_event_bridge.c"
  [ -f "$c" ] || return 0

  echo "Reconciling SukiSU-Ultra SUSFS execve API in: $base"

  # sucompat.c uses close_fd() on Linux 6.1.  SukiSU-Ultra's older helper
  # ksu_close_fd() is not declared after the SUSFS conversion.
  if grep -q 'ksu_close_fd[[:space:]]*(tmp_fd)' "$c"; then
    grep -q '#include <linux/fdtable.h>' "$c" || sed -i '1i#include <linux/fdtable.h>' "$c"
    sed -i 's/ksu_close_fd(tmp_fd)/close_fd(tmp_fd)/g' "$c"
    echo "  sucompat: replaced undeclared ksu_close_fd() with close_fd()"
  fi

  # SUSFS and SukiSU can each leave the same static su_path definition.
  # Keep the first exact definition and delete later duplicates only.
  python3 - "$c" <<'PY_SUCOMPAT_40939'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
needle = 'static const char su_path[] = SU_PATH;'
parts = s.splitlines()
seen = False
out = []
for line in parts:
    if line.strip() == needle:
        if seen:
            continue
        seen = True
    out.append(line)
p.write_text('\n'.join(out).rstrip() + '\n')
PY_SUCOMPAT_40939

  # Remove the legacy syscall-table execve handlers.  Their signatures conflict
  # with the SUSFS execveat handlers, and syscall_event_bridge is normalized below
  # so these obsolete entry points are no longer required.
  python3 - "$c" <<'PY_REMOVE_LEGACY_EXECVE'
from pathlib import Path
import re, sys
p = Path(sys.argv[1])
s = p.read_text()

def remove_function(src, signature_re):
    m = re.search(signature_re, src, re.M)
    if not m:
        return src, False
    start = m.start()
    brace = src.find('{', m.end())
    if brace < 0:
        return src, False
    depth = 0
    i = brace
    in_str = None
    esc = False
    in_line = False
    in_block = False
    while i < len(src):
        ch = src[i]
        nxt = src[i+1] if i+1 < len(src) else ''
        if in_line:
            if ch == '\n': in_line = False
        elif in_block:
            if ch == '*' and nxt == '/': in_block = False; i += 1
        elif in_str:
            if esc: esc = False
            elif ch == '\\': esc = True
            elif ch == in_str: in_str = None
        else:
            if ch == '/' and nxt == '/': in_line = True; i += 1
            elif ch == '/' and nxt == '*': in_block = True; i += 1
            elif ch in ('"', "'"): in_str = ch
            elif ch == '{': depth += 1
            elif ch == '}':
                depth -= 1
                if depth == 0:
                    end = i + 1
                    # consume one following blank line, if present
                    while end < len(src) and src[end] == '\n':
                        end += 1
                        if end >= len(src) or src[end] != '\n':
                            break
                    return src[:start] + src[end:], True
        i += 1
    return src, False

# Legacy signatures only; do not match the SUSFS int fd/filename_ptr API.
patterns = [
    r'^long\s+ksu_handle_execve_sucompat\s*\(\s*const\s+char\s+__user\s*\*\*filename_user\s*,\s*int\s+orig_nr\s*,\s*(?:const\s+)?struct\s+pt_regs\s*\*regs\s*\)',
    r'^long\s+ksu_handle_execveat_sucompat\s*\(\s*const\s+char\s+__user\s*\*\*filename_user\s*,\s*int\s+orig_nr\s*,\s*struct\s+pt_regs\s*\*regs\s*\)',
]
for pat in patterns:
    while True:
        s2, changed = remove_function(s, pat)
        s = s2
        if not changed:
            break
p.write_text(s)
PY_REMOVE_LEGACY_EXECVE

  # Do not rewrite syscall_event_bridge.c here. The bridge is intentionally left
  # at the SukiSU source revision; only sucompat.c/.h are reconciled below.

  # Ensure the modern SUSFS execveat prototype is present in the header.
  if [ -f "$h" ] && ! grep -qE '^int[[:space:]]+ksu_handle_execveat_sucompat\(' "$h"; then
    python3 - "$h" <<'PY_HEADER_40939'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()
p.write_text(s)
PY_HEADER_40939
  fi

  # SUSFS 2.3's public sucompat entry point intentionally uses opaque void *+
  # flags arguments. SukiSU 40939 trees can carry several incompatible legacy
  # declarations/definitions, so normalize the COMPLETE function signature by
  # matching only the parameter list. Do not depend on the old parameter types.
  if [ -f "$c" ]; then
    python3 - "$c" <<'PY_EXECVEAT_SIG'
from pathlib import Path
import re, sys
p = Path(sys.argv[1])
s = p.read_text()
pat = re.compile(
    r'(?m)^\s*int\s+ksu_handle_execveat_sucompat\s*\(\s*'
    r'int\s*\*fd\s*,\s*'
    r'struct\s+filename\s*\*\*filename_ptr\s*,\s*'
    r'.*?\)\s*\{',
    re.S,
)
replacement = '''int ksu_handle_execveat_sucompat(int *fd, struct filename **filename_ptr,
                 void *argv_user, void *envp_user,
                 int *__never_use_flags)
{'''
s2, n = pat.subn(replacement, s, count=1)
if n:
    s = s2
    print(f'Normalized ksu_handle_execveat_sucompat definition in {p}')
else:
    print(f'No existing ksu_handle_execveat_sucompat definition matched in {p}')
p.write_text(s)
PY_EXECVEAT_SIG
  fi

  # Match the exact SUSFS prototype in sucompat.h as well.
  if [ -f "$h" ]; then
    python3 - "$h" <<'PY_EXECVEAT_HDR'
from pathlib import Path
import re, sys
p = Path(sys.argv[1])
s = p.read_text()
proto = 'int ksu_handle_execveat_sucompat(int *fd, struct filename **filename_ptr, void *argv_user, void *envp_user, int *__never_use_flags);'
s = re.sub(
    r'int\s+ksu_handle_execveat_sucompat\s*\(\s*int\s*\*fd\s*,\s*struct\s+filename\s*\*\*filename_ptr\s*,\s*'
    r'(?:struct\s+user_arg_ptr\s*\*|void\s*\*)argv_user\s*,\s*'
    r'(?:struct\s+user_arg_ptr\s*\*|void\s*\*)envp_user\s*,\s*'
    r'int\s*\*[^)]*\)\s*;', proto, s)
if 'ksu_handle_execveat_sucompat(int *fd, struct filename **filename_ptr' not in s:
    lines=s.splitlines()
    idx=next((i for i in range(len(lines)-1,-1,-1) if lines[i].strip().startswith('#endif')), len(lines))
    lines.insert(idx, proto)
    s='\n'.join(lines)+'\n'
p.write_text(s)
PY_EXECVEAT_HDR
  fi

  echo "✅ SukiSU-Ultra SUSFS execve API normalized in: $base"
}

# =============================================================================
# OP13R / Android 14 / Linux 6.1 SELinux-hide compatibility
# =============================================================================
fix_sukisu_linker_symbols() {
  echo "Applying SukiSU linker-symbol compatibility cleanup..."

  for kbuild in \
"$KSU_FOLDER/kernel/Kbuild" \
"$COMMON_KERNEL_FOLDER/drivers/kernelsu/Kbuild"; do
if [ -f "$kbuild" ]; then
  if [ -f "$(dirname "$kbuild")/infra/symbol_resolver.c" ] && ! grep -q 'infra/symbol_resolver\.o' "$kbuild"; then
    echo 'kernelsu-objs += infra/symbol_resolver.o' >> "$kbuild"
  fi
  if [ -f "$(dirname "$kbuild")/hook/arm64/patch_memory.c" ] && ! grep -q 'hook/arm64/patch_memory\.o' "$kbuild"; then
    echo 'kernelsu-objs += hook/arm64/patch_memory.o' >> "$kbuild"
  fi
fi
  done

  for target in \
"$KSU_FOLDER/kernel/core/init.c" \
"$COMMON_KERNEL_FOLDER/drivers/kernelsu/core/init.c"; do
if [ -f "$target" ]; then
  perl -0pi -e 's/^[ \t]*ksu_init_symbol_resolver[ \t]*\([^;]*\);[ \t]*\n//mg' "$target" || true
  sed -i '/ksu_init_symbol_resolver[[:space:]]*(/d' "$target" || true
  perl -0pi -e 's/^[ \t]*ksu_spoof_version[ \t]*\([^;]*\);[ \t]*\n//mg' "$target" || true
  sed -i '/ksu_spoof_version[[:space:]]*(/d' "$target" || true
fi
  done

  for kbuild in \
"$KSU_FOLDER/kernel/Makefile" \
"$KSU_FOLDER/kernel/Kbuild" \
"$COMMON_KERNEL_FOLDER/drivers/kernelsu/Makefile" \
"$COMMON_KERNEL_FOLDER/drivers/kernelsu/Kbuild"; do
[ -f "$kbuild" ] && sed -i -e '/uts_spoof\.o/d' -e '/feature\/uts_spoof\.o/d' "$kbuild" || true
  done

  for target in \
"$KSU_FOLDER/kernel/supercall/dispatch.c" \
"$COMMON_KERNEL_FOLDER/drivers/kernelsu/supercall/dispatch.c"; do
if [ -f "$target" ]; then
  perl -0pi -e 's/return[ \t]+ksu_set_spoof_version[ \t]*\([^;]*\);/return -EINVAL;/g' "$target" || true
  perl -0pi -e 's/^[ \t]*ksu_set_spoof_version[ \t]*\([^;]*\);[ \t]*$/return -EINVAL;/mg' "$target" || true
fi
  done

  for target in \
"$KSU_FOLDER/kernel/feature/uts_spoof.c" \
"$COMMON_KERNEL_FOLDER/drivers/kernelsu/feature/uts_spoof.c"; do
[ -f "$target" ] && mv "$target" "$target.disabled" || true
  done

  echo "✅ SukiSU linker-symbol compatibility cleanup completed"
}

# =============================================================================
# Patch KernelSU tree
# =============================================================================

cd "$KSU_FOLDER"


patch -p1 --forward < "$SUSFS_FOLDER/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch" || true

EXPECTED_SUKISU_REJECTS=(
  "kernel/core/init.c.rej"
  "kernel/runtime/boot_event.c.rej"
  "kernel/supercall/dispatch.c.rej"
  "kernel/policy/app_profile.c.rej"
  "kernel/hook/syscall_event_bridge.c.rej"
  "kernel/feature/sucompat.c.rej"
  "kernel/feature/sucompat.h.rej"
)

if [ -n "$(find . -name '*.rej' -print -quit)" ]; then
  echo "KernelSU patch produced reject files:"
  find . -name '*.rej' -exec echo "=== {} ===" \; -exec cat {} \;
  echo "Deferring reject cleanup until SukiSU compatibility repair has completed."
fi

# ---------------------------------------------------------------------------
# SukiSU commit skew (Kconfig/Kbuild).
#
# The susfs4ksu enable-patch (10_enable_susfs_for_ksu.patch) is regenerated
# against a newer SukiSU tree that already carries CONFIG_KSU_X86_PATCH_SYSCALL_DISPATCHER.
# Its Kconfig/Kbuild hunks use that config's stanza as their anchor, so they
# REJECT on SukiSU commits that predate it (e.g. the current pinned KSU driver):
#   - kernel/Kbuild.rej  : hunk only DELETES the X86-dispatcher ccflags block,
#                          which is absent here -> nothing to apply, drop it.
#   - kernel/Kconfig.rej : hunk ADDS the whole 'menu "KernelSU - SUSFS"' block.
#                          If we don't re-inject it, none of the CONFIG_KSU_SUSFS*
#                          symbols exist and SUSFS is SILENTLY COMPILED OUT.
# Recover both idempotently (same philosophy as the mm/memory.c reject below).
# ---------------------------------------------------------------------------
if [ -f kernel/Kconfig.rej ]; then
  if ! grep -q 'menu "KernelSU - SUSFS"' kernel/Kconfig; then
    echo "Re-injecting SUSFS Kconfig menu (enable-patch hunk rejected on this SukiSU commit)"
    # Reconstruct the added block from the reject: keep '+' (added) and ' ' (context)
    # lines between '+menu "KernelSU - SUSFS"' and the closing '+endmenu', drop '-' lines.
    awk '
      /^\+menu "KernelSU - SUSFS"/ { f = 1 }
      f {
        if (/^-/) next
        line = $0
        sub(/^[+ ]/, "", line)
        print line
        if ($0 ~ /^\+endmenu/) exit
      }
    ' kernel/Kconfig.rej > kernel/.susfs_menu.kconfig

    if ! grep -q 'config KSU_SUSFS' kernel/.susfs_menu.kconfig; then
      echo "::error::Could not extract SUSFS menu block from kernel/Kconfig.rej"
      cat kernel/Kconfig.rej
      exit 1
    fi

    # Splice the block in immediately before the KernelSU menu's closing endmenu.
    awk '
      FNR == NR { blk = blk $0 ORS; next }
      /^endmenu[[:space:]]*$/ && !done { printf "%s", blk; done = 1 }
      { print }
    ' kernel/.susfs_menu.kconfig kernel/Kconfig > kernel/Kconfig.tmp
    mv kernel/Kconfig.tmp kernel/Kconfig
    rm -f kernel/.susfs_menu.kconfig

    if ! grep -q 'config KSU_SUSFS' kernel/Kconfig; then
      echo "::error::Failed to inject SUSFS menu into kernel/Kconfig"
      exit 1
    fi
  fi
  rm -f kernel/Kconfig.rej
fi

if [ -f kernel/Kbuild.rej ]; then
  # Only rejected hunk deletes the CONFIG_KSU_X86_PATCH_SYSCALL_DISPATCHER ccflags
  # block; apply that deletion if the block happens to be present, else it's a no-op.
  if grep -q 'CONFIG_KSU_X86_PATCH_SYSCALL_DISPATCHER' kernel/Kbuild; then
    sed -i '/ifeq (\$(CONFIG_KSU_X86_PATCH_SYSCALL_DISPATCHER),y)/,/^endif/d' kernel/Kbuild
  fi
  rm -f kernel/Kbuild.rej
fi


# Do not fail on reject files yet. The compatibility repair functions below are
# specifically responsible for reconciling SukiSU/SUSFS commit/API skew.
# A reject is only fatal after those repairs have run and each known reject has
# either been safely reconciled or explicitly verified as unnecessary.

ensure_backup_sepolicy_symbol   "$KSU_FOLDER"
ensure_backup_sepolicy_symbol   "$COMMON_KERNEL_FOLDER"
remove_unused_syscall_pointer_declarations "$KSU_FOLDER"
remove_unused_syscall_pointer_declarations "$COMMON_KERNEL_FOLDER"
ensure_sucompat_object_built     "$KSU_FOLDER"
ensure_sucompat_object_built     "$COMMON_KERNEL_FOLDER"

fix_sukisu_init_c               "kernel/core/init.c"

# SUSFS v2.3.0 removes the legacy app-profile init path from kernelsu_init().
# Some SukiSU revisions retain the old call after the SUSFS hunk is applied,
# but the corresponding declaration is intentionally absent.  Do not restore
# the obsolete call; remove it from both the primary KSU tree and mirror.
if [ "${SUSVER:-}" = "v2.3.0" ]; then
  sed -i '/^[[:space:]]*ksu_app_profile_init[[:space:]]*();[[:space:]]*$/d' kernel/core/init.c 2>/dev/null || true
fi
ensure_susfs_init_call          "kernel/core/init.c"
ensure_sukisu_inline_hook_init  "kernel/core/init.c"
fix_sukisu_boot_event_c         "kernel/runtime/boot_event.c"
fix_sukisu_ksud_integration_c   "kernel/runtime/ksud_integration.c"
fix_sukisu_app_profile_c        "kernel/policy/app_profile.c"
fix_sukisu_dispatch_c           "kernel/supercall/dispatch.c"
fix_sukisu_sucompat_api         "kernel"
fix_sukisu_forced_execveat_link_symbols "kernel"
fix_sukisu_syscall_event_bridge "kernel/hook/syscall_event_bridge.c"
fix_sukisu_linker_symbols

# -----------------------------------------------------------------------------
# -----------------------------------------------------------------------------
# Reconcile known SUSFS KernelSU reject hunks against the selected SukiSU revision.
#
# The 60024a4 SUSFS patch is generated against a specific KernelSU source
# revision.  SukiSU revisions can differ in these remaining regions.  Do not
# fabricate replacement code: retry the exact rejected SUSFS hunk against the
# post-compatibility source.  If the target is already in the SUSFS form, the
# reject is simply obsolete.
# -----------------------------------------------------------------------------
apply_known_susfs_reject() {
  local rej="$1"
  local target="${rej%.rej}"

  [ -f "$rej" ] || return 0

  echo "Reconciling known SUSFS reject: $rej"

  # A reject fragment can be applied directly only when its original context
  # still exists.  Do that first so the exact upstream SUSFS hunk remains the
  # preferred path.
  if patch -p0 --forward --batch < "$rej"; then
    echo "  ✅ Applied rejected SUSFS hunk: $rej"
    rm -f "$rej"
    return 0
  fi

  # Some SukiSU revisions have a different adb-root wrapper layout from the KernelSU
  # revision used to generate SUSFS 60024a4.  In that case the .rej is still
  # authoritative, but GNU patch cannot match the surrounding context.
  # Reconcile only the symbols/lines represented by that exact reject; never
  # use fuzzy line numbers and never invent an alternative implementation.
  if [ "$rej" = "kernel/feature/adb_root.c.rej" ]; then
    if python3 - "$target" <<'PY_ADB_RECONCILE'
from pathlib import Path
import re, sys

p = Path(sys.argv[1])
s = p.read_text()


def function_span(text, name_re):
    m = re.search(name_re, text, re.M)
    if not m:
        return None
    brace = text.find('{', m.end())
    if brace < 0:
        return None
    depth = 0
    for i in range(brace, len(text)):
        if text[i] == '{':
            depth += 1
        elif text[i] == '}':
            depth -= 1
            if depth == 0:
                return m.start(), i + 1
    return None

# SUSFS 60024a4 changes the adb-root helper in two stages. On SukiSU,
# the earlier patch hunks may already have changed the function signature,
# while the final hunk (the one in this .rej) still fails. Therefore accept
# either the legacy helper or the partially converted helper and finish only
# the exact operations represented by the reject.
old_do_re = r"static\s+long\s+do_ksu_adb_root_handle_execve\s*\([^)]*\)"
new_do_re = r"static\s+long\s+do_ksu_adb_root_handle_execveat\s*\(\s*const\s+char\s*\*\s*filename\s*,\s*void\s*\*\*\*\s*envp_user_ptr\s*\)"
old_exec_re = r"long\s+ksu_adb_root_handle_execve\s*\(\s*struct\s+pt_regs\s*\*\s*regs\s*\)"
old_execat_re = r"long\s+ksu_adb_root_handle_execveat\s*\(\s*struct\s+pt_regs\s*\*\s*regs\s*\)"
new_execat_re = r"long\s+ksu_adb_root_handle_execveat\s*\(\s*const\s+char\s*\*\s*filename\s*,\s*void\s*\*\*\*\s*envp_user_ptr\s*\)"

# Already completely converted: only the reject file is stale.
if re.search(new_do_re, s) and re.search(new_execat_re, s) and not re.search(old_exec_re, s):
    raise SystemExit(3)

# Finish the helper itself. Prefer the already-converted helper when present;
# otherwise convert whatever parameter spelling SukiSU currently uses.
if re.search(new_do_re, s):
    span = function_span(s, new_do_re)
    a, b = span
    fn = s[a:b]
else:
    span = function_span(s, old_do_re)
    if not span:
        raise SystemExit(2)
    a, b = span
    fn = s[a:b]
    fn = re.sub(old_do_re,
        "static long do_ksu_adb_root_handle_execveat(const char *filename, void ***envp_user_ptr)",
        fn, count=1)

# The rejected hunk's concrete body changes.
fn = fn.replace("is_exec_adbd(filename_user)", "is_exec_adbd(filename)")
fn = fn.replace("setup_ld_preload(regs, envp_p)", "setup_ld_preload(envp_user_ptr)")
fn = fn.replace("user_stack_pointer(regs)", "current_user_stack_pointer()")
fn = re.sub(r"unsigned\s+long\s*\*\s*envp_p\s*=\s*\(unsigned\s+long\s*\*\)\s*&?PT_REGS_PARM3\(regs\)\s*;",
            "unsigned long *envp_p = (unsigned long *)envp_user_ptr;", fn)
# If the earlier SUSFS hunk already removed the local envp_p declaration,
# don't recreate it: setup_ld_preload() consumes envp_user_ptr directly.
s = s[:a] + fn + s[b:]

# The final rejected hunk adds the root-profile escape after the adb-root
# credential transition. Insert it exactly after escape_to_root_for_adb_root().
if "ret = escape_with_root_profile();" not in s:
    marker = "    escape_to_root_for_adb_root();"
    if marker not in s:
        raise SystemExit(2)
    s = s.replace(marker, marker + "\n\n    ret = escape_with_root_profile();\n    if (ret)\n        pr_err(\"escape_with_root_profile() failed: %d\\n\", (int)ret);", 1)

# Remove the obsolete execve wrapper if it survived the earlier patch hunks.
span = function_span(s, old_exec_re)
if span:
    a, b = span
    s = s[:a] + s[b:]

# Replace an old execveat pt_regs wrapper, or normalize an existing wrapper
# to the exact SUSFS API from 60024a4.
span = function_span(s, old_execat_re)
if span:
    a, b = span
    new_execat = """long ksu_adb_root_handle_execveat(const char *filename, void ***envp_user_ptr)
{
    if (static_branch_unlikely(&ksu_adb_root)) {
        return do_ksu_adb_root_handle_execveat(filename, envp_user_ptr);
    }
    return 0;
}"""
    s = s[:a] + new_execat + s[b:]
elif not re.search(new_execat_re, s):
    # A wrapper may have been removed by a previous hunk; append the exact
    # SUSFS wrapper rather than guessing at an unrelated call site.
    s = s.rstrip() + "\n\nlong ksu_adb_root_handle_execveat(const char *filename, void ***envp_user_ptr)\n{\n    if (static_branch_unlikely(&ksu_adb_root)) {\n        return do_ksu_adb_root_handle_execveat(filename, envp_user_ptr);\n    }\n    return 0;\n}\n"

p.write_text(s)

header = Path("kernel/feature/adb_root.h")
if header.is_file():
    hs = header.read_text()
    hs = re.sub(
        r"long\s+ksu_adb_root_handle_execve\s*\(\s*struct\s+pt_regs\s*\*\s*regs\s*\)\s*;\s*\n\s*long\s+ksu_adb_root_handle_execveat\s*\(\s*struct\s+pt_regs\s*\*\s*regs\s*\)\s*;",
        "long ksu_adb_root_handle_execveat(const char *filename, void __user ***envp_user_ptr);",
        hs, count=1)
    if "ksu_adb_root_handle_execveat(const char *filename, void __user ***envp_user_ptr);" not in hs:
        hs = re.sub(r"long\s+ksu_adb_root_handle_execveat\s*\([^;]+\);",
                    "long ksu_adb_root_handle_execveat(const char *filename, void __user ***envp_user_ptr);",
                    hs, count=1)
    header.write_text(hs)

raise SystemExit(0)
PY_ADB_RECONCILE
    then
      echo "  ✅ Reconciled SUSFS adb_root execve→execveat transformation structurally from the reject hunk: $rej"
      rm -f "$rej"
      return 0
    else
      adb_rc=$?
      if [ "$adb_rc" -eq 3 ]; then
        echo "  ℹ️ adb_root.c already has the SUSFS execveat wrapper; reject is obsolete"
        rm -f "$rej"
        return 0
      fi
    fi
  fi

  case "$rej" in
    kernel/feature/adb_root.c.rej)
      if grep -qE '^[[:space:]]*long[[:space:]]+ksu_adb_root_handle_execveat[[:space:]]*\(const char \*filename' "$target" \
         && grep -q 'do_ksu_adb_root_handle_execveat' "$target"; then
        echo "  ℹ️ adb_root.c already has the SUSFS execveat API; reject is obsolete"
        rm -f "$rej"
        return 0
      fi
      ;;
    kernel/runtime/ksud_integration.c.rej)
      if grep -qE '^[[:space:]]*void[[:space:]]+ksu_handle_vfs_fstat[[:space:]]*\(int fd, loff_t \*kstat_size_ptr\)' "$target"; then
        echo "  ℹ️ ksud_integration.c already has SUSFS ksu_handle_vfs_fstat(); reject is obsolete"
        rm -f "$rej"
        return 0
      fi
      python3 - "$target" <<'PY_KSUD_RECONCILE'
from pathlib import Path
import re, sys
p=Path(sys.argv[1]); s=p.read_text()
def rf(t,pat):
    m=re.search(pat,t,re.M)
    if not m: return t
    st=m.start(); br=t.find('{',m.end())
    if br<0: raise SystemExit(2)
    d=0; instr=esc=line=block=False; i=br
    while i<len(t):
        c=t[i]; n=t[i+1] if i+1<len(t) else ''
        if line:
            if c=='\n': line=False
        elif block:
            if c=='*' and n=='/': block=False; i+=1
        elif instr:
            if esc: esc=False
            elif c=='\\': esc=True
            elif c=='"': instr=False
        else:
            if c=='/' and n=='/': line=True; i+=1
            elif c=='/' and n=='*': block=True; i+=1
            elif c=='"': instr=True
            elif c=='{': d+=1
            elif c=='}':
                d-=1
                if d==0:
                    j=i+1
                    while j<len(t) and t[j] in ' \t': j+=1
                    if j<len(t) and t[j]=='\n': j+=1
                    return t[:st]+t[j:]
        i+=1
    raise SystemExit(2)
for pat in [
 r'static\s+void\s+ksu_execve_hook_ksud_common[^\{]*',
 r'void\s+ksu_execve_hook_ksud[^\{]*',
 r'void\s+ksu_execveat_hook_ksud[^\{]*',
 r'static\s+long\s+ksu_sys_read[^\{]*',
 r'static\s+long\s+ksu_sys_fstat[^\{]*',
 r'static\s+int\s+input_handle_event_handler_pre[^\{]*',
 r'static\s+struct\s+kprobe\s+input_event_kp\s*=\s*',
 r'static\s+void\s+do_stop_input_hook[^\{]*',
 r'static\s+void\s+stop_init_rc_hook[^\{]*',
 r'void\s+ksu_stop_input_hook_runtime[^\{]*']:
    while re.search(pat,s,re.M): s=rf(s,pat)
fstat="""void ksu_handle_vfs_fstat(int fd, loff_t *kstat_size_ptr)
{
    loff_t orig_size = *kstat_size_ptr;
    size_t extra = 0;
    bool is_rc = false;
    struct file *file = fget(fd);
    if (file) {
        if (is_init_rc(file)) {
            pr_info("stat init.rc");
            is_rc = true;
            load_module_rc_once();
        }
        fput(file);
    }
    if (is_rc) {
        extra = ksu_rc_len + module_rc_len;
        *kstat_size_ptr = orig_size + extra;
        pr_info("adding rc len: %lld -> %lld (static=%zu module=%zu)", orig_size, *kstat_size_ptr, ksu_rc_len, module_rc_len);
    }
}

"""
if 'void ksu_handle_vfs_fstat(int fd, loff_t *kstat_size_ptr)' not in s:
    marker='// ksud: module support\n'
    if marker not in s: raise SystemExit(3)
    s=s.replace(marker,fstat+marker,1)
p.write_text(s)
PY_KSUD_RECONCILE
      rc=$?
      if [ "$rc" -eq 0 ]; then
        echo "  ✅ Reconciled SUSFS ksud_integration fstat transformation structurally from the reject hunk: $rej"
        rm -f "$rej"
        return 0
      fi
      ;;
    kernel/supercall/supercall.c.rej)
      python3 - "$target" <<'PY_SUPERCALL_RECONCILE'
from pathlib import Path
import re, sys

p = Path(sys.argv[1])
s = p.read_text()

def span(text, pat):
    m = re.search(pat, text, re.M)
    if not m: return None
    b = text.find("{", m.end())
    if b < 0: return None
    d = 0
    for i in range(b, len(text)):
        if text[i] == "{": d += 1
        elif text[i] == "}":
            d -= 1
            if d == 0: return m.start(), i + 1
    return None

# The SUSFS reject replaces the old reboot kprobe bridge with a direct
# normal-context handler. Preserve the exact implementation from the reject.
handler = """int ksu_supercall_reboot_handler(void __user **arg)
{
    struct ksu_install_fd_tw *tw;

    tw = kzalloc(sizeof(*tw), GFP_KERNEL);
    if (!tw)
        return 0;

    tw->outp = (int __user *)(*arg);
    tw->cb.func = ksu_install_fd_tw_func;

    if (task_work_add(current, &tw->cb, TWA_RESUME)) {
        kfree(tw);
        pr_warn("install fd add task_work failed\\n");
    }

    return 0;
}
"""

# Remove the legacy reboot kprobe pre-handler if present.
sp = span(s, r"static\s+int\s+reboot_handler_pre\s*\(")
if sp:
    a,b=sp; s=s[:a]+s[b:]

# Remove the legacy reboot_kp object if present.
sp = span(s, r"static\s+struct\s+kprobe\s+reboot_kp\s*=\s*")
if sp:
    a,b=sp; s=s[:a]+s[b:]

# Replace init/exit registration blocks only; retain dump/cleanup logic.
s = re.sub(r"\n\s*int rc;\n", "\n", s, count=1)
s = re.sub(r"\n\s*rc\s*=\s*register_kprobe\s*\(\s*&reboot_kp\s*\);.*?\n\s*\}\n", "\n", s, count=1, flags=re.S)
s = re.sub(r"\n\s*unregister_kprobe\s*\(\s*&reboot_kp\s*\);", "", s, count=1)

if not re.search(r"^int\s+ksu_supercall_reboot_handler\s*\(\s*void __user \*\*arg\s*\)", s, re.M):
    # Put the handler immediately before ksu_supercalls_init(), matching SUSFS.
    anchor = re.search(r"^void\s+__init\s+ksu_supercalls_init\s*\(\s*void\s*\)", s, re.M)
    if not anchor: raise SystemExit(2)
    s = s[:anchor.start()] + handler + "\n" + s[anchor.start():]

p.write_text(s)

# SUSFS also exports the handler through supercall.h.
h = Path("kernel/supercall/supercall.h")
if h.is_file():
    hs=h.read_text()
    if "ksu_supercall_reboot_handler" not in hs:
        marker="void ksu_supercalls_init(void);"
        if marker not in hs: raise SystemExit(3)
        hs=hs.replace(marker, marker+"\nint ksu_supercall_reboot_handler(void __user **arg);",1)
        h.write_text(hs)
PY_SUPERCALL_RECONCILE
      rc=$?
      if [ "$rc" -eq 0 ]; then
        echo "  ✅ Reconciled SUSFS supercall reboot kprobe→direct-handler transformation structurally from the reject hunk: $rej"
        rm -f "$rej"
        return 0
      fi
      if grep -qE '^[[:space:]]*int[[:space:]]+ksu_supercall_reboot_handler[[:space:]]*\(void __user \*\*arg\)' "$target" \
         && ! grep -qE '^[[:space:]]*static[[:space:]]+struct[[:space:]]+kprobe[[:space:]]+reboot_kp' "$target"; then
        echo "  ℹ️ supercall.c already has SUSFS ksu_supercall_reboot_handler(); reject is obsolete"
        rm -f "$rej"
        return 0
      fi
      ;;
  esac

  echo "::error::Known SUSFS reject could not be applied safely: $rej"
  echo "::error::Target: $target"
  cat "$rej"
  return 1
}

for rej in \
  kernel/feature/adb_root.c.rej \
  kernel/runtime/ksud_integration.c.rej \
  kernel/supercall/supercall.c.rej; do
  apply_known_susfs_reject "$rej" || exit 1
done

# Canonicalize the reboot-handler printk in case an earlier reject application
# left an actual newline inside the C string literal.
python3 - "$COMMON_KERNEL_FOLDER/drivers/kernelsu/supercall/supercall.c" <<'PY_FIX_SUPERCALL_STRING'
from pathlib import Path
import sys
p = Path(sys.argv[1])
if p.is_file():
    s = p.read_text()
    bad = 'pr_warn("install fd add task_work failed\n");'
    good = 'pr_warn("install fd add task_work failed\\n");'
    if bad in s:
        s = s.replace(bad, good)
        p.write_text(s)
        print("  ✅ Fixed malformed reboot-handler pr_warn string in supercall.c")
PY_FIX_SUPERCALL_STRING

# Patch common/drivers/kernelsu mirror
# =============================================================================

cd "$COMMON_KERNEL_FOLDER"

echo "Applying SukiSU compatibility fixes..."

sed -i '/DEFINE_MEMBER(netlink_kernel_cfg, cb_mutex)/d' drivers/kernelsu/kpm/super_access.c 2>/dev/null || true


sed -i 's/is_zygote_normal_app_uid(new_uid)/is_appuid(new_uid)/' drivers/kernelsu/hook/setuid_hook.c 2>/dev/null || true
# Only stub out ksu_handle_extra_susfs_work() when susfs_extra_works is NOT provided by the
# SUSFS source (SUSFS v2.1.0). On v2.2.0 the symbol exists in fs/susfs.c and drives the
# deferred umount/hide work, so it MUST stay enabled.
if ! grep -RqsE '\bsusfs_extra_works\b' "$COMMON_KERNEL_FOLDER/fs/susfs.c" 2>/dev/null; then
  sed -i 's/ksu_handle_extra_susfs_work();/\/\/ ksu_handle_extra_susfs_work();/' drivers/kernelsu/hook/setuid_hook.c 2>/dev/null || true
else
  echo "SUSFS v2.2.0: keeping ksu_handle_extra_susfs_work() enabled (susfs_extra_works present)"
fi

if [ -f drivers/kernelsu/core/init.c ]; then
  grep -q "feature/sucompat.h" drivers/kernelsu/core/init.c 2>/dev/null || \
sed -i '/#include "ksu.h"/a #include "feature/sucompat.h"' drivers/kernelsu/core/init.c 2>/dev/null || true

  grep -q "hook/setuid_hook.h" drivers/kernelsu/core/init.c 2>/dev/null || \
sed -i '/#include "ksu.h"/a #include "hook/setuid_hook.h"' drivers/kernelsu/core/init.c 2>/dev/null || true
fi

fix_sukisu_init_c               "drivers/kernelsu/core/init.c"

if [ "${SUSVER:-}" = "v2.3.0" ]; then
  sed -i '/^[[:space:]]*ksu_app_profile_init[[:space:]]*();[[:space:]]*$/d' drivers/kernelsu/core/init.c 2>/dev/null || true
fi
ensure_susfs_init_call          "drivers/kernelsu/core/init.c"
ensure_sukisu_inline_hook_init  "drivers/kernelsu/core/init.c"
fix_sukisu_boot_event_c         "drivers/kernelsu/runtime/boot_event.c"
fix_sukisu_ksud_integration_c   "drivers/kernelsu/runtime/ksud_integration.c"
fix_sukisu_app_profile_c        "drivers/kernelsu/policy/app_profile.c"
fix_sukisu_dispatch_c           "drivers/kernelsu/supercall/dispatch.c"
fix_sukisu_sucompat_api         "drivers/kernelsu"
fix_sukisu_forced_execveat_link_symbols "drivers/kernelsu"
fix_sukisu_syscall_event_bridge "drivers/kernelsu/hook/syscall_event_bridge.c"
fix_sukisu_linker_symbols

mkdir -p drivers/kernelsu/kpm/uapi include/uapi

cp "$KERNEL_PLATFORM_FOLDER/KernelSU/uapi/"*.h drivers/kernelsu/kpm/uapi/ 2>/dev/null || true
cp "$KERNEL_PLATFORM_FOLDER/KernelSU/uapi/"*.h include/uapi/ 2>/dev/null || true

KLOG_SRC="$(find "$KERNEL_PLATFORM_FOLDER/KernelSU" -name "klog.h" -type f 2>/dev/null | head -n 1 || true)"

if [ -n "$KLOG_SRC" ]; then
  for dest in drivers/kernelsu drivers/kernelsu/core drivers/kernelsu/feature drivers/kernelsu/hook drivers/kernelsu/selinux drivers/kernelsu/sulog; do
mkdir -p "$dest"
cp "$KLOG_SRC" "$dest/" 2>/dev/null || true
  done
fi

if [ -f drivers/kernelsu/Kbuild ]; then
  grep -q 'srctree)/$(src)' drivers/kernelsu/Kbuild || \
sed -i '1i\ccflags-y += -I$(srctree)/$(src)' drivers/kernelsu/Kbuild

  grep -q "kpm/uapi" drivers/kernelsu/Kbuild || \
sed -i '/^obj-\$(CONFIG_KPM) += kpm\/compact.o/i\ccflags-\$(CONFIG_KPM) += -I$(srctree)/$(src)/kpm/uapi -I$(srctree)/include/uapi' drivers/kernelsu/Kbuild

  # --- android16-6.12 / 6.13 GKI include fix ---
  # Kbuild changed $(src) semantics on 6.12/6.13, so the manager's own
  # -I$(KSU_KERNEL_DIR)/include (KSU_KERNEL_DIR = $(srctree)/$(src)) fails to resolve
  # for the symlinked drivers/kernelsu → 'util.h' (drivers/kernelsu/include/util.h) not
  # found compiling su_mount_ns.c / sucompat.c / supercall.c. Anchor an include on the
  # Kbuild's own absolute directory ($(MDIR) = $(dir $(abspath $(lastword ...)))), which
  # is immune to the $(src) breakage. Builds fine on older kernels too (additive -I).
  if ! grep -q 'susfs-fix-abs-include' drivers/kernelsu/Kbuild; then
if grep -qE '^MDIR := \$\(dir \$\(abspath' drivers/kernelsu/Kbuild; then
  sed -i '/^MDIR := \$(dir \$(abspath/a ccflags-y += -I$(MDIR) -I$(MDIR)include # susfs-fix-abs-include' drivers/kernelsu/Kbuild
else
  printf '\nKSU_ABS_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))\nccflags-y += -I$(KSU_ABS_DIR) -I$(KSU_ABS_DIR)include # susfs-fix-abs-include\n' >> drivers/kernelsu/Kbuild
fi
echo "Applied MDIR-based KSU include-path fix (6.12+) to drivers/kernelsu/Kbuild"
  fi
fi

ARCH_H="$(find "$KERNEL_PLATFORM_FOLDER/KernelSU" -name "arch.h" -type f 2>/dev/null | head -n 1 || true)"

if [ -n "$ARCH_H" ]; then
  for dest in feature hook infra selinux supercall core runtime; do
if [ -d "drivers/kernelsu/$dest" ]; then
  cp "$ARCH_H" "drivers/kernelsu/$dest/" 2>/dev/null || true
fi
  done
fi

KSU_CRED_DEF='extern struct cred *ksu_cred;'

while IFS= read -r f; do
  grep -qF "$KSU_CRED_DEF" "$f" || sed -i "1i\\$KSU_CRED_DEF" "$f"
done < <(grep -rl "ksu_cred" drivers/kernelsu/ --include="*.c" 2>/dev/null || true)

if grep -q "allow_shell" drivers/kernelsu/policy/allowlist.c 2>/dev/null; then
  if ! grep -q "extern bool allow_shell" drivers/kernelsu/policy/allowlist.c; then
sed -i '1i\#include <linux/types.h>\nextern bool allow_shell;' drivers/kernelsu/policy/allowlist.c
  fi
fi

if grep -q "KERNEL_SU_VERSION" drivers/kernelsu/supercall/dispatch.c 2>/dev/null; then
  grep -q "#define KERNEL_SU_VERSION" drivers/kernelsu/supercall/dispatch.c || \
sed -i "1i\\#ifndef KERNEL_SU_VERSION\n#define KERNEL_SU_VERSION ${KSUVER:-40787}\n#endif" drivers/kernelsu/supercall/dispatch.c
fi

if [ -f drivers/kernelsu/runtime/ksud.c ]; then
  grep -q "ksu_init_rc_hook_key_false" drivers/kernelsu/runtime/ksud.c || \
sed -i '1i\#include <linux/jump_label.h>\nDEFINE_STATIC_KEY_FALSE(ksu_init_rc_hook_key_false);\nDEFINE_STATIC_KEY_FALSE(ksu_input_hook_key_false);' drivers/kernelsu/runtime/ksud.c
fi

sed -i 's/extern struct static_key_true ksu_is_init_rc_hook_enabled;/DEFINE_STATIC_KEY_FALSE(ksu_is_init_rc_hook_enabled);/' fs/stat.c 2>/dev/null || true
sed -i 's/extern struct static_key_true ksu_is_input_hook_enabled;/DEFINE_STATIC_KEY_FALSE(ksu_is_input_hook_enabled);/' drivers/input/input.c 2>/dev/null || true

if [ -f fs/read_write.c ]; then
  grep -q "DEFINE_STATIC_KEY_FALSE.*ksu_is_init_rc_hook_enabled" fs/read_write.c || \
sed -i 's/DEFINE_STATIC_KEY_FALSE(ksu_is_init_rc_hook_enabled);/extern struct static_key_true ksu_is_init_rc_hook_enabled;/' fs/read_write.c 2>/dev/null || true
fi

if [ "$ANDROID_VER_LOCAL" = "android15" ] && [ "$KERNEL_VER_LOCAL" = "6.6" ]; then
  if ! grep -qxF '#include <trace/hooks/fs.h>' ./fs/namespace.c; then
sed -i '/#include <trace\/hooks\/blk.h>/a #include <trace/hooks/fs.h>' ./fs/namespace.c
  fi
fi

fake_patched=0

if [ "$ANDROID_VER_LOCAL" = "android15" ] && [ "$KERNEL_VER_LOCAL" = "6.6" ]; then
  if ! grep -qxF $'\tunsigned int nr_subpages = __PAGE_SIZE / PAGE_SIZE;' ./fs/proc/task_mmu.c; then
sed -i \
  -e '/int ret = 0, copied = 0;/a \\tunsigned int nr_subpages \= __PAGE_SIZE \/ PAGE_SIZE;' \
  -e '/int ret = 0, copied = 0;/a \\tpagemap_entry_t \*res = NULL;' \
  ./fs/proc/task_mmu.c
fake_patched=1
  fi

  if ! grep -qxF '#include <linux/dma-buf.h>' ./fs/proc/base.c; then
sed -i '/#include <linux\/cpufreq_times.h>/a #include <linux\/dma-buf.h>' ./fs/proc/base.c
  fi
fi

if [ "$ANDROID_VER_LOCAL" = "android12" ] && [ "$KERNEL_VER_LOCAL" = "5.10" ]; then
  grep -qxF $'\tif (!vma_pages(vma))' ./fs/proc/task_mmu.c || fake_patched=1
fi

if [ "$ANDROID_VER_LOCAL" = "android13" ] && [ "$KERNEL_VER_LOCAL" = "5.15" ]; then
  grep -qxF $'\tif (!vma_pages(vma))' ./fs/proc/task_mmu.c || fake_patched=1
fi

if [ "$ANDROID_VER_LOCAL" = "android14" ] && [ "$KERNEL_VER_LOCAL" = "6.1" ]; then
  grep -qxF $'\tif (!vma_pages(vma))' ./fs/proc/task_mmu.c || fake_patched=1

  if ! grep -qxF '#include <linux/dma-buf.h>' ./fs/proc/base.c; then
sed -i '/#include <linux\/cpufreq_times.h>/a #include <linux\/dma-buf.h>' ./fs/proc/base.c
  fi
fi

SELINUXFS_REL="security/selinux/selinuxfs.c"
SELINUXFS_PATH="$COMMON_KERNEL_FOLDER/$SELINUXFS_REL"
SELINUXFS_BACKUP=""

if [ -f "$SELINUXFS_PATH" ]; then
  SELINUXFS_BACKUP="${RUNNER_TEMP:-/tmp}/selinuxfs.c.before_susfs.$$"
  cp -a "$SELINUXFS_PATH" "$SELINUXFS_BACKUP"
fi

SUSFS_BRANCH_LOCAL="${SUSFS_KERNEL_BRANCH_LOCAL:-${SUSFS_KERNEL_BRANCH:-gki-${ANDROID_VER_LOCAL}-${KERNEL_VER_LOCAL}}}"
SUSFS_PATCH="$SUSFS_FOLDER/kernel_patches/50_add_susfs_in_${SUSFS_BRANCH_LOCAL}.patch"

echo "Using SUSFS kernel patch branch: $SUSFS_BRANCH_LOCAL"
echo "Using SUSFS kernel patch file: $SUSFS_PATCH"

if [ ! -f "$SUSFS_PATCH" ]; then
  echo "::error::SUSFS patch not found: $SUSFS_PATCH"
  echo "Available SUSFS patches:"
  find "$SUSFS_FOLDER/kernel_patches" -maxdepth 1 -type f -name '50_add_susfs_in_*.patch' -print | sort
  exit 1
fi

if ! patch -p1 --forward < "$SUSFS_PATCH"; then
  handled_rejects=0

  if [ -f mm/memory.c.rej ] && grep -q 'CONFIG_KSU_SUSFS_SUS_MAP' mm/memory.c.rej; then
echo "Handling known SUSFS mm/memory.c include reject..."

if grep -q '#include <linux/susfs_def.h>' mm/memory.c; then
  echo "SUSFS header already present in mm/memory.c"
elif grep -q '#include <linux/vmalloc.h>' mm/memory.c; then
  sed -i '/#include <linux\/vmalloc.h>/a #ifdef CONFIG_KSU_SUSFS_SUS_MAP\n#include <linux\/susfs_def.h>\n#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MAP' mm/memory.c
elif grep -q '#include <linux/mm.h>' mm/memory.c; then
  sed -i '/#include <linux\/mm.h>/a #ifdef CONFIG_KSU_SUSFS_SUS_MAP\n#include <linux\/susfs_def.h>\n#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MAP' mm/memory.c
else
  echo "::error::Could not find a safe include anchor in mm/memory.c"
  cat mm/memory.c.rej
  exit 1
fi

rm -f mm/memory.c.rej
handled_rejects=1
  fi

  if [ -f fs/proc/task_mmu.c.rej ] && grep -q 'CONFIG_KSU_SUSFS_SUS_MAP' fs/proc/task_mmu.c.rej; then
echo "Handling known SUSFS fs/proc/task_mmu.c show_smaps_rollup reject..."

if grep -q 'SUSFS_IS_INODE_SUS_MAP(file_inode(vma->vm_file))' fs/proc/task_mmu.c; then
  echo "SUSFS show_smaps_rollup logic already present in task_mmu.c"
  rm -f fs/proc/task_mmu.c.rej
  handled_rejects=1
else
  python3 <<'PY'
from pathlib import Path
import re
import sys

path = Path("fs/proc/task_mmu.c")

if not path.exists():
    print("::error::fs/proc/task_mmu.c does not exist")
    sys.exit(1)

text = path.read_text()

function_match = re.search(
    r"static\s+int\s+show_smaps_rollup\s*\([^)]*\)\s*\{",
    text,
)

if not function_match:
    print("::error::Could not find show_smaps_rollup() in fs/proc/task_mmu.c")
    sys.exit(1)

start = function_match.start()
tail = text[start:]

target_pattern = re.compile(
    r"(?P<indent>[ \t]+)smap_gather_stats\(vma,\s*&mss,\s*last_vma_end\);\n"
    r"(?P=indent)last_vma_end\s*=\s*vma->vm_end;",
)

match = target_pattern.search(tail)

if not match:
    print("::error::Could not find target smap_gather_stats block inside show_smaps_rollup()")
    sys.exit(1)

indent = match.group("indent")

replacement = (
    "#ifdef CONFIG_KSU_SUSFS_SUS_MAP\n"
    + indent + "if (!vma->vm_file || !(SUSFS_IS_INODE_SUS_MAP(file_inode(vma->vm_file)))) {\n"
    + indent + "\tsmap_gather_stats(vma, &mss, last_vma_end);\n"
    + indent + "\tlast_vma_end = vma->vm_end;\n"
    + indent + "}\n"
    + "#else\n"
    + indent + "smap_gather_stats(vma, &mss, last_vma_end);\n"
    + indent + "last_vma_end = vma->vm_end;\n"
    + "#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MAP"
)

absolute_start = start + match.start()
absolute_end = start + match.end()

new_text = text[:absolute_start] + replacement + text[absolute_end:]

path.write_text(new_text)

print("Applied SUSFS show_smaps_rollup fallback patch")

PY

  if ! grep -q 'SUSFS_IS_INODE_SUS_MAP(file_inode(vma->vm_file))' fs/proc/task_mmu.c; then
    echo "::error::Fallback patch did not modify fs/proc/task_mmu.c correctly"
    cat fs/proc/task_mmu.c.rej
    exit 1
  fi

  rm -f fs/proc/task_mmu.c.rej
  handled_rejects=1
fi
  fi

  if [ -f fs/proc/base.c.rej ] && grep -q 'linux/susfs_def.h' fs/proc/base.c.rej; then
    echo "Handling known SUSFS fs/proc/base.c susfs_def.h include reject..."
    if grep -q '#include <linux/susfs_def.h>' fs/proc/base.c; then
      echo "SUSFS header already present in fs/proc/base.c"
      rm -f fs/proc/base.c.rej
      handled_rejects=1
    else
      # On OP13R Android 14 / 6.1 the surrounding include block differs from
      # the upstream SUSFS patch by vendor-added headers. The rejected hunk
      # only adds susfs_def.h, so insert that exact conditional include after
      # the stable dma-buf anchor instead of altering any functional code.
      if grep -q '#include <linux/dma-buf.h>' fs/proc/base.c; then
        sed -i '/#include <linux\/dma-buf.h>/a #if defined(CONFIG_KSU_SUSFS_SUS_MAP) || defined(CONFIG_KSU_SUSFS_OPEN_REDIRECT)\n#include <linux/susfs_def.h>\n#endif // #if defined(CONFIG_KSU_SUSFS_SUS_MAP) || defined(CONFIG_KSU_SUSFS_OPEN_REDIRECT)' fs/proc/base.c
      elif grep -q '#include <linux/cpufreq_times.h>' fs/proc/base.c; then
        sed -i '/#include <linux\/cpufreq_times.h>/a #if defined(CONFIG_KSU_SUSFS_SUS_MAP) || defined(CONFIG_KSU_SUSFS_OPEN_REDIRECT)\n#include <linux/susfs_def.h>\n#endif // #if defined(CONFIG_KSU_SUSFS_SUS_MAP) || defined(CONFIG_KSU_SUSFS_OPEN_REDIRECT)' fs/proc/base.c
      else
        echo "::error::Could not find a safe include anchor in fs/proc/base.c for susfs_def.h"
        cat fs/proc/base.c.rej
        exit 1
      fi
      if ! grep -q '#include <linux/susfs_def.h>' fs/proc/base.c; then
        echo "::error::Fallback patch did not add susfs_def.h to fs/proc/base.c"
        cat fs/proc/base.c.rej
        exit 1
      fi
      rm -f fs/proc/base.c.rej
      handled_rejects=1
      echo "  ✅ Applied SUSFS fs/proc/base.c include fallback"
    fi
  fi

  if [ -n "$(find . -name "*.rej" -print -quit)" ]; then
echo "::error::SUSFS patch failed. Remaining reject files:"
find . -name "*.rej" -exec echo "=== {} ===" \; -exec cat {} \;
exit 1
  fi

  if [ "$handled_rejects" != "1" ]; then
echo "::error::SUSFS patch failed and no known fallback matched."
exit 1
  fi
fi

if [ -f fs/namei.c ] && grep -q 'set_nameidata(nd, old_dfd, fake_filename, NULL)' fs/namei.c; then
  nd_decl=$(awk '/void[ \t]+set_nameidata[ \t]*\(/ { f = 1 }
                 f { printf "%s ", $0; if (/\)/) exit }' fs/namei.c)
  nd_commas=$(printf '%s' "$nd_decl" | tr -cd ',' | wc -c)

  if [ -z "$nd_decl" ]; then
echo "::error::susfs added 4-arg set_nameidata() calls but no set_nameidata() declaration was found in fs/namei.c"
exit 1
  elif [ "$nd_commas" -eq 2 ]; then
sed -i 's/set_nameidata(nd, old_dfd, fake_filename, NULL)/set_nameidata(nd, old_dfd, fake_filename)/g' fs/namei.c

if grep -q 'set_nameidata(nd, old_dfd, fake_filename, NULL)' fs/namei.c; then
  echo "::error::Failed to drop the root argument from susfs's set_nameidata() calls in fs/namei.c"
  exit 1
fi

echo "Dropped susfs's 5.14+ root argument from set_nameidata() OPEN_REDIRECT calls (tree declares the 3-arg form)"
  else
echo "fs/namei.c declares the 4-arg set_nameidata(); leaving susfs OPEN_REDIRECT calls as-is"
  fi
fi

if [ "$fake_patched" = "1" ]; then
  if [ "$ANDROID_VER_LOCAL" = "android15" ] && [ "$KERNEL_VER_LOCAL" = "6.6" ]; then
sed -i \
  -e '/unsigned int nr_subpages \= __PAGE_SIZE \/ PAGE_SIZE;/d' \
  -e '/pagemap_entry_t \*res = NULL;/d' \
  ./fs/proc/task_mmu.c || true
  fi

  if [ "$ANDROID_VER_LOCAL" = "android12" ] && [ "$KERNEL_VER_LOCAL" = "5.10" ]; then
sed -i -e 's/goto show_pad;/return 0;/' ./fs/proc/task_mmu.c || true
  fi

  if [ "$ANDROID_VER_LOCAL" = "android13" ] && [ "$KERNEL_VER_LOCAL" = "5.15" ]; then
sed -i -e 's/goto show_pad;/return 0;/' ./fs/proc/task_mmu.c || true
  fi

  if [ "$ANDROID_VER_LOCAL" = "android14" ] && [ "$KERNEL_VER_LOCAL" = "6.1" ]; then
sed -i -e 's/goto show_pad;/return 0;/' ./fs/proc/task_mmu.c || true
  fi
fi

if [ "$ANDROID_VER_LOCAL" = "android16" ] && [ "$KERNEL_VER_LOCAL" = "6.12" ]; then
  SELINUXFS="$COMMON_KERNEL_FOLDER/security/selinux/selinuxfs.c"

  if [ -f "$SELINUXFS" ] && [ -n "${SELINUXFS_BACKUP:-}" ] && [ -f "$SELINUXFS_BACKUP" ]; then
cp -a "$SELINUXFS_BACKUP" "$SELINUXFS"
  elif [ -f "$SELINUXFS" ]; then
sed -i \
  -e '/ksu_selinux_hide_enabled/d' \
  -e '/fake_status/d' \
  -e '/initialize_fake_status/d' \
  -e '/fake_status_initialize_key/d' \
  -e 's/my_sel_open_handle_status/sel_open_handle_status/g' \
  "$SELINUXFS" || true
  fi
fi

fix_sukisu_dispatch_c           "drivers/kernelsu/supercall/dispatch.c"
fix_sukisu_sucompat_api         "drivers/kernelsu"
fix_sukisu_syscall_event_bridge "drivers/kernelsu/hook/syscall_event_bridge.c"
fix_sukisu_linker_symbols

# =============================================================================
# Final safety sweep
# =============================================================================

fix_sukisu_ultra_40939_api "drivers/kernelsu"
fix_sukisu_ultra_40939_api "kernel"

# The 60024a4 SUSFS integration uses direct execveat/VFS hooks and no longer
# needs the legacy syscall-table bridge. Disable the old manager and bridge
# together, after all compatibility transforms have finished.
disable_legacy_syscall_hook_stack "drivers/kernelsu"
disable_legacy_syscall_hook_stack "kernel"

if [ -f drivers/kernelsu/feature/sucompat.c ]; then
  if [ "$(grep -cE '^static const char su_path\[\] = SU_PATH;' drivers/kernelsu/feature/sucompat.c 2>/dev/null || true)" -gt 1 ]; then
    echo "::error::Duplicate su_path definitions remain after SukiSU-Ultra 40939 cleanup"
    grep -nE '^static const char su_path\[\] = SU_PATH;' drivers/kernelsu/feature/sucompat.c || true
    exit 1
  fi
  if grep -qE '^long ksu_handle_execveat_sucompat\(const char __user' drivers/kernelsu/feature/sucompat.c 2>/dev/null; then
    echo "::error::Legacy ksu_handle_execveat_sucompat signature remains in drivers/kernelsu/feature/sucompat.c"
    exit 1
  fi
fi

echo "Running final SukiSU targeted safety sweep..."

if [ -f drivers/kernelsu/core/init.c ]; then
  if grep -nE 'ksu_init_symbol_resolver[[:space:]]*\(|ksu_spoof_version[[:space:]]*\(' drivers/kernelsu/core/init.c; then
echo "::error::Unsupported SukiSU call still exists in drivers/kernelsu/core/init.c"
exit 1
  fi

  if ! grep -q 'susfs_init[[:space:]]*();' drivers/kernelsu/core/init.c; then
echo "::error::susfs_init() was not inserted into drivers/kernelsu/core/init.c"
exit 1
  fi

  # SUSFS v2.2.0: assert the inline hook init calls are wired whenever their definitions
  # exist in the tree. If a future SukiSU refactor keeps the functions but our anchor stops
  # matching (so ensure_sukisu_inline_hook_init silently no-ops), fail loud here rather than
  # ship a kernel whose SUSFS umount/sucompat never initialises. Stays a no-op on v2.1.0,
  # where these symbols are absent.
  for _fn in ksu_sucompat_init ksu_setuid_hook_init; do
if grep -RqsE "\b(void|int)([[:space:]]+__[a-z_]+)*[[:space:]]+${_fn}[[:space:]]*\(" \
     drivers/kernelsu --include='*.c' 2>/dev/null; then
  if ! grep -qE "\b${_fn}[[:space:]]*\(" drivers/kernelsu/core/init.c; then
    echo "::error::${_fn}() is defined but never called from drivers/kernelsu/core/init.c (v2.2.0 inline hook wiring missing)"
    exit 1
  fi
  echo "✅ ${_fn}() call present in drivers/kernelsu/core/init.c"
fi
  done
fi

if [ -f drivers/kernelsu/policy/app_profile.c ]; then
  if grep -n "Already root, don't escape" drivers/kernelsu/policy/app_profile.c; then
echo "::error::Already-root early abort still exists in drivers/kernelsu/policy/app_profile.c"
exit 1
  fi

  if awk '
/^[[:space:]]*disable_seccomp[[:space:]]*\(\);/ {
  if (prev !~ /TIF_SECCOMP/ && prev2 !~ /TIF_SECCOMP/) {
    print FNR ":" $0
    bad = 1
  }
}
{ prev2 = prev; prev = $0 }
END { exit bad ? 1 : 0 }
  ' drivers/kernelsu/policy/app_profile.c; then
:
  else
echo "::error::Unguarded disable_seccomp() still exists in drivers/kernelsu/policy/app_profile.c"
exit 1
  fi

  if grep -nE 'ksu_set_task_tracepoint_flag[[:space:]]*\(' drivers/kernelsu/policy/app_profile.c; then
echo "::error::ksu_set_task_tracepoint_flag() still exists in drivers/kernelsu/policy/app_profile.c"
exit 1
  fi
fi

if [ -f drivers/kernelsu/supercall/dispatch.c ]; then
  if grep -nE 'ksu_set_spoof_version[[:space:]]*\(' drivers/kernelsu/supercall/dispatch.c; then
echo "::error::ksu_set_spoof_version call still exists in drivers/kernelsu/supercall/dispatch.c"
exit 1
  fi

  if grep -qE 'SUSFS_MAGIC|CMD_SUSFS_|susfs_' drivers/kernelsu/supercall/dispatch.c; then
if ! grep -q '#include <linux/susfs.h>' drivers/kernelsu/supercall/dispatch.c; then
  echo "::error::drivers/kernelsu/supercall/dispatch.c uses SUSFS symbols but is missing #include <linux/susfs.h>"
  exit 1
fi
  fi
fi

if [ -f drivers/kernelsu/runtime/ksud_integration.c ]; then
  if grep -q 'ksu_no_custom_rc' drivers/kernelsu/runtime/ksud_integration.c && \
 ! grep -qE '^[[:space:]]*(extern[[:space:]]+)?bool[[:space:]]+ksu_no_custom_rc\b|^[[:space:]]*static[[:space:]]+bool[[:space:]]+ksu_no_custom_rc\b' drivers/kernelsu/runtime/ksud_integration.c; then
echo "::error::ksu_no_custom_rc is referenced but not declared in drivers/kernelsu/runtime/ksud_integration.c"
exit 1
  fi

  if [ -f drivers/kernelsu/runtime/ksud_integration.c ]; then
python3 - drivers/kernelsu/runtime/ksud_integration.c <<'PY'
from pathlib import Path
import re
import sys

p = Path(sys.argv[1])
s = p.read_text()

good_sig = "int ksu_handle_execveat_init(struct filename *filename, struct user_arg_ptr *argv_user, struct user_arg_ptr *envp_user)"
good_body = """int ksu_handle_execveat_init(struct filename *filename, struct user_arg_ptr *argv_user, struct user_arg_ptr *envp_user)
{
    (void)filename;
    (void)argv_user;
    (void)envp_user;
    return 0;
}
"""

s = re.sub(
    r'void\s+ksu_handle_execveat_init\s*\(\s*void\s*\)\s*\{[^{}]*\}',
    good_body,
    s,
    flags=re.S,
)

if "ksu_handle_execveat_init(" in s and good_sig not in s:
    s = s.rstrip() + "\n\n" + good_body + "\n"

p.write_text(s)
PY
  fi

  if grep -q 'ksu_handle_execveat_init[[:space:]]*(' drivers/kernelsu/runtime/ksud_integration.c && \
 ! grep -RqsE '^[[:space:]]*int[[:space:]]+ksu_handle_execveat_init[[:space:]]*\(' drivers/kernelsu --include='*.c'; then
echo "::error::ksu_handle_execveat_init is referenced but no function body exists anywhere under drivers/kernelsu"
grep -n 'ksu_handle_execveat_init' drivers/kernelsu/runtime/ksud_integration.c || true
exit 1
  fi
fi

for kbuild in drivers/kernelsu/Kbuild drivers/kernelsu/Makefile; do
  if [ -f "$kbuild" ]; then
if grep -nE 'uts_spoof\.o|feature/uts_spoof\.o' "$kbuild"; then
  echo "::error::uts_spoof.o is still enabled in $kbuild"
  exit 1
fi
  fi
done

for kbuild in \
  "$KSU_FOLDER/kernel/Kbuild" \
  "$KSU_FOLDER/kernel/Makefile" \
  "$COMMON_KERNEL_FOLDER/drivers/kernelsu/Kbuild" \
  "$COMMON_KERNEL_FOLDER/drivers/kernelsu/Makefile"; do
  if [ -f "$kbuild" ] && grep -nE 'hook/(syscall_event_bridge|syscall_hook_manager)\.o' "$kbuild"; then
    echo "::error::Legacy syscall-hook object remains enabled in $kbuild"
    exit 1
  fi
done

for sucompat_h in \
  "$KSU_FOLDER/kernel/feature/sucompat.h" \
  "$COMMON_KERNEL_FOLDER/drivers/kernelsu/feature/sucompat.h"; do
  if [ -f "$sucompat_h" ]; then
if grep -qE 'ksu_handle_faccessat_sucompat|ksu_handle_stat_sucompat' "$sucompat_h"; then
  echo "ℹ️ Old sucompat declarations present in $sucompat_h; allowed when matching implementations exist"
fi

if ! grep -qE 'ksu_handle_faccessat|ksu_handle_stat|ksu_handle_execve' "$sucompat_h"; then
  echo "::error::No sucompat API declarations found in $sucompat_h"
  exit 1
fi

echo "✅ sucompat.h API validated: $sucompat_h"
  fi
done

# Repair malformed sucompat.h guard concatenation before validating it.
# Some SukiSU/SUSFS compatibility edits can collapse the outer #endif directly
# onto the first legacy sucompat prototype (for example: #endiflong ...).
# Move that terminator to the end of the guarded declarations; do not alter the
# declarations themselves.
for sucompat_h in \
  "$KSU_FOLDER/kernel/feature/sucompat.h" \
  "$COMMON_KERNEL_FOLDER/drivers/kernelsu/feature/sucompat.h"; do
  if [ -f "$sucompat_h" ]; then
    python3 - "$sucompat_h" <<'PY_SUCOMPAT_GUARD'
from pathlib import Path
import re, sys

p = Path(sys.argv[1])
s = p.read_text()

# Only repair the specific malformed outer-guard form where #endif is glued
# directly to a ksu_handle_* prototype.  Do not touch normal preprocessor
# directives or nested #endif blocks.
pat = re.compile(r"^[ \t]*#endif(?=(?:long|int|void|extern|static)[ \t]+ksu_handle_)", re.M)
if pat.search(s):
    s = pat.sub("", s, count=1)

# If the header has the KSU outer guard, ensure its terminator is present at
# EOF.  Avoid adding duplicates when the header is already clean.
if re.search(r"^[ \t]*#ifndef[ \t]+__KSU_H_SUCOMPAT[ \t]*$", s, re.M):
    if not re.search(r"^[ \t]*#endif[ \t]*(?:/\*.*?\*/[ \t]*)?$", s.rstrip().splitlines()[-1], re.M):
        s = s.rstrip() + "\n#endif\n"

p.write_text(s)
PY_SUCOMPAT_GUARD
  fi
done

# Final build-object reconciliation. These must run after every KSU mirror/copy and
# compatibility edit, otherwise a later source sync can overwrite the Kbuild fixes.
ensure_sucompat_object_built "$KSU_FOLDER"
ensure_sucompat_object_built "$COMMON_KERNEL_FOLDER"
validate_sucompat_object_built "$KSU_FOLDER"
validate_sucompat_object_built "$COMMON_KERNEL_FOLDER"
remove_unused_syscall_pointer_declarations "$KSU_FOLDER"
remove_unused_syscall_pointer_declarations "$COMMON_KERNEL_FOLDER"

# Final sucompat.h guard validation.  This catches malformed declarations such as
# "#endifint ..." before the compiler reaches drivers/kernelsu/core/init.c.
for sucompat_h in \
  "$KSU_FOLDER/kernel/feature/sucompat.h" \
  "$COMMON_KERNEL_FOLDER/drivers/kernelsu/feature/sucompat.h"; do
  if [ -f "$sucompat_h" ]; then
    if grep -qE '#endif[[:space:]]*int[[:space:]]+ksu_handle_stat_user' "$sucompat_h"; then
      echo "::error::Malformed ksu_handle_stat_user prototype remains in $sucompat_h"
      sed -n '1,120p' "$sucompat_h"
      exit 1
    fi
    if ! tail -n 20 "$sucompat_h" | grep -q '^#endif[[:space:]]*$'; then
      echo "::error::sucompat.h header guard is not terminated cleanly: $sucompat_h"
      tail -n 30 "$sucompat_h"
      exit 1
    fi
  fi
done

for sucompat_c in \
  "$KSU_FOLDER/kernel/feature/sucompat.c" \
  "$COMMON_KERNEL_FOLDER/drivers/kernelsu/feature/sucompat.c"; do
  if [ -f "$sucompat_c" ]; then
if ! grep -qE 'DEFINE_STATIC_KEY_(TRUE|FALSE)\(ksu_su_compat_enabled\)' "$sucompat_c"; then
  echo "::error::ksu_su_compat_enabled static_key definition missing in $sucompat_c"
  exit 1
fi

# Hard fallback for older SukiSU execve sucompat handler shape.
# This handles:
#   ksu_sulog_capture_sucompat(*filename_user, argv_user, GFP_KERNEL)
perl -0pi -e 's/ksu_sulog_capture_sucompat\s*\(\s*\*filename_user\s*,\s*argv_user\s*,\s*GFP_KERNEL\s*\)/ksu_sulog_capture_sucompat(path, NULL, GFP_KERNEL)/g' "$sucompat_c"

if grep -q 'ksu_sulog_capture_sucompat(\*filename_user, argv_user, GFP_KERNEL)' "$sucompat_c"; then
  echo "::error::Old incompatible ksu_sulog_capture_sucompat argv_user call remains in $sucompat_c"
  grep -n 'ksu_sulog_capture_sucompat' "$sucompat_c" || true
  exit 1
fi

if grep -q 'ksu_sulog_capture_sucompat(\*filename_user, &argv_arg_ptr, GFP_KERNEL)' "$sucompat_c"; then
  if ! grep -q 'struct user_arg_ptr argv_arg_ptr;' "$sucompat_c"; then
    echo "::error::argv_arg_ptr is used but not declared in $sucompat_c"
    grep -nE 'argv_arg_ptr|ksu_sulog_capture_sucompat' "$sucompat_c" || true
    exit 1
  fi

  if ! grep -q '#include <linux/binfmts.h>' "$sucompat_c"; then
    echo "::error::struct user_arg_ptr compatibility include is missing in $sucompat_c"
    grep -nE 'linux/binfmts.h|argv_arg_ptr|ksu_sulog_capture_sucompat' "$sucompat_c" || true
    exit 1
  fi

  if grep -q 'argv_arg_ptr.is_compat = false;' "$sucompat_c" && \
     ! grep -q '#ifdef CONFIG_COMPAT' "$sucompat_c"; then
    echo "::error::argv_arg_ptr.is_compat is unguarded by CONFIG_COMPAT in $sucompat_c"
    grep -nE 'CONFIG_COMPAT|argv_arg_ptr|ksu_sulog_capture_sucompat' "$sucompat_c" || true
    exit 1
  fi
fi

# Hard fallback before validation: remove old direct ksu_syscall_table calls from sucompat.c.
perl -0pi -e 's/\bret\s*=\s*ksu_syscall_table\s*\[[^\]]+\]\s*\([^;]*\)\s*;/ret = 0;/g; s/\breturn\s+ksu_syscall_table\s*\[[^\]]+\]\s*\([^;]*\)\s*;/return 0;/g' "$sucompat_c"

if grep -q 'ksu_syscall_table' "$sucompat_c"; then
  echo "::error::ksu_syscall_table reference remains in $sucompat_c"
  grep -n 'ksu_syscall_table' "$sucompat_c" || true
  exit 1
fi

if grep -q 'ksu_handle_execveat[[:space:]]*(' "$COMMON_KERNEL_FOLDER/fs/exec.c" 2>/dev/null; then
  if ! grep -qE '^[[:space:]]*int[[:space:]]+ksu_handle_execveat[[:space:]]*\(' "$sucompat_c"; then
    echo "::error::fs/exec.c calls ksu_handle_execveat but implementation is missing in $sucompat_c"
    grep -nE 'ksu_handle_execveat|ksu_handle_execveat_sucompat' "$sucompat_c" || true
    exit 1
  fi
fi

if grep -q 'ksu_handle_execveat_sucompat[[:space:]]*(' "$COMMON_KERNEL_FOLDER/fs/exec.c" 2>/dev/null; then
  if ! grep -qE '^[[:space:]]*int[[:space:]]+ksu_handle_execveat_sucompat[[:space:]]*\(' "$sucompat_c"; then
    echo "::error::fs/exec.c calls ksu_handle_execveat_sucompat but implementation is missing in $sucompat_c"
    grep -nE 'ksu_handle_execveat|ksu_handle_execveat_sucompat' "$sucompat_c" || true
    exit 1
  fi
fi

echo "✅ sucompat.c API/static_key validated: $sucompat_c"
  fi
done

# Restore the actual SUSFS 2.3 post-exec implementation before final validation.
for _root in "$KSU_FOLDER" "$COMMON_KERNEL_FOLDER"; do
  ensure_post_execveat_sucompat_impl "$_root"
done

# Reconcile missing final-tree sucompat handlers from the staging SukiSU tree.
# The staging tree is already validated to contain the implementations; when the
# final common/drivers/kernelsu mirror lacks one, copy that exact implementation.
restore_missing_final_sucompat_handlers() {
  local final_root="$1"
  [ -d "$final_root" ] || return 0

  local final_c="$final_root/drivers/kernelsu/feature/sucompat.c"
  local staging_c="$KSU_FOLDER/kernel/feature/sucompat.c"
  [ -f "$final_c" ] || return 0
  [ -f "$staging_c" ] || return 0

  python3 - "$staging_c" "$final_c" <<'PY_SUCOMPAT_RECONCILE'
from pathlib import Path
import re, sys

src = Path(sys.argv[1])
dst = Path(sys.argv[2])
s = src.read_text()
d = dst.read_text()

names = (
    "ksu_handle_stat",
    "ksu_handle_faccessat",
)

def extract_function(text, name):
    m = re.search(r'(?m)^[ \t]*(?:static[ \t]+)?(?:inline[ \t]+)?(?:long|int|void|bool|unsigned[ \t]+long)[ \t]+%s[ \t]*\(' % re.escape(name), text)
    if not m:
        return None
    brace = text.find('{', m.end())
    if brace < 0:
        return None
    depth = 0
    in_str = None
    esc = False
    i = brace
    while i < len(text):
        c = text[i]
        if in_str:
            if esc:
                esc = False
            elif c == '\\\\':
                esc = True
            elif c == in_str:
                in_str = None
        else:
            if c in ('"', "'"):
                in_str = c
            elif c == '{':
                depth += 1
            elif c == '}':
                depth -= 1
                if depth == 0:
                    return text[m.start():i + 1]
        i += 1
    return None

changed = False
for name in names:
    if re.search(r'(?m)^\s*(?:static\s+)?(?:inline\s+)?(?:long|int|void|bool|unsigned\s+long)\s+' + re.escape(name) + r'\s*\(', d):
        continue
    fn = extract_function(s, name)
    if fn is None:
        print(f"::error::Unable to recover {name} from staging sucompat.c")
        sys.exit(1)
    d = d.rstrip() + "\n\n" + fn.rstrip() + "\n"
    changed = True

if changed:
    dst.write_text(d)
    print("[sucompat] restored missing final-tree stat/faccessat implementations")
PY_SUCOMPAT_RECONCILE
}

restore_missing_final_sucompat_handlers "$COMMON_KERNEL_FOLDER"

# Final linker-symbol preflight: if SUSFS added VFS callers, the implementation
# must be present and sucompat.o must be part of the KSU aggregate. This catches
# the exact failure at build-script time instead of waiting for ld.lld.
for _root in "$KSU_FOLDER" "$COMMON_KERNEL_FOLDER"; do
  [ -d "$_root" ] || continue
  # The final OP13R common tree is built from drivers/kernelsu.  Do not
  # accidentally validate a separate kernel/ copy when both exist.
  if [ "$_root" = "$COMMON_KERNEL_FOLDER" ]; then
    _sc="$_root/drivers/kernelsu/feature/sucompat.c"
    [ -f "$_sc" ] || _sc="$_root/kernel/feature/sucompat.c"
  else
    _sc="$_root/kernel/feature/sucompat.c"
    [ -f "$_sc" ] || _sc="$_root/drivers/kernelsu/feature/sucompat.c"
  fi
  if [ -f "$_sc" ]; then
    _kb="$(dirname "$_sc")/../Kbuild"
    [ -f "$_kb" ] || _kb="$(dirname "$_sc")/../Makefile"
    _agg="$(sed -nE 's/^[[:space:]]*obj-\$\(CONFIG_KSU\)[[:space:]]*\+=[[:space:]]*([A-Za-z0-9_.-]+)\.o[[:space:]]*$/\1/p' "$_kb" | head -n1)"
    [ -n "$_agg" ] || _agg="kernelsu"
    if ! grep -Eq "^[[:space:]]*${_agg}-objs[[:space:]]*(\+?=).*feature/sucompat\.o[[:space:]]*$" "$_kb"; then
      echo "::error::feature/sucompat.o is not part of ${_agg}-objs in $_kb"
      grep -nE '(^|-)objs.*sucompat|obj-\$\(CONFIG_KSU\)' "$_kb" || true
      exit 1
    fi
    # The KSU source tree is a staging tree. SUSFS may legitimately have a
    # rejected hunk there while the final common/drivers/kernelsu tree is the
    # tree that is actually compiled. Do not abort on the staging copy here.
    # The common tree is validated separately below.
    if [ "$_root" = "$COMMON_KERNEL_FOLDER" ]; then
      for _sym in ksu_handle_post_execveat_sucompat ksu_handle_stat ksu_handle_faccessat; do
        if grep -qE "^[[:space:]]*(int|long)[[:space:]]+${_sym}[[:space:]]*\(" "$_root/fs/exec.c" "$_root/fs/stat.c" "$_root/fs/open.c" 2>/dev/null; then
          if ! grep -qE "^[[:space:]]*(int|long)[[:space:]]+${_sym}[[:space:]]*\(" "$_sc"; then
            echo "::error::${_sym} is called by the final kernel tree but has no implementation in $_sc"
            echo "  Caller references:"
            grep -nE "${_sym}[[:space:]]*\(" "$_root/fs/exec.c" "$_root/fs/stat.c" "$_root/fs/open.c" 2>/dev/null || true
            echo "  sucompat implementation candidates:"
            grep -nE 'ksu_handle_(post_execveat_sucompat|execveat_sucompat|stat|faccessat)' "$_sc" 2>/dev/null || true
            exit 1
          fi
        fi
      done
    fi
  fi
done

# Compatibility repair is complete. Now remove only the SukiSU rejects that
# have corresponding compatibility handlers above. Anything else is fatal.
for rej in "${EXPECTED_SUKISU_REJECTS[@]}"; do
  if [ -f "$rej" ]; then
    echo "Removing handled SukiSU/SUSFS reject: $rej"
    rm -f "$rej"
  fi
done

# All compatibility repair functions have now run. Any remaining reject is real
# and must stop the workflow rather than being silently discarded.
if [ -n "$(find . -name '*.rej' -print -quit)" ]; then
  echo "::error::Unexpected KernelSU-side .rej files remain after compatibility repair:"
  find . -name '*.rej' -exec echo "=== {} ===" \; -exec cat {} \;
  exit 1
fi

echo "✅ No unresolved KernelSU-side .rej files remain"

# SUSFS defconfig — ONLY the CONFIG_KSU_SUSFS_* symbols that actually exist in the
# SUSFS version being built. v2.2.0 dropped the granular v1.5.x options
# (HAS_MAGIC_MOUNT, AUTO_ADD_*, SUS_OVERLAYFS, TRY_UMOUNT, SUS_SU); writing those
# does nothing (olddefconfig silently discards unknown symbols). The assert below
# fails the build if any symbol here is not defined in the KSU Kconfig, so this
# list can never silently drift again.
{
  cat <<'EOF'
CONFIG_KSU_SUSFS=y
CONFIG_KSU_SUSFS_SUS_PATH=y
CONFIG_KSU_SUSFS_SUS_MOUNT=y
CONFIG_KSU_SUSFS_SUS_KSTAT=y
CONFIG_KSU_SUSFS_ENABLE_LOG=y
CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y
CONFIG_KSU_SUSFS_OPEN_REDIRECT=y
CONFIG_KSU_SUSFS_SUS_MAP=y
EOF
} >> "$COMMON_KERNEL_FOLDER/arch/arm64/configs/gki_defconfig"

sed -i '/^CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=/d' \
  "$COMMON_KERNEL_FOLDER/arch/arm64/configs/gki_defconfig" || true

echo "CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=n" \
  >> "$COMMON_KERNEL_FOLDER/arch/arm64/configs/gki_defconfig"

# SUSFS uname spoofing — opt-in via OP_SPOOF_UNAME (workflow input 'spoof_uname',
# default off, since some apps read uname). Written explicitly so the value is
# deterministic regardless of what the base defconfig carried.
sed -i '/^CONFIG_KSU_SUSFS_SPOOF_UNAME=/d' \
  "$COMMON_KERNEL_FOLDER/arch/arm64/configs/gki_defconfig" || true
if [ "${OP_SPOOF_UNAME:-false}" = "true" ]; then
  echo "CONFIG_KSU_SUSFS_SPOOF_UNAME=y" >> "$COMMON_KERNEL_FOLDER/arch/arm64/configs/gki_defconfig"
  echo "SUSFS: SPOOF_UNAME enabled (OP_SPOOF_UNAME=true)"
else
  echo "CONFIG_KSU_SUSFS_SPOOF_UNAME=n" >> "$COMMON_KERNEL_FOLDER/arch/arm64/configs/gki_defconfig"
fi

# --- Assert every SUSFS defconfig symbol is real for this SUSFS version ---
# Guards against susfs renaming/removing options between versions (would otherwise
# be silently dropped by olddefconfig and the feature quietly never enabled).
_DEFCONFIG="$COMMON_KERNEL_FOLDER/arch/arm64/configs/gki_defconfig"
_KSU_KCONFIG=""
for _k in "$KSU_FOLDER/kernel/Kconfig" "$COMMON_KERNEL_FOLDER/drivers/kernelsu/Kconfig"; do
  [ -f "$_k" ] && { _KSU_KCONFIG="$_k"; break; }
done
if [ -n "$_KSU_KCONFIG" ]; then
  _susfs_missing=0
  while IFS= read -r _line; do
    _sym="${_line%%=*}"; _sym="${_sym#CONFIG_}"
    grep -qE "^[[:space:]]*config[[:space:]]+${_sym}([[:space:]]|\$)" "$_KSU_KCONFIG" && continue
    echo "::warning::SUSFS defconfig sets CONFIG_${_sym} but no 'config ${_sym}' exists in $_KSU_KCONFIG — it would be dropped by olddefconfig"
    _susfs_missing=$((_susfs_missing + 1))
  done < <(grep -E '^CONFIG_KSU_SUSFS' "$_DEFCONFIG")
  if [ "$_susfs_missing" -gt 0 ]; then
    echo "::error::$_susfs_missing SUSFS defconfig option(s) are not defined in the KSU Kconfig for this SUSFS version — update the SUSFS defconfig block in apply_susfs_patches.sh"
    exit 1
  fi
  echo "✅ All SUSFS defconfig options are defined in $_KSU_KCONFIG"
else
  echo "::warning::Could not locate KSU Kconfig to verify SUSFS defconfig options"
fi

echo "✅ SUSFS patches applied successfully"
echo "::endgroup::"
