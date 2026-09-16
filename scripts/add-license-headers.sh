#!/bin/bash
# Puts the AGPL licence header at the top of every source file.
# Repeatable: files that already carry it are left alone.
set -euo pipefail
cd "$(dirname "$0")/.."

read -r -d '' HEADER <<'EOF' || true
Spind — Copyright (C) 2026 Christoph Lindl-Guk

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU Affero General Public License as
published by the Free Software Foundation, either version 3 of the
License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
GNU Affero General Public License for more details.

You should have received a copy of the GNU Affero General Public
License along with this program. If not, see <https://www.gnu.org/licenses/>.
EOF

stamp() {
    local file=$1 prefix=$2
    grep -q "GNU Affero" "$file" && return 0
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
