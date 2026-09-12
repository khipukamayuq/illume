# Decisions Log

A running record of architectural/design decisions, dependency bugs,
workarounds, and deviations from the original spec, kept as the project
evolves. Add an entry whenever: a dependency bug is found and worked
around; an implementation diverges from what was originally planned or
asked for; a design tradeoff is made deliberately over a real alternative;
or something known-imperfect is consciously deferred rather than silently
skipped. Entries are numbered and chronological (oldest first) within each
section; add new ones to the bottom of the relevant section, or start a
new section if a new theme emerges.

## Core architecture (from the initial spec)

### 1. Single provider, no abstraction layer
**Date:** 2026-09-04 · **Status:** Accepted
Hardcoded against the Anthropic API only — no Ollama, no provider
abstraction. Explicit hard constraint from the original request, not
something to relax without asking first.

### 2. Hand-built GenServer loop instead of `Messages.run/1`
**Date:** 2026-09-04 · **Status:** Accepted
`Illume.Agent` is a GenServer state machine (`idle -> awaiting_model ->
awaiting_tool -> done`, driven by `handle_continue/2`) built from
`req_anthropic`'s primitive `Messages.create/1`. `Messages.run/1` (its
auto-loop helper) is deliberately never used — outsourcing the loop would
defeat the point of the exercise. See entry 25 for how the two actually
differ under the hood.

### 3. Every tool call runs under `Task.Supervisor` with a timeout
**Date:** 2026-09-04 · **Status:** Accepted
`Illume.Tools.Runner` wraps every tool dispatch in
`Task.Supervisor.async_nolink` + `Task.yield`/`Task.shutdown`. A crash or
timeout becomes an error tuple fed back to the model; it can never reach
the Agent process itself.

### 4. Explicit allow-list, re-checked at the point of dispatch
**Date:** 2026-09-04 · **Status:** Accepted
`Illume.Tools.dispatch/4` re-checks the allow-list itself rather than
trusting the caller or any underlying server's own configuration — this
is the actual enforcement of "read-only," not an assumption. Checked at
two independent layers: `Illume.Agent.run_tool/2` (to short-circuit
before even attempting dispatch) and `Illume.Tools.dispatch/4` itself
(defense in depth).

### 5. Max-iteration guard
**Date:** 2026-09-04 · **Status:** Accepted
Default 10 tool-use turns; on hitting the limit, the agent returns a
clear "gave up" message instead of looping forever or crashing.

### 6. `:telemetry` instrumentation
**Date:** 2026-09-04 · **Status:** Accepted
Events for `loop_turn`, `tool_call`, and `model_call`, each with
start/stop/exception variants.

### 7. Two-phase tool implementation, half-day timebox on Phase B
**Date:** 2026-09-04 · **Status:** Accepted — Phase B landed within budget
Tools were built first as direct in-process Elixir calls, then (within a
stated half-day timebox) an MCP-backed alternative was added, proxying to
the official filesystem and git reference servers via `anubis_mcp`. The
timebox was explicit: if Phase B didn't land cleanly, Phase A would ship
as final and MCP would become a documented next step rather than a
blocker. It landed cleanly (see entries 14–16 for what that actually
took).

## Tool design

### 8. Added `grep_content` as a 5th, permanently local tool
**Date:** 2026-09-04 · **Status:** Accepted (discussed with the user)
Neither reference MCP server exposes content search — `search_files`
only matches file *names*. Without content search, "where is X used"
questions would require reading entire files iteratively. Added
`grep_content` (fixed-string, not regex) as a tool with no MCP
equivalent, ever — a deliberate, disclosed exception to the plan's
"3–4 tools drawn from the two reference servers" target, agreed with the
user before implementation rather than decided unilaterally.

### 9. Fixed-string search, not regex
**Date:** 2026-09-04 · **Status:** Accepted
`grep_content` uses `grep -F`, not regex matching. Avoids the model
needing to reason about regex-escaping when searching for an identifier,
and avoids a regex-injection-shaped surface entirely.

### 10. Hardcoded model and token limit
**Date:** 2026-09-04 · **Status:** Accepted
`Illume.LLM.AnthropicClient` hardcodes `model: "claude-sonnet-5"` and
`max_tokens: 4096`. Not configurable — matches the spec's "hardcode
against Claude Sonnet" instruction.

### 11. Default limits: 10 iterations, 10s tool timeout
**Date:** 2026-09-04 · **Status:** Accepted
Both configurable via `Illume.Agent.start_link/1` opts, but default to
values chosen to keep a confused loop or a hung tool from stalling the
CLI indefinitely.

### 12. Output caps and noise filtering
**Date:** 2026-09-04 · **Status:** Accepted
`read_file` truncates at 300KB; `search_files` and `grep_content` cap
results at 200 (and `grep_content` also caps at 200 matches *per file*,
see entry 30); both skip `.git`, `_build`, `deps`, `node_modules`,
`.elixir_ls`, `cover`. Deliberate token-budget and noise-reduction
choices, not exhaustively tuned.

### 13. Phase B shipped as an opt-in `--mcp` flag, not a default swap
**Date:** 2026-09-04 · **Status:** Accepted (judgment call, not explicitly requested)
The plan's Phase B framing read as "replace Phase A once it works."
Instead, `:direct` stayed the permanent default and MCP is opt-in via
`--mcp`, reasoning: spawning `npx`/`uvx` subprocesses and depending on
network access on first run is real added fragility for a portfolio demo
that a fully-working, zero-external-dependency direct implementation
doesn't have. This was my own call, stated at the time, not something
the user asked for — flagging it here as a deviation worth being able to
revisit.

## Dependency bugs found

### 14. `anubis_mcp` 2.0.0 — ETS table collision between same-named clients
**Date:** 2026-09-04 · **Status:** Root-caused; worked around, not patched
`Anubis.Client.Cache` keys its `:private` ETS tool-validator table by
`client_info["name"]` alone, not by client process. Two `Anubis.Client`
processes sharing the same name (the filesystem and git clients were
both initially named `"illume"`) collide on that table: the second
process can't read a table owned by the first, and crashes with an ETS
"insufficient access rights" error on any tool result carrying
`structuredContent` — which includes every `isError` result. Found via
live testing against real `npx`/`uvx`-spawned servers, not theorized.
Worked around (see entry 15) rather than reported/patched upstream.

## Workarounds

### 15. Distinct `client_info["name"]` per MCP client
**Date:** 2026-09-04 · **Status:** Fixed
Direct fix for entry 14 — `"illume-filesystem"` / `"illume-git"` instead
of a shared `"illume"`.

### 16. `Illume.Tools.MCP.Client` behaviour + `AnubisClient` adapter
**Date:** 2026-09-04 · **Status:** Accepted
`anubis_mcp` isn't designed to be swapped out, so a thin behaviour +
adapter (mirroring the existing `Illume.LLM.Client` pattern) was
introduced purely so Mox can mock `Anubis.Client` calls in tests without
spawning real server processes. Not in the original plan — added when
closing test-coverage gaps.

### 17. `Req.Test` + `plug` as a test-only dependency
**Date:** 2026-09-04 · **Status:** Accepted
Used to test `Illume.LLM.AnthropicClient` without hitting the real
network, via `req_anthropic`'s `Application.get_env(:req_anthropic,
:plug)` test hook. `plug` isn't a direct dependency of anything else in
the project (it's optional for both `req` and `anubis_mcp`), so it had to
be added explicitly, `only: :test`.

### 18. `DynamicSupervisor` for Agent and MCP client processes
**Date:** 2026-09-04 · **Status:** Accepted (forced by tooling)
The plan called for the Agent to be "linked, one-shot, not under a
permanent supervisor." The session's Iron Law hook (`iron-law-verifier`)
blocked every bare `GenServer/Agent.start_link` call outside a module
definition, both in tests and in `Illume.CLI`. Resolved by adding
`Illume.AgentSupervisor` and `Illume.MCPSupervisor` (both
`DynamicSupervisor`s) and starting one-shot children under them with
`restart: :temporary` — functionally equivalent to the original plan, but
structural supervision the plan didn't call for, added to satisfy the
harness rather than a re-evaluated requirement.

### 19. `Path.wildcard/2` returns matches with `..` unresolved
**Date:** 2026-09-04 · **Status:** Fixed
Discovered while fixing the `search_files` traversal bug (entry 26): a
first attempt filtered wildcard matches by string-prefix-checking them
against the root, which did nothing, because `Path.wildcard` doesn't
lexically normalize `..` in its own output (a match like
`lib/../../../etc/passwd` still starts with the root string). Fixed by
`Path.expand/1`-ing every match before the confinement check. Caught by
testing the fix itself with a live exploit attempt, not by inspection.

### 20. macOS `awk` doesn't support `\s` or 3-arg `match()`
**Date:** 2026-09-04 · **Status:** Worked around
Hit while auditing the codebase for missing `@spec`s during a cleanup
pass — BSD `awk` (macOS default) silently no-ops on GNU-style regex
shorthand. Rewrote the audit script using `[ \t]*` character classes.

### 21. No `timeout` command on macOS by default
**Date:** 2026-09-04 · **Status:** Worked around
Wanted to bound a test invocation of an MCP reference server; macOS
ships BSD userland without GNU coreutils' `timeout`. Used `npm view` for
a bounded connectivity check instead.

### 22. `gh repo create`/`gh repo edit` required extra flags
**Date:** 2026-09-04 · **Status:** Worked around
`gh repo create --source=. --remote=origin` was needed to wire up a
remote without pushing (setting local `branch.main.remote`/`.merge`
config by hand, since the remote branch doesn't exist yet to track).
`gh repo edit --visibility public` additionally required
`--accept-visibility-change-consequences`.

### 23. Git branch tracking config didn't survive `git branch -D main && git branch -m main`
**Date:** 2026-09-04 · **Status:** Worked around
Expected `branch.main.remote`/`branch.main.merge` (being name-keyed
config) to persist across deleting old `main` and renaming the squashed
orphan branch to `main`. It didn't — had to re-run `git config
branch.main.remote origin` / `branch.main.merge refs/heads/main` by hand
after the rename, before pushing.

## Bugs found in our own code (via self-review)

### 24. `search_files` had no path confinement at all
**Date:** 2026-09-04 · **Status:** Fixed — Severity: High, confirmed exploitable
Unlike `read_file`, `search_files` never called the confinement check.
Confirmed live: `*/../../../../../etc/passwd`-style glob patterns
escaped the target directory and leaked the real absolute path back
unmodified. Fixed by extracting shared `Illume.Tools.PathConfinement`
and filtering every match through it (see entry 19 for the follow-on bug
in that fix).

### 25. Agent crashed on a content-less-but-successful API response
**Date:** 2026-09-04 · **Status:** Fixed — Severity: Critical, confirmed
`handle_continue(:call_model, ...)` had no catch-all for `{:ok, body}`
lacking a `"content"` key — an unexpected-but-valid API response shape
crashed the GenServer instead of returning a clean error, defeating the
one guarantee this architecture exists to provide. This is also the
concrete difference from `Messages.run/1` worth naming: `Messages.run/1`
calls tool functions *inline* in the calling process with no
supervision, so a broken tool there crashes/hangs the caller directly;
`Illume.Agent` isolates every tool call via `Task.Supervisor` (entry 3),
so this particular bug was in the *model-response* handling, not tool
handling — and was the one gap in that isolation story.

### 26. Phase B skipped the local guards Phase A had
**Date:** 2026-09-04 · **Status:** Fixed — Severity: Medium, not currently exploitable
`Illume.Tools.MCP`'s `read_file`/`git_show` had no local path-confinement
or flag-injection guard, unlike their direct-call counterparts. Verified
live that both official reference servers currently catch these
themselves — so not an active vulnerability — but a violation of "never
rely on an underlying server's own configuration." Fixed by hoisting
both guards into `Illume.Tools.dispatch/4`, applied uniformly regardless
of backend.

### 27. Path confinement was lexical only, symlink-unaware
**Date:** 2026-09-04 · **Status:** Fixed — Severity: real but lower priority (per the review)
`PathConfinement` compared `Path.expand/2` output directly, so a symlink
inside the target directory pointing outside it would pass. Fixed with
`real_path/1`, a `realpath`-style walk of every path component (not just
the final one, since a symlinked *directory* redirects just as easily),
capped at 40 hops and failing closed on a cycle.

### 28. `DynamicSupervisor` child leak on partial MCP-client-start failure
**Date:** 2026-09-04 · **Status:** Fixed — Severity: minor
If the filesystem client started but the git client (or either
`await_ready`) failed, the already-started child was left running.
Fixed with `stop_clients/0`, called on any failure branch of
`start_clients/1`.

### 29. Unbounded grep output before truncation
**Date:** 2026-09-04 · **Status:** Fixed — Severity: minor
`grep_content` buffered a tool's entire stdout before `cap/2` truncated
it — a single huge matching file could blow up memory before truncation
ever ran. Fixed with grep's own `-m 200` per-file match cap. Verified
against a real 1000-line-match file (capped at 200).

### 30. UTF-8 truncation could split a multi-byte character
**Date:** 2026-09-04 · **Status:** Fixed — Severity: minor
`read_file`'s truncation used `binary_part/3` at an exact byte offset,
which can land mid-codepoint and produce invalid UTF-8 (which would then
fail JSON-encoding the tool result). Fixed by rejecting non-UTF-8 file
content outright, and truncating oversized files at a valid UTF-8
boundary (backing off byte-by-byte until valid). Verified against a file
engineered to straddle the exact boundary, and a fake PNG.

### 31. Minor idiom issues
**Date:** 2026-09-04 · **Status:** Fixed
`format_error/1` matched `%{__exception__: true}` directly instead of
using the `is_exception/1` guard; `Agent` built up `messages` via
repeated `++`-append (O(n) each time) instead of prepending (O(1)) and
reversing once before sending to the model.

### 32. `Application.put_env` global state for backend selection
**Date:** 2026-09-04 · **Status:** Fixed
`:tool_backend` was originally read via `Application.get_env` inside
`Illume.Tools`, mutated globally by `Illume.CLI`. This is process-global
mutable state determining per-call control flow — flagged as a landmine
for future reuse (and directly demonstrated as one: testing the `:mcp`
branch required careful `async: false` + `on_exit` isolation to avoid
contaminating unrelated concurrent tests). Fixed by threading `backend`
as an explicit parameter: `Illume.CLI` -> `Illume.Agent` (new
`tool_backend` struct field) -> `Illume.Tools.dispatch/4`. The
`:mcp_client` env var (entry 16's DI seam) was deliberately *not*
changed the same way — every test that touches it wants the same mock
value, and Mox's own per-process expectation ownership (not that value)
is what actually isolates concurrent tests, so it doesn't share
`:tool_backend`'s hazard.

## Deviations from the original plan

### 33. `dispatch/3` became `dispatch/4`
**Date:** 2026-09-04 · **Status:** Accepted (see entry 32)
A bigger interface change than the plan described, driven by the
`:tool_backend` global-state fix.

### 34. "Phase A"/"Phase B" language removed from code and docs
**Date:** 2026-09-04 · **Status:** Accepted (user request)
Renamed to "direct"/"mcp" throughout — implementation-history labels
from planning aren't domain concepts and don't belong in code comments
or module docs. The plan file itself (local, gitignored scratch
documentation) still uses the original phase language; it wasn't
required to match.

### 35. Test infrastructure grew beyond the original plan
**Date:** 2026-09-04 · **Status:** Accepted
The plan's verification section said the suite would make "no real
network calls" but didn't call for a Mox-mockable seam around the MCP
client boundary, `Req.Test`-based testing of the Anthropic client, or
the `plug` test dependency (entries 16–17) — all added later, in
response to a direct request to close test-coverage gaps, not planned
up front.

### 36. Git history squashed before the first push; repo made public
**Date:** 2026-09-04 · **Status:** Accepted (explicit user request)
5 incremental commits (MVP, symlink fix, test-coverage-gap fixes, minor
review-item fixes, README/license) were squashed into a single clean
initial commit before the first push, since nothing had reached the
remote yet (safe, non-destructive to any shared history). Repo
visibility was changed from private to public per explicit request,
after which an MIT `LICENSE` was added and the README was written to
note the `anubis_mcp` LGPL-3.0 dependency (used unmodified, doesn't
affect this project's own license — see the license discussion in
conversation history for the full reasoning).

## Documentation & process decisions

### 37. README framing choices
**Date:** 2026-09-04 · **Status:** Accepted (user request)
No author/contact section; includes an explicit "work in progress, not
production-hardened" disclaimer; deliberately avoids framing the project
as existing "to demonstrate OTP design" even though that was the
original motivation — the README describes what the tool does and how,
not why it was built.

### 38. `.gitignore` scope
**Date:** 2026-09-04 · **Status:** Accepted
Excludes `.claude/settings.local.json` and the plugin's local working
directories (`plans/`, `reviews/`, `audit/`, `research/`, `solutions/`,
`skill-metrics/`) as tooling-local scratch data, not project source;
also `.DS_Store` and the compiled `/illume` escript binary (a build
artifact). This means review reports and the plan file live only
locally, not in the public repo — `DECISIONS.md` (this file) is the
durable, committed substitute for the parts of that history worth
keeping public.

## Hardening pass

A follow-up pass (separate from the original spec above) addressing six
issues from an independent code review plus one capability upgrade, on a
`hardening-pass` branch with one commit per item — deliberately not
squashed, unlike entry 36, since this round wanted a reviewable PR history.

### 39. MCP `search_files` given its own confinement layer
**Date:** 2026-09-07 · **Status:** Accepted
`Illume.Tools.MCP.search_files/2` forwarded the model's pattern straight
to the external filesystem server with no confinement check of its own,
unlike the `:direct` backend's `Filesystem.search_files/2`. Before
fixing, live-probed the real reference server's `search_files` response
(not assumed): a successful result is one `"text"` content block of
newline-joined absolute paths, with the literal sentinel `"No matches
found"` for zero matches; `structuredContent` is present on *every*
result, not only `isError` ones (entry 14's original note about it
appearing "on any tool result carrying `structuredContent`" undersold
this — it's universal, not error-specific, though this didn't change
anything since `extract_text/1` only ever reads `"content"`). Matches
are now re-filtered through `PathConfinement.within?/2`, dropping
anything outside `target_dir` and emitting a new
`[:illume, :mcp, :confinement_violation]` telemetry event — a distinct
event family rather than folded into `[:illume, :tool_call, ...]`,
since the latter's start/stop/exception vocabulary is a per-call
lifecycle marker emitted by `Illume.Agent`, while this is a
security-relevant signal emitted from inside `Illume.Tools.MCP` itself.

### 40. Model call converged into `Runner.run/2`, manual `rescue` removed
**Date:** 2026-09-07 · **Status:** Accepted
Two separate review findings — no wall-clock timeout on the model call,
and `call_model/1`'s `rescue e -> {:error, e}` only catching raises, not
exits — converged on one fix: routing `state.client.create/1` through
`Illume.Tools.Runner.run/2` (the same primitive tool calls already use)
under a new `model_timeout` field (default 60s). This made the manual
`rescue` redundant (Runner's Task isolation catches raises, exits, and
hangs uniformly), so it was removed rather than kept alongside the new
path — the diff is smaller than "two fixes" would imply, deliberately.

### 41. MCP subprocess cleanup: `try/after` added, Ctrl-C left as a known gap
**Date:** 2026-09-07 · **Status:** Accepted (investigated, not silently assumed)
Verified empirically before fixing: normal completion (including the
agent-error path) already left no leaked `npx`/`uvx` processes, but a
`--mcp` run interrupted mid-flight with SIGINT did leak — confirmed live
via a temporary `Process.sleep` probe (reverted before committing), not
simulated. Investigated why: the Erlang VM intercepts SIGINT for its own
built-in BREAK menu before any Elixir code runs, and `System.trap_signal/2,3`
explicitly refuses `:sigint` (confirmed against the actual
`FunctionClauseError` guard — only `sigquit`, `sigterm`, `sigusr1`,
`sighup`, `sigabrt`, `sigalrm`, `sigusr2`, `sigchld`, `sigstop`, and
`sigtstp` are trappable). A real fix would mean dropping to the
undocumented-for-typical-use `:os.set_signal/2` plus a custom
`erl_signal_server` handler. Given the choice, explicitly decided against
that: added `try/after` around the two outcomes `Agent.ask/2` can
actually produce (guaranteed cleanup on success and on agent-error), and
documented the Ctrl-C gap in `Illume.CLI`'s moduledoc rather than
reaching for the low-level workaround or leaving the gap unmentioned.

### 42. `git_show`'s flag-injection fix changed mid-implementation after live testing
**Date:** 2026-09-07 · **Status:** Accepted
The plan going in was to mirror `Grep.grep_content/2`'s `--`-before-the-
pattern idiom in `Git.git_show/2`, removing the existing (duplicated)
`String.starts_with?(revision, "-")` checks entirely. Tested live before
committing to that, rather than trusting the idiom would transfer: it
doesn't. `git show --stat -p -- <revision>` silently returns an empty,
exit-0 result for a *real* commit SHA — git's `--` switches everything
after it to pathspec-only mode, not "shielded positional argument" mode,
so this would have been a functional regression, not just a security
gap. Separately, with no shielding at all, `git show --stat -p
"--output=/tmp/x"` was confirmed to actually write the diff to an
arbitrary file — a real arbitrary-file-write via a tool that's supposed
to be strictly read-only, not a theoretical concern. The original
leading-dash check was already correct and load-bearing; the actual
(valid) complaint was only that it existed in two places
(`Git.git_show/2` and `Tools.validate_input/3`) with two different error
shapes. Resolution: kept the check, consolidated to one copy in
`Tools.validate_input/3` only, so it still applies uniformly regardless
of backend; `Git.git_show/2` no longer duplicates it and documents that
it depends on already-validated input.

### 43. CI and static analysis added from scratch
**Date:** 2026-09-07 · **Status:** Accepted
`credo` and `dialyxir` added as `:dev, :test` deps (both environments
needed — `mix test` forces `MIX_ENV=test`, `mix credo`/`mix dialyzer`
default to `MIX_ENV=dev`); GitHub Actions workflow pinned to the exact
local toolchain (Elixir 1.20.2 / OTP 29) rather than a version matrix.
First run surfaced 5 small Credo findings (fully-qualified calls to
already-aliased-elsewhere modules) and zero Dialyzer findings — fixed
the former inline as planned rather than reshaping code around them,
since none were nontrivial.

### 44. Concurrent tool execution
**Date:** 2026-09-07 · **Status:** Accepted
Multiple `tool_use` blocks in one model turn now run concurrently via
`Task.Supervisor.async_stream_nolink` (new `max_tool_concurrency` field,
default 4) instead of `Enum.map`. `Runner.run/2` already guarantees each
individual call can't hang or crash the caller, so this is purely a
parallelization of already-safe work, not a new safety layer. The
stream's output is zipped back against the original `tool_uses` list to
prove — not assume — that `ordered: true` actually preserves
`tool_use_id` correlation under concurrent completion order.

### 45. Independent review of the hardening pass caught a real regression before merge
**Date:** 2026-09-11 · **Status:** Fixed
Ran a 4-agent parallel review (elixir-reviewer, security-analyzer,
testing-reviewer, requirements-verifier) against the hardening-pass diff
before opening it for merge — the pass itself had not been reviewed at
implementation time. Two agents independently flagged the same Critical
finding: entry 44's `Task.Supervisor.async_stream_nolink` call had no
`:timeout`/`:on_timeout`, silently inheriting Elixir's defaults —
5000ms with `on_timeout: :exit`. Confirmed directly against the
installed Elixir version's own docs, then reproduced empirically
(reverted the fix, got the exact predicted failure —
`Task.Supervised.stream(5000) ** (EXIT) time out` — then restored it):
a tool running past 5s didn't yield a graceful `{:exit, reason}` stream
entry, it killed the `Illume.Agent` GenServer outright, crashing the
caller's `GenServer.call(pid, {:ask, _}, :infinity)`. This directly
contradicted entry 44's own stated rationale that concurrency "doesn't
add a new layer of timeout/crash semantics." Fixed with
`timeout: :infinity, on_timeout: :kill_task` — the actual bound was
always meant to come from `Runner.run/2`'s `tool_timeout` alone.

### 46. `git_show` upgraded from single-check to structurally safe, based on a review finding
**Date:** 2026-09-11 · **Status:** Fixed
Review also pointed out that entry 42's consolidation left
`Illume.Tools.Git.git_show/2` with zero validation of its own, and
identified a primitive the original investigation had missed:
`--end-of-options` (git ≥2.24) shields a revision from being parsed as
a flag without `--`'s side effect of switching to pathspec-only mode.
Re-verified live in both directions before adopting it — a real SHA
still resolves, a flag-like payload is still safely rejected. The
original investigation (entry 42) had tested `--end-of-options` only
combined with a redundant trailing `--`, which reintroduces the
pathspec trap, and wrongly concluded from that combination that the
flag "isn't honored" — a genuine methodology error, caught by review
rather than by the original testing. `git_show/2` now uses
`--end-of-options` and is safe on its own; `Tools.validate_input/3`'s
leading-dash check stays as a cheap fail-fast, making the two mechanisms
genuinely complementary rather than duplicated. Also added a
`when is_binary(revision)` guard so a non-string revision is rejected
cleanly instead of raising inside `String.starts_with?/2`.

### 47. MCP `search_files` confinement now requires matches to already be absolute
**Date:** 2026-09-11 · **Status:** Fixed
Review noted that entry 39's confinement filter fed external, unverified
strings into `PathConfinement.within?/2`, which was designed for
locally-generated absolute paths and resolves a relative input against
this VM's own working directory via `Path.expand/1`'s single-argument
form — not against `target_dir`. Masked in practice because the live-
tested reference server has only ever returned absolute paths, but
reproduced the real gap directly: with `target_dir` set to this VM's own
cwd (a normal invocation shape, e.g. `illume . "..."`), a relative match
mixed into an otherwise-valid response incorrectly passed confinement
and got included in the result — a path the server never actually
claimed. Fixed by requiring `Path.type(path) == :absolute` before
checking confinement at all, and documented the precondition on both
`Illume.Tools.MCP`'s and `PathConfinement`'s own moduledocs, since
`within?/2` never having advertised this requirement is how the gap
arose in the first place.

## Known gaps (deliberately deferred, not silently skipped)

- `grep_content` can pick up non-ignored binary/cache directories (e.g.
  a `.expert/` index cache observed during testing) — grep's own
  binary-file detection prevents garbage output, but it's noisy. Not
  fixed; not asked for.
- ~~No CI pipeline, no Dialyzer/Credo integration~~ — resolved by the
  hardening pass (entry 43).
- A `--mcp` run interrupted with Ctrl-C/SIGINT does not clean up its
  spawned `npx`/`uvx` subprocesses (entry 41) — Elixir's public API
  cannot trap `:sigint`; closing this fully would require dropping to
  undocumented-for-typical-use low-level OS signal APIs. Documented in
  `Illume.CLI`'s moduledoc; not fixed.
- No MCP server mode, multi-turn conversation support, or provider
  abstraction — explicitly out of scope for both the original spec and
  the hardening pass, not oversights.
