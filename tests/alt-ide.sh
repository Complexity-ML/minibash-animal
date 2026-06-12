#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
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

cat > "$TMP/bin/alt-edit" <<'EOF'
#!/usr/bin/env bash
echo "edit $1"
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
export ALT_IDE_EDIT_BIN="$TMP/bin/alt-edit"
export ALT_IDE_DEV_ENV_BIN="$TMP/bin/alt-agent"
export ALT_IDE_SHELL_LINT_BIN="$TMP/bin/alt-agent"

bash "$ROOT/rootfs/bin/alt-ide" workspace status > "$TMP/workspace.out"
grep -q "Altitude IDE workspace" "$TMP/workspace.out"
grep -q "dev-env-ok" "$TMP/workspace.out"

bash "$ROOT/rootfs/bin/alt-ide" files list demo > "$TMP/files.out"
grep -q "scripts/demo.sh" "$TMP/files.out"

bash "$ROOT/rootfs/bin/alt-ide" files open scripts/demo.sh > "$TMP/open.out"
grep -q "edit scripts/demo.sh" "$TMP/open.out"

bash "$ROOT/rootfs/bin/alt-ide" actions list > "$TMP/actions.out"
grep -q "^agent.context" "$TMP/actions.out"
grep -q "^language.bash.lint" "$TMP/actions.out"

bash "$ROOT/rootfs/bin/alt-ide" actions run files.list demo > "$TMP/action-files.out"
grep -q "scripts/demo.sh" "$TMP/action-files.out"

bash "$ROOT/rootfs/bin/alt-ide" actions run diagnostics.quick scripts/demo.sh > "$TMP/action-quick.out"
grep -q "shell-lint-ok scripts/demo.sh" "$TMP/action-quick.out"

bash "$ROOT/rootfs/bin/alt-ide" language list > "$TMP/languages.out"
grep -q "^bash$" "$TMP/languages.out"

bash "$ROOT/rootfs/bin/alt-ide" language bash lint scripts/demo.sh > "$TMP/lint.out"
grep -q "shell-lint-ok scripts/demo.sh" "$TMP/lint.out"

bash "$ROOT/rootfs/bin/alt-ide" language bash run scripts/demo.sh > "$TMP/run.out"
grep -q "^demo$" "$TMP/run.out"

bash "$ROOT/rootfs/bin/alt-ide" language bash new scripts/new.sh > "$TMP/new.out"
grep -q "edit scripts/new.sh" "$TMP/new.out"
grep -q "set -euo pipefail" "$TMP/workspace/scripts/new.sh"

bash "$ROOT/rootfs/bin/alt-ide" agent context scripts/demo.sh > "$TMP/context.out"
grep -q "Altitude IDE Agent Context" "$TMP/context.out"
grep -q "scripts/demo.sh" "$TMP/context.out"

bash "$ROOT/rootfs/bin/alt-ide" agent doctor scripts/demo.sh > "$TMP/doctor.out"
grep -q "Altitude IDE Agent Doctor" "$TMP/doctor.out"
grep -q "shell-lint-ok scripts/demo.sh" "$TMP/doctor.out"

bash "$ROOT/rootfs/bin/alt-ide" agent plan "add bash diagnostics" > "$TMP/plan.out"
grep -q "Altitude IDE Agent Plan" "$TMP/plan.out"
grep -q "add bash diagnostics" "$TMP/plan.out"

bash "$ROOT/rootfs/bin/alt-ide" agent next > "$TMP/next.out"
grep -q "Altitude IDE Next Upgrades" "$TMP/next.out"
grep -q "alt-ide actions list" "$TMP/next.out"

echo "Altitude IDE: ok"
