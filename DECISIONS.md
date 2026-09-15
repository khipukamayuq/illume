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

### 48. Low-severity review findings fixed as a follow-up batch
**Date:** 2026-09-14 · **Status:** Fixed
The same review that produced entries 45-47 also flagged six Low-severity
items. All fixed: (1-2) a shared `strip_stacktrace/1` helper now keeps
`format_error/1`'s crash fallback, `tool_stream_result/1`'s `{:exit,
reason}` clause, and `run_allowed_tool/4`'s `{:crashed, reason}` branch
from `inspect/1`-ing a raw exit reason's full stacktrace (verified via a
Task that `throw/1`s a non-exception value); (3) `confine_matches/2` in
`lib/illume/tools/mcp.ex` now distinguishes "confinement dropped every
match" from "the server found nothing," and its sentinel-passthrough
check is trim-tolerant instead of exact-match; (4) the newline-in-
filename transport ambiguity has no real fix (checked the review's
suggested one — `structuredContent` returns the identical joined
string, not an array, per the live probe behind entry 39) and is
documented as an accepted limitation instead; (5) the concurrency
test's timing margin widened from ~30-50ms of slack to ~100ms; (6)
`within_confinement?/2`'s side-effecting `else` branch extracted into a
named function. Each behavioral fix was reverted and re-tested to
confirm its accompanying test actually catches the regression before
being restored, consistent with every other fix in this pass.

## MCP server (Component 1)

### 49. `%Anubis.Server.Component.Tool{}` built directly, not via `Frame.register_tool/3` or the `component` macro
**Date:** 2026-09-14 · **Status:** Fixed
`lib/illume/mcp_server.ex`'s `init/2` builds `%Anubis.Server.Component.Tool{}`
structs by hand from `Illume.Tools.specs()` and puts them straight into
`frame.tools`, rather than calling `Frame.register_tool/3` or using the
`component`/`schema do...end` DSL. Both of those paths run the input
schema through `Component.__clean_schema_for_peri__/1`, which expects a
Peri-DSL schema (atom-shorthand types) — not the raw Anthropic-shaped JSON
Schema maps `Tools.specs()` already produces for the model. Using either
would have silently produced a broken or wrong schema. Confirmed by
reading `deps/anubis_mcp`'s actual vendored source (version 2.0.0), not
guessed from the client API used elsewhere in this codebase.

A second, more dangerous footgun found the same way:
`Anubis.Server.Handlers.Tools.validate_params/3` has a clause
`validate_params(_, %Tool{validate_input: nil}, _), do: {:ok, %{}}` — a
`Tool` with `validate_input: nil` has the client's real arguments silently
**discarded and replaced with `%{}`** before dispatch ever sees them, not
passed through unvalidated as the field name would suggest. Every
`%Tool{}` built here sets `validate_input: fn params -> {:ok, params} end`
(identity pass-through) for exactly this reason — real validation is
`Illume.Tools.dispatch/4`'s job, not this library's. `handler: nil` routes
calls to `handle_tool_call/3` (one dispatch function for five tools,
instead of five component modules).

### 50. `target_dir` for `--serve` passed via `Application.put_env/3`, not supervisor opts
**Date:** 2026-09-14 · **Status:** Fixed
`Anubis.Server.Supervisor`'s own start opts (`:transport`, `:name`,
`:registry`, etc.) don't forward arbitrary application config into a
server's `init/2` — the only `assigns`-merging path
(`merge_transport_assigns/2`) is fed from per-connection transport context
(e.g. a Plug conn's assigns), not static supervisor start opts, and stdio
has no such per-connection context at all. `Illume.CLI`'s `serve/1` sets
`Application.put_env(:illume, :mcp_server_target_dir, target_dir)` once,
immediately before starting `Illume.MCPServer`, and `init/2` reads it back
with `Application.fetch_env!/2`. This is process-global config, which
`Illume.Tools`' own moduledoc otherwise warns against for backend
selection — but `--serve` is a one-shot, blocking CLI invocation
(never two in the same VM), and the value is genuinely immutable for the
process's whole lifetime, not per-call mutable state. Different situation,
same codebase; worth the explicit call-out rather than a silent exception
to the pattern.

### 51. Component 1 test strategy: two-tier, since `StubTransport` isn't published
**Date:** 2026-09-14 · **Status:** Fixed
`Anubis.Server.Supervisor`'s `@type transport` includes a `StubTransport`,
but its module is only defined under `anubis_mcp`'s own `test/support/` —
excluded from the published hex package (confirmed: no `stub` file
anywhere under `deps/anubis_mcp/lib`). So there's no in-process, no-real-
transport way to drive a server with `anubis_mcp`'s own client. Used two
tiers instead: (1) `mcp_server_test.exs` calls `init/2` and
`handle_tool_call/3` directly as plain functions — no transport, no
session, no supervisor — for schema equivalence, disallow-list behavior,
and path/revision rejection, mirrored 1:1 against `Illume.Tools.dispatch/4`
calls; (2) `mcp_server_e2e_test.exs`, tagged `:e2e` and excluded from the
default `mix test` run (`ExUnit.start(exclude: [:e2e])` in
`test/test_helper.exs`; run explicitly with `mix test --only e2e`), starts
the actual compiled escript as a real OS subprocess and drives it with a
real `Anubis.Client` over real stdio — protocol handshake, tool listing, a
real tool call round-trip. This does spawn one OS subprocess (our own
compiled escript, not an external `npx`/`uvx`-style tool), a lighter
version of what the spec's "no subprocess" guidance was steering away
from; flagged explicitly rather than silently reinterpreted.

### 52. `anubis_mcp`'s own stdio Logger-redirect is a no-op; worked around in `Illume.CLI`
**Date:** 2026-09-14 · **Status:** Fixed
The end-to-end smoke test (entry 51) failed its first real run with a
flood of `decode_failed`/`invalid_json` client warnings. Cause: Elixir's
default `:logger` handler writes to stdout, and `anubis_mcp`'s stdio
transport reads this process's own stdout as newline-delimited JSON-RPC —
any log line corrupts the protocol stream. `Anubis.Server.Transport.STDIO.init/1`
(`deps/anubis_mcp/lib/anubis/server/transport/stdio.ex:74`) already tries
to guard against exactly this via
`:logger.update_handler_config(:default, :config, %{type: :standard_error})`,
but that call's result is discarded — and it always fails.
`logger_std_h` refuses to change a *running* handler's `:type` (Erlang
returns `{:error, {:illegal_config_change, ...}}`; reproduced directly in
`iex` before touching any code), so the library's own fix has never
actually worked. This is a **known, unresolved upstream bug**: the
maintainer confirmed it in `zoedsoupe/anubis-mcp` issue #14 ("we indeed
have a bug on the server part because of the library logs... for STDIO
transport"), tracked as issue #25 (closed without the underlying fix
working, per direct testing against 2.0.0 — the latest published
release as of this writing). Fixed on our side in
`Illume.CLI.redirect_logger_to_stderr/0`, called before starting the
server: remove the `:default` handler and re-add it with the same
formatter/filters/level, only the device changed — the only way Erlang
actually allows this change. Cross-checked against Tidewave's own MCP
stdio proxy (`tidewave_phoenix`'s `lib/mix/tasks/tidewave.proxy.ex`,
`redirect_logs_to_stderr/0`), which does the identical remove-and-re-add
for the identical reason — independent confirmation this is the correct
fix, not a guess.

### 53. Stdio EOF restart-storm: `Anubis.Server.Supervisor`'s `:one_for_all` has no backoff
**Date:** 2026-09-14 · **Status:** Mitigated, not fixed (upstream)
Also found by the entry-51 smoke test: once the connected client
disconnects (stdin EOF), `Anubis.Server.Transport.STDIO` stops `:normal`
as designed — but its supervisor (`Anubis.Server.Supervisor`, `:one_for_all`,
default restart intensity) restarts the whole session tree, which sees the
same permanently-closed stdin and hits EOF again immediately, in a loop
with no backoff, typically exhausting the default intensity (3 restarts /
5s) within the same millisecond and crashing the supervisor with
`reached_max_restart_intensity`. A related, merged upstream fix (PR #240,
`restart: :temporary` for `Session` processes) addresses a *different*
lifecycle event (idle-session expiry) and does not touch the transport
child, which stays `:permanent`. No supported option exists on
`Anubis.Server.Supervisor.start_link/2` to change this. Tidewave's own
stdio server (`Tidewave.MCP.Stdio.run/2`) avoids the whole class of bug
architecturally — no OTP supervision at all, just a blocking
`IO.stream(:line) |> Enum.each(...)` loop that ends naturally on EOF —
which isn't available to us without abandoning `use Anubis.Server`
entirely. Decided against that scope; instead `Illume.CLI.serve/1` now
monitors the started `Anubis.Server.Supervisor` pid
(`await_server_exit/1`) and exits the escript — cleanly on `:normal`/
`:shutdown`, with a visible error otherwise — the moment it dies, rather
than sleeping forever as a zombie process with a dead server underneath
it. The restart storm itself (a few milliseconds of CPU spin before the
crash) is not eliminated; filing this upstream is future work, not done
as part of this pass. The end-to-end test's own teardown avoids the same
trigger from the client side too: no explicit `Supervisor.stop/1` on the
test's `Anubis.Client` (observed to itself crash the test's BEAM with a
`badarg` from inside its own EXIT report) — the client supervisor is
linked to the test process and torn down via that link when the test
ends instead.

## Shared question-runner (Component 2)

### 54. `Illume.QA.ask/4` extracted from `Illume.CLI.run_agent/3` verbatim
**Date:** 2026-09-14 · **Status:** Done
Component 3's LiveView needs the exact same "start an `Illume.Agent`, block
on `ask/2`" behavior the CLI already had inlined in `run_agent/3`. Extracted
as `Illume.QA.ask/4` with no behavior change — same
`DynamicSupervisor.start_child(Illume.AgentSupervisor, ...)` +
`Illume.Agent.ask/2` call, `opts` now passed through so a caller (tests,
Component 3) can override `model_timeout`/`tool_timeout`/`client` the same
way `Illume.Agent.init/1` already supports, without new surface area.
`run_agent/3` now delegates in one line. Regression check: `cli_test.exs`
and `agent_test.exs` needed no changes and stayed green — per the spec, a
break there would have been a signal the extraction leaked something.

## Web front end (Component 3)

### 55. `Illume.Endpoint` + `config/` added now, ahead of the Endpoint-wiring task (3.3)
**Date:** 2026-09-14 · **Status:** Done
Task 3.1's `start_async`/`handle_async` spike needs a real, running
`Phoenix.Endpoint` (`Phoenix.LiveViewTest.live_isolated/3` reads endpoint
config from an ETS table populated only once the endpoint process starts —
confirmed by reproducing the exact `ArgumentError` first, not guessing).
That dependency runs the other way from the plan's own task order (3.2
adds the deps; 3.1 needs them to write the spike at all), so the minimal
permanent pieces — `config/{config,dev,test,prod}.exs` and
`lib/illume/endpoint.ex` — were built now rather than as throwaway
test-only scaffolding, since Decision C already fully specifies what this
endpoint looks like (on-demand start via `mix illume.server`, no change to
`Illume.Application`'s default children) — there was nothing left
genuinely ambiguous to defer. `config/prod.exs` is intentionally near-
empty: this project has no `mix release`/production deployment path in
scope, only the escript and `mix illume.server` (both dev-env by default).
The endpoint's `server: false` default (overridden explicitly by
`mix illume.server` in task 3.3) mirrors `mix phx.server`'s own
`PHX_SERVER`-gated convention, for the same reason: compiling or testing
the project must never bind a port by accident.

Also added `import_deps: [:phoenix]` and the `Phoenix.LiveView.HTMLFormatter`
plugin to `.formatter.exs`, and `lazy_html` as a test-only dep
(`Phoenix.LiveViewTest` requires it for `live_isolated/3`'s HTML
assertions — hit as a real, actionable runtime error, not anticipated in
advance). `plug`'s existing `only: :test` restriction had to be dropped
too: `bandit`'s `websock_adapter` needs `plug` as a real runtime
dependency once Bandit is added, and Mix refuses to resolve a dependency
tree with conflicting `:only` requirements for the same package.

### 56. `start_async`/`handle_async` spike confirms the design is safe for `Illume.QA.ask/4` specifically
**Date:** 2026-09-14 · **Status:** Confirmed, not just assumed
`test/illume/async_spike_test.exs` proves both claims the plan's research
section needed proven live, not cited from docs: (1) a raising async fun
delivers `{:exit, {exception, stacktrace}}` to `handle_async/3` without
crashing the LiveView process; (2) a fun running past 5s (the exact
duration `async_stream_nolink`'s old default timeout used to bite this
project, entry 45) is neither killed nor treated as a crash — it
completes normally via `{:ok, result}` once it actually returns.

Reading `Phoenix.LiveView.Async`'s source (not just black-box testing)
explains *why*, and surfaces the one real gap: `run_async_task/5` starts
the async fun under `Task.start_link/1`, directly linked to the LiveView
process — `do_async/5` wraps the fun in `try/catch`, reports the result,
then explicitly `Process.unlink/1`s *before* re-raising, so a plain
raise/exit occurring in the fun's own process (exactly what
`GenServer.call` failing looks like) is always caught and unlinked first.
The gap: if the fun itself spawns *another* linked process (e.g. an inner
`Task.async/1`) and that one crashes, the untrapped EXIT signal kills the
async task before it ever reaches its own unlink-then-reraise, and that
kill *would* propagate to the LiveView for real, bypassing `handle_async/3`
entirely — this is the literal scenario the plan's research flagged as
unverified. It doesn't apply here: `Illume.QA.ask/4` only does
`DynamicSupervisor.start_child/2` (no link to the caller) and a plain
`GenServer.call/3` (no persistent link either) — no nested linked process
is ever created inside the async fun. Confirmed by reading the call
chain, not assumed from the absence of a crash in testing.

### 57. `mix illume.server` starts `Illume.Endpoint` under its own supervisor, not `Illume.Application`
**Date:** 2026-09-14 · **Status:** Done
Mirrors Decision A's pattern for `Illume.MCPServer`: `Illume.Application`'s
default children stay exactly as they were (`Task.Supervisor`,
`AgentSupervisor`, `MCPSupervisor`, `MCPServerSupervisor` — confirmed
unchanged by diff, not just by intent) so the plain CLI/escript path never
starts a PubSub or an HTTP listener it doesn't need. `mix illume.server`
(`lib/mix/tasks/illume.server.ex`) runs `app.config`, flips the endpoint's
`:server` config to `true` (merged into existing config via
`Keyword.put/3` — a naive `Application.put_env/3` would have clobbered
`secret_key_base`/`live_view`/`pubsub_server` wholesale, since `put_env`
replaces the whole value, not just one key inside it), starts the app
normally via `Application.ensure_all_started/1`, then starts
`Phoenix.PubSub` and `Illume.Endpoint` under a fresh `Supervisor` the task
owns directly.

Two real, live-caught issues along the way: (1) Phoenix defaults to
`Phoenix.Endpoint.Cowboy2Adapter` unless told otherwise, and `plug_cowboy`
was never added as a dependency (the plan chose Bandit specifically) —
the endpoint failed to start with `Plug.Cowboy is not available` on the
first real run; fixed with `config :illume, Illume.Endpoint, adapter:
Bandit.PhoenixAdapter` in `config/config.exs`. (2) `mix dialyzer` couldn't
see `Mix.Task`'s callbacks or `Mix.shell/0` for the new task module
(`Callback info about the Mix.Task behaviour is not available`) — fixed
by adding `plt_add_apps: [:mix]` to `mix.exs`'s dialyzer config.

Manually verified end to end: `mix illume.server` binds
`http://localhost:4000` via Bandit (confirmed in the log line and via
`lsof`), curling it returns `500` (expected — no router/route exists
until task 3.4), and `Illume.Application`'s own children remain
untouched.

### 58. `target_dir` for the web UI: a compile-time constant resolved from the module's own source path, not `File.cwd!()`
**Date:** 2026-09-14 · **Status:** Done
`Illume.QuestionLive`'s `@target_dir` is `Path.expand("../..", __DIR__)`,
not `File.cwd!()` — both are "hardcoded" in the sense the spec requires
(never form input, never runtime-supplied), but `File.cwd!()` bakes in
whatever directory `mix compile` happened to run from, which is fragile
if `mix illume.server` is ever invoked from elsewhere. Resolving from
`__DIR__` (this module's own file location under `lib/illume/`) is
correct regardless of invocation directory, for the same reason
`Illume.MCPServer`'s footguns (entry 49) favored being explicit over
convenient elsewhere in this phase. `handle_async/3`'s three clauses map directly to
`Illume.Agent.ask/2`'s existing contract: `{:ok, {:ok, text}}` renders the
answer, `{:ok, {:error, reason}}` renders `reason` verbatim (it is already
a formatted string — every error path in `Illume.Agent` runs through
`format_error/1` before replying, confirmed by reading `finish/2`'s call
sites directly rather than assuming), and `{:exit, _reason}` renders a
generic message — the raw exit reason is a crash term/stacktrace, not
something to show a user, and per entry 56, this path is already known
unreachable for `Illume.QA.ask/4`'s specific call shape.

### 59. Status-line telemetry handler gated on `asking?`, since `:telemetry` events aren't scoped to a request
**Date:** 2026-09-14 · **Status:** Done
`Illume.QuestionLive` attaches `:telemetry.attach_many/4` on
`[:illume, :model_call, :start]` / `[:illume, :tool_call, :start]` /
`[:illume, :loop_turn, :stop]` only on the connected mount (`connected?/1`
guards it — the static pre-connect render would otherwise attach and
immediately leak a handler with no matching `terminate/2` call), with a
handler ID scoped to `{__MODULE__, self()}` and detached in `terminate/2`.
These events are global — Illume has no per-request/session scoping for
`:telemetry`, so every open LiveView connection's handler receives every
in-flight agent's events, not just its own. `handle_info/2` only applies
an incoming event to `status_line` while `assigns.asking?` is true;
without that guard, an unrelated question (another tab, another
concurrent request) would flash a stray status update on an idle page.
Not a new gap introduced here — `Illume.Agent`'s telemetry vocabulary was
already global/unscoped — just the first place a UI reads it live enough
for that to be visibly wrong if unguarded.

### 60. `qa_client` Application-env seam added so `QuestionLive` can be tested with a mocked LLM client
**Date:** 2026-09-14 · **Status:** Done
`Illume.QuestionLive.handle_event/3` hardcodes `target_dir` and `:direct`
backend (both per spec, never test/request-configurable) but needs *some*
way for tests to inject `Illume.LLM.ClientMock` instead of the real
Anthropic client, without adding a form field or otherwise widening the
page's real input surface. Added `Application.get_env(:illume,
:qa_client)`, forwarded as `Illume.QA.ask/4`'s `opts[:client]` — same
shape as the existing `Illume.Tools.MCP.client_adapter/0` seam, not a new
pattern. `test/illume/question_live_test.exs` sets it in `setup`/`on_exit`.

Also confirmed empirically why `handle_async/3`'s `{:exit, reason}` clause
can't be reached through a mocked client at all, even a raising or
never-returning one: `Illume.Agent`/`Illume.Tools.Runner`'s whole design
isolates every model/tool failure into a formatted `{:ok, {:error,
string}}` before `Illume.QA.ask/4` ever returns (see DECISIONS.md entry
56) — a mocked crash or `{:error, :timeout}` both land in the *already*
-reachable `{:ok, {:error, reason}}` branch instead. Tested `{:exit,
reason}` directly as a plain function call on `handle_async/3` (mirroring
how `mcp_server_test.exs` unit-tests callbacks no transport can cheaply
exercise) rather than contriving an artificial crash path through
`Illume.QA.ask/4` itself just to reach it.

### 61. The web UI didn't actually work in a real browser — hardening-pass fix
**Date:** 2026-09-14 · **Status:** Done
The `/phx:review` pass on Components 1-3 found a Critical gap: every test
in this branch used `live_isolated/3`, which bypasses the browser/JS
layer entirely, so nothing ever caught that `QuestionLive`'s `render/1`
emitted a bare `<div>` with no surrounding `<html>`/`<head>`, no
`<script>` loading LiveView's client JS, and no `Plug.Static` to serve
it. A real browser could never open the LiveView websocket.

Fixed with `Illume.Layouts.root/1` (an inline `Phoenix.Component`, not a
separate `.heex` file — a single layout with no CSS/asset pipeline
didn't warrant a second file) wired via the router's `live_session
:default, root_layout: {Illume.Layouts, :root}` — the *root* layout
option, not `use Phoenix.LiveView, layout:` (that's the *inner* layout;
it doesn't wrap the page in `<html>`, so it can't carry the CSRF meta tag
or script tags). Confirmed empirically (`deps/plug/lib/plug/static.ex`
line 466-467) that `Plug.Static`'s `:from` tuple resolves through
`Application.app_dir/1`, which works for *any* loaded OTP application —
not just the host app — so `phoenix.js`/`phoenix_live_view.js` are
served straight from `{:phoenix, "priv/static"}` /
`{:phoenix_live_view, "priv/static"}` with no copy-into-`priv/static`
step, no build tooling, and no compile-time asset hook. Both files are
plain global-exposing IIFE bundles (`var Phoenix = (() => {...})()`,
`var LiveView = (() => {...})()`), not ES modules — confirmed by reading
them directly — so the root layout's inline connect script uses the
`Phoenix`/`LiveView` globals (`new LiveView.LiveSocket("/live",
Phoenix.Socket, ...)`) rather than an `import`.

Manually verified in a real Chrome tab (this is the one task in the
whole hardening plan a `mix test` run cannot verify by itself): the
console logs "mount: received diff" on load (proof the websocket joined
and the server replied), and submitting a question round-trips in place
with no page reload.

**Two hard blockers found only by doing that manual check** (both
pulled forward from Phase 2 of the hardening plan, because P1-T1's own
verification could not pass without them — the plan had filed them as
independent security tasks, not realizing they were load-bearing for the
UI to function at all):

1. `plug :protect_from_forgery` (planned as P2-T4, a router-hardening
   task) turned out to be a functional dependency, not just a security
   plug: it's the thing that actually writes the CSRF master token into
   the session on first request. Without it, nothing ever writes to the
   session, so `Plug.Session`'s cookie store never sends a `Set-Cookie`
   header, the browser has no session cookie to present on the websocket
   upgrade, `Phoenix.LiveView.Channel` sees `connect_info.session ==
   nil`, and the join fails as "stale." The client's fallback behavior
   for that failure is a full-page reload — which hits the exact same
   missing-session state again, forever. Observed directly: 1477 tight-
   loop console messages and 1000+ repeated `GET /` requests in under a
   second before this was caught and the server killed.
2. Fixing (1) immediately surfaced a second, previously-masked bug: both
   dev/test `secret_key_base` values (added when the endpoint was first
   built) were 62 bytes — 2 short of `Plug.Session`'s hardcoded 64-byte
   minimum (`Plug.Session.COOKIE.validate_secret_key_base/1`). Nothing
   had ever exercised the actual cookie-signing code path before, since
   nothing wrote to the session until (1) was fixed, so this had been
   silently wrong since Component 3 was first built. Regenerated both
   (plus both `live_view: [signing_salt: ...]` values) via `mix
   phx.gen.secret`, per the hardening plan's own P2-T2 (also pulled
   forward with this fix, since it's the same blocking bug). The
   original review had flagged the old values only as low-entropy
   dictionary phrases — a real finding, but this makes clear the actual
   severity was "the endpoint cannot complete a single request that
   touches the session," not just weak secrets.

Root-caused both via `:telemetry.attach/4` on `[:phoenix, :error_rendered]`
to read the real `reason`/`stacktrace` out of the event metadata —
`Phoenix.Endpoint.RenderErrors` re-raises the *original* exception after
logging it, but only if rendering the error page itself succeeds; this
app has no `ErrorHTML`/`ErrorView` module, so the render step's own
`ArgumentError` ("no template defined") was masking the real one at
every layer (`curl`, `Phoenix.Endpoint.call/2`, even `Mix.raise`-style
rescues). The telemetry event's `reason` field bypasses that masking
entirely.

### 62. `put_secure_browser_headers/2` doesn't set `x-frame-options` in this Phoenix version
**Date:** 2026-09-14 · **Status:** Done
The hardening plan's own test wording for the standard `:browser` pipeline
plugs (P2-T4) assumed `x-frame-options` would be one of the asserted
headers. Reading `Phoenix.Controller.put_secure_defaults/1` directly
(Phoenix 1.8.14) shows it actually sets `referrer-policy`,
`content-security-policy`, `x-content-type-options`, and
`x-permitted-cross-domain-policies` — no `x-frame-options` (superseded by
the CSP's `frame-ancestors 'self'` directive). `test/illume/endpoint_test.exs`
asserts the headers Phoenix actually sets, not the plan's original guess.

`Phoenix.ConnTest`'s `use Phoenix.ConnTest` is deprecated in this
Phoenix version in favor of `import Plug.Conn; import Phoenix.ConnTest`
— used the latter here.

### 63. Server-side `ask` guard + bounded agent concurrency
**Date:** 2026-09-14 · **Status:** Done
The review's M1 finding: `QuestionLive`'s `asking?`/length guard only
existed client-side (the `disabled` attribute on the form). A non-browser
client (or a hand-crafted websocket frame) can send a `phx-submit "ask"`
event directly, bypassing any HTML attribute entirely, and each one spawns
a real billed Anthropic call with no server-side limit. Fixed with a
server-side check in `handle_event/3` — reject (no-op, no
`Illume.QA.ask/4` call) when `asking?` is already true, the trimmed
question is empty, or it exceeds 4000 bytes (a model-context ceiling, not
a hard product requirement) — plus `max_children: 20` on
`Illume.AgentSupervisor`'s `DynamicSupervisor` spec as defense in depth,
so a bypass of the event-level guard still can't spawn unbounded
concurrent agents. Tested via `Mox.deny/3`/an `expect` call-count, not
just the rendered HTML, per the plan's own instruction — asserting only
the rendered output wouldn't distinguish "the guard ran" from "the guard
never ran but the answer happened to look the same."

### 64. Bearer-token auth on the web endpoint (review finding M2)
**Date:** 2026-09-14 · **Status:** Done
The review's M2 finding: `check_origin` (Phoenix's default CSRF-adjacent
websocket protection) only stops a browser-originated cross-site
connection — it does nothing against a non-browser local client (no
`Origin` header at all), which is the actual realistic attack path for a
single-user local dev tool: any co-resident local process could drive
unbounded billed Anthropic calls through the open port. Confirmed with
the user (bearer-token option, over documentation-only) before
implementing.

`mix illume.server` generates one random token per run
(`:crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)`),
stores it via `Application.put_env/3` (same one-shot pattern as
`mcp_server_target_dir`, entry 50), and prints it as part of the startup
URL. `QuestionLive.mount/3` checks the `token` query param against it
with `Plug.Crypto.secure_compare/2` (timing-safe, not `==`).

Two implementation details worth recording:
1. **`mount/3`'s `params` is not always a map.** `live_isolated/3` (used
   by every other test in this file) always passes the literal atom
   `:not_mounted_at_router`, never real query params — confirmed
   empirically after a `FunctionClauseError` in `Access.get/3`.
   `authorized?/1` pattern-matches `%{"token" => token}` explicitly and
   falls through to "authorized only if no token is configured" for
   anything else, so `live_isolated/3`-based tests keep working
   unmodified (no token ever gets configured in most test setups). The
   four new tests that actually exercise the token check
   (`question_live_test.exs`, "bearer-token auth (P2-T3)") route through
   `Illume.Router` for real via `Phoenix.LiveViewTest.live/2` instead —
   the only way to get a real `token` query param into `mount/3` at all.
2. **Unauthorized doesn't crash the mount or close the socket** — `mount/3`
   still returns `{:ok, socket}`, with `assign(authorized?: false)`.
   `render/1` shows a plain "Unauthorized" message instead of the form,
   and `handle_event("ask", ...)` also checks `authorized?` before doing
   anything (not just gating what's rendered — a raw socket client could
   otherwise send a `phx-submit` event directly regardless of what's on
   screen). Chose this over raising/refusing the LiveView connection
   outright: no valid `mount/3` return conveys "reject the socket," so
   the alternative would be an unhandled raise inside `mount/3` — noisy,
   inconsistent with this codebase's established "isolate every failure
   gracefully" design (entry 56), and no more secure in practice, since
   the billing-relevant path (`handle_event/3`) is independently guarded
   either way.

### 65. Type guards for malformed MCP client input (review finding L1)
**Date:** 2026-09-14 · **Status:** Done
The review's L1 finding: an external MCP client (any process able to
speak the stdio protocol to `--serve`, not necessarily one this codebase
controls) could send a non-`String.t()` `path`/`pattern` — e.g.
`%{"path" => 123}` — which would previously reach
`PathConfinement.confine/2`'s `Path.expand/2` (for `read_file`) or the
glob/grep matchers (for `search_files`/`grep_content`) unguarded,
crashing that MCP session (a self-inflicted DoS on the caller's own
tool). Extended `Illume.Tools.validate_input/3` with clauses for both,
following the exact shape the existing `git_show` revision-type guard
already established in the same function: a `when is_binary(...)` guard
on the existing valid-input clause, plus an explicit fallback clause
returning `{:error, "invalid ..."}` for anything else — not a
`try/rescue` in `handle_tool_call/3`, per this pass's own technical
decision to keep validation in the one place `Illume.Tools`' moduledoc
already designates for it. Tested at both the `Illume.Tools.dispatch/4`
level (`tools_test.exs`, mirroring `git_show`'s existing non-string
test) and through `Illume.MCPServer.handle_tool_call/3`
(`mcp_server_test.exs`, mirroring the existing path-escaping/revision-
injection tests) — the latter proves the error is a clean `{:error, _}`
result at the actual MCP response layer, not an unhandled crash.

Went one field further than the plan's own enumeration while
implementing: `grep_content`'s *optional* `path` (a subdirectory scope,
distinct from `pattern`) had the identical unguarded
`PathConfinement.confine/2` crash — `%{"pattern" => "x", "path" => nil}`
crashed exactly like the two guarded fields. Same vulnerability class the
review flagged, one extra clause to close it (guarded only when present,
since a missing `path` is a legitimate "search everything" default).

Fixing this closed off `agent_test.exs`'s "a crashing tool is recovered
as an error tool_result, not an agent crash" test's own crash trigger
(`%{"path" => nil}` on `read_file`) — it had relied on exactly the bug
this entry fixes. Repointed that test at a crash source outside the
now-guarded `input` map entirely: an invalid `target_dir` (never
model-supplied, so never in scope for `validate_input/3`), which still
reaches `Path.expand/1` unguarded and raises. Confirms the generic
crash-recovery plumbing (`Illume.Tools.Runner`) still works, independent
of which specific tool-input bugs do or don't currently exist.

### 66. Tightened `qa_test.exs`'s weak error-path assertion
**Date:** 2026-09-14 · **Status:** Done
The review's Testing Critical finding: "returns an :error result unchanged
when the model call fails" only asserted `{:error, _reason}` — it would
pass even if `Illume.QA.ask/4` returned the wrong formatted string, or
the wrong error entirely, as long as the shape was `{:error, _}`. The
mock already returned a specific, recognizable `{:error, :boom}`; only
the assertion was weak. Tightened to `{:error, ":boom"}` — `:boom` isn't
`:timeout` or `{:crashed, _}` or an exception, so `Illume.Agent`'s
`format_error/1` (private, so asserted by literal expected value rather
than calling it reflectively) falls through to its catch-all `inspect/1`
clause, pinning down which branch actually ran.

### 67. Deleted `async_spike_test.exs`
**Date:** 2026-09-14 · **Status:** Done
The review flagged two real issues with this file: it cost 6.5s of
`Process.sleep` on every default `mix test` run, and it risked a
named-process collision (`Illume.Endpoint`/`Illume.PubSub`) against
`question_live_test.exs`, since both start the same named processes
independently. Confirmed with the user (delete, over the
tag-`:slow`-and-exclude alternative) before removing it — its two
findings (a raising async fun delivers `{:exit, reason}` without
crashing the LiveView; no built-in `start_async` timeout) are already
fully captured in DECISIONS.md entries 55-56 in enough detail to
reconstruct an equivalent spike from scratch if a future
`phoenix_live_view` upgrade ever warrants re-verifying either claim, and
`question_live_test.exs`'s own "slow call" test already covers the real
`QuestionLive` module's behavior under a slow mocked call, using the
real endpoint (now that Phase 1 landed) rather than a throwaway
`SpikeLive`.

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
- ~~No MCP server mode~~ — added (`--serve`, entries 49-53). The
  whole-agent-loop-as-one-tool design (exposing `Illume.QA.ask/4` itself
  as a single MCP tool, rather than the five read-only primitives) remains
  deferred — out of scope for this pass, not an oversight.
- No multi-turn conversation support or provider abstraction — explicitly
  out of scope for both the original spec and the hardening pass, not
  oversights.
- ~~No web interface~~ — added (`mix illume.server`, entries 55-60). No
  auth, no multi-tenancy — single local user in spirit, not a deployment
  target.
- The stdio EOF restart-storm in `anubis_mcp`'s `Anubis.Server.Supervisor`
  (entry 53) is mitigated (the escript exits cleanly instead of hanging)
  but not fixed — the underlying few-millisecond restart storm still
  happens on every client disconnect. Filing this upstream is future work.
