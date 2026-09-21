#!/usr/bin/env zsh
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SKILL="$ROOT/agents/skills/agent-with-agent/SKILL.md"

[[ -f "$SKILL" ]]
grep -q '^name: agent-with-agent$' "$SKILL"
grep -q 'canonical live skill' "$SKILL"
grep -q 'https://awa.lost.plus/skill.md' "$SKILL"
! grep -q '^## Mint' "$SKILL"
! grep -q '^## Join' "$SKILL"

echo "agent-with-agent skill tests passed"
