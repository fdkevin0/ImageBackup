#!/usr/bin/env bash
# Checks the WebDAV behaviours the MVP depends on, against your real NAS.
# Run this BEFORE building — if HEAD or MKCOL misbehaves here, it's cheaper to find
# out than on a phone. The conditional-PUT line is informational only; nothing
# depends on it (see the note at that check).
#
#   scripts/verify-webdav.sh http://192.168.1.10:5005/PhotoBackup user 'password'
set -uo pipefail

BASE=${1:?usage: verify-webdav.sh <base-url> <user> <password>}
USER=${2:?usage: verify-webdav.sh <base-url> <user> <password>}
PASS=${3:?usage: verify-webdav.sh <base-url> <user> <password>}
BASE=${BASE%/}

DIR="_imagebackup_probe"
FILE="$DIR/probe.bin"
fail=0

req() {  # method path [extra curl args...]
  local method=$1 path=$2
  shift 2
  curl -s -o /dev/null -w "%{http_code}" --max-time 20 \
       -X "$method" -u "$USER:$PASS" "$@" "$BASE/$path"
}

check() {  # label actual accepted...
  local label=$1 actual=$2
  shift 2
  local want
  for want in "$@"; do
    if [ "$actual" = "$want" ]; then
      printf '  ok    %-44s %s\n' "$label" "$actual"
      return
    fi
  done
  printf '  FAIL  %-44s got %s, want one of [%s]\n' "$label" "$actual" "$*"
  fail=1
}

echo "Probing $BASE"
echo

# Walk the path one level at a time, exactly as the app does — MKCOL cannot create
# intermediate collections (RFC 4918 §9.7.1), so a single MKCOL on a nested path gets 409.
walked=""
while IFS= read -r part; do
  walked="${walked:+$walked/}$part"
  code=$(req MKCOL "$walked")
  case "$code" in
    201) echo "  ok    MKCOL /$walked" ;;
    405) echo "  ok    MKCOL /$walked (already existed)" ;;
    401|403) echo "  FAIL  auth rejected ($code) — check user / password / URL"; exit 1 ;;
    *) echo "  FAIL  MKCOL /$walked returned $code — is WebDAV enabled on this share?"; exit 1 ;;
  esac
done <<< "$(printf '%s\n' "$DIR" | tr '/' '\n')"

# Note: servers disagree here. RFC 4918 says 405 for an existing collection; rclone answers 201.
# The app accepts both, which is why this check is informational rather than pass/fail.
echo "  info  MKCOL on an existing collection           $(req MKCOL "$DIR") (201 or 405 both fine)"

# The load-bearing one. The app HEADs before every PUT, so it can skip what's already backed up
# without trusting a conditional PUT (see the info line below for why).
check "HEAD on a missing file reports 404" 404 "$(req HEAD "$FILE")"

check "PUT creates the file" \
      "$(req PUT "$FILE" --data-binary 'hello' -H 'Content-Type: application/octet-stream')" \
      200 201 204

check "HEAD on the stored file reports 200" 200 "$(req HEAD "$FILE")"

stored=$(curl -sI --max-time 20 -u "$USER:$PASS" "$BASE/$FILE" \
         | tr -d '\r' | awk -F': ' 'tolower($1)=="content-length"{print $2}')
if [ "$stored" = 5 ]; then
  echo "  ok    HEAD reports a usable Content-Length        5"
else
  echo "  FAIL  HEAD Content-Length is '$stored', want 5 — the collision check needs this"
  fail=1
fi

# Informational only, deliberately NOT pass/fail: servers disagree, and rclone ignores the header
# outright (201 instead of 412 — verified 2026-09-24). The app must never depend on this.
echo "  info  conditional PUT (If-None-Match: *)        $(req PUT "$FILE" --data-binary 'hello' -H 'If-None-Match: *') (412 good, 201 = ignored)"

# Confirms the file really landed, and that the URL layout maps to what the app writes.
check "GET reads it back" 200 "$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 -u "$USER:$PASS" "$BASE/$FILE")"

req DELETE "$FILE" >/dev/null
req DELETE "$DIR" >/dev/null

echo
if [ "$fail" = 0 ]; then
  echo "All checks passed — the MVP's transport assumptions hold."
else
  echo "Something failed. A HEAD or MKCOL failure needs a different collision strategy —"
  echo "see research §6.4, and §6.1 for the folder-creation rules."
fi
exit $fail
