# loopctl-runner

Dev-machine runner for the loopctl agent delivery loop. The design is
`docs/agent-delivery-loop.md`; where an issue comment and the design disagree, the design wins.

## What this repo is

- **A client, never a cluster peer.** The runner connects OUTBOUND to loopctl (build order step
  1b onward). A dev machine never joins the production BEAM cluster (design §2).
- **Topology and trigger lists live in configuration, never in source.** This repo is private
  because it encodes fleet topology and channel-token handling (design §13). Machine names, repo
  paths and allow-lists belong in `~/.config/loopctl-runner/runner.json`; only
  `config/*.example.json` is tracked. Going public later must stay "delete a config directory".
- **Enrolled machines:** minis, mac-mini, blockit. Not beelink (dedicated CI host) and not xps13.
- **Dev port 4040**, reserved for step 1b's Phoenix app (fleet registry: cron_books 4010,
  home_care_billing 4020, loopctl 4030). Step 1a has no server. Probe `127.0.0.1`, never
  `localhost`.

## Rules the code enforces, and must keep enforcing

- **Every `claude` process goes through `claude-headless.sh`.** `ANTHROPIC_API_KEY` in the
  environment silently outranks the claude.ai login (~USD 300 incident). `Config` refuses any
  other launcher, and `test/headless_launcher_canary_test.exs` fails on a direct invocation
  anywhere in `lib/`, `priv/` or `config/`.
- **A session is an OS process tree, not a BEAM process, and not just a process group.** Closing
  a Port kills nothing, and Claude Code's Bash tool detaches every command into a new session.
  End a session with `LoopctlRunner.ProcessGroup.terminate/3`, passing its `LOOP_SESSION_ID`
  marker and its launcher tree file: on macOS the marker is invisible for Apple binaries.
  `priv/bin/session-launcher.sh` does the same when the Port's pipe closes; `LoopctlRunner.Reaper`
  is the boot-time backstop.
- **A story's worktree is cut from `origin`'s base and torn down by CONTENT** (`Worktree`). A new
  branch is cut, `--no-track`, from `origin`'s copy of the base after a bounded fetch, and from the
  local base when that fetch fails or the local base holds commits `origin`'s lacks, and the
  `worktree.created` trace event names which, with git's error. A branch holding nothing
  `origin`'s base lacks is RETIRED: teardown removes its tree and deletes it, and a re-dispatch
  resets it to a fresh start inside the tree already there, keeping what the tree ignores. It
  holds nothing when its tip IS the base's commit or a local base reaches it, or when a fetch made
  for that decision shows `origin`'s base carrying its commits by history, by patch-id (`git
  cherry` for a rebase merge, the branch's cumulative patch-id for a squash, so a later edit to the
  same lines does not hide it) or by content (`git merge-tree`, for a squash whose conflicts were
  resolved). A remote-tracking ref alone never vouches: any other commit keeps the branch, and so
  does a failed fetch, named in the reason. A worktree is kept, branch and all, while a repository
  nested in it holds work `git worktree remove --force` would take: uncommitted changes, or commits
  that neither its remotes nor a submodule's recorded commit reach — for a nested worktree of the
  same repository, a HEAD no branch reaches, since its branches outlive the tree. `deps`,
  `_build`, `node_modules` and editor build dirs are not scanned. The fetch is the runner's own and
  can never prompt (`Worktree.fetch_base/2`: stdin from /dev/null, `GIT_TERMINAL_PROMPT=0`, no
  askpass, `credential.interactive=false`, ssh in BatchMode, the group killed at thirty seconds)
  and writes only origin's ref. The reaper fetches each repo's base at most once per reap, all
  repos at once, only when a removal asks origin, and removes a tree under its lock after checking
  it still reads as it did before the fetch.
- **The daemon's credential is a file readable by this user alone** (`control.token_file`,
  mode 600), sent only in the `x-loopctl-runner-token` header. Never put it in the config JSON,
  an environment variable a `claude` session inherits, or a URL.
- **The runner arms the subagent git grant for an implement session — the one run on a branch of
  its own (`own_worktree: true`) — and removes it at teardown** (`LoopctlRunner.GitGrant`).
  `block-subagent-git.sh` is a user-settings hook, and every loop session loads the operator's
  settings, so an engineer agent the session dispatches has its commit refused without it — while
  its report reads as having chosen not to commit. `LOOP_GIT_GRANT` tells the session where its
  grant is, and is unset for a session with none. Session-scoped by uuid, so an orphan authorises an
  id nothing will hold again. The argv is checked BEFORE the grant is armed, and anything that
  raises after arming disarms it. Each grant records its OWNER, the pid and start time of the BEAM
  that armed it (`LoopctlRunner.Owner`, which never raises and reads "cannot tell" as alive), and
  the sweep (`GitGrant.sweep/1`, which `Reaper.reap/4` runs first on its third argument, the
  grant directory, passed positionally and never defaulted) — which runs before every run and
  from `mix loopctl.reap`, beside live sessions — removes only a grant whose owner is no longer
  running, or whose recorded session launcher (written once the Port opens) is not. One without a
  parseable owner is left alone. A pending file (owner line only, before the launcher's is added)
  is removed on the same rule, or once it is ten minutes old. The directory is CONFIG DATA (`Config.grant_dir`, `Config.default_grant_dir/0`, the real `~/.claude`
  when absent, a refused load when there is no HOME), never a default a test can reach: the suite
  drives the production path, and an after-suite check (`test/support/grant_canary.ex`) fails the
  run on any grant or pending file in the real directory owned by the test BEAM, and on any grant
  present at the start that is gone at the end while its owner and launcher still live.
- **Every payload sent to loopctl is validated against the vendored contract**
  (`priv/runner_contract/v1.json`, copied from mkreyman/loopctl, never re-typed). When loopctl
  bumps the contract, copy the file again from loopctl MASTER, once it is merged AND deployed;
  a branch or an unmerged master is the same trap in the other direction. Do not edit it here.
  **A version that names a schema it does not define is not vendorable yet**, and the fix is
  never to write the missing definition on this side: an envelope transcribed out of loopctl's
  commit message is the re-typing this rule forbids, and the two enums then drift with nothing
  able to see it. Ask loopctl for the definition and vendor the version that carries it.
  `contract_test.exs` fails on any `x-connection` event or reply name `$defs` does not resolve.
- **A schema keyword is implemented in `Contract` before loopctl publishes it, and deployed on
  every runner before loopctl enforces it.** An unimplemented keyword FAILS validation rather
  than being skipped, so a definition carrying one would refuse every payload on this side.
  `Contract.validate_against/3` tests a keyword on an inline schema before the vendored file
  uses it; loopctl's own test fails when its enforced set exceeds its exported set.
- **A refusal naming a capability must be a real capability statement.** `kind_not_supported`
  says this runner never runs that kind. The only site that answers it is
  `Control.declared_kind/1`, for a kind outside `@kinds`; nothing else here may, and a transient
  local condition gets its own `DispatchPolicy` reason instead. What the reply costs depends
  entirely on whether the join declared kinds: for a runner that declares none, loopctl records
  it in `DispatchLedger`, keyed by kind, with no expiry and no clearing path short of revoking
  and re-enrolling — and since `implement` is the only dispatchable kind, refusing it there ends
  dispatch to that machine while it stays connected and looks healthy.
- **This runner declares its kinds on every join** (`RunnerJoin.kinds`, contract 1.6.0), from the
  one `@kinds` list in `Control` that `declared_kind/1` also reads, so the permanence above does
  not apply to it: loopctl reads a present, non-empty declaration INSTEAD of its ledger, and a
  declared kind refused anyway is suppressed for the rest of that connection and re-sent on the
  next one that declares it. Keep the two sides on one list — a declaration the check does not
  honour is a self-contradiction, and a check stricter than the declaration loses that kind's
  work. `@kinds` must never be empty (a compile-time raise refuses it): loopctl reads an empty
  array as no declaration and falls back to the ledger. Draining is how this runner stops taking
  work. Adding a kind is not enough to run it — the accept path requires a `story`, which only an
  `implement` dispatch carries, so a new kind needs its payload and its own accept path first.
- **The daemon starts only under `LOOPCTL_RUNNER_DAEMON=1`**, so `mix loopctl.run` never joins
  the pool.
- **A loop session asks for a human by running `priv/bin/loop-escalate`**, whose path the system
  prompt names — and the prompt is the ONLY path, so if that text stops reaching it a session has
  no way to ask and grinds silently to its turn limit. No hook can observe a question a headless
  session wanted to ask, so escalation must stay a command it calls; the run ends `escalated`.
- **Unattended sessions run with the same authority as a locally dispatched agent, and inherit
  the operator's user-scoped Claude setup.** `--permission-mode bypassPermissions`, no
  `--allowedTools` composed at all, and no `--setting-sources ""`. Mark, 2026-09-16: *"All agents
  must run with the yolo mode, the same as I'm running all my sessions now!"* and *"everything
  must inherit my entire user scoped claude setup."* The measurement that produced the old rule
  stands and is worth keeping: the first end-to-end run, under `--permission-mode auto`,
  committed through a bash wrapper, ran `docker exec psql` and `gh`, and read `~/.claude`. What
  changed is the conclusion. That is the BLAST RADIUS of a session on this machine, and it is the
  same radius a dispatched `elixir-engineer` has had all along — same OS user, same keys, same
  shell. Treating "nobody is watching" as if it shrank the radius confused it with DETECTION
  TIME, which is a different problem and is addressed by the wall clock, the liveness park and
  `loop-escalate`, none of them a permission flag. Committing is now the goal, not the hazard:
  automating a filed ticket end to end is what this repo is for. `auto` is still wrong and for
  its own reason — its classifier approves what it judges safe, which is neither this posture nor
  the old one. **What would overturn this:** Mark saying so, or a session acting on story text
  in a way a permission mode would actually have stopped.
- **What remains is not a permission.** `--permission-prompts none` (there is no human on the
  other end: asking cannot be ANSWERED, and without it a session blocks for ever on a dialog
  nobody sees), `--max-turns` (a budget loopctl sets per story), and the `claude-headless.sh`
  launcher with `ANTHROPIC_API_KEY` unset (a BILLING control, ~USD 300 in one night, KB
  `b38ef90e` — not part of anyone's Claude setup). The argv carries no tool list, no allow- or
  deny-list, and no settings or MCP override.
- **Deny by NAME with a reason per name; never deny a class and grant exceptions back.** That
  inverts who has to notice a mistake: a class deny takes every capability in the class —
  `Agent`, `SendMessage`, `WebFetch` and `Skill` under a fixed tool list, tidewave and playwright
  under an MCP wildcard — and each stays missing until someone asks the right question.
- **loopctl's MCP tools are not excluded, and the tempting argument against that is wrong.** A
  session holding `claim_story`/`contract_story` could move the story it was dispatched to
  implement — but the story-lifecycle protocol IS those tools, so excluding them would disable
  `loopctl-contract`, `loopctl-status`, `loopctl-mcp` and `/loopctl:implement`. A local
  `elixir-engineer` holds them today. If the custody model needs more, that is loopctl's to solve.
- **No tool is excluded, tidewave included.** A session inherits the repo's `.mcp.json` from the
  tree the runner starts it in, as an attended session in that tree does. Repos resolve tidewave
  per worktree (their `.mcp.json` launching through a per-tree port script), an attended worktree
  session carries no exclusion, and parity forbids one here (Mark, 2026-09-27: *"unattended sessions should enjoy the same permissions as
  attended sessions -- no less."*). A repo whose `.mcp.json` hardcodes the main tree's URL has that defect
  in attended worktrees too, and it is that repo's to fix. **What would overturn this:** Mark
  saying so.
- **A session inherits none of the runner's release environment** (`RELEASE_*`, the release's
  `PATH` entries): `Session.release_env/1` and `release_path/1`. Otherwise it gets the environment
  an attended session has — agent sockets and forge tokens included — less `ANTHROPIC_API_KEY`
  and the variables that redirect git (`Session.unset_names/0`). Mark, 2026-09-27: *"unattended
  sessions should enjoy the same permissions as attended sessions -- no less."*
  The runner's OWN commands — the liveness probe, its fetch, its submodule git — are the other way
  round: credentials are scrubbed by name and by shape (`ProcessGroup.run/5`,
  `ProcessGroup.scrubbed_env/0`), and a name reaches one only when its caller inherits it.
- **Nothing here is a sandbox.** `mix test` runs whatever code the session wrote, as this user,
  and there is no longer any rule stopping the session's own commands either. Isolation needs an
  OS boundary the runner does not have.
- **Parking is never "no writes under `subagents/`"** (design §8). See `LoopctlRunner.Liveness`.
- **A triage run works in a DETACHED worktree, never in the operator's live checkout.** It is the
  repo's one reused tree (`Worktree.triage_tree_path/2`, under `runs_dir/.triage-trees`, so his
  checkout gains nothing), refreshed to the commit the checkout has out by the run holding its
  `WorktreeLock`; a run that finds it held cuts a tree of its own, removed at teardown whatever it
  holds. Either is on no branch, recorded in `state.json` as `scratch` before it is cut, and
  removed by the reaper whatever it holds. Only a tree that is detached AND carries the runner's
  marker is ever reset; anything else at that path is moved aside, never removed, and the tree
  cut again, never a refusal every later run repeats. No repository-wide `git worktree prune`:
  it drops every missing worktree of the operator's, one on an unmounted volume included. A
  checkout git will not read is `checkout_unreadable`; a tree the runner could not cut is its own
  `no_verdict_written`.
- **Fail closed.** A missing or malformed config refuses every dispatch.
- **The SESSION finishes the work, as the repository's delivery mode says; the runner reports
  where it got to.** The dispatch prompt states the mode, read once the tree exists from
  `.loopctl/mode` in the commit the worktree was cut from — a new or reset tree's HEAD before any
  session runs, or for an adopted tree the merge base of its HEAD with the base, local and
  `origin`'s, a commit the tree itself holds — never from the working tree, which the session can
  write, and never from an unfetched remote ref that can differ from the tree (`Worktree.create/4`'s `cut_from`, `Worktree.commit_file/4`, `DispatchRun.prompt/4`).
  A BOM, whitespace and case are set aside; only an explicit `thread` or `pr` runs. **A repository
  with no `.loopctl/mode` is refused** (`repository has no .loopctl/mode`, reason `other`, never
  `kind_not_supported`), because `pr` means the session merges on its own and a repository that
  never opted in has not asked for that; an empty file or any other value is refused the same way
  (`DispatchPolicy.delivery_mode/1`). In a `thread` repository the session commits and pushes
  ONLY through `priv/bin/loop-push`, whose absolute path the prompt names
  (`Session.push_script/0`), and opens no pull request, merges nothing and never force-pushes —
  loopctl's merge executor merges the checkpoints the runner reports. In a `pr` repository it
  follows the operator's delivery loop, which it inherits with `SOUL.md` and the user `CLAUDE.md`
  — Mark, 2026-09-16: *"the same claude setup means the same claude setup as the local agents.
  with the same rules and workflows. the same soul.md, the same claude.md, etc"* — opening the PR
  with `gh pr create --base <the dispatch's base>` and merging only into that base. The branch and
  the worktree stay the runner's: the pr-mode prompt tells the session not to remove the worktree,
  delete the local branch or check the base out in it, and so to merge without `--delete-branch`.
  `LOOP_BRANCH` names the story's branch in the session's environment, because `loop-push` refuses
  to run without it. The contract carries the whole ladder (`claimed → worktree → implementing →
  reviewing → pr_open → ci → merged → deployed`, since 1.12.0). The RUNNER itself commits,
  pushes and merges nothing, and its teardown deletes a branch only when `origin`'s base already
  carries its content.
- **Thread mode waits on #60 and then #59.** #60 adds `priv/bin/loop-push`; #59 adds
  `LoopctlRunner.CheckpointStream`, which reports each pushed commit as the checkpoint loopctl's
  merge executor merges. Until both are in, a thread-mode run is refused before a session starts:
  `push helper missing` without the first (`DispatchPolicy.push_helper/2`), `checkpoint reporting
  not available` without the second (`DispatchPolicy.checkpoint_reporting/2`), rather than
  started on a prompt naming a command that is not there, or pushing work nothing ever merges.
- **The story-lifecycle protocol lives in the operator's skills and commands, NOT in this repo.**
  `loopctl-contract`, `loopctl-status`, `loopctl-mcp`, `loopctl-plan`, `loopctl-verify-artifacts`
  and `/loopctl:implement` already carry contract, claim, stage reporting and verification, and a
  session inheriting the setup gets all of them. Do not reimplement any of it here, and do not add
  a runner-side command for reporting stages: the session reports its own through the loopctl MCP
  tools those skills call. The runner reports only the two stages it can OBSERVE — `claimed →
  worktree` when it cuts the tree, `worktree → implementing` when the session starts — plus the
  SESSION's end as `session_ended` (`completed`, `wall_clock_exceeded`, `max_turns_exceeded` or
  `crashed`, read off the run's status by `DispatchRun.session_ended/2`), from which control
  decides the story's next stage. **Never report a delivered story `-> escalated`**: that label
  cannot leave `deployed` and says a human is needed when none is. The runner sends `-> escalated`
  only when it is the truth — the session ran `loop-escalate` (then `session_ended` follows, and
  its `completed` "changes nothing", per the contract) or no session ever started (no worktree, a
  refused prompt). `terminal_reported` in `state.json` records that the run's LAST end report
  settled, which is what a restarted daemon reads before reporting it again.
- **Tests never record environment VALUES.** The dev machines carry live credentials in the
  environment, and a failing assertion prints whatever it compared.

## How changes get made here

**The rule to DISPATCH binds the SESSION Mark is talking to, not the agent it dispatches.** If you
are that agent: do the work you were sent for and do not re-delegate it — but the rest of this
section still applies to you, and one bullet of it especially. THE BRANCH, THE COMMIT, THE PUSH,
THE PR AND THE MERGE ARE NEVER THE DISPATCHED AGENT'S; leave your changes uncommitted and
describe them, which is your correct end state (SOUL's Subordination Rule). They belong to the
session, which is what the bullet below says from the other side. This file is the one
tier a subagent is guaranteed to read, which is why the scoping is written here rather than
assumed — and why it scopes one rule rather than waving the section away.

- **Implementation is DISPATCHED, not typed by the session.** Any change to ELIXIR code — a
  feature, a fix, a refactor, and the fixes a review round asks for — goes to `elixir-engineer`.
  Mark, 2026-09-15: *"make it a standing rule that you dispatch an engineer agent on high effort
  for any implementation and fixes. I see it over and over again that sessions doing direct
  editing are doing sloppy job."*
- **Dispatch it with NO `model` override.** "High effort" is a property of the agent's own
  definition, which lives in `claude-config` and is not this repo's to re-state — pinning its
  values here would be the re-typing the contract rule forbids, drifting silently the first time
  that repo changes or a machine has not pulled. The Agent tool's `model` argument OVERRIDES that
  definition, so passing one is how a dispatch quietly buys something weaker than the rule
  promises. Name the agent; pass nothing else about how it runs.
- **What this rule does NOT route, because no agent here fits it**: the shell and unit files —
  `priv/bin/session-launcher.sh`, `priv/bin/loop-escalate`, `priv/bin/loop-verdict`,
  `rel/install.sh`, and the systemd and launchd templates. The engineer agents are Elixir and
  TypeScript; there is no shell-capable one in the roster. Those stay with the session, and the
  session says so in the PR — the same disclosure an inline fix carries. `session-launcher.sh` is
  the one to be most careful with by hand: its teardown is load-bearing and macOS and Linux
  diverge inside it.
- **The review fixers are a carve-out, not a violation.** `/code-review --fix` applies findings to
  the working tree itself, and `enhanced-review-workflow`'s FIXER commits by design. Both are
  sanctioned by the delivery loop, so using them is compliance; what is not allowed is the session
  typing the fix itself while a dispatch was available.
- **The session keeps what the Subordination Rule gives no agent**: the branch, the commit, the
  PR, the review gate, the merge, the deploy — and VERIFYING the agent's report. "All green" is a
  claim: re-run the suite, read the diff, and re-run at least one mutation proof for any
  ASSERTION THE CHANGE ADDED. A refactor that adds no assertion has nothing to falsify, and
  claiming that step anyway is the false green this bar exists to prevent.
- **Two bounds, so it is a rule and not a ritual.** Prose is not implementation — this file, a
  doc, a PR body — and is written where it is read. A change statable completely in one command
  needs no agent; one that needs a DECISION is implementation however few lines it is. And if
  dispatch genuinely fails, do it inline and say so in the PR, never calling a restriction an
  incapacity.
- **No tidewave preflight here.** The global rule says to start the dev server before dispatching
  an Elixir subagent. This repo has no `.mcp.json`, no endpoint and no `config/dev.exs` server —
  step 1a has no server at all, and port 4040 is reserved for a step-1b app that does not exist
  yet. There is nothing to preflight, and nothing degraded by its absence.

## Elixir / Phoenix guidelines

These are the stock `phx.new` rules, condensed. Each line is a hard rule.

### Elixir
- Lists have no index access (`list[i]`) — use `Enum.at/2`, pattern match, or `List`.
- No `else if` / `elsif` — use `cond` or `case` for multiple conditionals.
- Block expressions (`if`/`case`/`cond`) must have their result bound to a var; never rebind inside the block (`socket = if ... do assign(...) end`, not assigning inside).
- Use `with` for chaining `{:ok, _}` / `{:error, _}`.
- One module per file (nesting risks cyclic deps / compile errors).
- No map-access syntax on structs (`struct[:field]`) — access fields directly, or `Ecto.Changeset.get_field/2` for changesets.
- Use stdlib `Time`/`Date`/`DateTime`/`Calendar` for date/time; add no deps except `date_time_parser` for parsing.
- Never `String.to_atom/1` on user input (memory leak).
- Predicate fns end in `?`, not an `is_` prefix (reserve `is_` for guards).
- `DynamicSupervisor`/`Registry` need a `name:` in the child spec.
- `Task.async_stream/3` for concurrent enumeration with backpressure (usually `timeout: :infinity`).

### Mix
- Read `mix help <task>` before using a task.
- Debug tests with `mix test path/to_test.exs` or `mix test --failed`.
- Avoid `mix deps.clean --all` (almost never needed).

### Phoenix
- A `scope` block's alias prefixes all routes inside it — never add your own alias; watch for double prefixes.
- `Phoenix.View` is gone — don't use it.
- Never run `mix precommit` by hand — it is a pre-commit hook and runs itself on every
  commit. While working use the fast ladder: `mix format`, `mix compile
  --warnings-as-errors`, the tests for the files you touched, `mix credo --strict`,
  regenerate any checked-in generated artifact your edit invalidated, and `mix dialyzer`
  only if a spec or return shape moved. HTTP via `Req` only (not httpoison/tesla/httpc).

### Ecto
- Preload associations that templates will access.
- `import Ecto.Query` (and friends) in `seeds.exs`.
- Schema fields use `:string` even for `:text` columns.
- `validate_number/2` has no `:allow_nil` option (validations already skip nil/absent changes).
- Access changeset fields via `Ecto.Changeset.get_field/2`.
- Programmatic fields (e.g. `user_id`) are never in `cast` — set them explicitly on the struct.

### HEEx
- Templates use `~H` or `.heex` files, never `~E`.
- Forms: `Phoenix.Component.form/1` + `inputs_for/1` + `to_form/2`; never `Phoenix.HTML.form_for`/`inputs_for`. Access fields as `@form[:field]`.
- Unique DOM IDs on forms/buttons/key elements (for tests).
- App-wide imports go in `my_app_web.ex`'s `html_helpers` block.
- Literal `{`/`}` in `<pre>`/`<code>` needs `phx-no-curly-interpolation` on the parent tag.
- `class` conditionals must use list syntax and wrap inline `if` in parens:
  `class={["px-2", @flag && "py-5", if(@cond, do: "a", else: "b")]}`. Bare `{...}` without `[]` is a compile error.
- Generate template content with `<%= for item <- @col do %>`, never `<% Enum.each %>`.
- Comments are `<%!-- comment --%>`.
- Interpolation: use `{...}` in attrs and in tag bodies; use `<%= ... %>` ONLY for block constructs (if/cond/case/for) inside tag bodies. Never `<%= %>` inside an attribute.

### LiveView
- No `live_redirect`/`live_patch` — use `<.link navigate=/patch=>` and `push_navigate`/`push_patch`.
- Avoid LiveComponents unless strongly justified.
- Name LiveViews `AppWeb.FooLive`; the `:browser` scope is already aliased (`live "/foo", FooLive`).
- A `phx-hook` that manages its own DOM also needs `phx-update="ignore"`.
- No inline `<script>` in HEEx — put JS in `assets/js` and wire it through `app.js`.

#### Streams
- Use streams for collections (avoids memory ballooning). Parent needs a DOM `id` + `phx-update="stream"`; each child uses the stream-provided id as its DOM id:
  ```
  <div id="messages" phx-update="stream">
    <div :for={{id, msg} <- @streams.messages} id={id}>{msg.text}</div>
  </div>
  ```
- Streams aren't enumerable — to filter/refresh, refetch and re-stream with `reset: true`.
- No built-in count or empty-state: track count in a separate assign; empty state via `<div class="hidden only:block">…</div>` (only works when it's the sole sibling of the for-comprehension).
- Never `phx-update="append"`/`"prepend"`.

#### LiveView tests
- `Phoenix.LiveViewTest` + `LazyHTML`; forms via `render_submit/2` / `render_change/2`.
- Assert on elements and IDs (`has_element?/2`, `element/2`), never raw HTML; test outcomes, not implementation.
- Debug by scoping output with `LazyHTML.from_fragment` + `LazyHTML.filter`.

#### Forms
- From params: `to_form(params)` (string keys), or `to_form(params, as: :user)` to nest.
- From changeset: `changeset |> to_form()` — `:as` is auto-computed; submit yields `%{"user" => params}`.
- Always drive the UI from a `to_form/2` assign: `<.form for={@form} id="x-form">` + `<.input field={@form[:field]}>`. FORBIDDEN: passing a changeset to `<.form>`, or `<.form let={f}>`.

### Phoenix v1.8
- LiveView templates begin with `<Layouts.app flash={@flash} ...>` (wraps all content); `Layouts` is already aliased.
- `current_scope` errors → move routes to the proper `live_session` and pass `current_scope` to `<Layouts.app>`.
- `<.flash_group>` only inside `layouts.ex`.
- Icons via `<.icon name="hero-x-mark" class="w-5 h-5"/>`, never `Heroicons`.
- Use the imported `<.input>` for inputs; overriding its `class` drops ALL default classes (style fully).

### CSS / JS
- Tailwind v4: no `tailwind.config.js`. Keep app.css's `@import "tailwindcss" source(none);` + `@source` lines.
- No `@apply`; hand-write Tailwind components (no daisyUI) for a unique look.
- Only `app.js` / `app.css` bundles ship — import vendor deps there; no external `src`/`href`, no inline `<script>`.
- UI/UX: world-class, usable, modern — subtle micro-interactions, clean typography/spacing/balance, delightful hover/loading/transition details.

### Authentication (`phx.gen.auth`)
- Handle auth at the router level with proper redirects.
- It creates two live_sessions: `:current_user` (works with or without auth) and `:require_authenticated_user` (auth required). Both assign `@current_scope` — NOT `@current_user`.
- Access the user via `current_scope.user`; never use `@current_user` in templates/LiveViews.
- Always state which scope / live_session / pipeline a route goes in, AND WHY.
- Auth-required routes → the existing `:require_authenticated_user` block. Optional-auth routes → the existing `:current_user` block.
- Never duplicate a `live_session` name — all routes for a name live in one block.
