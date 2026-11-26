#!/usr/bin/env bash
# Encrypt local designs from scheduled/<N>/ into sealed/<N>/ so they can be committed
# without being readable until the deploy workflow releases them.
#
#   tools/seal.sh          seal every day in scheduled/
#   tools/seal.sh 3 4      seal only days 3 and 4
#
# Unchanged files are skipped, so re-running doesn't churn the git diff.
# The key lives in .seal-key (gitignored) and must match the SEAL_KEY repo secret.
set -euo pipefail
cd "$(dirname "$0")/.."

[ -f .seal-key ] || { echo "Missing .seal-key. Create one with: openssl rand -base64 48 > .seal-key" >&2; exit 1; }
SEAL_KEY="$(cat .seal-key)"
export SEAL_KEY
ENC=(openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -pass env:SEAL_KEY)

if [ $# -gt 0 ]; then days=("$@"); else
  days=(); for d in scheduled/*/; do [ -d "$d" ] && days+=("$(basename "$d")"); done
fi
[ ${#days[@]} -gt 0 ] || { echo "Nothing in scheduled/ to seal."; exit 0; }

for day in "${days[@]}"; do
  src="scheduled/$day"; dst="sealed/$day"
  [ -f "$src/index.html" ] || { echo "day $day: no $src/index.html, skipping" >&2; continue; }
  changed=0
  while read -r rel; do
    rel="${rel#./}"
    out="$dst/$rel.enc"
    if [ -f "$out" ] && "${ENC[@]}" -d -in "$out" 2>/dev/null | cmp -s - "$src/$rel"; then continue; fi
    mkdir -p "$(dirname "$out")"
    "${ENC[@]}" -salt -in "$src/$rel" -out "$out"
    changed=1
  done < <(cd "$src" && find . -type f ! -name '.DS_Store')
  # Drop sealed files whose source was deleted.
  if [ -d "$dst" ]; then
    while read -r rel; do
      rel="${rel#./}"
      [ -f "$src/${rel%.enc}" ] || { rm "$dst/$rel"; changed=1; }
    done < <(cd "$dst" && find . -type f -name '*.enc')
  fi
  [ $changed = 1 ] && echo "day $day: sealed" || echo "day $day: unchanged"
done
