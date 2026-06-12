#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ALT_IDE_UNDER_TEST="${ALT_IDE_UNDER_TEST:-$ROOT/rootfs/bin/alt-ide}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin" "$TMP/workspace/scripts" "$TMP/workspace/rootfs/bin"

cat > "$TMP/bin/alt-agent" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  status) echo "agent-status" ;;
  dev-env) echo "dev-env-ok" ;;
  dev-check) echo "dev-check-ok" ;;
  shell-lint) echo "shell-lint-ok ${*:2}" ;;
  recipes) echo demo ;;
  publish-staging) echo publish ;;
  systemd-audit) echo audit ;;
  *) echo "bad agent command: $*" >&2; exit 64 ;;
esac
EOF

chmod +x "$TMP/bin/"*

cat > "$TMP/workspace/scripts/demo.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo demo
EOF
chmod +x "$TMP/workspace/scripts/demo.sh"
echo helper > "$TMP/workspace/rootfs/bin/helper"

export ALTITUDE_AGENT_SOURCE_ROOT="$TMP/workspace"
export ALT_IDE_AGENT_BIN="$TMP/bin/alt-agent"
export ALT_IDE_DEV_ENV_BIN="$TMP/bin/alt-agent"
export ALT_IDE_SHELL_LINT_BIN="$TMP/bin/alt-agent"
export ALT_IDE_STATE_DIR="$TMP/state"
export ALT_IDE_LOG="$TMP/ide.log"

bash "$ALT_IDE_UNDER_TEST" workspace status > "$TMP/workspace.out"
grep -q "Altitude IDE workspace" "$TMP/workspace.out"
grep -q "dev-env-ok" "$TMP/workspace.out"

bash "$ALT_IDE_UNDER_TEST" files list demo > "$TMP/files.out"
grep -q "scripts/demo.sh" "$TMP/files.out"

bash "$ALT_IDE_UNDER_TEST" files open scripts/demo.sh > "$TMP/open.out"
grep -q "path=scripts/demo.sh" "$TMP/open.out"
grep -q "^echo demo$" "$TMP/open.out"

bash "$ALT_IDE_UNDER_TEST" session start test > "$TMP/session-start.out"
grep -q "Altitude IDE session started" "$TMP/session-start.out"
grep -q "^id=" "$TMP/state/current"

bash "$ALT_IDE_UNDER_TEST" session status > "$TMP/session-status.out"
grep -q "workspace=$TMP/workspace" "$TMP/session-status.out"

bash "$ALT_IDE_UNDER_TEST" session run agent.context scripts/demo.sh > "$TMP/session-action.out"
grep -q "Altitude IDE Agent Context" "$TMP/session-action.out"
bash "$ALT_IDE_UNDER_TEST" session tail 10 > "$TMP/session-tail.out"
grep -q "action.start" "$TMP/session-tail.out"
grep -q "action.ok" "$TMP/session-tail.out"

bash "$ALT_IDE_UNDER_TEST" actions list > "$TMP/actions.out"
grep -q "^agent.context" "$TMP/actions.out"
grep -q "^language.bash.lint" "$TMP/actions.out"
grep -q "^language.bash.snippets" "$TMP/actions.out"

bash "$ALT_IDE_UNDER_TEST" actions run files.list demo > "$TMP/action-files.out"
grep -q "scripts/demo.sh" "$TMP/action-files.out"

bash "$ALT_IDE_UNDER_TEST" actions run diagnostics.quick scripts/demo.sh > "$TMP/action-quick.out"
grep -q "shell-lint-ok scripts/demo.sh" "$TMP/action-quick.out"

bash "$ALT_IDE_UNDER_TEST" language list > "$TMP/languages.out"
grep -q "^bash$" "$TMP/languages.out"

bash "$ALT_IDE_UNDER_TEST" language bash lint scripts/demo.sh > "$TMP/lint.out"
grep -q "shell-lint-ok scripts/demo.sh" "$TMP/lint.out"

bash "$ALT_IDE_UNDER_TEST" language bash run scripts/demo.sh > "$TMP/run.out"
grep -q "^demo$" "$TMP/run.out"

bash "$ALT_IDE_UNDER_TEST" language bash new scripts/new.sh > "$TMP/new.out"
grep -q "created=scripts/new.sh" "$TMP/new.out"
grep -q "set -euo pipefail" "$TMP/workspace/scripts/new.sh"

bash "$ALT_IDE_UNDER_TEST" language bash snippets > "$TMP/snippets.out"
grep -q "^strict" "$TMP/snippets.out"
grep -q "^service" "$TMP/snippets.out"

bash "$ALT_IDE_UNDER_TEST" language bash snippet log > "$TMP/snippet-log.out"
grep -q "^log()" "$TMP/snippet-log.out"
grep -q "^die()" "$TMP/snippet-log.out"

bash "$ALT_IDE_UNDER_TEST" agent context scripts/demo.sh > "$TMP/context.out"
grep -q "Altitude IDE Agent Context" "$TMP/context.out"
grep -q "scripts/demo.sh" "$TMP/context.out"

bash "$ALT_IDE_UNDER_TEST" agent doctor scripts/demo.sh > "$TMP/doctor.out"
grep -q "Altitude IDE Agent Doctor" "$TMP/doctor.out"
grep -q "shell-lint-ok scripts/demo.sh" "$TMP/doctor.out"

bash "$ALT_IDE_UNDER_TEST" agent plan "add bash diagnostics" > "$TMP/plan.out"
grep -q "Altitude IDE Agent Plan" "$TMP/plan.out"
grep -q "add bash diagnostics" "$TMP/plan.out"

bash "$ALT_IDE_UNDER_TEST" agent next > "$TMP/next.out"
grep -q "Altitude IDE Next Upgrades" "$TMP/next.out"
grep -q "alt-ide actions list" "$TMP/next.out"

echo "Altitude IDE: ok"
