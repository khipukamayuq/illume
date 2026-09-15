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
- **`Illume.Tools.Runner`** — every tool call, and the model call itself,
  runs under a `Task.Supervisor` with a configurable timeout
  (`tool_timeout` / `model_timeout`, default 60s for the latter). A tool
  crash or timeout becomes an error result fed back to the model; a model
  call crash or timeout is terminal for that `ask/2` call instead — there's
  no tool result to recover into.
- **Concurrent tool execution** — when a single model turn requests
  multiple tools, they run concurrently (bounded by `max_tool_concurrency`,
  default 4) via `Task.Supervisor.async_stream_nolink`, rather than one
  after another. Each call is still individually isolated by
  `Illume.Tools.Runner`; concurrency doesn't add a second timeout/crash
  layer, it just parallelizes already-safe work.
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

## MCP server mode

Run Illume itself as an MCP server, exposing the same five read-only
tools over stdio to an external MCP client (Claude Desktop, another
agent, etc.):

```sh
./illume --serve <target_dir>
```

This is a distinct axis from `--mcp` above: `--mcp` controls which
backend *this process's own* agent loop uses internally, while `--serve`
skips the agent loop and question entirely and turns Illume into a tool
provider for someone else's client. `target_dir` is fixed for the
process's whole lifetime (no per-call override) and no
`ANTHROPIC_API_KEY` is required — no model is called in this mode. The
process blocks until the connected client disconnects, then exits (see
DECISIONS.md's "MCP server (Component 1)" section for the real bugs —
one in `anubis_mcp` itself — this mode's implementation had to work
around).

## Web front end

A minimal LiveView front end — a question field, a live status line, and
the rendered answer — for browsing the same Q&A capability without a
terminal:

```sh
mix illume.server
```

Starts a Phoenix/Bandit endpoint at `http://localhost:4000`, on demand —
`Illume.Application`'s default children are unchanged, so the plain CLI
never starts a PubSub or an HTTP listener it doesn't need. Prints a URL
with a required `?token=...` bearer token — generated fresh each run and
checked on every request, so open `http://localhost:4000` directly and
you'll get an unauthorized page; use the printed URL as-is. `target_dir`
for the web form is a hardcoded compile-time constant (illume's own
checkout) — the page never accepts an arbitrary filesystem path as
request input, by design, not by omission (see DECISIONS.md's
"`target_dir` for the web UI resolves from the module's own source
path" note under "Web front end (Component 3)").
The status line is driven by `Illume.Agent`'s existing `:telemetry`
events, so it reflects what the agent is actually doing (calling the
model, running a tool) rather than a generic spinner.

## Scope

Single provider (Anthropic), single agent, strictly read-only — no code
execution, file writes, or commits, enforced by the allow-list rather than
assumed from any tool's own configuration. No streaming, no persistence.
MCP *server* mode exposes only the five existing read-only tools
individually — not the whole agent loop as a single tool. The web front
end is single-page, single-user-at-a-time in spirit — gated by a random
bearer token printed at startup, not multi-user accounts — not a
multi-tenant deployment.

## Testing

```sh
mix test
```

The suite runs offline — no real network calls to Anthropic or an MCP
server. The LLM client is Mox-mocked, MCP calls are mocked at the
`Anubis.Client` boundary, and `Illume.LLM.AnthropicClient` is tested via
`Req.Test` intercepting the real request pipeline.

One test is excluded by default: `mcp_server_e2e_test.exs` (tagged
`:e2e`) builds the escript and drives it as a real OS subprocess over
real stdio — the one deliberate exception to "no real subprocesses" in
this suite, proving the `--serve` stack works end to end at least once.
Run it explicitly with:

```sh
mix test --only e2e
```

CI (GitHub Actions) runs `mix format --check-formatted`, `mix test`,
`mix credo --strict`, and `mix dialyzer` on every push and PR, pinned to
the same Elixir/OTP toolchain used locally.

## License

MIT — see [LICENSE](LICENSE). One dependency, `anubis_mcp`, is licensed
LGPL-3.0; it's used unmodified as a normal Hex dependency, which doesn't
affect this project's own license.
