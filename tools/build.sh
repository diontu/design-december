#!/usr/bin/env bash
# Build the deployable site into _site/.
#
# For each day N (Dec N, 00:00 UTC launch):
#   - before launch-1h: /N/ is a countdown page; the real design is NOT in the build.
#   - launch-1h .. launch: the real design is decrypted into /N/, with a small gate that
#     sends visitors to /N/soon/ (a countdown) until 00:00 UTC, then back to /N/.
#   - after launch: the real design is served as-is.
#
# Env:
#   SEAL_KEY   key used to decrypt sealed/ (required once any day is due)
#   NOW        override the current time (unix seconds) for testing
#   YEAR       override the year (default 2026)
set -euo pipefail
cd "$(dirname "$0")/.."

YEAR="${YEAR:-2026}"
NOW="${NOW:-$(date -u +%s)}"
OUT=_site
TEMPLATE=templates/countdown.html

launch_ts() { # day -> unix seconds of Dec <day> 00:00 UTC
  python3 -c "import calendar,sys; print(calendar.timegm(($YEAR,12,int(sys.argv[1]),0,0,0)))" "$1"
}

countdown() { # day outfile
  mkdir -p "$(dirname "$2")"
  sed -e "s/{{DAY}}/$1/g" -e "s/{{YEAR}}/$YEAR/g" "$TEMPLATE" > "$2"
}

decrypt() { # in out
  mkdir -p "$(dirname "$2")"
  openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -pass env:SEAL_KEY -in "$1" -out "$2"
}

rm -rf "$OUT"
mkdir -p "$OUT"
cp index.html "$OUT/"
[ -f CNAME ] && cp CNAME "$OUT/"
[ -d assets ] && cp -R assets "$OUT/"

echo "Building at $(date -u -r "$NOW" 2>/dev/null || date -u -d "@$NOW") (NOW=$NOW)"
for day in $(seq 1 25); do
  launch=$(launch_ts "$day")
  release=$((launch - 3600))
  sealed="sealed/$day"

  if [ "$NOW" -lt "$release" ]; then
    countdown "$day" "$OUT/$day/index.html"
    echo "  day $day: countdown"
    continue
  fi

  if [ ! -f "$sealed/index.html.enc" ]; then
    countdown "$day" "$OUT/$day/index.html"
    echo "  day $day: DUE BUT NOT SEALED, serving countdown" >&2
    continue
  fi

  : "${SEAL_KEY:?SEAL_KEY is required to release day $day}"
  (cd "$sealed" && find . -type f -name '*.enc') | while read -r f; do
    rel="${f#./}"
    decrypt "$sealed/$rel" "$OUT/$day/${rel%.enc}"
  done

  if [ "$NOW" -lt "$launch" ]; then
    # Released early to give the deploy time to land; hold visitors on a countdown until launch.
    gate="<script>if(Date.now()<$((launch * 1000))){document.documentElement.style.display='none';location.replace('/$day/soon/')}</script>"
    python3 - "$OUT/$day/index.html" "$gate" <<'PY'
import re, sys
path, gate = sys.argv[1], sys.argv[2]
html = open(path, encoding="utf-8").read()
m = re.search(r"<head[^>]*>", html, re.I)
html = html[:m.end()] + gate + html[m.end():] if m else gate + html
open(path, "w", encoding="utf-8").write(html)
PY
    countdown "$day" "$OUT/$day/soon/index.html"
    echo "  day $day: released, gated until launch"
  else
    echo "  day $day: live"
  fi
done
