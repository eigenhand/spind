#!/bin/bash
# Puts the licence header (Apache 2.0, SPDX) at the top of every source file.
# Repeatable: files that already carry it are left alone.
set -euo pipefail
cd "$(dirname "$0")/.."

read -r -d '' HEADER <<'EOF' || true
Spind — Copyright (C) 2026 Christoph Lindl-Guk
SPDX-License-Identifier: Apache-2.0
EOF

stamp() {
    local file=$1 prefix=$2
    grep -q "SPDX-License-Identifier" "$file" && return 0
    local tmp perms
    perms=$(stat -f "%Lp" "$file")   # mv would otherwise lose the executable bit
    tmp=$(mktemp)
    {
        # The shebang has to stay on the first line.
        if head -1 "$file" | grep -q '^#!'; then
            head -1 "$file"
            echo "$HEADER" | sed "s|^|$prefix|;s| *$||"
            echo
            tail -n +2 "$file"
        else
            echo "$HEADER" | sed "s|^|$prefix|;s| *$||"
            echo
            cat "$file"
        fi
    } > "$tmp"
    mv "$tmp" "$file"
    chmod "$perms" "$file"
    echo "  + $file"
}

echo "▸ Swift …"
find Sources Tests -name "*.swift" -print0 | while IFS= read -r -d '' f; do
    stamp "$f" "// "
done
echo "▸ Python …"
find server -name "*.py" -print0 | while IFS= read -r -d '' f; do
    stamp "$f" "# "
done
echo "▸ Shell …"
for f in scripts/*.sh; do
    stamp "$f" "# "
done
echo "✓ Fertig"
