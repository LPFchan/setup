#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

export HOME="$TEST_TMP/home"
export TEST_TMP
export OPENCODEX_REGISTRY="$HOME/.config/opencodex/managed-profiles.json"
export OPENCODEX_AUTH_JSON="$HOME/.local/share/opencode/auth.json"
export OPENCODEX_CONFIG="$HOME/.opencodex/config.json"
export OPENCODEX_MANAGED="$HOME/.opencodex/setup-managed-providers.json"
export OPENCODEX_BIN="$HOME/.local/bin/ocx"
export CODEX_HOME="$TEST_TMP/codex \"home"
mkdir -p "$HOME/.local/bin" "$(dirname "$OPENCODEX_REGISTRY")" "$(dirname "$OPENCODEX_AUTH_JSON")"
cp "$ROOT/files/claudex-profiles.json" "$OPENCODEX_REGISTRY"
printf '{"commandcode":{"type":"api","key":"secret"}}\n' > "$OPENCODEX_AUTH_JSON"

fail() { echo "FAIL: $*" >&2; exit 1; }

cat > "$OPENCODEX_BIN" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    ensure) printf 'ensure\n' >> "$TEST_TMP/ocx-calls" ;;
    claude)
        printf '%s\n' "$@" > "$TEST_TMP/claude-args"
        env | grep '^ANTHROPIC_' | sort > "$TEST_TMP/claude-env"
        ;;
    *) printf '%s\n' "$@" > "$TEST_TMP/ocx-args" ;;
esac
EOF
cat > "$TEST_TMP/codex" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$TEST_TMP/codex-args"
EOF
cat > "$HOME/.local/bin/fzf-multicolumn" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$TEST_TMP/picker-args"
cat > "$TEST_TMP/picker-input"
printf 'provider\037commandcode\037commandcode\n'
printf 'harness\037codex\037codex\n'
EOF
chmod +x "$OPENCODEX_BIN" "$TEST_TMP/codex" "$HOME/.local/bin/fzf-multicolumn"
PATH="$TEST_TMP:$PATH"
export PATH

"$ROOT/files/opencodex"
grep -q -- '--grid=2' "$TEST_TMP/picker-args" || fail "picker did not request two columns"
grep -q $'provider\037commandcode\037commandcode' "$TEST_TMP/picker-input" \
    || fail "picker omitted provider entries"
grep -q $'harness\037claude\037claude' "$TEST_TMP/picker-input" \
    || fail "picker omitted harness entries"
expected_model="commandcode/$(jq -r '.profiles[] | select(.name == "commandcode") | .default_model' "$OPENCODEX_REGISTRY")"
expected_catalog_override=$(python3 - "$CODEX_HOME/opencodex-catalog.json" <<'PY'
import json
import sys
print("model_catalog_json=" + json.dumps(sys.argv[1], ensure_ascii=False))
PY
)
"$ROOT/files/opencodex" run commandcode codex --sandbox read-only
[[ $(cat "$TEST_TMP/codex-args") == "$(printf '%s\n%s\n%s\n%s\n%s\n%s' \
    -c "$expected_catalog_override" -m "$expected_model" --sandbox read-only)" ]] \
    || fail "Codex did not receive the configured catalog, routed model, and forwarded arguments"
python3 - "$expected_catalog_override" "$CODEX_HOME/opencodex-catalog.json" <<'PY'
import sys
import tomllib

key, value = sys.argv[1].split("=", 1)
assert tomllib.loads(f"{key} = {value}\n")[key] == sys.argv[2]
PY

resume_id="11111111-2222-4333-8444-555555555555"
"$ROOT/files/opencodex" run commandcode claude --resume "$resume_id"
grep -q '^claude$' "$TEST_TMP/claude-args" || fail "Claude was not launched through ocx"
grep -q '^--resume$' "$TEST_TMP/claude-args" || fail "Claude arguments were not forwarded"
grep -Fqx "ANTHROPIC_MODEL=$expected_model" "$TEST_TMP/claude-env" \
    || fail "Claude default model was not routed"
grep -Fqx "$resume_id"$'\tcommandcode' "$HOME/.config/opencodex/sessions.tsv" \
    || fail "Claude resume mapping did not use the explicit session id"

short_resume_id="aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
"$ROOT/files/opencodex" run commandcode claude -r "$short_resume_id"
grep -Fqx -- '-r' "$TEST_TMP/claude-args" || fail "Claude's short resume flag was not forwarded"
grep -Fqx -- "$short_resume_id" "$TEST_TMP/claude-args" || fail "Claude's short resume id was not forwarded"
! grep -Fqx -- '--session-id' "$TEST_TMP/claude-args" \
    || fail "short resume was combined with a generated session id"
grep -Fqx "$short_resume_id"$'\tcommandcode' "$HOME/.config/opencodex/sessions.tsv" \
    || fail "short resume mapping did not preserve the requested session id"

"$ROOT/files/opencodex" run commandcode claude
generated_id=$(awk 'previous == "--session-id" { print; exit } { previous = $0 }' "$TEST_TMP/claude-args")
python3 - "$generated_id" <<'PY'
import sys
import uuid
uuid.UUID(sys.argv[1])
PY
grep -Fqx "$generated_id"$'\tcommandcode' "$HOME/.config/opencodex/sessions.tsv" \
    || fail "new Claude session did not record its generated UUID"

"$ROOT/files/opencodex" __apply "$OPENCODEX_REGISTRY"
jq -e '.syncResumeHistory == false' "$OPENCODEX_CONFIG" >/dev/null \
    || fail "Linux enabled Codex Desktop history synchronization"
jq -e '.providers.commandcode.apiKey == "secret"' "$OPENCODEX_CONFIG" >/dev/null \
    || fail "OpenCodex provider credentials were not rendered"

python3 - "$ROOT/files/opencodex" "$OPENCODEX_REGISTRY" <<'PY'
import runpy
import sys
from pathlib import Path

namespace = runpy.run_path(sys.argv[1], run_name="opencodex_test")
assert namespace["PROVIDER_CONSUMER_MODULES"] == ("claudex", "opencodex", "refresh-models")
registry = namespace["load_registry"](Path(sys.argv[2]))
original = namespace["sys"].platform
namespace["sys"].platform = "darwin"
try:
    config, _ = namespace["desired_opencodex_config"](registry, {}, {})
finally:
    namespace["sys"].platform = original
assert config["syncResumeHistory"] is True
PY

"$ROOT/files/opencodex" --version
grep -q '^--version$' "$TEST_TMP/ocx-args" || fail "OpenCodex CLI arguments were not forwarded"

echo "opencodex launcher tests passed"
