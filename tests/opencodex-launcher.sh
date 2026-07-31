#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# Physical path: the launcher resolves CODEX_HOME, so on macOS a /var/folders
# temp dir comes back as /private/var/... and every path assertion below would
# compare a symlinked prefix against a resolved one.
TEST_TMP=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$TEST_TMP"' EXIT

export HOME="$TEST_TMP/home"
export TEST_TMP
# The launcher copies the process env into the harness; inherited provider
# aliases from the outer shell must not pollute the launch-env assertions.
while IFS='=' read -r name _; do
    case "$name" in ANTHROPIC_*|MAX_THINKING_TOKENS) unset "$name" ;; esac
done < <(env)
export OPENCODEX_REGISTRY="$HOME/.config/opencodex/managed-profiles.json"
export OPENCODEX_AUTH_JSON="$HOME/.local/share/opencode/auth.json"
export OPENCODEX_CONFIG="$HOME/.opencodex/config.json"
export OPENCODEX_MANAGED="$HOME/.opencodex/setup-managed-providers.json"
export PROVIDER_STATE_PATH="$HOME/.config/providers/state.json"
export OPENCODEX_BIN="$HOME/.local/bin/ocx"
export CODEX_HOME="$TEST_TMP/codex \"home"
export OPENCODEX_PICKER_STATE="$HOME/.config/opencodex/picker-state.json"
# Point the live-probe at a dead port: the catalog fixture must be the only
# model source, otherwise the real ocx on this machine injects extra models.
export OPENCODEX_MODELS_URL="http://127.0.0.1:9/v1/models"
# Disable the per-provider capability probe too: the catalog fixture must be
# the only source of reasoning metadata in this offline environment.
export OPENCODEX_CAPABILITY_PROBE=0
mkdir -p "$HOME/.local/bin" "$(dirname "$OPENCODEX_REGISTRY")" "$(dirname "$OPENCODEX_AUTH_JSON")" "$CODEX_HOME"
cp "$ROOT/files/claudex-profiles.json" "$OPENCODEX_REGISTRY"
printf '{"commandcode":{"type":"api","key":"secret"}}\n' > "$OPENCODEX_AUTH_JSON"
# Minimal codex catalog so the picker lists commandcode models in this offline env.
python3 - "$OPENCODEX_REGISTRY" "$CODEX_HOME/opencodex-catalog.json" <<'PY'
import json
import sys

registry = json.load(open(sys.argv[1]))
provider = registry["providers"]["commandcode"]
models = sorted({provider["default_model"], "moonshotai/Kimi-K3", "MiniMaxAI/MiniMax-M3"})
catalog = {
    "models": [
        {
            # Encoded so hierarchy is unambiguous: '_' marks a '/', '-'
            # doubles to '--'. Neither pattern can arise from ocx's real
            # dash-joining (its '_' never survives; '--' never occurs).
            "slug": f"commandcode/{model.replace('-', '--').replace('/', '_')}",
            "default_reasoning_level": "medium",
            "supported_reasoning_levels": [
                {"effort": level} for level in ("low", "medium", "high")
            ],
        }
        for model in models
    ]
}
json.dump(catalog, open(sys.argv[2], "w"))
PY

fail() { echo "FAIL: $*" >&2; exit 1; }

cat > "$OPENCODEX_BIN" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    ensure) printf 'ensure\n' >> "$TEST_TMP/ocx-calls" ;;
    account)
        printf 'account %s\n' "${3:-}" >> "$TEST_TMP/ocx-calls"
        if [[ -e "$TEST_TMP/anthropic-login" ]]; then
            printf '{"accounts":[{"type":"oauth","needsReauth":false}]}\n'
        else
            printf '{"accounts":[]}\n'
        fi
        ;;
    login)
        printf 'login %s\n' "${2:-}" >> "$TEST_TMP/ocx-calls"
        touch "$TEST_TMP/anthropic-login"
        ;;
    sync) printf 'sync\n' >> "$TEST_TMP/ocx-calls" ;;
    claude)
        printf '%s\n' "$@" > "$TEST_TMP/claude-args"
        env | grep -E '^(ANTHROPIC_|MAX_THINKING_TOKENS=)' | sort > "$TEST_TMP/claude-env"
        # The launcher records sessions by diffing ~/.claude/projects, so the
        # stub must produce the jsonl a real claude run would.
        sid=""
        previous=""
        for arg in "$@"; do
            case "$previous" in --session-id|--resume|-r) sid="$arg" ;; esac
            previous="$arg"
        done
        if [[ -n "${EXPECT_PRECLAIM:-}" && -n "$sid" ]]; then
            grep -Fqx "$sid"$'\tcommandcode' "$HOME/.config/opencodex/sessions.tsv" \
                && touch "$TEST_TMP/session-preclaimed"
        fi
        if [[ -n "$sid" ]]; then
            jsonl="$HOME/.claude/projects/-test-proj/$sid.jsonl"
            mkdir -p "$(dirname "$jsonl")"
            printf '{"type":"user","message":{"role":"user","content":"turn"}}\n' >> "$jsonl"
        fi
        ;;
    *) printf '%s\n' "$@" > "$TEST_TMP/ocx-args" ;;
esac
EOF
cat > "$TEST_TMP/codex" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$TEST_TMP/codex-args"
EOF
cat > "$TEST_TMP/claude" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$TEST_TMP/grok" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$TEST_TMP/grok-args"
EOF
cat > "$TEST_TMP/kimi" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$TEST_TMP/kimi-args"
EOF
# Stateful fzf stub: each invocation consumes stdin and prints the next canned
# selection from fzf-responses, driving the launcher's fallback prompt chain.
cat > "$TEST_TMP/fzf" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$TEST_TMP/fzf-args"
cat > /dev/null
n=$(cat "$TEST_TMP/fzf-call" 2>/dev/null || echo 0)
n=$((n + 1))
echo "$n" > "$TEST_TMP/fzf-call"
sed -n "${n}p" "$TEST_TMP/fzf-responses"
EOF
chmod +x "$OPENCODEX_BIN" "$TEST_TMP/claude" "$TEST_TMP/codex" "$TEST_TMP/grok" "$TEST_TMP/kimi" "$TEST_TMP/fzf"
PATH="$TEST_TMP:$PATH"
export PATH

cc_default="$(jq -r '.providers.commandcode.default_model' "$OPENCODEX_REGISTRY")"
cc_opus="moonshotai/Kimi-K3"
# The fallback prompt lists display labels (routing prefix stripped), so the
# canned answers use the stripped form too.
printf '%s\n' commandcode "$cc_default" high codex > "$TEST_TMP/fzf-responses"
"$ROOT/files/opencodex"
[[ $(cat "$TEST_TMP/codex-args") == "$(printf '%s\n%s\n%s\n%s\n%s\n%s' \
    -c "$(python3 -c 'import json,sys; print("model_catalog_json=" + json.dumps(sys.argv[1]))' "$CODEX_HOME/opencodex-catalog.json")" \
    -c "$(python3 -c 'import json; print("model_reasoning_effort=" + json.dumps("high"))')" \
    -m "commandcode/$cc_default")" ]] \
    || fail "fallback picker did not launch codex with the chosen model and effort"
grep -c -- '--prompt' "$TEST_TMP/fzf-args" | grep -q '^4$' \
    || fail "fallback picker did not prompt for provider, model, effort, and harness"
jq -e --arg model "commandcode/$cc_default" '
    .version == 1 and .provider == "commandcode" and .harness == "codex"
    and .models.commandcode == $model and .efforts[$model] == "high"
' "$OPENCODEX_PICKER_STATE" >/dev/null \
    || fail "launch did not remember all four picker selections"
[[ $(grep -c '^login anthropic$' "$TEST_TMP/ocx-calls") == 1 ]] \
    || fail "pre-discovery authentication did not login exactly once"
[[ $(grep -c '^sync$' "$TEST_TMP/ocx-calls") == 1 ]] \
    || fail "fresh pre-discovery login did not sync exactly once"
[[ $(sed -n '1,4p' "$TEST_TMP/ocx-calls") == "$(printf '%s\n%s\n%s\n%s' \
    ensure 'account anthropic' 'login anthropic' sync)" ]] \
    || fail "Anthropic authentication did not finish before model discovery/launch"

printf '%s\n' commandcode "$cc_opus" max claude > "$TEST_TMP/fzf-responses"
rm -f "$TEST_TMP/fzf-call"
"$ROOT/files/opencodex"
grep -Fqx "ANTHROPIC_MODEL=commandcode/$cc_opus" "$TEST_TMP/claude-env" \
    || fail "picker model selection did not override ANTHROPIC_MODEL"
# The --model flag is the only override that beats a settings.json "model" pin.
[[ $(awk 'previous == "--model" { print; exit } { previous = $0 }' "$TEST_TMP/claude-args") == "commandcode/$cc_opus" ]] \
    || fail "claude was not launched with --model <routed model>"
! grep -q '^ANTHROPIC_DEFAULT_' "$TEST_TMP/claude-env" \
    || fail "launch still set claude alias model env vars"
grep -Fqx "MAX_THINKING_TOKENS=128000" "$TEST_TMP/claude-env" \
    || fail "picker effort selection did not set MAX_THINKING_TOKENS"
jq -e --arg model "commandcode/$cc_opus" '
    .provider == "commandcode" and .harness == "claude"
    and .models.commandcode == $model and .efforts[$model] == "max"
' "$OPENCODEX_PICKER_STATE" >/dev/null \
    || fail "launch did not update model, effort, and harness memory"

expected_model="commandcode/$(jq -r '.providers.commandcode.default_model' "$OPENCODEX_REGISTRY")"
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

override_model="$cc_opus"
"$ROOT/files/opencodex" run commandcode --model "$override_model" codex
[[ $(head -4 "$TEST_TMP/codex-args") == "$(printf '%s\n%s\n%s\n%s' \
    -c "$expected_catalog_override" -m "commandcode/$override_model")" ]] \
    || fail "run --model did not override the codex model"
"$ROOT/files/opencodex" run commandcode --effort ultra --model "$override_model" codex
[[ $(head -6 "$TEST_TMP/codex-args") == "$(printf '%s\n%s\n%s\n%s\n%s\n%s' \
    -c "$expected_catalog_override" -c "$(python3 -c 'import json; print("model_reasoning_effort=" + json.dumps("ultra"))')" \
    -m "commandcode/$override_model")" ]] \
    || fail "run --effort did not add the reasoning effort override"
"$ROOT/files/opencodex" run commandcode codex --model kept --effort low
grep -Fqx -- '--model' "$TEST_TMP/codex-args" && grep -Fqx 'kept' "$TEST_TMP/codex-args" \
    || fail "run swallowed a --model placed after the harness"
[[ $(head -4 "$TEST_TMP/codex-args") == "$(printf '%s\n%s\n%s\n%s' \
    -c "$expected_catalog_override" -m "$expected_model")" ]] \
    || fail "a --model after the harness changed the launched model"
! "$ROOT/files/opencodex" run commandcode --effort bogus codex 2>"$TEST_TMP/effort-error" \
    || fail "run accepted an invalid effort"
grep -q 'unknown reasoning effort: bogus' "$TEST_TMP/effort-error" \
    || fail "invalid effort did not produce a clear error"

! "$ROOT/files/opencodex" run bogus codex 2>"$TEST_TMP/provider-error" \
    || fail "run accepted an unknown provider"
grep -q 'unknown provider: bogus' "$TEST_TMP/provider-error" \
    || fail "an unknown provider did not produce a clear error"

mkdir -p "$(dirname "$PROVIDER_STATE_PATH")"
printf '{"version":1,"providers":{"commandcode":{"enabled":false}}}\n' > "$PROVIDER_STATE_PATH"
! "$ROOT/files/opencodex" run commandcode codex 2>"$TEST_TMP/disabled-provider-error" \
    || fail "run accepted a locally disabled provider"
grep -q 'provider is disabled: commandcode' "$TEST_TMP/disabled-provider-error" \
    || fail "a disabled provider did not produce a clear error"
rm "$PROVIDER_STATE_PATH"

"$ROOT/files/opencodex" run commandcode grok
[[ $(cat "$TEST_TMP/grok-args") == "$(printf '%s\n%s' -m "$expected_model")" ]] \
    || fail "grok harness did not receive the routed default model via -m"
"$ROOT/files/opencodex" run commandcode --model "$override_model" grok
[[ $(cat "$TEST_TMP/grok-args") == "$(printf '%s\n%s' -m "commandcode/$override_model")" ]] \
    || fail "grok harness did not receive the routed override model via -m"

"$ROOT/files/opencodex" run commandcode kimi
[[ $(cat "$TEST_TMP/kimi-args") == "$(printf '%s\n%s' -m "$expected_model")" ]] \
    || fail "kimi harness did not receive the routed default model via -m"
"$ROOT/files/opencodex" run commandcode --model "$override_model" kimi
[[ $(cat "$TEST_TMP/kimi-args") == "$(printf '%s\n%s' -m "commandcode/$override_model")" ]] \
    || fail "kimi harness did not receive the routed override model via -m"

anthropic_default=$(jq -r '.providers.anthropic.default_model' "$OPENCODEX_REGISTRY")
"$ROOT/files/opencodex" run anthropic codex
[[ $(tail -2 "$TEST_TMP/codex-args") == "$(printf '%s\n%s' -m "anthropic/$anthropic_default")" ]] \
    || fail "Anthropic OAuth profile did not route its default model"
[[ $(grep -c '^login anthropic$' "$TEST_TMP/ocx-calls") == 1 ]] \
    || fail "healthy Anthropic account repeated the pre-discovery login"
[[ $(grep -c '^sync$' "$TEST_TMP/ocx-calls") == 1 ]] \
    || fail "healthy Anthropic account repeated sync"
"$ROOT/files/opencodex" run anthropic codex
[[ $(grep -c '^login anthropic$' "$TEST_TMP/ocx-calls") == 1 ]] \
    || fail "authenticated Anthropic launch repeated OAuth login"
[[ $(grep -c '^sync$' "$TEST_TMP/ocx-calls") == 1 ]] \
    || fail "authenticated Anthropic launch repeated sync"

"$ROOT/files/opencodex" run commandcode --effort default claude
! grep -q '^MAX_THINKING_TOKENS=' "$TEST_TMP/claude-env" \
    || fail "'default' effort should not set MAX_THINKING_TOKENS"

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

EXPECT_PRECLAIM=1 "$ROOT/files/opencodex" run commandcode claude
generated_id=$(awk 'previous == "--session-id" { print; exit } { previous = $0 }' "$TEST_TMP/claude-args")
python3 - "$generated_id" <<'PY'
import sys
import uuid
uuid.UUID(sys.argv[1])
PY
grep -Fqx "$generated_id"$'\tcommandcode' "$HOME/.config/opencodex/sessions.tsv" \
    || fail "new Claude session did not record its generated UUID"
[[ -e "$TEST_TMP/session-preclaimed" ]] \
    || fail "new Claude session was not mapped before the child process started"

# A resume under the same provider refreshes the row instead of duplicating
# or clobbering it: the sidecar still holds exactly one line for the sid.
"$ROOT/files/opencodex" run commandcode claude --resume "$resume_id"
[[ $(grep -c "^$resume_id"$'\t' "$HOME/.config/opencodex/sessions.tsv") == 1 ]] \
    || fail "resume duplicated the session mapping"
grep -Fqx "$resume_id"$'\tcommandcode' "$HOME/.config/opencodex/sessions.tsv" \
    || fail "resume clobbered the session provider mapping"

# Codex, grok, and kimi harness sessions stay out of the sidecar: their ids
# are resumable through their own harnesses, and recording them here would
# mistag a same-named claude session. The earlier codex/grok/kimi launches
# must not have added rows — only the five claude launches (the picker launch,
# the --effort default launch, the two resumes, and the new session above)
# belong, all under provider commandcode.
# Arithmetic, not string, comparison: BSD wc pads its count with spaces.
(( $(wc -l < "$HOME/.config/opencodex/sessions.tsv") == 5 )) \
    || fail "sidecar holds unexpected rows beyond the five claude sessions"
! grep -Evq $'\tcommandcode$' "$HOME/.config/opencodex/sessions.tsv" \
    || fail "a session recorded under something other than its provider"

"$ROOT/files/opencodex" __apply "$OPENCODEX_REGISTRY"
# Codex Desktop resume-history sync is a macOS behaviour, so the rendered flag
# tracks the host platform rather than a fixed value.
if [[ $(uname -s) == Darwin ]]; then expected_sync=true; else expected_sync=false; fi
jq -e --argjson want "$expected_sync" '.syncResumeHistory == $want' "$OPENCODEX_CONFIG" >/dev/null \
    || fail "Codex Desktop history synchronization did not follow the platform"
jq -e '.providers.anthropic.adapter == "anthropic"
    and .providers.anthropic.authMode == "oauth"
    and .providers.anthropic.baseUrl == "https://api.anthropic.com"
    and .providers.anthropic.defaultModel == "claude-sonnet-5"
    and (.providers.anthropic | has("apiKey") | not)' "$OPENCODEX_CONFIG" >/dev/null \
    || fail "Anthropic subscription OAuth provider was not rendered"
jq -e '.providers.commandcode.apiKey == "secret"' "$OPENCODEX_CONFIG" >/dev/null \
    || fail "OpenCodex provider credentials were not rendered"
"$ROOT/files/opencodex" __status "$OPENCODEX_REGISTRY" \
    || fail "freshly applied OpenCodex config was not current"

# OpenCodex persists OAuth preset metadata while reconciling providers at
# service startup. Those runtime-owned fields must not create setup drift.
cp "$OPENCODEX_CONFIG" "$TEST_TMP/opencodex-config-clean.json"
python3 - "$OPENCODEX_CONFIG" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path) as stream:
    config = json.load(stream)
provider = config["providers"]["anthropic"]
provider.update(
    {
        "models": ["claude-sonnet-5"],
        "contextWindow": 200000,
        "modelContextWindows": {"claude-sonnet-5": 200000},
        "defaultMaxOutputTokens": 64000,
        "modelMaxOutputTokens": {"claude-sonnet-5": 64000},
        "modelInputModalities": {"claude-sonnet-5": ["text", "image"]},
        "noReasoningModels": [],
        "noVisionModels": [],
        "reasoningEfforts": ["low", "medium", "high"],
        "modelReasoningEfforts": {"claude-sonnet-5": ["low", "high"]},
        "reasoningEffortMap": {"low": "low"},
        "modelReasoningEffortMap": {"claude-sonnet-5": {"high": "high"}},
        "noTemperatureModels": [],
        "noTopPModels": [],
        "noPenaltyModels": [],
        "autoToolChoiceOnlyModels": [],
        "preserveReasoningContentModels": ["claude-sonnet-5"],
    }
)
with open(path, "w") as stream:
    json.dump(config, stream)
PY
"$ROOT/files/opencodex" __status "$OPENCODEX_REGISTRY" \
    || fail "OpenCodex OAuth runtime reconciliation fields created setup drift"

python3 - "$OPENCODEX_CONFIG" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path) as stream:
    config = json.load(stream)
config["providers"]["anthropic"]["baseUrl"] = "https://drift.example"
with open(path, "w") as stream:
    json.dump(config, stream)
PY
if "$ROOT/files/opencodex" __status "$OPENCODEX_REGISTRY"; then
    fail "setup-owned Anthropic provider drift was ignored"
fi

cp "$TEST_TMP/opencodex-config-clean.json" "$OPENCODEX_CONFIG"
python3 - "$OPENCODEX_CONFIG" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path) as stream:
    config = json.load(stream)
# API key values are intentionally redacted from status comparisons.
config["providers"]["commandcode"]["apiKey"] = "rotated-secret"
with open(path, "w") as stream:
    json.dump(config, stream)
PY
"$ROOT/files/opencodex" __status "$OPENCODEX_REGISTRY" \
    || fail "API key redaction created setup drift"
python3 - "$OPENCODEX_CONFIG" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path) as stream:
    config = json.load(stream)
config["providers"]["commandcode"]["models"] = ["runtime-field-must-not-be-ignored"]
with open(path, "w") as stream:
    json.dump(config, stream)
PY
if "$ROOT/files/opencodex" __status "$OPENCODEX_REGISTRY"; then
    fail "runtime-field drift on a key-auth provider was ignored"
fi
cp "$TEST_TMP/opencodex-config-clean.json" "$OPENCODEX_CONFIG"

python3 - "$ROOT/files/opencodex" "$OPENCODEX_REGISTRY" <<'PY'
import copy
import json
import runpy
import sys
import tempfile
import types
from pathlib import Path

namespace = runpy.run_path(sys.argv[1], run_name="opencodex_test")
assert namespace["PROVIDER_CONSUMER_MODULES"] == ("claudex", "opencodex", "refresh-models")
registry = namespace["load_registry"](Path(sys.argv[2]))
module_globals = namespace["choose_launch"].__globals__

# The neutral provider state overrides OpenAI-compatible registry defaults,
# while OAuth providers remain registry-owned.
provider_state_path = Path(tempfile.mkdtemp()) / "state.json"
module_globals["PROVIDER_STATE"] = provider_state_path
fallback_providers = namespace["enabled_providers"](registry)
assert "commandcode" in fallback_providers  # missing file preserves bootstrap behavior
provider_state_path.write_text(json.dumps({
    "version": 1,
    "providers": {
        "commandcode": {"enabled": False},
        "codex": {"enabled": False},
        "anthropic": {"enabled": False},
    },
}))
disabled_providers = namespace["enabled_providers"](registry)
assert "commandcode" not in disabled_providers
assert "codex" in disabled_providers and "anthropic" in disabled_providers
disabled_index = {
    "commandcode/hidden": {"id": "commandcode/hidden", "efforts": []},
}
assert namespace["provider_model_options"]("other", registry, disabled_index) == []

registry_disabled = copy.deepcopy(registry)
registry_disabled["providers"]["commandcode"]["enabled"] = False
provider_state_path.write_text(json.dumps({
    "version": 1,
    "providers": {"commandcode": {"enabled": True}},
}))
assert "commandcode" in namespace["enabled_providers"](registry_disabled)

provider_state_path.write_text(json.dumps({
    "version": 1,
    "providers": {"commandcode": {"enabled": False}},
}))
original_urlopen = namespace["urllib"].request.urlopen
try:
    namespace["urllib"].request.urlopen = lambda *args, **kwargs: (_ for _ in ()).throw(
        AssertionError("disabled provider was probed")
    )
    assert namespace["provider_support_index"](
        registry, {"commandcode": {"key": "secret"}}
    ) == {}
finally:
    namespace["urllib"].request.urlopen = original_urlopen

for malformed in (
    [],
    {"version": 99, "providers": {}},
    {"version": 1, "providers": {"commandcode": {"enabled": "no"}}},
):
    provider_state_path.write_text(json.dumps(malformed))
    try:
        namespace["enabled_providers"](registry)
    except namespace["UserError"] as exc:
        assert "provider state" in str(exc)
    else:
        raise AssertionError("malformed provider state was accepted")
provider_state_path.unlink()

# Provider-owned OAuth is completed synchronously before either discovery path.
events = []
original_auth = module_globals["ensure_discovery_auth"]
original_merge = module_globals["merged_model_index"]
original_picker = module_globals["picker_available"]
original_harnesses = module_globals["available_harnesses"]
original_fallback = module_globals["_choose_launch_fallback"]
try:
    module_globals["ensure_discovery_auth"] = lambda current: events.append("auth")
    def fetched(current):
        assert events == ["auth"]
        events.append("fetch")
        return {"anthropic/claude-opus-5": {"id": "anthropic/claude-opus-5", "efforts": []}}
    module_globals["merged_model_index"] = fetched
    module_globals["picker_available"] = lambda: False
    module_globals["available_harnesses"] = lambda: ["codex"]
    def fallback(providers, current, index, harnesses):
        assert "anthropic/claude-opus-5" in index
        events.append("select")
        return "anthropic", "codex", "anthropic/claude-opus-5", "default"
    module_globals["_choose_launch_fallback"] = fallback
    assert namespace["choose_launch"](registry)[2] == "anthropic/claude-opus-5"
    assert events == ["auth", "fetch", "select"]
finally:
    module_globals["ensure_discovery_auth"] = original_auth
    module_globals["merged_model_index"] = original_merge
    module_globals["picker_available"] = original_picker
    module_globals["available_harnesses"] = original_harnesses
    module_globals["_choose_launch_fallback"] = original_fallback

# A fresh account login syncs once; a healthy account does neither.
original_run = namespace["subprocess"].run
calls = []
def fresh_run(command, **kwargs):
    calls.append(command[1:])
    stdout = '{"accounts":[]}' if command[1:3] == ["account", "list"] else ""
    return types.SimpleNamespace(returncode=0, stdout=stdout, stderr="")
try:
    namespace["subprocess"].run = fresh_run
    assert namespace["ensure_provider_auth"]("anthropic") is True
    assert calls == [
        ["account", "list", "anthropic", "--json", "--all"],
        ["login", "anthropic"],
        ["sync"],
    ]
    calls.clear()
    def healthy_run(command, **kwargs):
        calls.append(command[1:])
        return types.SimpleNamespace(
            returncode=0,
            stdout='{"accounts":[{"type":"oauth","needsReauth":false}]}',
            stderr="",
        )
    namespace["subprocess"].run = healthy_run
    assert namespace["ensure_provider_auth"]("anthropic") is False
    assert calls == [["account", "list", "anthropic", "--json", "--all"]]
    def failed_sync_run(command, **kwargs):
        stdout = '{"accounts":[]}' if command[1:3] == ["account", "list"] else ""
        return types.SimpleNamespace(
            returncode=1 if command[1:] == ["sync"] else 0,
            stdout=stdout,
            stderr="",
        )
    namespace["subprocess"].run = failed_sync_run
    try:
        namespace["ensure_provider_auth"]("anthropic")
    except namespace["UserError"] as exc:
        assert str(exc) == "OpenCodex sync failed after Anthropic OAuth login; run ocx sync"
    else:
        raise AssertionError("a failed post-login sync was ignored")
finally:
    namespace["subprocess"].run = original_run
original = namespace["sys"].platform
namespace["sys"].platform = "darwin"
try:
    config, managed = namespace["desired_opencodex_config"](
        registry,
        {"providers": {"anthropic": {"authMode": "key", "apiKey": "old-key"}}},
        {},
    )
finally:
    namespace["sys"].platform = original
assert config["syncResumeHistory"] is True
assert "anthropic" in managed
assert config["providers"]["anthropic"] == {
    "adapter": "anthropic",
    "authMode": "oauth",
    "baseUrl": "https://api.anthropic.com",
    "defaultModel": "claude-sonnet-5",
}
assert config["providers"]["commandcode"]["defaultModel"] == "xiaomi/mimo-v2.5-pro"
assert config["providers"]["kimicode"]["defaultModel"] == "k3"

# A provider-only entry (no same-named profile anywhere) still supplies its
# defaultModel from the provider descriptor's default_model.
solo_registry = copy.deepcopy(registry)
solo_registry["profiles"] = []
solo_registry["providers"]["soloroute"] = {
    "provider_type": "OpenAICompatible",
    "base_url": "https://solo.example/v1",
    "api_format": "openai",
    "npm": "@ai-sdk/openai-compatible",
    "auth": {"type": "api-key", "store": "opencode", "key": "soloroute"},
    "enabled": True,
    "default_model": "solo-model",
}
namespace["validate_registry"](solo_registry)
config, _ = namespace["desired_opencodex_config"](solo_registry, {}, {"soloroute": {"key": "k"}})
assert config["providers"]["soloroute"]["defaultModel"] == "solo-model"

# The validator no longer requires a profiles array...
namespace["validate_registry"]({"version": 1, "providers": registry["providers"]})
bare = copy.deepcopy(registry)
del bare["profiles"]
namespace["validate_registry"](bare)
# ...but a malformed provider default_model is still rejected.
broken = copy.deepcopy(registry)
broken["providers"]["commandcode"]["default_model"] = ""
try:
    namespace["validate_registry"](broken)
except namespace["UserError"]:
    pass
else:
    raise AssertionError("an empty provider default_model was accepted")

index = {
    "gpt-5.6-sol": {"id": "gpt-5.6-sol", "efforts": ["low", "medium", "high"], "default_effort": "low"},
    "anthropic/claude-opus-5": {"id": "anthropic/claude-opus-5", "efforts": ["low", "medium", "high"], "default_effort": "high"},
    "commandcode/moonshotai/Kimi-K3": {"id": "commandcode/moonshotai/Kimi-K3", "efforts": ["low", "medium"], "default_effort": "low"},
    "commandcode/xiaomi/mimo-v2.5-pro": {"id": "commandcode/xiaomi/mimo-v2.5-pro", "efforts": ["low", "medium", "high"], "default_effort": "medium"},
    "kimicode/kimi-for-coding": {"id": "kimicode/kimi-for-coding", "efforts": ["low", "medium"], "default_effort": "low"},
    "unknown/mystery": {"id": "unknown/mystery", "efforts": ["low", "medium", "high"], "default_effort": "medium"},
}

providers = namespace["enabled_providers"](registry)
assert "anthropic" in providers and "codex" in providers and "commandcode" in providers and "kimicode" in providers

options = namespace["provider_model_options"]("commandcode", registry, index)
# Labels drop the routing prefix (the provider reel already names it)...
assert options[0][0] == "moonshotai/Kimi-K3"
assert [label for label, _, _ in options] == ["moonshotai/Kimi-K3", "xiaomi/mimo-v2.5-pro"]
# ...while ids keep it, since it makes the model routable.
assert [model for _, model, _ in options] == [
    "commandcode/moonshotai/Kimi-K3", "commandcode/xiaomi/mimo-v2.5-pro",
]
oauth_options = namespace["provider_model_options"]("codex", registry, index)
assert [model for _, model, _ in oauth_options] == ["gpt-5.6-sol"]  # bare ids
anthropic_options = namespace["provider_model_options"]("anthropic", registry, index)
assert [model for _, model, _ in anthropic_options] == ["anthropic/claude-opus-5"]
other = namespace["provider_model_options"]("other", registry, index)
assert [model for _, model, _ in other] == ["unknown/mystery"]  # bare ids belong to codex

state = namespace["ReelState"](providers, registry, index, list(namespace["HARNESSES"]), {})
assert state.provider_names == providers + ["other"]

def provider_walk(current, target):
    current.focus = 0  # provider-walk loops spin forever on any other reel
    while current.selected_provider() != target:
        namespace["handle_key"](current, "down")
provider_walk(state, "codex")
sel_provider, harness, model, effort = state.selection()
assert sel_provider == "codex" and harness == "claude"
assert model == "gpt-5.6-sol" and effort == "high"  # full tier: top real level
provider_walk(state, "commandcode")
namespace["handle_key"](state, "right")
assert state.selected_model() == "commandcode/moonshotai/Kimi-K3"  # alphabetical first
namespace["handle_key"](state, "down")
assert state.selected_model() == "commandcode/xiaomi/mimo-v2.5-pro"
assert state.efforts() == ["low", "medium", "high"]  # effort reel follows the model
namespace["handle_key"](state, "right")
assert state.selected_effort() == "high"  # full tier: top real level for that model
namespace["handle_key"](state, "right")
namespace["handle_key"](state, "down")
assert state.selection()[1] == "codex"  # harness reel
assert state.focus == 3
namespace["handle_key"](state, "right")
assert state.focus == 0  # focus wraps around all four reels
namespace["handle_key"](state, "left")
assert state.focus == 3  # and wraps backwards too
namespace["handle_key"](state, "left")  # back through effort...
namespace["handle_key"](state, "left")  # ...and model...
namespace["handle_key"](state, "left")  # ...to the provider reel
assert state.focus == 0
import curses as curses_mod
rows, cols = 30, 120
width, gap = namespace["reel_geometry"](cols)
wheel_right = getattr(curses_mod, "BUTTON6_PRESSED", None)
wheel_left = getattr(curses_mod, "BUTTON7_PRESSED", None)
if wheel_right is not None and wheel_left is not None:
    namespace["handle_mouse"](state, wheel_right, 0, 0, rows, cols)
    assert state.focus == 1  # horizontal wheel moves focus like the arrow keys
    namespace["handle_mouse"](state, wheel_left, 0, 0, rows, cols)
    assert state.focus == 0
click = getattr(curses_mod, "BUTTON1_PRESSED", None)
if click is not None:
    _, _, _, _, body, first_row = namespace["picker_layout"](rows, cols)
    reel_x = width + gap  # x offset of reel 1 (model)
    before = state.cursors[1]
    target_row = first_row + 2  # two entries below the centered selector
    namespace["handle_mouse"](state, click, reel_x + 1, target_row, rows, cols)
    assert state.focus == 1  # a click focuses the reel under the pointer
    assert state.cursors[1] == min(before + 2, len(state.reel_entries(1)) - 1)
    drag = getattr(curses_mod, "BUTTON1_REPEAT", None)
    if drag is not None:
        namespace["handle_mouse"](state, drag, reel_x + 1, target_row + 1, rows, cols)
        assert state.cursors[1] == min(before + 3, len(state.reel_entries(1)) - 1)
    # A click on a reel's padding (no entry under the pointer) still focuses it.
    state.focus = 0
    namespace["handle_mouse"](state, click, 2 * (width + gap) + 1, 0, rows, cols)
    assert state.focus == 2
    namespace["handle_key"](state, "left")  # ...back through effort...
    namespace["handle_key"](state, "left")  # ...to the provider reel
assert state.focus == 0

# The reel body uses all rows between the header and the hint line.
_, _, header_y, center_y, body, first_row = namespace["picker_layout"](rows, cols)
assert body >= rows - header_y - 4  # no artificial 15-row cap
assert first_row + body <= rows - 1  # and it never spills onto the hint row
assert first_row >= header_y + 1
provider_walk(state, "other")
namespace["handle_key"](state, "down")
assert state.selected_provider() == providers[0]  # the reel wraps
assert namespace["handle_key"](state, "cancel") == "cancel"

# All four last-used values seed their reels. Effort memory is keyed by the
# full routed model id so provider/model changes restore the right value.
remembered = {
    "version": 1,
    "provider": "commandcode",
    "harness": "codex",
    "models": {"commandcode": "commandcode/xiaomi/mimo-v2.5-pro"},
    "efforts": {"commandcode/xiaomi/mimo-v2.5-pro": "medium"},
}
state = namespace["ReelState"](providers, registry, index, list(namespace["HARNESSES"]), remembered)
assert state.selected_provider() == "commandcode"
assert state.selected_model() == "commandcode/xiaomi/mimo-v2.5-pro"
assert state.selected_effort() == "medium"
assert state.selection()[1] == "codex"

# Unlaunched choices are draft picker state: each model keeps its current
# effort and each provider keeps its current model while the reels are browsed.
state.focus = 1
namespace["handle_key"](state, "up")
assert state.selected_model() == "commandcode/moonshotai/Kimi-K3"
state.focus = 2
namespace["handle_key"](state, "up")
assert state.selected_effort() == "low"
state.focus = 1
namespace["handle_key"](state, "down")
assert state.selected_model() == "commandcode/xiaomi/mimo-v2.5-pro"
assert state.selected_effort() == "medium"
namespace["handle_key"](state, "up")
assert state.selected_model() == "commandcode/moonshotai/Kimi-K3"
assert state.selected_effort() == "low"
state.focus = 0
namespace["handle_key"](state, "up")
provider_walk(state, "commandcode")
assert state.selected_model() == "commandcode/moonshotai/Kimi-K3"
assert state.selected_effort() == "low"
assert remembered["models"]["commandcode"] == "commandcode/xiaomi/mimo-v2.5-pro"
assert remembered["efforts"] == {"commandcode/xiaomi/mimo-v2.5-pro": "medium"}

stale = namespace["ReelState"](
    providers,
    registry,
    index,
    list(namespace["HARNESSES"]),
    {
        "version": 1,
        "provider": "rotated-out",
        "harness": "missing",
        "models": {providers[0]: "rotated-out/model"},
        "efforts": {index[next(iter(index))]["id"]: "impossible"},
    },
)
assert stale.selected_provider() == providers[0]
assert stale.selection()[1] == namespace["HARNESSES"][0]
assert stale.cursors[1] == 0 and stale.selected_effort() in stale.efforts()

# Disk state round-trips, preserves old effort when a direct run omits it,
# migrates the legacy flat map in memory, and rejects malformed fields safely.
state_path = Path(tempfile.mkdtemp()) / "picker-state.json"
module_globals["PICKER_STATE"] = state_path
namespace["record_picker_state"]("commandcode", "commandcode/xiaomi/mimo-v2.5-pro", "medium", "codex")
namespace["record_picker_state"]("commandcode", "commandcode/xiaomi/mimo-v2.5-pro", None, "claude")
round_trip = namespace["load_picker_state"]()
assert round_trip == {
    "version": 1,
    "provider": "commandcode",
    "harness": "claude",
    "models": {"commandcode": "commandcode/xiaomi/mimo-v2.5-pro"},
    "efforts": {"commandcode/xiaomi/mimo-v2.5-pro": "medium"},
}
state_path.write_text(json.dumps({"commandcode": "commandcode/moonshotai/Kimi-K3", "bad": 7}))
legacy = namespace["load_picker_state"]()
assert legacy["models"] == {"commandcode": "commandcode/moonshotai/Kimi-K3"}
assert legacy["provider"] is None and legacy["harness"] is None
for malformed in (
    "not json",
    "[]",
    '{"version":99,"provider":"commandcode"}',
    '{"version":1,"provider":[],"harness":7,"models":null,"efforts":"high"}',
):
    state_path.write_text(malformed)
    assert namespace["load_picker_state"]() == namespace["empty_picker_state"]()

# A late-arriving index (background fetch) swaps in without losing the
# provider cursor, and a remembered model is re-applied to the new list.
loading = namespace["ReelState"](
    providers,
    registry,
    {},
    list(namespace["HARNESSES"]),
    {
        "version": 1,
        "provider": "commandcode",
        "harness": "grok",
        "models": {"commandcode": "commandcode/xiaomi/mimo-v2.5-pro"},
        "efforts": {"commandcode/xiaomi/mimo-v2.5-pro": "medium"},
    },
)
assert loading.models == []  # spinner state: no models before the fetch lands
assert "other" not in loading.provider_names
assert loading.selected_provider() == "commandcode"
assert loading.selection()[1] == "grok"
loading.swap_index(index)
assert loading.selected_provider() == "commandcode"  # provider cursor kept
assert loading.selected_model() == "commandcode/xiaomi/mimo-v2.5-pro"  # remembered re-applied
assert loading.selected_effort() == "medium"
assert loading.selection()[1] == "grok"  # provider/harness survive the late fetch
assert "other" in loading.provider_names  # late 'other' row appears
late = namespace["ReelState"](providers, registry, {}, list(namespace["HARNESSES"]), {})
late.swap_index({"unknown/mystery": {"id": "unknown/mystery", "efforts": []}})
assert late.provider_names[-1] == "other"  # the late 'other' row appears last

# The picker only offers harnesses whose subprocess entry points resolve.
original_which = namespace["shutil"].which
try:
    namespace["shutil"].which = lambda name: f"/bin/{name}" if name in {"claude", "codex"} else None
    assert namespace["available_harnesses"]() == ["claude", "codex"]
finally:
    namespace["shutil"].which = original_which
filtered = namespace["ReelState"](providers, registry, index, ["codex"], {})
assert filtered.reel_entries(3) == ["codex"]
assert filtered.selection()[1] == "codex"

# Effort choices follow the server's reasoning-support tier.
model_efforts = namespace["model_efforts"]
assert model_efforts({"efforts": ["low", "medium"]}) == ["low", "medium"]  # full: real levels
assert model_efforts({"efforts": [], "support": "partial"}) == ["none", "default"]  # partial
assert model_efforts({"efforts": []}) == ["default"]  # none
assert model_efforts({}) == ["default"]  # absent info -> default
probe = namespace["_probe_capability"]
assert probe({"supported_reasoning_levels": [{"effort": "low"}]}) == "full"
assert probe({"think_efforts": {"support": True, "values": ["low", "high"]}}) == "full"
assert probe({"reasoning_effort": True}) == "partial"
assert probe({"supports_reasoning": True}) == "partial"
assert probe({"custom_reasoning": True}) == "partial"
assert probe({"capabilities": ["completion"]}) == "none"  # no reasoning metadata
assert probe({"capabilities": ["embedding"]}) == "none"
assert probe({}) == "none"

split = namespace["split_launch_args"]
assert split(["--model", "m", "--effort", "high", "codex", "-x"]) == ("m", "high", ["codex", "-x"])
assert split(["codex", "--model", "m"]) == (None, None, ["codex", "--model", "m"])
assert split(["--effort=max", "claude"]) == (None, "max", ["claude"])
assert split([]) == (None, None, [])

known = {"commandcode/moonshotai/Kimi-K3", "gpt-5.6-sol"}
restore = namespace["_restore_catalog_slug"]
assert restore("commandcode/moonshotai-Kimi-K3", known) == "commandcode/moonshotai/Kimi-K3"
assert restore("commandcode/MiniMaxAI-MiniMax-M3", {"commandcode/MiniMaxAI/MiniMax-M3"}) == "commandcode/MiniMaxAI/MiniMax-M3"
assert restore("commandcode/moonshotai_Kimi--K3", set()) == "commandcode/moonshotai/Kimi-K3"  # '_' + '--' encoding
assert restore("commandcode/xiaomi_mimo--v2.5--pro", set()) == "commandcode/xiaomi/mimo-v2.5-pro"
assert restore("commandcode/MiniMaxAI_MiniMax--M3", set()) == "commandcode/MiniMaxAI/MiniMax-M3"
assert restore("gpt-5.6-sol", known) == "gpt-5.6-sol"
assert restore("crofai/glm-5.2", known) == "crofai/glm-5.2"

width, gap = namespace["reel_geometry"](120)
reel_at = namespace["reel_at"]
assert reel_at(0, width, gap) == 0
assert reel_at(width - 1, width, gap) == 0
assert reel_at(width, width, gap) is None  # gap between reels
assert reel_at(width + gap, width, gap) == 1
assert reel_at(3 * (width + gap), width, gap) == 3
assert reel_at(4 * (width + gap), width, gap) is None  # padding
assert reel_at(-1, width, gap) is None
PY

"$ROOT/files/opencodex" --version
grep -q '^--version$' "$TEST_TMP/ocx-args" || fail "OpenCodex CLI arguments were not forwarded"

echo "opencodex launcher tests passed"
