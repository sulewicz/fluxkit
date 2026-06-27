#!/usr/bin/env bash
# fluxkit test suite
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FLUXKIT="$ROOT/fluxkit"
WORK_ROOT="$ROOT/tests/.work"
TMP=""
PASS=0
FAIL=0
ORIG_HOME="${HOME:-}"
ORIG_CODEX_HOME_SET=0
ORIG_CODEX_HOME=""
if [[ "${CODEX_HOME+x}" == "x" ]]; then
  ORIG_CODEX_HOME_SET=1
  ORIG_CODEX_HOME="$CODEX_HOME"
fi

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

setup_mock_container() {
  local bindir="$1"
  local command_name="${2:-engine}"
  mkdir -p "$bindir"
  cat >"$bindir/$command_name" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  info)
    if [[ "${MOCK_CONTAINER_INFO_FAIL_CMDS:-}" == *"|$(basename "$0")|"* ]]; then
      exit 1
    fi
    exit 0
    ;;
  ps)
    shift
    format=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --format)
          format="$2"
          shift 2
          ;;
        --filter)
          shift 2
          ;;
        *)
          shift
          ;;
      esac
    done
    if [[ -n "${MOCK_CONTAINER_PS_FORMAT_LOG:-}" ]]; then
      printf '%s\n' "$format" >>"$MOCK_CONTAINER_PS_FORMAT_LOG"
    fi
    if [[ "$format" == *".ID"* && "$format" == *".Names"* && "$format" != *".Ports"* ]]; then
      [[ -n "${MOCK_CONTAINER_PS_TARGETS:-}" ]] && printf '%s\n' "$MOCK_CONTAINER_PS_TARGETS"
    else
      [[ -n "${MOCK_CONTAINER_PS_ROWS:-}" ]] && printf '%s\n' "$MOCK_CONTAINER_PS_ROWS"
    fi
    exit 0
    ;;
  inspect)
    shift
    format=""
    if [[ "${1:-}" == "-f" ]]; then
      format="$2"
      shift 2
    fi
    target="${1:-}"
    if [[ "$format" == *"fluxkit.state_mode"* && "$format" == *"fluxkit.data_file"* ]]; then
      values=()
      for label in fluxkit.state_mode fluxkit.external_scope fluxkit.branch fluxkit.repo_root fluxkit.data_file; do
        found=""
        while IFS=$'\t' read -r label_target label_name label_value; do
          if [[ "$label_target" == "$target" && "$label_name" == "$label" ]]; then
            found="$label_value"
            break
          fi
        done <<< "${MOCK_CONTAINER_LABELS:-}"
        values+=("$found")
      done
      printf '%s|%s|%s|%s|%s\n' "${values[@]}"
      exit 0
    fi
    case "$format" in
      "{{.State.Running}}")
        if [[ "${MOCK_CONTAINER_RUNNING_TARGETS:-}" == *"|$target|"* ]]; then
          echo true
        else
          echo false
        fi
        ;;
      "{{ index .Config.Labels "*)
        label="${format#*\"}"
        label="${label%%\"*}"
        found=""
        while IFS=$'\t' read -r label_target label_name label_value; do
          if [[ "$label_target" == "$target" && "$label_name" == "$label" ]]; then
            found="$label_value"
            break
          fi
        done <<< "${MOCK_CONTAINER_LABELS:-}"
        echo "$found"
        ;;
      "{{.Name}}")
        found=""
        while IFS=$'\t' read -r name_target name_value; do
          if [[ "$name_target" == "$target" ]]; then
            found="$name_value"
            break
          fi
        done <<< "${MOCK_CONTAINER_NAMES:-}"
        [[ -n "$found" ]] || found="$target"
        echo "/$found"
        ;;
      *)
        if [[ -n "$target" && "${MOCK_CONTAINER_INSPECT_TARGETS:-}" == *"|$target|"* ]]; then
          echo "{}"
        else
          exit 1
        fi
        ;;
    esac
    exit 0
    ;;
  rm)
    shift
    if [[ "${1:-}" == "-f" ]]; then
      shift
    fi
    if [[ -n "${MOCK_CONTAINER_RM_LOG:-}" ]]; then
      printf '%s %s\n' "$(basename "$0")" "$*" >>"$MOCK_CONTAINER_RM_LOG"
    fi
    exit 0
    ;;
  logs)
    exit 0
    ;;
  run)
    echo "mock-container"
    exit 0
    ;;
esac
echo "mock container: unknown args: $*" >&2
exit 1
MOCK
  chmod +x "$bindir/$command_name"
}

FLUXKIT_NO_MAIN=1
# shellcheck source=/dev/null
source "$FLUXKIT"
unset FLUXKIT_NO_MAIN

run_fluxkit() {
  "$FLUXKIT" "$@"
}

restore_user_env() {
  export HOME="$ORIG_HOME"
  unset XDG_DATA_HOME XDG_STATE_HOME
  if (( ORIG_CODEX_HOME_SET )); then
    export CODEX_HOME="$ORIG_CODEX_HOME"
  else
    unset CODEX_HOME
  fi
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

echo "== container engine discovery =="
TMP="$(new_work_dir)"
MOCK_BIN="$TMP/bin"
setup_mock_container "$MOCK_BIN" podman
OLD_PATH="$PATH"
PATH="$MOCK_BIN"
found_container_cmd="$(fluxkit_find_container_cmd)"
PATH="$OLD_PATH"
assert_eq "$found_container_cmd" "$MOCK_BIN/podman" "podman is discovered when docker is unavailable"
rm -rf "$TMP"
TMP=""

TMP="$(new_work_dir)"
MOCK_BIN="$TMP/bin"
setup_mock_container "$MOCK_BIN" docker
setup_mock_container "$MOCK_BIN" podman
OLD_PATH="$PATH"
PATH="$MOCK_BIN:$OLD_PATH"
export MOCK_CONTAINER_INFO_FAIL_CMDS="|docker|"
found_container_cmd="$(fluxkit_find_container_cmd)"
PATH="$OLD_PATH"
assert_eq "$found_container_cmd" "$MOCK_BIN/podman" "podman is discovered when docker is installed but unavailable"
podman_user_args="$(fluxkit_container_user_args "$MOCK_BIN/podman")"
docker_user_args="$(fluxkit_container_user_args "$MOCK_BIN/docker")"
assert_contains "$podman_user_args" "--userns
keep-id" "podman uses keep-id user namespace for bind mount writes"
assert_contains "$podman_user_args" "--user
$(id -u):$(id -g)" "podman still runs as the invoking uid/gid"
assert_not_contains "$docker_user_args" "--userns" "docker does not receive podman-only user namespace flags"
rm -rf "$TMP"
TMP=""
unset MOCK_CONTAINER_INFO_FAIL_CMDS

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
assert_contains "$(cat .flux/bin/mcp)" "for candidate in docker podman" "generated mcp launcher discovers docker or podman"
assert_contains "$(cat .flux/bin/mcp)" "docker.io/sirsjg/flux-mcp:latest" "generated mcp launcher uses fully qualified default image"
assert_contains "$(cat .flux/bin/mcp)" "--userns keep-id" "generated mcp launcher handles rootless podman bind mount writes"
assert_contains "$(cat .flux/bin/mcp)" "FLUXKIT_CONTAINER_VOLUME_SUFFIX" "generated mcp launcher supports container volume suffix"
assert_not_contains "$(grep -v '^[[:space:]]*#' .flux/bin/mcp)" "mapfile -t" "generated mcp launcher avoids Bash 4-only mapfile"
configured_output="$(run_fluxkit configured)"
assert_contains "$configured_output" "configured: yes" "configured reports local setup"
assert_contains "$configured_output" "mode: local" "configured reports local mode"
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

echo "== external branch-scoped init =="
TMP="$(new_work_dir)"
MOCK_BIN="$TMP/bin"
setup_mock_flux "$MOCK_BIN"
setup_mock_container "$MOCK_BIN"
export FLUXKIT_FLUX_CMD="$MOCK_BIN/flux"
export FLUXKIT_CONTAINER_CMD="$MOCK_BIN/engine"
export HOME="$TMP/home"
export XDG_DATA_HOME="$HOME/.local/share"
export XDG_STATE_HOME="$HOME/.local/state"
export CODEX_HOME="$HOME/.codex"
new_git_repo "$TMP/project"
pushd "$TMP/project" >/dev/null
run_fluxkit init -e branch
if [[ ! -e .flux && ! -e .cursor && ! -e .codex && ! -e AGENTS.md && ! -e .gitignore ]]; then
  PASS=$((PASS + 1))
else
  echo "FAIL: external init should not create repo-local artifacts"
  FAIL=$((FAIL + 1))
fi
data_main="$(fluxkit_data_file)"
port_main="$(fluxkit_preferred_port)"
initial_branch="$(fluxkit_branch_name)"
assert_file_exists "$data_main" "external main branch data exists"
assert_file_exists "$HOME/.codex/config.toml" "global codex config exists"
assert_file_exists "$HOME/.cursor/mcp.json" "global cursor mcp exists"
assert_file_exists "$HOME/AGENTS.md" "home AGENTS.md exists"
assert_contains "$(cat "$(dirname "$data_main")/config.json")" '"scope": "branch"' "external branch config records scope"
assert_contains "$(cat "$(dirname "$data_main")/config.json")" '"port_strategy": "hash_repo_path_and_branch"' "external branch config records port strategy"
configured_output="$(run_fluxkit configured)"
assert_contains "$configured_output" "configured: yes" "configured reports external setup"
assert_contains "$configured_output" "mode: external" "configured reports external mode"
assert_contains "$configured_output" "scope: branch" "configured reports branch scope"
assert_contains "$configured_output" "mcp: fluxkit mcp" "configured reports global mcp command"
assert_contains "$(cat "$HOME/.codex/config.toml")" 'args = ["mcp"]' "global codex uses fluxkit mcp"
assert_contains "$(cat "$HOME/.cursor/mcp.json")" '"mcp"' "global cursor uses fluxkit mcp"
assert_contains "$(cat "$HOME/AGENTS.md")" "BEGIN FLUXKIT GLOBAL MANAGED BLOCK" "home agents global block"
assert_contains "$(cat "$HOME/AGENTS.md")" "fluxkit configured" "home agents tells agents to check configured status"
mcp_output="$(run_fluxkit mcp)"
assert_eq "$mcp_output" "mock-container" "external configured mcp starts real container path"
branch_index=1
while true; do
  git checkout -q "$initial_branch"
  git checkout -qb "feature/work-$branch_index"
  run_fluxkit init -e branch
  data_feature="$(fluxkit_data_file)"
  port_feature="$(fluxkit_preferred_port)"
  if [[ "$port_main" != "$port_feature" ]]; then
    break
  fi
  branch_index=$((branch_index + 1))
  if (( branch_index > 20 )); then
    break
  fi
done
if [[ "$data_main" != "$data_feature" ]]; then
  PASS=$((PASS + 1))
else
  echo "FAIL: external data path should differ by branch"
  FAIL=$((FAIL + 1))
fi
if [[ "$port_main" != "$port_feature" ]]; then
  PASS=$((PASS + 1))
else
  echo "FAIL: branch-scoped external preferred port should differ by branch"
  FAIL=$((FAIL + 1))
fi
assert_file_exists "$data_feature" "external feature branch data exists"
feature_container="$(fluxkit_ui_container_name)"
git checkout -q "$initial_branch"
main_container="$(fluxkit_ui_container_name)"
git checkout -q "feature/work-$branch_index"
if [[ "$main_container" != "$feature_container" ]]; then
  PASS=$((PASS + 1))
else
  echo "FAIL: branch-scoped external UI containers should differ by branch"
  FAIL=$((FAIL + 1))
fi
set +e
run_fluxkit doctor >/dev/null 2>&1
rc=$?
set -e
assert_eq "$rc" "0" "external doctor passes after init"
popd >/dev/null
rm -rf "$TMP"
TMP=""
restore_user_env
unset FLUXKIT_CONTAINER_CMD

echo "== external repo-scoped init =="
TMP="$(new_work_dir)"
MOCK_BIN="$TMP/bin"
setup_mock_flux "$MOCK_BIN"
setup_mock_container "$MOCK_BIN"
export FLUXKIT_FLUX_CMD="$MOCK_BIN/flux"
export FLUXKIT_CONTAINER_CMD="$MOCK_BIN/engine"
export HOME="$TMP/home"
export XDG_DATA_HOME="$HOME/.local/share"
export XDG_STATE_HOME="$HOME/.local/state"
export CODEX_HOME="$HOME/.codex"
new_git_repo "$TMP/project"
pushd "$TMP/project" >/dev/null
run_fluxkit init -e
data_main="$(fluxkit_data_file)"
port_main="$(fluxkit_preferred_port)"
assert_file_exists "$data_main" "external repo-scope data exists"
assert_contains "$(cat "$(dirname "$data_main")/config.json")" '"scope": "repo"' "external repo config records scope"
assert_contains "$(cat "$(dirname "$data_main")/config.json")" '"port_strategy": "hash_repo_path"' "external repo config records port strategy"
set +e
run_fluxkit init --external=branch >/dev/null 2>&1
rc=$?
set -e
assert_eq "$rc" "0" "--external=branch form is accepted"
FLUXKIT_STATE_MODE=external
FLUXKIT_EXTERNAL_SCOPE=repo
data_main="$(fluxkit_data_file)"
unset FLUXKIT_STATE_MODE FLUXKIT_EXTERNAL_SCOPE
git checkout -qb feature/work
data_feature="$(fluxkit_data_file)"
port_feature="$(fluxkit_preferred_port)"
assert_eq "$data_feature" "$data_main" "repo-scoped external data path stable across branches"
assert_eq "$port_feature" "$port_main" "repo-scoped external preferred port stable across branches"
run_fluxkit init -e branch
branch_data="$(fluxkit_data_file)"
configured_output="$(run_fluxkit configured)"
if [[ "$branch_data" != "$data_main" ]]; then
  PASS=$((PASS + 1))
else
  echo "FAIL: branch-scoped external data should take precedence over repo-scoped data"
  FAIL=$((FAIL + 1))
fi
assert_contains "$configured_output" "scope: branch" "configured reports branch precedence when both scopes exist"
assert_contains "$configured_output" "$branch_data" "configured reports branch-precedence data path"
set +e
init_output="$(run_fluxkit init 2>&1)"
rc=$?
set -e
assert_eq "$rc" "1" "plain init refuses to create local state when external state exists"
assert_contains "$init_output" "fluxkit init --local" "plain init tells user how to force local state"
if [[ ! -e .flux ]]; then
  PASS=$((PASS + 1))
else
  echo "FAIL: refused local init should not create .flux"
  FAIL=$((FAIL + 1))
fi
run_fluxkit init -l
assert_file_exists ".flux/data.json" "forced local init creates repo-local data"
configured_output="$(run_fluxkit configured)"
assert_contains "$configured_output" "mode: local" "local state takes precedence over external branch and repo state"
assert_eq "$(fluxkit_data_file)" "$PWD/.flux/data.json" "local data path takes precedence when local and external state exist"
popd >/dev/null
rm -rf "$TMP"
TMP=""
restore_user_env
unset FLUXKIT_CONTAINER_CMD

echo "== ui startup clears existing Fluxkit container name =="
TMP="$(new_work_dir)"
MOCK_BIN="$TMP/bin"
setup_mock_container "$MOCK_BIN"
export FLUXKIT_CONTAINER_CMD="$MOCK_BIN/engine"
export MOCK_CONTAINER_RM_LOG="$TMP/rm.log"
new_git_repo "$TMP/project"
pushd "$TMP/project" >/dev/null
run_fluxkit init >/dev/null
container_name="$(fluxkit_ui_container_name)"
export MOCK_CONTAINER_INSPECT_TARGETS="|$container_name|"
fluxkit_remove_existing_container "$container_name" "$MOCK_BIN/engine"
assert_contains "$(cat "$MOCK_CONTAINER_RM_LOG")" "$container_name" "startup cleanup removes existing Fluxkit container name"
popd >/dev/null
rm -rf "$TMP"
TMP=""
unset FLUXKIT_CONTAINER_CMD MOCK_CONTAINER_INSPECT_TARGETS MOCK_CONTAINER_RM_LOG

echo "== configured before init =="
TMP="$(new_work_dir)"
new_git_repo "$TMP/project"
pushd "$TMP/project" >/dev/null
set +e
run_fluxkit configured >/dev/null 2>&1
rc=$?
set -e
assert_eq "$rc" "1" "configured fails before init"
popd >/dev/null
rm -rf "$TMP"
TMP=""

echo "== disabled mcp for unconfigured repos =="
TMP="$(new_work_dir)"
new_git_repo "$TMP/project"
pushd "$TMP/project" >/dev/null
mcp_input=$'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05"}}\n{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}\n{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}\n'
mcp_output="$(printf '%s' "$mcp_input" | run_fluxkit mcp)"
assert_contains "$mcp_output" '"serverInfo":{"name":"fluxkit-disabled","version":"' "unconfigured repo mcp initializes disabled server"
assert_contains "$mcp_output" '"tools":[]' "unconfigured repo mcp advertises no tools"
assert_contains "$mcp_output" "Fluxkit is not initialized for this repo/branch" "unconfigured repo mcp explains disabled state"
popd >/dev/null
rm -rf "$TMP"
TMP=""

TMP="$(new_work_dir)"
mkdir -p "$TMP/not-git"
pushd "$TMP/not-git" >/dev/null
mcp_output="$(printf '%s' "$mcp_input" | env GIT_CEILING_DIRECTORIES="$WORK_ROOT" "$FLUXKIT" mcp)"
assert_contains "$mcp_output" '"serverInfo":{"name":"fluxkit-disabled","version":"' "non-git mcp initializes disabled server"
assert_contains "$mcp_output" "not inside a git repository" "non-git mcp explains disabled state"
popd >/dev/null
rm -rf "$TMP"
TMP=""

echo "== global UI container management =="
TMP="$(new_work_dir)"
MOCK_BIN="$TMP/bin"
setup_mock_container "$MOCK_BIN"
export FLUXKIT_CONTAINER_CMD="$MOCK_BIN/engine"
export MOCK_CONTAINER_PS_ROWS=$'aaaaaaaaaaaa\tfluxkit-aaaaaaaaaaaa\t127.0.0.1:42001->42001/tcp\ncccccccccccc\tfluxkit-cccccccccccc\t127.0.0.1:42003->42003/tcp\nbbbbbbbbbbbb\tfluxkit-bbbbbbbbbbbb\t127.0.0.1:42002->42002/tcp\nshortshort12\tfluxkit-short\t127.0.0.1:42004->42004/tcp\nnotflux12345\tnot-fluxkit\t127.0.0.1:43000->43000/tcp'
export MOCK_CONTAINER_PS_TARGETS=$'aaaaaaaaaaaa\tfluxkit-aaaaaaaaaaaa\ncccccccccccc\tfluxkit-cccccccccccc\nbbbbbbbbbbbb\tfluxkit-bbbbbbbbbbbb\nshortshort12\tfluxkit-short\nnotflux12345\tnot-fluxkit'
export MOCK_CONTAINER_NAMES=$'aaaaaaaaaaaa\tfluxkit-aaaaaaaaaaaa\ncccccccccccc\tfluxkit-cccccccccccc\nbbbbbbbbbbbb\tfluxkit-bbbbbbbbbbbb\ndddddddddddd\tnot-fluxkit\nshortshort12\tfluxkit-short\nnotflux12345\tnot-fluxkit'
export MOCK_CONTAINER_INSPECT_TARGETS="|fluxkit-bbbbbbbbbbbb|"
export MOCK_CONTAINER_RM_LOG="$TMP/rm.log"
export MOCK_CONTAINER_PS_FORMAT_LOG="$TMP/ps-format.log"
pushd "$TMP" >/dev/null
list_output="$(run_fluxkit ui list)"
assert_contains "$list_output" "aaaaaaaaaaaa" "ui list includes first fluxkit container ID"
assert_contains "$list_output" "fluxkit-aaaaaaaaaaaa" "ui list includes first fluxkit container name"
assert_contains "$list_output" "fluxkit-bbbbbbbbbbbb" "ui list includes second fluxkit container"
assert_contains "$list_output" "fluxkit-cccccccccccc" "ui list includes valid Fluxkit-looking container"
assert_not_contains "$list_output" "not-fluxkit" "ui list excludes non-matching containers"
assert_not_contains "$list_output" "fluxkit-short" "ui list excludes invalid fluxkit names"
run_fluxkit ui down -t aaaaaaaaaaaa >/dev/null
rm_log="$(cat "$MOCK_CONTAINER_RM_LOG")"
assert_contains "$rm_log" "aaaaaaaaaaaa" "ui down -t stops selected CONTAINER ID"
assert_not_contains "$rm_log" "bbbbbbbbbbbb" "ui down -t does not stop other containers"
run_fluxkit ui down -t fluxkit-bbbbbbbbbbbb >/dev/null
rm_log="$(cat "$MOCK_CONTAINER_RM_LOG")"
assert_contains "$rm_log" "fluxkit-bbbbbbbbbbbb" "ui down -t accepts selected Fluxkit NAME value"
run_fluxkit ui down -t cccccccccccc >/dev/null
rm_log="$(cat "$MOCK_CONTAINER_RM_LOG")"
assert_contains "$rm_log" "cccccccccccc" "ui down -t accepts listed Fluxkit-looking container ID"
set +e
run_fluxkit ui down -t dddddddddddd >/dev/null 2>&1
rc=$?
set -e
assert_eq "$rc" "1" "ui down -t refuses hex ID whose container name is not Fluxkit"
: >"$MOCK_CONTAINER_RM_LOG"
run_fluxkit ui down -a >/dev/null
rm_log="$(cat "$MOCK_CONTAINER_RM_LOG")"
assert_contains "$rm_log" "aaaaaaaaaaaa" "ui down --all stops first fluxkit container"
assert_contains "$rm_log" "bbbbbbbbbbbb" "ui down --all stops second fluxkit container"
assert_contains "$rm_log" "cccccccccccc" "ui down --all stops third valid fluxkit container"
assert_not_contains "$rm_log" "not-fluxkit" "ui down --all skips non-matching containers"
assert_not_contains "$rm_log" "fluxkit-short" "ui down --all skips invalid fluxkit names"
ps_format_log="$(cat "$MOCK_CONTAINER_PS_FORMAT_LOG")"
assert_contains "$ps_format_log" '{{printf "%s\t%s\t%s" .ID .Names .Ports}}' "ui list uses portable container ps row format"
assert_contains "$ps_format_log" '{{printf "%s\t%s" .ID .Names}}' "ui down --all uses portable container ps target format"
popd >/dev/null
rm -rf "$TMP"
TMP=""
unset FLUXKIT_CONTAINER_CMD MOCK_CONTAINER_PS_ROWS MOCK_CONTAINER_PS_TARGETS MOCK_CONTAINER_NAMES MOCK_CONTAINER_INSPECT_TARGETS MOCK_CONTAINER_RM_LOG MOCK_CONTAINER_PS_FORMAT_LOG

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

echo "== runtime container engine persistence =="
TMP="$(new_work_dir)"
MOCK_BIN="$TMP/bin"
setup_mock_container "$MOCK_BIN" docker
setup_mock_container "$MOCK_BIN" podman
export MOCK_CONTAINER_RM_LOG="$TMP/rm.log"
new_git_repo "$TMP/project"
pushd "$TMP/project" >/dev/null
run_fluxkit init >/dev/null
container_name="$(fluxkit_ui_container_name)"
export MOCK_CONTAINER_RUNNING_TARGETS="|$container_name|"
fluxkit_write_runtime_env "$(fluxkit_preferred_port)" "" "container" "$container_name" "$MOCK_BIN/podman"
assert_contains "$(cat .flux/runtime.env)" "FLUX_UI_CONTAINER_CMD=$MOCK_BIN/podman" "runtime.env persists container engine"
OLD_PATH="$PATH"
PATH="$MOCK_BIN:$OLD_PATH"
run_fluxkit ui down >/dev/null
PATH="$OLD_PATH"
rm_log="$(cat "$MOCK_CONTAINER_RM_LOG")"
assert_contains "$rm_log" "podman " "ui down uses persisted container engine"
assert_contains "$rm_log" "$container_name" "ui down stops persisted container"
assert_contains "$rm_log" "--time 0" "podman ui down kills immediately by default"
assert_not_contains "$rm_log" "docker $container_name" "ui down does not rediscover another ready engine"
popd >/dev/null
rm -rf "$TMP"
TMP=""
unset MOCK_CONTAINER_RM_LOG MOCK_CONTAINER_RUNNING_TARGETS

echo "== doctor checks =="
TMP="$(new_work_dir)"
MOCK_BIN="$TMP/bin"
setup_mock_flux "$MOCK_BIN"
setup_mock_container "$MOCK_BIN"
export FLUXKIT_FLUX_CMD="$MOCK_BIN/flux"
export FLUXKIT_CONTAINER_CMD="$MOCK_BIN/engine"
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
unset FLUXKIT_CONTAINER_CMD

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
assert_not_contains "$(grep -v '^[[:space:]]*#' "$FLUXKIT")" "mapfile -t" "fluxkit avoids Bash 4-only mapfile"

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
