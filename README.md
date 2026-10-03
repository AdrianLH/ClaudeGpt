# ClaudeGpt

A ChatGPT app (an MCP server, per the OpenAI Apps SDK) that lets ChatGPT start and drive
**Claude Code CLI** instances on your own machine. It is written in Zig as a single static binary with no
dependencies beyond the standard library.

```
ChatGPT ──HTTPS──> tunnel (cloudflared / ngrok) ──> claudegpt 127.0.0.1:8765/mcp
                                                       │  one child per instance:
                                                       └─ claude -p --input-format stream-json
                                                                 --output-format stream-json --verbose
```

Each instance is one long-lived `claude` process in headless stream-json mode, running in a directory
you allow. It uses your existing Claude Code login and does not need an API key.

## Build

Requires **Zig 0.16.x** and the `claude` CLI on `PATH`.

```sh
zig build -Doptimize=ReleaseSafe                         # zig-out/bin/claudegpt
zig build -Dtarget=x86_64-windows -Doptimize=ReleaseSafe # cross-compile claudegpt.exe
zig build test                                           # unit tests
bash test/integration.sh                                 # end-to-end against a fake claude
```

CI builds the Windows binary as an artifact (`claudegpt-windows-x86_64`).

## Run

```powershell
# Windows (PowerShell)
$env:CLAUDEGPT_TOKEN = -join ((1..32) | % { '{0:x}' -f (Get-Random -Max 16) })
.\claudegpt.exe --root C:\src --root D:\work
```

```sh
# Linux / macOS
export CLAUDEGPT_TOKEN=$(openssl rand -hex 32)
./zig-out/bin/claudegpt --root ~/src
```

| Flag | Default | |
|---|---|---|
| `--root <dir>` | required | Instances may only run in these directories or below them. Repeatable. |
| `--port <n>` | `8765` | |
| `--bind <ip>` | `127.0.0.1` | Keep it on loopback and let the tunnel provide TLS. |
| `--max-instances <n>` | `8` | Maximum number of instances running at once. |
| `--claude-path <path>` | `claude` | Resolved via `PATH` (including `.exe`/`.cmd` on Windows). |
| `--allow-bypass` | off | Allows `permission_mode: bypassPermissions`. |

Expose it over HTTPS, for example `cloudflared tunnel --url http://127.0.0.1:8765` or `ngrok http 8765`.

## Connect ChatGPT

1. ChatGPT → Settings → Apps & Connectors → Advanced → enable **Developer mode**.
2. Create a connector with the URL `https://<your-tunnel>/mcp` and authentication set to a bearer token / API key, using the value of `CLAUDEGPT_TOKEN`.
3. In a chat, enable the connector and ask, e.g. *"Start Claude Code in C:\src\myrepo and ask it to fix the failing test."*

Any MCP client that speaks Streamable HTTP works too, e.g.
`npx @modelcontextprotocol/inspector` with the `Authorization: Bearer …` header.

## Tools

| Tool | Arguments | |
|---|---|---|
| `claude_start` | `cwd`, `prompt?`, `model?`, `permission_mode?`, `allowed_tools?`, `resume_session_id?`, `wait_seconds?` | Starts an instance and optionally runs a first turn. |
| `claude_send` | `id`, `prompt`, `wait_seconds?` | Sends a follow-up turn. Turns sent while one is running are queued. |
| `claude_output` | `id`, `since?`, `wait_seconds?`, `max_bytes?` | Reads the transcript from a cursor, optionally waiting for running turns. |
| `claude_list` | – | Lists instances with state, session id and cost. |
| `claude_interrupt` | `id` | Aborts the current turn. |
| `claude_stop` | `id` | Ends the process. The transcript stays readable and the session can be resumed. |

`wait_seconds` defaults to 25 for start/send. If a turn takes longer, the result says
`completed: false` and ChatGPT follows up with `claude_output since=<next_cursor>`.

The transcript contains `prompt`, `init`, `text`, `tool_use`, `tool_result`/`tool_error`,
`result`/`result_error`, `stderr` and `exit` events. Each instance keeps its last 2000 events.

## Permissions and security

This server lets a chat model run an agent that can edit files and execute commands on your machine.

- **Headless Claude Code cannot ask for permission.** Any tool not allowed by `permission_mode` or
  `allowed_tools` is denied. Use `allowed_tools` (e.g. `["Edit", "Bash(npm test:*)"]`) or
  `permission_mode: acceptEdits` to grant what the task needs. `bypassPermissions` is refused unless
  you start the server with `--allow-bypass`.
- The bearer token is mandatory and is compared in constant time. It is removed from the environment
  passed to `claude`.
- `cwd` is canonicalised and must be inside a `--root`.
- Prompts go to claude over stdin, never on the command line. Model names and tool rules are checked
  against a strict character set and may not start with `-`.
- Requests are logged as method and tool name only. Prompt text is not logged.
- Windows: if `claude` is the npm `.cmd` shim, a forced stop terminates the shim and not its `node`
  child. Prefer the native `claude.exe` installer. Normally `claude_stop` closes stdin and Claude Code
  exits on its own.
