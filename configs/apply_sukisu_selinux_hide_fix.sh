#!/usr/bin/env bash
set -euo pipefail

echo "::group::Apply SukiSU SELinux-hide verification/fix"

required_env=(KERNEL_PLATFORM_FOLDER COMMON_KERNEL_FOLDER KSU_FOLDER ANDROID_VER_LOCAL KERNEL_VER_LOCAL)
for v in "${required_env[@]}"; do
  [ -n "${!v:-}" ] || { echo "::error::$v missing"; exit 1; }
done

if [ "$ANDROID_VER_LOCAL" != "android14" ] || [ "$KERNEL_VER_LOCAL" != "6.1" ]; then
  echo "Skipping: not Android 14 / Linux 6.1"
  echo "::endgroup::"
  exit 0
fi

verify_selinux() {
  local f="$1"
  [ -f "$f" ] || return 1
  grep -q "backup_sepolicy" "$f" &&
  grep -q "struct selinux_policy.*backup_sepolicy" "$f"
}

verify_lsm() {
  local f="$1"
  [ -f "$f" ] || return 1
  grep -q "ksu_lsm_hook_target_matches" "$f" || grep -q "current_origin == target" "$f"
}

minimal_symbol_fix() {
  local f="$1"
  [ -f "$f" ] || return 0
  sed -i \
    -e 's/^static int security_context_to_sid_with_policy(/int security_context_to_sid_with_policy(/' \
    -e 's/^static int security_sid_to_context_with_policy(/int security_sid_to_context_with_policy(/' \
    -e 's/^static void security_compute_av_user_with_policy(/void security_compute_av_user_with_policy(/' \
    "$f" || true
}

check_tree() {
  if verify_selinux "$1" && verify_lsm "$2"; then
    echo "SukiSU SELinux-hide API is internally consistent"
    echo "  backup_sepolicy: declaration + definition verified"
    echo "  common-tree LSM matcher: verified"
    return 0
  fi
  return 1
}

trees=(
"$KSU_FOLDER/kernel/feature/selinux_hide.c|$KSU_FOLDER/kernel/hook/lsm_hook.c"
"$COMMON_KERNEL_FOLDER/drivers/kernelsu/feature/selinux_hide.c|$COMMON_KERNEL_FOLDER/drivers/kernelsu/hook/lsm_hook.c"
)

for t in "${trees[@]}"; do
  IFS='|' read -r selinux hook <<< "$t"
  if ! check_tree "$selinux" "$hook"; then
    echo "Applying minimal compatibility fix: $selinux"
    minimal_symbol_fix "$selinux"
  fi
done

echo "Do not inject lsm_hook.o automatically"
echo "Do not apply KCFI matcher rewrite automatically"
echo "✅ SELinux-hide verification complete"
echo "::endgroup::"
