# Fluxkit

Fluxkit is a single-file shell utility that wires [Flux](https://github.com/sirsjg/flux) into any local git repository. Each repo gets its own independent Kanban board, a stable local UI port, MCP integration for Cursor and Codex, and agent guidance for Flux-backed work tracking.

Fluxkit is language-agnostic: it only requires `git` and works with any project type.

## What it does

- Creates repo-local Flux state under `.flux/`
- Optionally creates external Flux state outside the repo with repo or branch scope
- Generates Cursor (`.cursor/mcp.json`) and Codex (`.codex/config.toml`) MCP configs
- In external mode, configures home-level Cursor/Codex MCP to run `fluxkit mcp`
- Extends `AGENTS.md` with a managed Flux workflow block (never replaces your whole file)
- In external mode, extends `~/AGENTS.md` with global Fluxkit guidance
- Starts/stops a repo-scoped Flux UI/API server on a stable hash-based port
- Provides a repo-local MCP launcher at `.flux/bin/mcp`

## Installation

Copy the script anywhere on your `PATH`:

```bash
git clone https://github.com/your-org/fluxkit
cd fluxkit
chmod +x fluxkit
cp fluxkit ~/bin/fluxkit   # or /usr/local/bin/fluxkit
```

Requirements:

- `git`
- [Docker](https://www.docker.com/) (`sirsjg/flux-mcp:latest`) for the Kanban web UI — required for `fluxkit ui up`
- Docker is also used for MCP when the UI is not running

## Quickstart

```bash
cd my-project
fluxkit init
fluxkit doctor
fluxkit ui up
# open the printed URL
# open Cursor or run Codex in this repo
```

## Commands

| Command | Description |
|---------|-------------|
| `fluxkit init` | Create or update repo-local Flux files |
| `fluxkit init -l` | Force repo-local Flux files when external state already exists |
| `fluxkit init -e [repo\|branch]` | Create or update external Flux files and home MCP config |
| `fluxkit ui up` | Start Flux UI/API for this repo |
| `fluxkit ui down` | Stop the server started by fluxkit |
| `fluxkit ui down -t CONTAINER` | Stop a listed Fluxkit Docker UI container |
| `fluxkit ui down -a` | Stop all running Fluxkit Docker UI containers |
| `fluxkit ui status` | Show running/stopped state and ports |
| `fluxkit ui list` | List running Fluxkit Docker UI containers |
| `fluxkit port` | Print repo root, preferred port, and running URL |
| `fluxkit mcp` | Run the repo-aware MCP server for the current repo/branch |
| `fluxkit configured` | Report whether Fluxkit is configured for this repo/branch |
| `fluxkit doctor` | Verify setup and suggest fixes |
| `fluxkit help` | Show usage |

## Repository layout

After `fluxkit init`:

```text
.flux/
  data.json          # Flux board (commit this)
  config.json        # Fluxkit + UI settings (commit this)
  project.json       # Project identity hint (commit this)
  runtime.env        # Generated at runtime (gitignored)
  ui.log             # UI/docker logs (gitignored)
  bin/
    mcp              # MCP launcher for editors
.cursor/
  mcp.json
.codex/
  config.toml
AGENTS.md            # Extended with managed Flux block
```

`.gitignore` gains (idempotently):

```gitignore
.flux/runtime.env
.flux/ui.log
.flux/*.pid
```

## External state mode

Use external mode when Flux task state should not appear in the repository or pull request history:

```bash
cd my-project
fluxkit init -e branch
```

`branch` scope stores board data outside the repo, scoped by repository path and current git branch:

```text
${XDG_DATA_HOME:-~/.local/share}/fluxkit/repos/<repo-id>/branches/<branch-id>/.flux/
  data.json
  config.json
  project.json

${XDG_STATE_HOME:-~/.local/state}/fluxkit/repos/<repo-id>/branches/<branch-id>/
  runtime.env
  ui.log
```

The repository is left clean: no `.flux/`, `.cursor/`, `.codex/`, `.gitignore`, or repo `AGENTS.md` changes are made by `fluxkit init --external`.

Each branch gets its own external `.flux/data.json`. Switching branches changes the resolved Flux board after that branch has been initialized with `fluxkit init -e branch`.

Use repo scope when every branch in the same worktree should share one external board. Repo scope is the default when `-e`/`--external` has no argument:

```bash
fluxkit init -e
# equivalent:
fluxkit init -e repo
```

Repo-scoped external state uses:

```text
${XDG_DATA_HOME:-~/.local/share}/fluxkit/repos/<repo-id>/.flux/
  data.json
  config.json
  project.json

${XDG_STATE_HOME:-~/.local/state}/fluxkit/repos/<repo-id>/
  runtime.env
  ui.log
```

Repo-local initialization always uses repository-local `.flux/` state.

If external state already exists and repo-local `.flux/` does not, `fluxkit init` refuses to create repo-local state implicitly. Run `fluxkit init -l` or `fluxkit init --local` when you explicitly want local state in that repo.

When multiple setups exist for the same repo, Fluxkit resolves them in this order: repo-local `.flux/`, external branch scope, external repo scope.

Agents and scripts can check the active setup with:

```bash
fluxkit configured
```

It exits zero when Fluxkit is configured for the current repo/branch and prints the resolved mode, scope, branch, data path, and MCP command. It exits non-zero when no Fluxkit setup applies.

External mode configures home-level MCP entries:

```text
~/.cursor/mcp.json
~/.codex/config.toml
```

Those entries run:

```bash
fluxkit mcp
```

`fluxkit mcp` resolves the current git repository and branch from the editor's working directory, then connects to the matching external board. If the UI/API for that repo is running, it uses remote MCP mode; otherwise it falls back to direct JSON-backed MCP via Docker.

External mode also adds a managed block to `~/AGENTS.md` telling agents to use Fluxkit work tracking only when it is configured for the current repository.

## Stable ports

Each git repository gets a preferred port derived from its canonical absolute path:

1. `git rev-parse --show-toplevel`
2. Resolve to a canonical absolute path
3. SHA-256 hash → first 8 hex chars → integer
4. `preferred_port = port_base + (hash % port_span)`

For `fluxkit init -e branch`, the preferred port seed is the same canonical repository path plus the current branch name. This lets separate branch-scoped external boards prefer separate ports.

Defaults: ports **42000–42999** (`port_base=42000`, `port_span=1000`).

Override with environment variables:

```bash
export FLUXKIT_PORT_BASE=43000
export FLUXKIT_PORT_SPAN=500
```

If the preferred port is busy, fluxkit probes `preferred+1`, `preferred+2`, … wrapping within the range. It never kills unrelated processes.

## UI server

`fluxkit ui up` starts the **Kanban web UI** via Docker:

```text
sirsjg/flux-mcp:latest  →  bun packages/server/dist/index.js
```

Your repo is mounted so the board uses `.flux/data.json`.

Set `FLUXKIT_UI_BACKEND=cli` only if you want API-only mode (`flux serve` via npm — no web UI).

Runtime state is written to `.flux/runtime.env`:

```env
FLUX_SERVER=http://127.0.0.1:<port>
FLUX_UI_PORT=<port>
FLUX_UI_PID=<pid>
FLUX_REPO_ROOT=<absolute repo root>
```

`fluxkit ui down` stops only the PID recorded in that file, and only after verifying it looks like a `flux serve` process for this repo's data file.

`fluxkit ui up` and `fluxkit ui down` use the Fluxkit setup resolved from the current git repository and branch. No target is needed for local, repo-scoped, or branch-scoped state.

To inspect and stop Docker UI containers globally, even after a branch has been deleted or an external branch state path is no longer active:

```bash
fluxkit ui list
fluxkit ui down -a
```

`fluxkit ui down -a` stops running Docker containers with Fluxkit's managed container name pattern. It does not discover API-only `FLUXKIT_UI_BACKEND=cli` processes.

For `fluxkit ui down`, `-t`/`--target` accepts the Docker ID in the `CONTAINER` column from `fluxkit ui list`. It also accepts the generated Fluxkit `NAME` value for compatibility. Both forms can be run outside a git repository, and both require the container to have Fluxkit's managed Docker label:

```bash
fluxkit ui down -t 1a2b3c4d5e6f
# or:
fluxkit ui down -t fluxkit-<12-hex-id>
```

## Cursor integration

Fluxkit creates `.cursor/mcp.json`:

```json
{
  "mcpServers": {
    "flux": {
      "type": "stdio",
      "command": ".flux/bin/mcp"
    }
  }
}
```

The command is repo-relative so it works in both Cursor IDE and `cursor-agent` CLI (which does not expand `${workspaceFolder}`).

## Codex integration

Fluxkit creates `.codex/config.toml` with a Flux MCP server entry.

Run Codex from the repository root so `.flux/bin/mcp` resolves.

## MCP launcher behavior

Repo-local mode creates `.flux/bin/mcp`:

1. If `.flux/runtime.env` exists and the UI/API is healthy → connect via `FLUX_SERVER` (remote MCP mode)
2. Otherwise → fall back to direct JSON-backed MCP via Docker (`sirsjg/flux-mcp:latest`) scoped to `.flux/data.json`

MCP always targets this repository's board, not global Flux state.

External mode uses the global `fluxkit mcp` command instead of a repo-local launcher. It resolves the active repo/branch and targets the corresponding external `.flux/data.json`.

## AGENTS.md managed block

Fluxkit **extends** existing `AGENTS.md`; it never replaces the whole file.

It manages only the section between:

```md
<!-- BEGIN FLUXKIT MANAGED BLOCK -->
<!-- END FLUXKIT MANAGED BLOCK -->
```

The managed block instructs agents to use the repository-local Flux MCP server for all board changes and not to read or edit `.flux/data.json` or `.flux/project.json` directly.

Rules:

- No markers → append the managed block
- Both markers → replace content between them only
- One marker only → error (malformed markers); fix manually
- User content outside the block is always preserved

Workflow examples belong in this README or your own docs — not in the hard-coded `AGENTS.md` block.

## Example agent workflows

These are example prompts you can give agents. Fluxkit does not encode them as CLI commands.

### Sequential task workflow

Use when you want one task at a time with confirmation between tasks:

```text
Use the repo-local Flux board. Pick one ready task, confirm it with me, implement only that task, run relevant checks, update Flux with progress and verification notes, then stop and ask me before moving to another task.
```

### Delegated project-manager workflow

Use when the board has many tasks and the main agent should coordinate work across multiple agent turns:

```text
Use the repo-local Flux board as the project manager. Keep tasks focused and current. For each ready task, delegate implementation and review to separate focused agent sessions. Require review approval before marking the task done. Commit completed approved work with a message referencing the Flux task. Report progress after each task or blocker. Continue until the board is done or blocked.
```

## Troubleshooting

| Issue | Fix |
|-------|-----|
| `Web UI not found` at the printed URL | Stop API-only server: `fluxkit ui down`, fix `docker info`, then `fluxkit ui up` |
| `docker-credential-desktop` errors on pull | Edit `~/.docker/config.json` and remove or fix `credsStore` (use `"credStore": ""` or install the helper) |
| `EACCES` in `.flux/ui.log` | Fixed in current fluxkit (runs container as your uid); update script and retry |
| `flux CLI not found` | `npm install -g flux-tasks`, or use Docker-only with `FLUXKIT_UI_BACKEND=docker` |
| MCP fails without UI | Install Docker; image `sirsjg/flux-mcp:latest` is pulled on first use |
| Port in use | Run `fluxkit port`; fluxkit picks the next free port in range |
| `doctor` fails on AGENTS.md | Ensure both managed block markers exist in pairs |
| Wrong Flux board | Confirm you opened the correct repo; each repo has its own `.flux/data.json` |

## Limitations

- MCP via Docker requires the Flux Docker image; the npm `flux-tasks` package requires Bun to run `flux serve`
- `flux serve` binds to localhost; there is no `--host` flag in current Flux CLI
- Port collision detection uses TCP probes; race conditions are possible but rare
- Codex/Cursor config merging for pre-existing files is best-effort (python3 helps merge Cursor JSON)

## Testing

```bash
bash tests/run.sh
```

Tests use mock `flux` binaries and ephemeral git repos under `tests/.work/` (gitignored).
Do not run `fluxkit init` in the fluxkit source repository root; use a separate project
or let the test suite create temporary workspaces.

## License

Fluxkit is licensed under GPL-3.0-or-later.

Fluxkit is a developer tool. Running Fluxkit against a repository does not
change that repository's license.

Files generated by Fluxkit, including `.flux/config.json`, `.flux/project.json`,
`.cursor/mcp.json`, `.codex/config.toml`, `.gitignore` entries, and the
Fluxkit-managed block in `AGENTS.md`, may be used, modified, and distributed
under the license of the target repository. They are not subject to the GPL
solely because they were generated by Fluxkit.

### Does Fluxkit make my project GPL?

No. Fluxkit itself is GPL-3.0-or-later. Repositories initialized or managed by
Fluxkit keep their own license. Generated configuration files and generated
AGENTS.md managed blocks may be used under the target repository's license.
