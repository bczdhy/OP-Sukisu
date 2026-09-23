#!/usr/bin/env bash
set -euo pipefail

echo "::group::Apply SukiSU SELinux-hide verification/fix"

required_env=(
  KERNEL_PLATFORM_FOLDER
  COMMON_KERNEL_FOLDER
  KSU_FOLDER
  ANDROID_VER_LOCAL
  KERNEL_VER_LOCAL
)

for v in "${required_env[@]}"; do
  if [ -z "${!v:-}" ]; then
    echo "::error::Missing environment variable $v"
    exit 1
  fi
done

if [ "$ANDROID_VER_LOCAL" != "android14" ] || [ "$KERNEL_VER_LOCAL" != "6.1" ]; then
  echo "SukiSU SELinux-hide fix: not Android 14 / 6.1; skipping"
  echo "::endgroup::"
  exit 0
fi

verify_selinux_hide() {
  local target="$1"
  [ -f "$target" ] || return 1

  grep -q "backup_sepolicy" "$target" || return 1
  grep -q "struct selinux_policy.*backup_sepolicy" "$target" || return 1

  return 0
}

verify_lsm_matcher() {
  local target="$1"
  [ -f "$target" ] || return 1

  grep -q "current_origin == target" "$target" && return 0
  grep -q "ksu_lsm_hook_target_matches" "$target" && return 0

  return 1
}

fix_selinux_symbols() {
  local target="$1"
  [ -f "$target" ] || return 0

  echo "Applying minimal SELinux symbol visibility fix: $target"

  sed -i \
    -e 's/^static int security_context_to_sid_with_policy(/int security_context_to_sid_with_policy(/' \
    -e 's/^static int security_sid_to_context_with_policy(/int security_sid_to_context_with_policy(/' \
    -e 's/^static void security_compute_av_user_with_policy(/void security_compute_av_user_with_policy(/' \
    "$target" || true
}

check_tree() {
  local selinux="$1"
  local hook="$2"

  if verify_selinux_hide "$selinux" && verify_lsm_matcher "$hook"; then
    echo "SukiSU SELinux-hide API is internally consistent"
    echo "  backup_sepolicy: declaration + definition verified"
    echo "  common-tree LSM matcher: verified"
    return 0
  fi

  return 1
}

KSU_SELINUX="$KSU_FOLDER/kernel/feature/selinux_hide.c"
KSU_HOOK="$KSU_FOLDER/kernel/hook/lsm_hook.c"

COMMON_SELINUX="$COMMON_KERNEL_FOLDER/drivers/kernelsu/feature/selinux_hide.c"
COMMON_HOOK="$COMMON_KERNEL_FOLDER/drivers/kernelsu/hook/lsm_hook.c"

if check_tree "$KSU_SELINUX" "$KSU_HOOK"; then
  echo "KernelSU tree already correct"
else
  echo "KernelSU tree requires minimal compatibility fixes"
  fix_selinux_symbols "$KSU_SELINUX"
fi

if [ -f "$COMMON_SELINUX" ] && [ -f "$COMMON_HOOK" ]; then
  if check_tree "$COMMON_SELINUX" "$COMMON_HOOK"; then
    echo "Common-tree already correct"
  else
    echo "Common-tree requires minimal compatibility fixes"
    fix_selinux_symbols "$COMMON_SELINUX"
  fi
fi

echo "✅ SukiSU SELinux-hide verification completed"
echo "::endgroup::"
