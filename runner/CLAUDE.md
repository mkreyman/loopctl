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
- **The daemon's credential is a file readable by this user alone** (`control.token_file`,
  mode 600), sent only in the `x-loopctl-runner-token` header. Never put it in the config JSON,
  an environment variable a `claude` session inherits, or a URL.
- **Every payload sent to loopctl is validated against the vendored contract**
  (`priv/runner_contract/v1.json`, copied from mkreyman/loopctl, never re-typed). When loopctl
  bumps the contract, copy the file again from loopctl MASTER, once it is merged AND deployed;
  a branch or an unmerged master is the same trap in the other direction. Do not edit it here.
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
- **A loop session asks for a human by running `priv/bin/loop-escalate`**, the one command the
  runner always pre-allows. No hook can observe a question a headless session wanted to ask, so
  escalation must stay a command it calls; the run ends `escalated`.
- **Unattended sessions can only run pre-allowed tools.** `--permission-mode dontAsk` runs only
  what an `--allowedTools` rule names, under `--setting-sources ""` so no operator or repository
  settings add rules, hooks or plugins; the file tools are scoped to the worktree; a story's
  `allowed_tools` must each appear in the runner config's `allowed_tools`. Never `auto`: its
  classifier approves what it judges safe, and the first end-to-end run committed, ran docker
  and gh, and read `~/.claude` under it.
- **A session inherits none of the runner's release environment** (`RELEASE_*`, the release's
  `PATH` entries): `Session.release_env/1` and `release_path/1`.
- **The Bash allow-list is not a sandbox.** `mix test` runs whatever code the session wrote, as
  this user. The allow-list stops the session's own commands; isolation beyond that needs an OS
  boundary the runner does not have yet.
- **Parking is never "no writes under `subagents/`"** (design §8). See `LoopctlRunner.Liveness`.
- **Fail closed.** A missing or malformed config refuses every dispatch.
- **The runner commits, pushes and merges nothing** in step 1. Teardown keeps a branch that has
  commits of its own rather than deleting work.
- **Tests never record environment VALUES.** The dev machines carry live credentials in the
  environment, and a failing assertion prints whatever it compared.

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
