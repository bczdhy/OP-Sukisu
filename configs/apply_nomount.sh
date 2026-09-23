#!/usr/bin/env bash
set -euo pipefail

# NoMount built-in integration for the OP13R Android 14 / Linux 6.1 kernel.
# Uses the upstream NoMount kernel setup script and pins the known v2.0.0 release
# so the kernel build is reproducible.

COMMON_KERNEL_FOLDER="${COMMON_KERNEL_FOLDER:?COMMON_KERNEL_FOLDER is not set}"
NOMOUNT_VERSION="${NOMOUNT_VERSION:-v2.0.0}"
SETUP_URL="https://raw.githubusercontent.com/maxsteeel/nomount/${NOMOUNT_VERSION}/kernel/setup.sh"
SETUP_SCRIPT="${RUNNER_TEMP:-/tmp}/nomount-setup-${NOMOUNT_VERSION//\//_}.sh"
DEFCONFIG="$COMMON_KERNEL_FOLDER/arch/arm64/configs/gki_defconfig"

if [[ ! -d "$COMMON_KERNEL_FOLDER/fs" ]]; then
  echo "::error::NoMount: kernel fs/ directory not found: $COMMON_KERNEL_FOLDER/fs"
  exit 1
fi

if [[ ! -f "$DEFCONFIG" ]]; then
  echo "::error::NoMount: defconfig not found: $DEFCONFIG"
  exit 1
fi

echo "Installing NoMount kernel integration: $NOMOUNT_VERSION"
echo "Source: https://github.com/maxsteeel/nomount"

echo "Downloading upstream NoMount setup script..."
curl -fL --retry 3 --retry-delay 2 -o "$SETUP_SCRIPT" "$SETUP_URL"
chmod +x "$SETUP_SCRIPT"

cd "$COMMON_KERNEL_FOLDER"
sh "$SETUP_SCRIPT" "$NOMOUNT_VERSION"

# Explicitly request built-in integration. NoMount's Kconfig defaults to y,
# but keeping the symbol in the product defconfig makes the intended mode
# unambiguous and prevents a later config merge from selecting m/n.
sed -i '/^CONFIG_NOMOUNT=/d' "$DEFCONFIG"
printf '%s\n' 'CONFIG_NOMOUNT=y' >> "$DEFCONFIG"

if [[ ! -L "$COMMON_KERNEL_FOLDER/fs/nomount" ]]; then
  echo "::error::NoMount: fs/nomount integration link was not created"
  exit 1
fi

if ! grep -q '^obj-$(CONFIG_NOMOUNT) += nomount/' "$COMMON_KERNEL_FOLDER/fs/Makefile"; then
  echo "::error::NoMount: fs/Makefile integration is missing"
  exit 1
fi

if ! grep -q '^source "fs/nomount/Kconfig"' "$COMMON_KERNEL_FOLDER/fs/Kconfig"; then
  echo "::error::NoMount: fs/Kconfig integration is missing"
  exit 1
fi

if ! grep -q '^CONFIG_NOMOUNT=y$' "$DEFCONFIG"; then
  echo "::error::NoMount: CONFIG_NOMOUNT=y was not added to defconfig"
  exit 1
fi

echo "✅ NoMount $NOMOUNT_VERSION integrated as built-in (CONFIG_NOMOUNT=y)"
echo "   fs/nomount: $(readlink -f "$COMMON_KERNEL_FOLDER/fs/nomount")"
