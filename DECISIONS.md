# Decisions Log

A record of the architectural decisions, real bugs found, and deliberate
deviations from spec that shaped this project — kept as an overview of
what matters for understanding the system today, not a chronological
play-by-play. Add an entry when a decision, bug, or deferral would
otherwise be invisible from reading the code alone.

## Core architecture

- **Single provider, no abstraction layer.** Hardcoded against the
  Anthropic API — no Ollama, no provider abstraction. Explicit constraint
  from the original spec.
- **Hand-built GenServer loop, not `Messages.run/1`.** `Illume.Agent` is a
  GenServer state machine (`idle -> awaiting_model -> awaiting_tool ->
  done`, driven by `handle_continue/2`) built from `req_anthropic`'s
  primitive `Messages.create/1`. The key behavioral difference:
  `Messages.run/1` calls tool functions inline in the calling process
  with no supervision, so a broken tool crashes/hangs the caller
  directly; `Illume.Agent` isolates every tool call via `Task.Supervisor`.
- **Every tool call runs under `Task.Supervisor` with a timeout.**
  `Illume.Tools.Runner` wraps every dispatch in
  `Task.Supervisor.async_nolink` + `Task.yield`/`Task.shutdown`. A crash
  or timeout becomes an error tuple fed back to the model; it never
  reaches the Agent process.
- **Explicit allow-list, re-checked at dispatch.** `Illume.Tools.dispatch/4`
  re-checks the allow-list itself rather than trusting the caller or any
  underlying MCP server's own configuration — this is the actual
  enforcement of "read-only."
- **Guardrails**: a 10-iteration cap (clear "gave up" message instead of
  looping forever), `:telemetry` events for `loop_turn`/`tool_call`/
  `model_call`, and tool-level output caps (300KB `read_file` truncation,
  200-result caps on search/grep) plus standard ignored directories
  (`.git`, `_build`, `deps`, `node_modules`, etc.) to keep token usage
  bounded.
- **Tools shipped in two phases**: direct in-process Elixir calls first,
  then an MCP-backed alternative proxying to the official filesystem and
  git reference servers via `anubis_mcp`, added as a genuinely separate,
  opt-in `--mcp` flag rather than replacing the default — spawning
  `npx`/`uvx` subprocesses and depending on network access on first run
  is real added fragility a fully-working, zero-external-dependency
  direct implementation doesn't have.

## Tool design

- **`grep_content` added as a 5th, permanently local tool.** Neither
  reference MCP server exposes content search (`search_files` only
  matches file names), so "where is X used" would otherwise require
  reading whole files iteratively. Fixed-string (`grep -F`), not regex —
  avoids the model needing to reason about escaping and avoids a
  regex-injection-shaped surface. Agreed with the user before
  implementation as a disclosed exception to "tools drawn from the two
  reference servers."
- **Model and token limit are hardcoded**, not configurable — matches the
  spec's "hardcode against Claude Sonnet" instruction.

## Dependency bugs found

- **`anubis_mcp` 2.0.0 — ETS table collision between same-named clients.**
  `Anubis.Client.Cache` keys its ETS tool-validator table by
  `client_info["name"]` alone, not by process. Two clients sharing a name
  (the filesystem and git clients were both initially `"illume"`) collide:
  the second can't read a table the first owns, crashing on any result
  carrying `structuredContent`. Found via live testing against real
  `npx`/`uvx`-spawned servers. Worked around with distinct client names
  (`"illume-filesystem"` / `"illume-git"`), not reported upstream.

## Workarounds

- **`Illume.Tools.MCP.Client` behaviour + adapter**, mirroring the
  existing `Illume.LLM.Client` pattern, added purely so Mox can mock
  `Anubis.Client` calls in tests without spawning real server processes.
- **`Req.Test` + `plug`** as a test-only dependency, to test
  `Illume.LLM.AnthropicClient` without hitting the network via
  `req_anthropic`'s `Application.get_env(:req_anthropic, :plug)` hook.
- **`DynamicSupervisor` for Agent and MCP client processes.** The plan
  called for one-shot, unsupervised processes; a project safety hook
  blocked bare `start_link` calls outside a module definition. Resolved
  with `Illume.AgentSupervisor`/`Illume.MCPSupervisor` (both
  `DynamicSupervisor`s), children started with `restart: :temporary` —
  functionally equivalent to the original plan, structural supervision
  added to satisfy the harness rather than a re-evaluated requirement.
- **`Path.wildcard/2` returns matches with `..` unresolved.** A first
  confinement-check attempt string-prefix-filtered wildcard matches
  against the root, which did nothing — `Path.wildcard` doesn't lexically
  normalize `..` in its own output. Fixed by `Path.expand/1`-ing every
  match before the confinement check.

## Bugs found in our own code (via self-review)

- **`search_files` had no path confinement at all** (High, confirmed
  exploitable) — unlike `read_file`, it never called the confinement
  check; `*/../../../../../etc/passwd`-style globs escaped the target
  directory. Fixed by extracting shared `Illume.Tools.PathConfinement`
  and filtering every match through it.
- **Agent crashed on a content-less-but-successful API response**
  (Critical) — `handle_continue(:call_model, ...)` had no catch-all for
  `{:ok, body}` lacking a `"content"` key, defeating the architecture's
  one core guarantee (no unhandled crashes). Fixed with an explicit
  catch-all clause.
- **The MCP backend skipped the local guards the direct backend had**
  (Medium, not actively exploitable — both reference servers currently
  catch these themselves, but relying on that violated "never trust an
  underlying server's own configuration"). Fixed by hoisting path-
  confinement and flag-injection guards into `Illume.Tools.dispatch/4`,
  applied uniformly regardless of backend.
- **Path confinement was lexical only, symlink-unaware.** A symlink
  inside the target directory pointing outside it would pass. Fixed with
  a `realpath`-style walk of every path component, capped at 40 hops,
  failing closed on a cycle.
- **Smaller fixes**: a `DynamicSupervisor` child leak on partial
  MCP-client-start failure (fixed with `stop_clients/0` on every failure
  branch); unbounded grep output before truncation (fixed with grep's own
  per-file match cap); UTF-8 truncation that could split a multi-byte
  character mid-codepoint (fixed by rejecting non-UTF-8 content outright
  and truncating at a valid boundary); a couple of minor idiom fixes
  (`is_exception/1` guard, O(1) message prepending instead of `++`).
- **`Application.put_env` global state for backend selection** — `
  :tool_backend` was read via `Application.get_env` inside
  `Illume.Tools`, mutated globally by `Illume.CLI`: process-global mutable
  state determining per-call control flow, and a real hazard in practice
  (testing the `:mcp` branch required careful test isolation to avoid
  contaminating unrelated concurrent tests). Fixed by threading `backend`
  as an explicit parameter end to end (`Illume.CLI` → `Illume.Agent` →
  `Illume.Tools.dispatch/4`, which grew from arity 3 to 4 as a result).

## Deviations from the original plan

- Implementation-history labels ("Phase A"/"Phase B") removed from code
  and docs, renamed to "direct"/"mcp" — planning-era labels aren't domain
  concepts and don't belong in module docs.
- Test infrastructure (Mox seams, `Req.Test`, the `plug` test dependency)
  grew beyond the original plan's "no real network calls" requirement, in
  response to closing test-coverage gaps rather than being planned up
  front.
- Git history was squashed into a single clean initial commit before the
  first push (nothing had reached the remote yet), and the repo was made
  public per explicit request — an MIT `LICENSE` was added and the README
  notes the `anubis_mcp` LGPL-3.0 dependency (used unmodified, doesn't
  affect this project's own license).

## Documentation & process

- README has no author/contact section and includes an explicit
  "work in progress, not production-hardened" disclaimer.
- `.gitignore` excludes tooling-local scratch data (plans, reviews,
  solutions) as not project source — `DECISIONS.md` is the durable,
  committed substitute for the parts of that history worth keeping
  public.

## Hardening pass 1 — independent review of Components 1-2

A follow-up pass fixing six issues an independent code review found in
the original MCP-tooling implementation, plus one capability upgrade
(concurrent tool execution), each as its own reviewable commit.

- **MCP `search_files` given its own confinement layer.** It forwarded
  the model's pattern straight to the external filesystem server with no
  local confinement check, unlike the direct backend. Fixed by
  re-filtering every match through `PathConfinement.within?/2` — which in
  turn required requiring matches be already-absolute paths first, since
  `within?/2` resolves a relative input against this VM's own cwd, not
  `target_dir`, and a relative match mixed into an otherwise-valid
  response could incorrectly pass confinement.
- **Model call routed through `Runner.run/2`.** Two findings — no
  wall-clock timeout on the model call, and a manual `rescue` that only
  caught raises, not exits — converged on one fix: routing the client
  call through the same `Task`-isolation primitive tool calls already
  use, making the manual `rescue` redundant.
- **MCP subprocess cleanup**: `try/after` guarantees `stop_clients/0` runs
  on both success and agent-error paths. A `--mcp` run interrupted by
  Ctrl-C still leaks spawned `npx`/`uvx` processes — Elixir's public API
  cannot trap `:sigint` (confirmed against `System.trap_signal/2,3`'s own
  guard clause), and a real fix means dropping to undocumented low-level
  OS signal APIs. Documented as a known gap in `Illume.CLI`'s moduledoc
  rather than reached for.
- **`git_show` hardened against flag injection**, iteratively:
  `--end-of-options` (git ≥2.24) shields a revision from being parsed as
  a flag without `--`'s side effect of switching to pathspec-only mode
  (which would have silently broken real commit lookups — verified live
  before shipping either approach). `git_show/2` is now safe on its own;
  `Tools.validate_input/3`'s leading-dash check stays as a cheap
  fail-fast, so the two layers are complementary rather than duplicated.
- **CI and static analysis added** (`credo`, `dialyxir`, a GitHub Actions
  workflow pinned to the exact local toolchain).
- **Concurrent tool execution**: multiple `tool_use` blocks in one model
  turn now run concurrently via `Task.Supervisor.async_stream_nolink`
  (default concurrency 4) instead of sequentially, with the stream's
  `ordered: true` output verified (not assumed) to preserve `tool_use_id`
  correlation under concurrent completion order.
- **A follow-up independent review of this pass itself** caught a real
  regression before merge: `async_stream_nolink` had no explicit
  `:timeout`, silently inheriting Elixir's 5000ms default with
  `on_timeout: :exit` — a tool running past 5s didn't yield a graceful
  error, it killed the Agent GenServer outright. Reproduced directly
  (reverted the fix, got the predicted crash, restored it) and fixed with
  `timeout: :infinity, on_timeout: :kill_task` — the actual bound was
  always meant to come from `Runner.run/2`'s own `tool_timeout` alone.
  The same review also flagged six Low-severity items, all fixed: shared
  stacktrace-stripping for crash error messages, MCP confinement
  distinguishing "dropped every match" from "server found nothing,"
  a documented (not fixed) newline-in-filename transport ambiguity, and
  small test/readability cleanups.

## MCP server (Component 1)

- **`%Anubis.Server.Component.Tool{}` built directly**, not via
  `Frame.register_tool/3` or the `component` macro — both expect a
  Peri-DSL schema and would mangle the raw JSON Schema maps
  `Tools.specs()` already produces for the model. A second, more
  dangerous footgun found while confirming this against the vendored
  source: a `Tool` with `validate_input: nil` has the client's real
  arguments silently discarded and replaced with `%{}` before dispatch
  ever sees them — every tool here sets an identity-passthrough
  `validate_input` for exactly that reason (real validation is
  `Illume.Tools.dispatch/4`'s job).
- **`target_dir` passed via `Application.put_env/3`**, not supervisor
  start opts — `anubis_mcp` has no channel to forward arbitrary config
  into a server's `init/2` for the stdio transport. Acceptable
  process-global state here specifically because `--serve` is a one-shot,
  blocking CLI invocation (never two in the same VM).
- **Two-tier test strategy**, since `anubis_mcp`'s `StubTransport` isn't
  published in the hex package: `mcp_server_test.exs` calls `init/2`/
  `handle_tool_call/3` directly as plain functions (no transport); a
  separate `:e2e`-tagged test (excluded by default, run with
  `mix test --only e2e`) spawns the real compiled escript as an OS
  subprocess and drives it with a real client over real stdio.
- **`anubis_mcp`'s own stdio Logger-redirect is a no-op** — a known,
  confirmed-with-the-maintainer upstream bug (any log line corrupts the
  stdio JSON-RPC stream, and the library's own guard against this always
  fails because Erlang refuses to change a *running* logger handler's
  `:type`). Fixed on our side by removing and re-adding the default
  logger handler with the device changed, the only way Erlang allows it.
- **Stdio EOF restart-storm**: once a connected client disconnects,
  `Anubis.Server.Supervisor`'s `:one_for_all` strategy (no backoff)
  restarts the whole session tree, which hits the same closed stdin
  immediately and crashes on `reached_max_restart_intensity` within
  milliseconds. No supported way to change this. Mitigated, not fixed:
  `Illume.CLI.serve/1` monitors the server supervisor and exits cleanly
  the moment it dies, rather than hanging as a zombie. Filing this
  upstream is future work.

## Shared question-runner (Component 2)

- `Illume.QA.ask/4` was extracted verbatim from `Illume.CLI`'s inlined
  agent-start-and-block logic, so the web UI (Component 3) drives the
  exact same path the CLI does. `opts` is threaded through so callers can
  override `model_timeout`/`tool_timeout`/`client`.

## Web front end (Component 3)

- **`Illume.Endpoint` and `config/` built ahead of the plan's own task
  order**, since an earlier task (an async-behavior spike) needed a real
  running endpoint to test against. `config/prod.exs` is intentionally
  near-empty — this project has no `mix release`/production path, only
  the escript and `mix illume.server` (both dev-env by default), and the
  endpoint defaults to `server: false` for the same reason `mix
  phx.server` gates on `PHX_SERVER` — compiling or testing must never
  bind a port by accident.
- **A `start_async`/`handle_async` spike confirmed the design is safe**
  for `Illume.QA.ask/4` specifically: a raising async fun delivers a
  clean `{:exit, reason}` without crashing the LiveView, and there's no
  built-in timeout (a fun still running past 5s completes normally once
  it returns). Reading the library source surfaced the one real gap this
  doesn't cover — an *inner* linked process crashing inside the async fun
  would bypass this isolation — which doesn't apply here, since
  `Illume.QA.ask/4` never spawns a nested linked process.
- **`mix illume.server` starts `Illume.Endpoint` under its own
  supervisor**, not `Illume.Application`'s default children, mirroring
  the MCP server's pattern — the plain CLI/escript path never starts a
  PubSub or HTTP listener it doesn't need. Two real issues caught on
  first run: Phoenix defaults to a Cowboy adapter that was never added as
  a dependency (fixed by explicitly configuring the Bandit adapter), and
  Dialyzer couldn't see `Mix.Task`'s callbacks for the new task module
  (fixed with `plt_add_apps: [:mix]`).
- **`target_dir` for the web UI resolves from the module's own source
  path** (`Path.expand("../..", __DIR__)`), not `File.cwd!()` — correct
  regardless of the directory `mix illume.server` is invoked from.
- **The status-line telemetry handler is gated on `asking?`.**
  `:telemetry` events aren't scoped to a request — every open LiveView
  connection's handler receives every in-flight agent's events — so
  without the guard, an unrelated question in another tab would flash a
  stray status update. This narrows but doesn't fully close a
  cross-session information leak; see Known Gaps.

## Hardening pass 2 — post-review hardening of Components 1-3

A `/phx:review` pass on Components 1-3 came back REQUIRES CHANGES: one
Critical functional gap, 5 Medium/2 Low security findings, 2 test-quality
issues, and several code-quality gaps. This pass closed every one of
them, either fixed or explicitly documented as deferred.

- **The web UI didn't actually work in a real browser** — every test used
  `live_isolated/3`, which bypasses the browser/JS layer entirely, so
  nothing caught that `render/1` emitted a bare `<div>` with no
  `<html>`/`<head>`, no client JS, and no `Plug.Static`. Fixed with a
  proper root layout (`Illume.Layouts.root/1`, wired via the router's
  `root_layout` option, not the inner `layout:` option) and `Plug.Static`
  entries serving `phoenix.js`/`phoenix_live_view.js` straight from the
  `phoenix`/`phoenix_live_view` deps' own `priv/static` (`Plug.Static`'s
  `:from` tuple resolves via `Application.app_dir/1`, which works for any
  loaded OTP app, not just the host — no build tooling needed).
  Manually verified in a real browser, which surfaced two hard blockers
  the plan hadn't connected to this task: `protect_from_forgery` turned
  out to be load-bearing for the LiveView socket to work at all (without
  it nothing writes to the session, no cookie is ever set, and the
  client loops forever reloading), and fixing that exposed dev/test
  `secret_key_base` values that were 2 bytes short of Plug's 64-byte
  minimum, crashing the first real session write. Both were pulled
  forward and fixed alongside this task. Standard Phoenix security
  headers (`protect_from_forgery`, `put_secure_browser_headers`,
  `:accepts`) were added to the router pipeline at the same time.
- **Server-side `ask` guard + bounded agent concurrency.** The
  `asking?`/length guard only existed client-side (the `disabled`
  attribute); a non-browser client could bypass it and spawn unbounded
  billed model calls. Fixed with a server-side check in `handle_event/3`
  plus `max_children: 20` on `Illume.AgentSupervisor` as defense in
  depth.
- **Bearer-token auth on the web endpoint.** `check_origin` doesn't stop
  a non-browser local client (no `Origin` header). `mix illume.server`
  now generates a random token per run, prints it in the startup URL, and
  `QuestionLive` checks it (via `Plug.Crypto.secure_compare/2`) in both
  `mount/3` and `handle_event/3` — not just gating what's rendered, since
  a raw socket client could otherwise send events directly regardless of
  what's on screen.
- **Type guards for malformed MCP client input.** A non-`String.t()`
  `path`/`pattern` from an external MCP client could crash that session
  by reaching `Path.expand/2` unguarded. Extended `validate_input/3` with
  type guards for `read_file`'s path, `search_files`/`grep_content`'s
  pattern, and (found while implementing, same vulnerability class)
  `grep_content`'s optional path field too.
- **Test-quality fixes**: a weak error-path assertion in `qa_test.exs`
  tightened to check the actual formatted string, not just the shape; a
  flaky polling-based wait pattern replaced with
  `Phoenix.LiveViewTest.render_async/2` (a hand-rolled message-based fix
  was tried first and found to still race — see below); a throwaway spike
  test deleted (its findings were already captured here); new coverage
  for telemetry handler detach and a previously-untested status-line
  branch; new in-process coverage that `--serve` actually boots the MCP
  server.
- **Two places a review-proposed fix was tried and found unsafe or
  unreliable before landing anything else**, both worth remembering:
  1. A message-based test de-flake (`send(test_pid, :done)` from inside a
     mocked async function, then `assert_receive`) was tried and failed
     non-deterministically under repeated test seeds — `send/2` only
     guarantees ordering between one sender and one receiver, and the
     mock's message to the test process races independently against the
     async task's own completion message to the LiveView process.
     `Phoenix.LiveViewTest.render_async/2` (which monitors the actual
     task and blocks on its exit before rendering) sidesteps this by
     keeping both the wait and the render on messages to the *same*
     process.
  2. Starting the real MCP server with its actual `transport: :stdio` in
     a test process was tried and found to trigger the stdio restart-storm
     bug (above) *synchronously inside the start call itself* — because a
     test run's stdin is already closed, unlike a real subprocess's. This
     risks crashing the whole shared test VM, not just one test. Used a
     non-stdio transport (`:streamable_http`) instead to prove the same
     "does the supervisor accept this child spec" claim safely.
- **Code-quality cleanups**: de-duplicated a test's byte-for-byte copy of
  `to_content_string/1` (made the real function public instead),
  tightened `Illume.QA.ask/4`'s `@spec` to the actual error-string
  invariant, and replaced a bare pattern match that could crash with an
  unhandled `MatchError` with a proper `case`.
- **A `/phx:review` re-pass** (required before considering this branch
  done) came back PASS WITH WARNINGS. One reported finding — the bearer
  token being logged in plaintext — was investigated further and
  disproven: Phoenix ships a built-in `filter_parameters` default
  (`["password", "token"]`) that already redacts it, confirmed by reading
  the library source and by rerunning the suite and checking the actual
  log output. One real bug did survive: `handle_event("ask", ...)`
  crashed on a non-binary `question` value from a raw socket client — the
  same input-validation class already closed at the MCP boundary, left
  open at the web boundary this pass added. Fixed with a type guard. The
  remaining findings were either already correctly scoped/documented
  (no change needed) or small direct fixes: dev's `secret_key_base`
  moved out of git into `config/runtime.exs` (random per boot, since
  nothing about this tool needs cross-restart session persistence), a
  documentation note on an `inspect/1` fallback's assumptions, and a
  misleading in-code comment reworded to match what `DECISIONS.md`
  already said correctly about the telemetry cross-session leak.
- `test/illume/cli_test.exs`'s `validate/1` tests mutated the global
  `ANTHROPIC_API_KEY` env var under `async: true` — a latent cross-test
  race (no other test file happened to touch that var, so nothing
  collided in practice, but the hazard was real). Fixed by moving the
  whole module to `async: false`; a one-line change not worth leaving
  deferred once actually looked at.
- `search_files`/`grep_content` used to filter noise via a small
  hardcoded directory list (`.git`, `_build`, `deps`, `node_modules`,
  etc.), which could never be exhaustive across languages/tools. Added
  `Illume.Tools.FileDiscovery`, shared by both: when `target_dir` is a
  git repo, enumerates files via `git ls-files --cached --others
  --exclude-standard`, so a target project's own `.gitignore` is
  respected instead of a generic guess; falls back to the old
  walk-and-skip-a-static-list approach otherwise (still
  confinement-checked, since `Path.wildcard/2`'s `**` — unlike git or
  `grep -r`'s own default — follows symlinked directories). Also had to
  guard against a subtler case: `git -C dir ls-files` inherits an
  *enclosing* repo's ignore rules for the path to `dir`, not just paths
  under it, which silently returned empty for any `target_dir` that
  itself sits inside a gitignored path of a larger repo (hit immediately
  by ExUnit's own `tmp_dir` fixtures, which live under this project's
  own gitignored `tmp/`) — checked explicitly with `git check-ignore`
  rather than trusting that empty result. `grep_content` also moved from
  letting `grep -r` walk the directory itself to being handed the
  discovered file list directly, batched (500 files per invocation) to
  avoid one unbounded argument list on a very large target.
- The global `:telemetry` handler `QuestionLive.mount/3` attaches gave
  every open LiveView connection every in-flight agent's events — the
  `asking?` guard only stopped an unrelated event from being displayed,
  not from being received, so one connection's tool-call names could
  flash on another's screen. Fixed with a `request_id` (`make_ref/0`,
  fresh per `ask`) threaded through the existing `opts` pass-through
  `Illume.QA.ask/4` already had (no new parameter needed there) into
  `Illume.Agent`'s `init/1`, which stashes it in the process
  dictionary — read back by the one private `telemetry/2` helper every
  emission already goes through, so all ~15 call sites picked it up
  without individually threading it, the same way `Logger.metadata/1`
  attaches process-local context without touching every log call.
  `QuestionLive.handle_info/2` now requires the incoming event's
  `request_id` to match the connection's own current one, not just
  `asking?`. Testing this precisely meant a small test redesign: the
  connection's real `request_id` is opaque from outside `handle_event/3`
  (fresh `make_ref/0` per ask), so there's no way to fire a *matching*
  synthetic telemetry event at a real `live_isolated/3` view from a
  test — exercised `handle_info/2` as a plain function instead (same
  pattern already used for `terminate/2` and `handle_async/3`'s
  `{:exit, reason}` case), which also let both the matching and
  mismatched cases be asserted precisely, something the old
  fire-at-a-real-view test couldn't do at all.

## Known gaps (deliberately deferred, not silently skipped)

- A `--mcp`/`--serve`/`mix illume.server` run interrupted with Ctrl-C
  doesn't run cleanup — Elixir's public API cannot trap `:sigint`;
  closing this fully would require undocumented low-level OS signal
  APIs. Consequence differs by entrypoint: `--mcp` leaks spawned
  `npx`/`uvx` subprocesses; `--serve` and `mix illume.server` have
  nothing of their own to leak, but a direct Ctrl-C on `--serve` also
  bypasses `await_server_exit/1`'s graceful-exit monitor (moot in
  practice — a real MCP client disconnects via stdin EOF, which
  `--serve` already handles; entry 53). `--serve`'s exposure to this
  wasn't documented until noticed well after `--serve` itself was
  built — the original note (entry 41) predates `--serve`'s existence
  by a week and was never revisited against it. Documented in all
  three entrypoints' moduledocs now.
- No multi-turn conversation support, provider abstraction, or
  multi-user auth/accounts — explicitly out of scope throughout; the web
  UI and MCP server stay single-operator, local-only in spirit.
- The MCP server's stdio EOF restart-storm (upstream `anubis_mcp` bug) is
  mitigated (the escript exits cleanly instead of hanging) but not fixed
  — the underlying restart storm still happens on every client
  disconnect. Filing this upstream is future work.
