#!/usr/bin/env bash
set -euo pipefail

: "${COMMON_KERNEL_FOLDER:?COMMON_KERNEL_FOLDER is required}"

HIDE="$COMMON_KERNEL_FOLDER/drivers/kernelsu/feature/selinux_hide.c"
HEADER="$COMMON_KERNEL_FOLDER/drivers/kernelsu/selinux/sepolicy.h"
RULES="$COMMON_KERNEL_FOLDER/drivers/kernelsu/selinux/rules.c"

for f in "$HIDE" "$HEADER" "$RULES"; do
  [ -f "$f" ] || { echo "::error::Required SukiSU SELinux file missing: $f"; exit 1; }
done

python3 - "$HIDE" "$HEADER" "$RULES" <<'PY'
from pathlib import Path
import re
import sys

hide, header, rules = map(Path, sys.argv[1:])

static_re = re.compile(
    r'(?m)^[ \t]*static[ \t]+struct[ \t]+selinux_policy[ \t]*\*[ \t]*backup_sepolicy[ \t]*;[ \t]*\n?'
)
extern_re = re.compile(
    r'(?m)^[ \t]*extern[ \t]+struct[ \t]+selinux_policy[ \t]*\*[ \t]*backup_sepolicy[ \t]*;[ \t]*\n?'
)
def_re = re.compile(
    r'(?m)^[ \t]*(?!extern\b)(?:static[ \t]+)?struct[ \t]+selinux_policy[ \t]*\*[ \t]*backup_sepolicy[ \t]*(?:=[^;]*)?;[ \t]*\n?'
)

# Only remove the conflicting private definition from selinux_hide.c.
hide.write_text(static_re.sub('', hide.read_text()))

# rules.c owns exactly one global definition.
rt = rules.read_text()
ms = list(def_re.finditer(rt))
if not ms:
    marker = '#include "sepolicy.h"'
    definition = 'struct selinux_policy *backup_sepolicy;\n'
    if marker in rt:
        rt = rt.replace(marker, marker + '\n\n' + definition, 1)
    else:
        rt = definition + rt
elif len(ms) > 1:
    out = []
    last = 0
    for m in ms[1:]:
        out.append(rt[last:m.start()])
        last = m.end()
    out.append(rt[last:])
    rt = ''.join(out)
rules.write_text(rt)

# sepolicy.h exposes the shared symbol.
ht = extern_re.sub('', header.read_text())
line = 'extern struct selinux_policy *backup_sepolicy;'
marker = 'struct selinux_policy *ksu_dup_sepolicy(struct selinux_policy *old_pol);'
if marker in ht:
    ht = ht.replace(marker, line + '\n\n' + marker, 1)
elif '#endif' in ht:
    ht = ht.replace('#endif', line + '\n\n#endif', 1)
else:
    ht += '\n' + line + '\n'
header.write_text(ht)

if not re.search(r'(?m)^[ \t]*extern[ \t]+struct[ \t]+selinux_policy[ \t]*\*[ \t]*backup_sepolicy[ \t]*;', header.read_text()):
    raise SystemExit('backup_sepolicy validation: extern missing from sepolicy.h')
if len(def_re.findall(rules.read_text())) != 1:
    raise SystemExit('backup_sepolicy validation: expected exactly one global definition in rules.c')
if static_re.search(hide.read_text()):
    raise SystemExit('backup_sepolicy validation: conflicting static definition remains in selinux_hide.c')

print('  [SELinux-hide] backup_sepolicy definition: rules.c')
print('  [SELinux-hide] backup_sepolicy declaration: sepolicy.h')
print('  [SELinux-hide] conflicting static definition removed: selinux_hide.c')
PY
