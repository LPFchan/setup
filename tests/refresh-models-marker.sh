#!/usr/bin/env zsh
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" XDG_STATE_HOME="$TMP/custom-state"
mkdir -p "$HOME/.config/opencode" "$HOME/.local/bin"
printf '{"servers":{"demo":{"baseURL":"http://demo","auth":{"type":"auth_json","provider":"demo"}}}}\n' > "$HOME/.config/opencode/refresh-models.json"

# Import the producer and invoke onboarding without service-manager side effects.
python3 - <<PY
import importlib.machinery, importlib.util, os, pathlib, sys
path = '$ROOT/files/refresh-models'
loader = importlib.machinery.SourceFileLoader('refresh_models_test', path)
spec = importlib.util.spec_from_loader(loader.name, loader)
m = importlib.util.module_from_spec(spec); loader.exec_module(m)
m._is_macos = lambda: False
m.subprocess.run = lambda *a, **k: type('R', (), {'returncode': 0, 'stderr': b''})()
sys.argv = [path, 'enable']
m.cmd_enable()
PY
marker="$XDG_STATE_HOME/setup/refresh-models.needs-auth"
[[ -f "$marker" ]] || { echo "producer did not use custom XDG_STATE_HOME" >&2; exit 1; }
[[ ! -e "$HOME/.local/state/setup/refresh-models.needs-auth" ]] || { echo "producer wrote legacy hardcoded marker" >&2; exit 1; }

cat > "$HOME/.local/bin/refresh-models" <<'EOF'
#!/bin/sh
[[ "$1" == auth ]] && exit 0
EOF
chmod +x "$HOME/.local/bin/refresh-models"
export STATE_DIR="$XDG_STATE_HOME/setup" SETUP_SOURCE_ONLY=1
# shellcheck disable=SC1091
source "$ROOT/bin/setup"
# Force the non-terminal consumer branch: it must observe the producer marker.
output=$(_post_auth_check 2>&1 || true)
[[ "$output" == *"needs API keys"* ]] || { echo "consumer did not observe custom-XDG producer marker" >&2; exit 1; }
[[ -f "$marker" ]] || { echo "noninteractive consumer unexpectedly removed marker" >&2; exit 1; }

echo "refresh-models marker tests passed"
