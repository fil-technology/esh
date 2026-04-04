#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <zip-archive>" >&2
  exit 1
fi

ARCHIVE_PATH="$1"
[[ -f "$ARCHIVE_PATH" ]] || {
  echo "Archive not found: $ARCHIVE_PATH" >&2
  exit 1
}

: "${APPLE_API_KEY_ID:?APPLE_API_KEY_ID is required}"
: "${APPLE_API_ISSUER_ID:?APPLE_API_ISSUER_ID is required}"
: "${APPLE_API_PRIVATE_KEY_P8:?APPLE_API_PRIVATE_KEY_P8 is required}"
: "${APPLE_TEAM_ID:?APPLE_TEAM_ID is required}"

KEY_PATH="${RUNNER_TEMP:-/tmp}/AuthKey_${APPLE_API_KEY_ID}.p8"
printf '%s' "$APPLE_API_PRIVATE_KEY_P8" > "$KEY_PATH"
chmod 600 "$KEY_PATH"

xcrun notarytool submit "$ARCHIVE_PATH" \
  --key "$KEY_PATH" \
  --key-id "$APPLE_API_KEY_ID" \
  --issuer "$APPLE_API_ISSUER_ID" \
  --team-id "$APPLE_TEAM_ID" \
  --wait
