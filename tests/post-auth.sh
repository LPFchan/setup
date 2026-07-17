#!/usr/bin/env zsh
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
command -v script >/dev/null 2>&1 || { echo "post-auth tests skipped (script unavailable)"; exit 0; }
mkdir -p "$TMP/home/.local/bin" "$TMP/state/setup"
marker="$TMP/state/setup/refresh-models.needs-auth"

cat > "$TMP/home/.local/bin/refresh-models" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$AUTH_LOG"
exit "${AUTH_RC:-0}"
EOF
chmod +x "$TMP/home/.local/bin/refresh-models"
cat > "$TMP/driver" <<EOF
#!/usr/bin/env zsh
export HOME='$TMP/home' XDG_STATE_HOME='$TMP/state' STATE_DIR='$TMP/state/setup'
export SETUP_SOURCE_ONLY=1 PATH='/usr/bin:/bin'
source '$ROOT/bin/setup'
_post_auth_check
EOF
chmod +x "$TMP/driver"

: > "$marker"
AUTH_LOG="$TMP/auth.log" AUTH_RC=7 script -qec "$TMP/driver" /dev/null >/dev/null 2>&1 || true
[[ -e "$marker" ]] || { echo "failed auth removed retry marker" >&2; exit 1; }
[[ $(cat "$TMP/auth.log") == auth ]] || { echo "managed refresh-models was not resolved outside PATH" >&2; exit 1; }

AUTH_LOG="$TMP/auth.log" AUTH_RC=0 script -qec "$TMP/driver" /dev/null >/dev/null 2>&1
[[ ! -e "$marker" ]] || { echo "successful auth did not clear marker" >&2; exit 1; }
[[ $(wc -l < "$TMP/auth.log") -eq 2 ]] || { echo "auth was not retried after failure" >&2; exit 1; }

echo "post-auth tests passed"
