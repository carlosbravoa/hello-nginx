#!/bin/bash
# Rename the snap built from this template.
#
#   scripts/rename.sh <snap-name> ["Display Title"]
#
# Changes the snap name, the CLI app (which must match the snap name so the
# command is just `<snap-name>`), the title, and mentions in site/.
# Everything under src/ derives the name at runtime and needs no change.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
YAML="$ROOT/snap/snapcraft.yaml"

usage() { echo "usage: $0 <snap-name> [\"Display Title\"]" >&2; exit 2; }
[ $# -ge 1 ] && [ $# -le 2 ] || usage

new=$1
current=$(sed -n 's/^name: *//p' "$YAML")

# Snap Store naming rules: lowercase letters, digits and single hyphens,
# at most 40 characters, at least one letter, no leading or trailing hyphen.
if ! [[ $new =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || [ ${#new} -gt 40 ] || ! [[ $new =~ [a-z] ]]; then
    echo "error: '$new' is not a valid snap name" >&2
    echo "  use lowercase letters, digits and single hyphens, max 40 chars, at least one letter" >&2
    exit 1
fi
[ "$new" != "$current" ] || { echo "Already named '$new'."; exit 0; }

title=${2:-$(echo "$new" | tr '-' ' ' | sed 's/\b\(.\)/\u\1/g')}

# Text files that mention the current name.
mapfile -t files < <(
    { echo "$YAML"; find "$ROOT/site" -type f \( -name '*.html' -o -name '*.htm' -o -name '*.txt' \); } |
        xargs grep -l -F -- "$current" 2>/dev/null || true
)

for f in "${files[@]}"; do
    # Skip names inside URL paths (".../hello-nginx"): links to the template
    # repository must stay valid until you change them yourself.
    sed -i -E "s/(^|[^/[:alnum:]-])$current\b/\1$new/g" "$f"
    echo "updated ${f#$ROOT/}"
done
sed -i "s/^title: .*/title: $title/" "$YAML"

cat <<EOF

Renamed '$current' -> '$new' (title: "$title").

Next:
  1. Edit snap/snapcraft.yaml: version, summary, description, license,
     and the contact/issues/source-code/website links (they point at the template).
  2. Put your website in site/ and your nginx rules in nginx/site.conf.
  3. snapcraft pack && tests/lxd-smoke.sh
  4. snapcraft register $new   (once)
EOF

# Anything left outside the template docs is worth a look.
left=$(grep -rIl -F \
        --exclude-dir=.git --exclude-dir=docs --exclude-dir=parts --exclude-dir=stage --exclude-dir=prime \
        --exclude=README.md --exclude=AGENTS.md --exclude=CLAUDE.md --exclude=rename.sh --exclude='*.snap' \
        -- "$current" "$ROOT" || true)
if [ -n "$left" ]; then
    echo
    echo "Still mentioning '$current' (check by hand):"
    echo "$left" | sed "s|^$ROOT/|  |"
fi
