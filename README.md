# Illume

A read-only, natural-language Q&A CLI for Elixir codebases. Point it at a
directory and ask a question — "where is X used", "explain this function",
"what changed and why in these commits" — and it runs a multi-step
tool-calling loop against Claude to gather evidence and synthesize a direct
answer, rather than just dumping raw search output.

> **Work in progress.** This is a small side project, not a hardened or
> production-ready tool. Expect rough edges.

## How it works

- **`Illume.Agent`** — a GenServer state machine
  (`idle → awaiting_model → awaiting_tool → done`) driving the
  conversation loop via `handle_continue/2`. Calls the Anthropic API
  through `req_anthropic`'s primitive `Messages.create/1` — not its
  `Messages.run/1` auto-loop helper; the loop here is hand-built.
- **`Illume.Tools`** — an explicit allow-list of five read-only tools
  (`read_file`, `search_files`, `grep_content`, `git_log`, `git_show`),
  re-checked at dispatch regardless of caller. Nothing outside the
  allow-list is ever reachable, even if an underlying server offers
  write/delete tools.
- **`Illume.Tools.Runner`** — every tool call runs under a
  `Task.Supervisor` with a configurable timeout. A crash or timeout
  becomes an error result fed back to the model instead of taking down
  the agent.
- **Two tool backends, one interface** — tools run as direct in-process
  calls by default, or (`--mcp` flag) proxied through the official
  filesystem and git reference MCP servers via `anubis_mcp`.
  `Illume.Agent` doesn't change between the two.
- **`:telemetry`** events for every loop turn, tool call, and model call.

## Setup

Requires an [Anthropic API key](https://console.anthropic.com/).

```sh
mix deps.get
mix escript.build
export ANTHROPIC_API_KEY=sk-ant-...
```

## Usage

```sh
./illume <target_dir> "<question>"

# examples
./illume . "where is the tool allow-list enforced?"
./illume ~/code/my_app "what does the Repo module do?"
./illume . "what changed in the last few commits and why?"
```

Pass `--mcp` to route tools through the official filesystem/git MCP
reference servers instead of direct in-process calls (requires `npx` and
`uvx` on `PATH`, plus network access on first run):

```sh
./illume --mcp . "where is the tool allow-list enforced?"
```

## Scope

Single provider (Anthropic), single agent, strictly read-only — no code
execution, file writes, or commits, enforced by the allow-list rather than
assumed from any tool's own configuration. No streaming, no persistence,
no web interface, no MCP *server* mode.

## Testing

```sh
mix test
```

The suite runs offline — no real network calls to Anthropic or an MCP
server. The LLM client is Mox-mocked, MCP calls are mocked at the
`Anubis.Client` boundary, and `Illume.LLM.AnthropicClient` is tested via
`Req.Test` intercepting the real request pipeline.

## License

MIT — see [LICENSE](LICENSE). One dependency, `anubis_mcp`, is licensed
LGPL-3.0; it's used unmodified as a normal Hex dependency, which doesn't
affect this project's own license.
