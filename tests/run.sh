#!/usr/bin/env bash
# fluxkit test suite
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FLUXKIT="$ROOT/fluxkit"
WORK_ROOT="$ROOT/tests/.work"
TMP=""
PASS=0
FAIL=0

mkdir -p "$WORK_ROOT"

new_work_dir() {
  mktemp -d "$WORK_ROOT/run.XXXXXX"
}

cleanup() {
  if [[ -n "$TMP" && -d "$TMP" ]]; then
    rm -rf "$TMP"
  fi
}
trap cleanup EXIT

assert_eq() {
  local got="$1" want="$2" msg="${3:-}"
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS + 1))
  else
    echo "FAIL: ${msg:-assert_eq}"
    echo "  want: $want"
    echo "  got:  $got"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" msg="${3:-}"
  if [[ "$haystack" == *"$needle"* ]]; then
    PASS=$((PASS + 1))
  else
    echo "FAIL: ${msg:-assert_contains}"
    echo "  needle: $needle"
    echo "  haystack: $haystack"
    FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local haystack="$1" needle="$2" msg="${3:-}"
  if [[ "$haystack" != *"$needle"* ]]; then
    PASS=$((PASS + 1))
  else
    echo "FAIL: ${msg:-assert_not_contains}"
    echo "  needle: $needle"
    echo "  haystack: $haystack"
    FAIL=$((FAIL + 1))
  fi
}

assert_file_exists() {
  local file="$1" msg="${2:-}"
  if [[ -f "$file" ]]; then
    PASS=$((PASS + 1))
  else
    echo "FAIL: ${msg:-missing file}: $file"
    FAIL=$((FAIL + 1))
  fi
}

new_git_repo() {
  local dir="$1"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" config user.email "test@test.com"
  git -C "$dir" config user.name "Test"
  echo "# test" >"$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" commit -qm "init"
}

setup_mock_flux() {
  local bindir="$1"
  mkdir -p "$bindir"
  cat >"$bindir/flux" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "serve" ]]; then
  port=""
  data=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -p|--port) port="$2"; shift 2 ;;
      --data) data="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  echo "mock flux serve port=$port data=$data" >&2
  if command -v python3 >/dev/null 2>&1; then
    exec python3 - "$port" <<'PY'
import socket, sys, os, signal
port = int(sys.argv[1])
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", port))
s.listen(1)
signal.signal(signal.SIGTERM, lambda *_: os._exit(0))
import time
while True:
    time.sleep(3600)
PY
  else
    sleep 3600
  fi
fi
if [[ "${1:-}" == "project" && "${2:-}" == "list" && "${3:-}" == "--json" ]]; then
  echo '[{"id":"proj_test","name":"Test"}]'
  exit 0
fi
echo "mock flux: unknown args: $*" >&2
exit 1
MOCK
  chmod +x "$bindir/flux"
}

FLUXKIT_NO_MAIN=1
# shellcheck source=/dev/null
source "$FLUXKIT"
unset FLUXKIT_NO_MAIN

run_fluxkit() {
  "$FLUXKIT" "$@"
}

base="${FLUXKIT_PORT_BASE:-42000}"
span="${FLUXKIT_PORT_SPAN:-1000}"

echo "== stable port hashing =="
TMP="$(new_work_dir)"
new_git_repo "$TMP/repo-a"
new_git_repo "$TMP/repo-b"
pushd "$TMP/repo-a" >/dev/null
p1="$(fluxkit_preferred_port)"
p2="$(fluxkit_preferred_port)"
assert_eq "$p1" "$p2" "preferred port stable for same repo"
pa="$p1"
popd >/dev/null
pushd "$TMP/repo-b" >/dev/null
pb="$(fluxkit_preferred_port)"
popd >/dev/null
if [[ "$pa" != "$pb" ]]; then
  PASS=$((PASS + 1))
else
  echo "FAIL: different repos should usually get different ports (got same $pa)"
  FAIL=$((FAIL + 1))
fi
pushd "$TMP/repo-a" >/dev/null
p="$(fluxkit_preferred_port)"
popd >/dev/null
if (( p >= base && p < base + span )); then
  PASS=$((PASS + 1))
else
  echo "FAIL: port $p outside range $base-$((base + span - 1))"
  FAIL=$((FAIL + 1))
fi
rm -rf "$TMP"
TMP=""

echo "== deterministic collision fallback =="
TMP="$(new_work_dir)"
new_git_repo "$TMP/repo"
pushd "$TMP/repo" >/dev/null
preferred="$(fluxkit_preferred_port)"
fluxkit_port_in_use() {
  local port="$1"
  [[ "$port" == "$preferred" ]]
}
got="$(fluxkit_find_ui_port "$preferred")"
want=$((preferred + 1))
if (( want >= base + span )); then
  want=$base
fi
assert_eq "$got" "$want" "collision fallback to preferred+1"
popd >/dev/null
rm -rf "$TMP"
TMP=""

echo "== idempotent init =="
TMP="$(new_work_dir)"
MOCK_BIN="$TMP/bin"
setup_mock_flux "$MOCK_BIN"
export FLUXKIT_FLUX_CMD="$MOCK_BIN/flux"
new_git_repo "$TMP/project"
pushd "$TMP/project" >/dev/null
run_fluxkit init
run_fluxkit init
assert_file_exists ".flux/data.json"
assert_file_exists ".flux/config.json"
assert_file_exists ".flux/project.json"
data1="$(cat .flux/data.json)"
run_fluxkit init
data2="$(cat .flux/data.json)"
assert_eq "$data1" "$data2" "data.json preserved on re-init"
count="$(grep -c 'BEGIN FLUXKIT MANAGED BLOCK' AGENTS.md || true)"
assert_eq "$count" "1" "single managed block after re-init"
popd >/dev/null
rm -rf "$TMP"
TMP=""

echo "== generated Cursor MCP config =="
TMP="$(new_work_dir)"
MOCK_BIN="$TMP/bin"
setup_mock_flux "$MOCK_BIN"
export FLUXKIT_FLUX_CMD="$MOCK_BIN/flux"
new_git_repo "$TMP/project"
pushd "$TMP/project" >/dev/null
run_fluxkit init
assert_file_exists ".cursor/mcp.json"
content="$(cat .cursor/mcp.json)"
assert_contains "$content" '"flux"' "cursor flux entry"
assert_contains "$content" '.flux/bin/mcp' "cursor mcp path"
assert_not_contains "$content" 'workspaceFolder' "cursor mcp avoids workspaceFolder"
popd >/dev/null
rm -rf "$TMP"
TMP=""

echo "== migrates legacy Cursor MCP config =="
TMP="$(new_work_dir)"
MOCK_BIN="$TMP/bin"
setup_mock_flux "$MOCK_BIN"
export FLUXKIT_FLUX_CMD="$MOCK_BIN/flux"
new_git_repo "$TMP/project"
pushd "$TMP/project" >/dev/null
mkdir -p .cursor
cat > .cursor/mcp.json <<'EOF'
{
  "mcpServers": {
    "flux": {
      "type": "stdio",
      "command": "${workspaceFolder}/.flux/bin/mcp"
    }
  }
}
EOF
run_fluxkit init
content="$(cat .cursor/mcp.json)"
assert_contains "$content" '"command": ".flux/bin/mcp"' "cursor mcp migrated command"
assert_not_contains "$content" 'workspaceFolder' "cursor mcp migration removes workspaceFolder"
popd >/dev/null
rm -rf "$TMP"
TMP=""

echo "== generated Codex MCP config =="
TMP="$(new_work_dir)"
MOCK_BIN="$TMP/bin"
setup_mock_flux "$MOCK_BIN"
export FLUXKIT_FLUX_CMD="$MOCK_BIN/flux"
new_git_repo "$TMP/project"
pushd "$TMP/project" >/dev/null
run_fluxkit init
assert_file_exists ".codex/config.toml"
content="$(cat .codex/config.toml)"
assert_contains "$content" '[mcp_servers.flux]' "codex flux section"
assert_contains "$content" '.flux/bin/mcp' "codex mcp command"
popd >/dev/null
rm -rf "$TMP"
TMP=""

echo "== AGENTS.md creation when missing =="
TMP="$(new_work_dir)"
MOCK_BIN="$TMP/bin"
setup_mock_flux "$MOCK_BIN"
export FLUXKIT_FLUX_CMD="$MOCK_BIN/flux"
new_git_repo "$TMP/project"
pushd "$TMP/project" >/dev/null
run_fluxkit init
assert_file_exists "AGENTS.md"
assert_contains "$(cat AGENTS.md)" "BEGIN FLUXKIT MANAGED BLOCK" "agents begin marker"
  assert_contains "$(cat AGENTS.md)" "Flux task workflow" "agents workflow section"
  assert_contains "$(cat AGENTS.md)" "Do not read or edit \`.flux/data.json\` or \`.flux/project.json\` directly" "agents MCP-only flux file access"
popd >/dev/null
rm -rf "$TMP"
TMP=""

echo "== AGENTS.md extension when existing =="
TMP="$(new_work_dir)"
MOCK_BIN="$TMP/bin"
setup_mock_flux "$MOCK_BIN"
export FLUXKIT_FLUX_CMD="$MOCK_BIN/flux"
new_git_repo "$TMP/project"
pushd "$TMP/project" >/dev/null
echo "# Custom intro" >AGENTS.md
echo "Keep this line." >>AGENTS.md
run_fluxkit init
content="$(cat AGENTS.md)"
assert_contains "$content" "Custom intro" "preserved user header"
assert_contains "$content" "Keep this line." "preserved user content"
assert_contains "$content" "BEGIN FLUXKIT MANAGED BLOCK" "appended managed block"
popd >/dev/null
rm -rf "$TMP"
TMP=""

echo "== AGENTS.md managed block replacement =="
TMP="$(new_work_dir)"
new_git_repo "$TMP/project"
pushd "$TMP/project" >/dev/null
cat >AGENTS.md <<'EOF'
# Project

<!-- BEGIN FLUXKIT MANAGED BLOCK -->
old content
<!-- END FLUXKIT MANAGED BLOCK -->
EOF
fluxkit_update_agents_md AGENTS.md
content="$(cat AGENTS.md)"
assert_contains "$content" "# Project" "header kept"
assert_contains "$content" "Flux task workflow" "new block content"
if [[ "$content" == *"old content"* ]]; then
  echo "FAIL: old managed content should be replaced"
  FAIL=$((FAIL + 1))
else
  PASS=$((PASS + 1))
fi
popd >/dev/null
rm -rf "$TMP"
TMP=""

echo "== malformed AGENTS.md marker detection =="
TMP="$(new_work_dir)"
new_git_repo "$TMP/project"
pushd "$TMP/project" >/dev/null
echo "<!-- BEGIN FLUXKIT MANAGED BLOCK -->" >AGENTS.md
fluxkit_die() { return 1; }
set +e
fluxkit_update_agents_md AGENTS.md >/dev/null 2>&1
rc=$?
set -e
assert_eq "$rc" "1" "malformed markers exit non-zero"
unset -f fluxkit_die 2>/dev/null || true
FLUXKIT_NO_MAIN=1
# shellcheck source=/dev/null
source "$FLUXKIT"
unset FLUXKIT_NO_MAIN
popd >/dev/null
rm -rf "$TMP"
TMP=""

echo "== runtime.env parsing =="
TMP="$(new_work_dir)"
new_git_repo "$TMP/project"
pushd "$TMP/project" >/dev/null
mkdir -p .flux
canonical="$(fluxkit_canonical_path "$(pwd)")"
cat >.flux/runtime.env <<EOF
FLUX_SERVER=http://127.0.0.1:42424
FLUX_UI_PORT=42424
FLUX_UI_PID=$$
FLUX_REPO_ROOT=$canonical
EOF
info="$(fluxkit_ui_running_info)"
assert_contains "$info" "preferred=" "runtime info includes preferred"
assert_contains "$info" "port=42424" "runtime info includes port"
popd >/dev/null
rm -rf "$TMP"
TMP=""

echo "== doctor checks =="
TMP="$(new_work_dir)"
MOCK_BIN="$TMP/bin"
setup_mock_flux "$MOCK_BIN"
export FLUXKIT_FLUX_CMD="$MOCK_BIN/flux"
new_git_repo "$TMP/project"
pushd "$TMP/project" >/dev/null
set +e
run_fluxkit doctor >/dev/null 2>&1
rc=$?
set -e
assert_eq "$rc" "1" "doctor fails before init"
run_fluxkit init >/dev/null
set +e
run_fluxkit doctor >/dev/null 2>&1
rc=$?
set -e
assert_eq "$rc" "0" "doctor passes after init"
popd >/dev/null
rm -rf "$TMP"
TMP=""

echo "== safe ui down refuses unrelated PID =="
TMP="$(new_work_dir)"
MOCK_BIN="$TMP/bin"
setup_mock_flux "$MOCK_BIN"
export FLUXKIT_FLUX_CMD="$MOCK_BIN/flux"
new_git_repo "$TMP/project"
pushd "$TMP/project" >/dev/null
mkdir -p .flux
canonical="$(fluxkit_canonical_path "$(pwd)")"
cat >.flux/runtime.env <<EOF
FLUX_SERVER=http://127.0.0.1:42424
FLUX_UI_PORT=42424
FLUX_UI_PID=$$
FLUX_REPO_ROOT=$canonical
EOF
set +e
run_fluxkit ui down >/dev/null 2>&1
rc=$?
set -e
assert_eq "$rc" "1" "ui down refuses unrelated process"
kill -0 $$ 2>/dev/null && PASS=$((PASS + 1)) || { echo "FAIL: test process was killed"; FAIL=$((FAIL + 1)); }
popd >/dev/null
rm -rf "$TMP"
TMP=""

echo "== gitignore idempotency =="
TMP="$(new_work_dir)"
new_git_repo "$TMP/project"
pushd "$TMP/project" >/dev/null
echo "node_modules/" >.gitignore
fluxkit_update_gitignore "$(pwd)"
fluxkit_update_gitignore "$(pwd)"
count="$(grep -c '^\.flux/runtime\.env$' .gitignore || true)"
assert_eq "$count" "1" "runtime.env gitignore entry not duplicated"
count="$(grep -c '^\.flux/ui\.log$' .gitignore || true)"
assert_eq "$count" "1" "ui.log gitignore entry not duplicated"
popd >/dev/null
rm -rf "$TMP"
TMP=""

echo "== flux CLI requires bun unless overridden =="
TMP="$(new_work_dir)"
MOCK_BIN="$TMP/bin"
setup_mock_flux "$MOCK_BIN"
if FLUXKIT_FLUX_CMD="$MOCK_BIN/flux" fluxkit_flux_cli_runnable >/dev/null 2>&1; then
  PASS=$((PASS + 1))
else
  echo "FAIL: FLUXKIT_FLUX_CMD override should be runnable without bun"
  FAIL=$((FAIL + 1))
fi
unset FLUXKIT_FLUX_CMD
if command -v flux >/dev/null 2>&1 && ! command -v bun >/dev/null 2>&1; then
  if fluxkit_flux_cli_runnable >/dev/null 2>&1; then
    echo "FAIL: flux without bun should not be considered runnable"
    FAIL=$((FAIL + 1))
  else
    PASS=$((PASS + 1))
  fi
else
  PASS=$((PASS + 1))
fi
rm -rf "$TMP"
TMP=""

echo "== licensing =="
assert_file_exists "$ROOT/LICENSE" "LICENSE file exists"
assert_contains "$(head -20 "$FLUXKIT")" "SPDX-License-Identifier: GPL-3.0-or-later" "fluxkit SPDX header"
assert_contains "$(cat "$ROOT/README.md")" "Does Fluxkit make my project GPL?" "README GPL clarification"
assert_contains "$(cat "$ROOT/README.md")" "GPL-3.0-or-later" "README license identifier"

echo "== repo root stays clean =="
if [[ ! -d "$ROOT/.flux" && ! -d "$ROOT/.cursor" && ! -d "$ROOT/.codex" && ! -f "$ROOT/AGENTS.md" ]]; then
  PASS=$((PASS + 1))
else
  echo "FAIL: fluxkit source repo must not contain generated init artifacts"
  echo "  remove .flux/, .cursor/, .codex/, and AGENTS.md from repo root"
  FAIL=$((FAIL + 1))
fi
if [[ "$WORK_ROOT" == "$ROOT/tests/.work" ]]; then
  PASS=$((PASS + 1))
else
  echo "FAIL: tests must use gitignored tests/.work for ephemeral repos"
  FAIL=$((FAIL + 1))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
if (( FAIL > 0 )); then
  exit 1
fi
exit 0
