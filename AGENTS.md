This is a web application written using the Phoenix web framework.

## Project guidelines

- Use `mix precommit` alias when you are done with all changes and fix any pending issues
- Use the already included and available `:req` (`Req`) library for HTTP requests, **avoid** `:httpoison`, `:tesla`, and `:httpc`. Req is included by default and is the preferred HTTP client for Phoenix apps

### `retrieve_*` (Context Retriever) vs `knowledge_*` (Wiki, incl. hybrid retrieval) vs `memory_*` (Memory)

loopctl has THREE agent information surfaces — pick by WHAT THE DATA IS (full
references: `docs/context-retriever.md`, `docs/agent-memory.md`,
`docs/knowledge-hybrid-retrieval.md`):

- **`retrieve_*` — Context Retriever** (Epic 30; `Loopctl.ContextRetriever`, table
  `entity_definitions`): GOVERNED, structured access to loopctl's own live ROWS
  (`projects`/`stories`/`epics`). An admin declares a tenant-scoped **entity**
  (typed, server-allowlisted fields) over `/api/v1/entities`; per-entity
  `cr_filter_*`/`cr_search_*` tools are generated dynamically and appended to
  ListTools from `GET /api/v1/retrieve/tools`; a `cr_*` call dispatches to
  `POST /api/v1/retrieve/:entity`. Parameterized (never model SQL), dual
  tenant-scoped, allowlist-shaped, audited (fail-closed), rate-limited. Use to
  query live operational state by a structured filter or full-text search.
- **`memory_*` — Agent Memory** (Epic 28 / #411; `Loopctl.Memory`; tables
  `memories`/`session_memories`): PRIVATE to your `(tenant, subject_id)` scope.
  Use for facts, preferences, and observations THIS agent learned about ITS
  task/user and needs to recall later. `long_term` = vector-embedded +
  semantically recalled; `session` = chronological + TTL-pruned. An optional
  `project_id` PARTITIONS a memory (global vs project); it is NOT the isolation
  boundary (`(tenant, subject_id)` is) — resolve a repo to its `project_id` with
  `resolve_project`. Tools: `memory_remember`, `memory_recall`, `memory_list`,
  `memory_forget`, `memory_promote` (compile a finished session's short-term turns
  into long-term memory), `memory_graduate` (graduate a proven-valuable long-term
  memory INTO a shared `knowledge_*` article — the bridge between the private and
  shared surfaces; `re_scope: "global"` promotes a project memory tenant-wide), and
  `recall_context` (ONE round-trip returning the merged, re-ranked `global ∪
  active-project` union of memory AND knowledge — prefer it over separate
  `memory_recall` + `knowledge_search` calls).
- **`knowledge_*` — Knowledge Wiki**: SHARED, curated tenant DOCUMENTS, deduped and
  linked. Use when the insight is worth ANOTHER agent reading.
  - **`knowledge_hybrid_search`** (Epic 31): resolves a query to a governed
    **curated** answer (ONLY when its absolute confidence clears a scale-matched
    threshold + margin over retrieval, and it is authoritative — not
    superseded/conflicted) else falls back to semantic/keyword **retrieval** — one
    shape carrying `meta.provenance` (`curated`/`retrieved`); never branch on
    which subsystem answered, branch on `meta.provenance`.
  - **`knowledge_progressive_index`/`knowledge_progressive_drill`** (Epic 31): a
    cheap, top-K-capped, curated-preferred topic browse (compact stubs, then a
    full-body drill) — NOT a substitute for `hybrid_search`'s semantic/governed
    resolution (a fuzzy topic can miss a lexically-dissimilar curated article).

Rule of thumb: *live structured business row?* → `retrieve_*`; *worth another
agent reading?* → `knowledge_create`; *a fact only I need to recall about my own
work?* → `memory_remember`; *might have a governed answer, need to know if it's
authoritative or "best guess"?* → `knowledge_hybrid_search`. Scope is key-derived
— you never pass `tenant_id`/`subject_id`. Do NOT conflate `Loopctl.Memory`
(Epic 28) with the article-level agent-memory *metadata*
(`memory_type`/`visibility`) on the Knowledge `articles` table (#163) —
different subsystems.

### Phoenix v1.8 guidelines

- **Always** begin your LiveView templates with `<Layouts.app flash={@flash} ...>` which wraps all inner content
- The `MyAppWeb.Layouts` module is aliased in the `my_app_web.ex` file, so you can use it without needing to alias it again
- Anytime you run into errors with no `current_scope` assign:
  - You failed to follow the Authenticated Routes guidelines, or you failed to pass `current_scope` to `<Layouts.app>`
  - **Always** fix the `current_scope` error by moving your routes to the proper `live_session` and ensure you pass `current_scope` as needed
- Phoenix v1.8 moved the `<.flash_group>` component to the `Layouts` module. You are **forbidden** from calling `<.flash_group>` outside of the `layouts.ex` module
- Out of the box, `core_components.ex` imports an `<.icon name="hero-x-mark" class="w-5 h-5"/>` component for hero icons. **Always** use the `<.icon>` component for icons, **never** use `Heroicons` modules or similar
- **Always** use the imported `<.input>` component for form inputs from `core_components.ex` when available. `<.input>` is imported and using it will save steps and prevent errors
- If you override the default input classes (`<.input class="myclass px-2 py-1 rounded-lg">)`) class with your own values, no default classes are inherited, so your
custom classes must fully style the input


<!-- usage-rules-start -->

<!-- phoenix:elixir-start -->
## Elixir guidelines

- Elixir lists **do not support index based access via the access syntax**

  **Never do this (invalid)**:

      i = 0
      mylist = ["blue", "green"]
      mylist[i]

  Instead, **always** use `Enum.at`, pattern matching, or `List` for index based list access, ie:

      i = 0
      mylist = ["blue", "green"]
      Enum.at(mylist, i)

- Elixir variables are immutable, but can be rebound, so for block expressions like `if`, `case`, `cond`, etc
  you *must* bind the result of the expression to a variable if you want to use it and you CANNOT rebind the result inside the expression, ie:

      # INVALID: we are rebinding inside the `if` and the result never gets assigned
      if connected?(socket) do
        socket = assign(socket, :val, val)
      end

      # VALID: we rebind the result of the `if` to a new variable
      socket =
        if connected?(socket) do
          assign(socket, :val, val)
        end

- **Never** nest multiple modules in the same file as it can cause cyclic dependencies and compilation errors
- **Never** use map access syntax (`changeset[:field]`) on structs as they do not implement the Access behaviour by default. For regular structs, you **must** access the fields directly, such as `my_struct.field` or use higher level APIs that are available on the struct if they exist, `Ecto.Changeset.get_field/2` for changesets
- Elixir's standard library has everything necessary for date and time manipulation. Familiarize yourself with the common `Time`, `Date`, `DateTime`, and `Calendar` interfaces by accessing their documentation as necessary. **Never** install additional dependencies unless asked or for date/time parsing (which you can use the `date_time_parser` package)
- Don't use `String.to_atom/1` on user input (memory leak risk)
- Predicate function names should not start with `is_` and should end in a question mark. Names like `is_thing` should be reserved for guards
- Elixir's builtin OTP primitives like `DynamicSupervisor` and `Registry`, require names in the child spec, such as `{DynamicSupervisor, name: MyApp.MyDynamicSup}`, then you can use `DynamicSupervisor.start_child(MyApp.MyDynamicSup, child_spec)`
- Use `Task.async_stream(collection, callback, options)` for concurrent enumeration with back-pressure. The majority of times you will want to pass `timeout: :infinity` as option

## Mix guidelines

- Read the docs and options before using tasks (by using `mix help task_name`)
- To debug test failures, run tests in a specific file with `mix test test/my_test.exs` or run all previously failed tests with `mix test --failed`
- `mix deps.clean --all` is **almost never needed**. **Avoid** using it unless you have good reason

## Test guidelines

- **Always use `start_supervised!/1`** to start processes in tests as it guarantees cleanup between tests
- **Avoid** `Process.sleep/1` and `Process.alive?/1` in tests
  - Instead of sleeping to wait for a process to finish, **always** use `Process.monitor/1` and assert on the DOWN message:

      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

   - Instead of sleeping to synchronize before the next call, **always** use `_ = :sys.get_state/1` to ensure the process has handled prior messages
<!-- phoenix:elixir-end -->

<!-- phoenix:phoenix-start -->
## Phoenix guidelines

- Remember Phoenix router `scope` blocks include an optional alias which is prefixed for all routes within the scope. **Always** be mindful of this when creating routes within a scope to avoid duplicate module prefixes.

- You **never** need to create your own `alias` for route definitions! The `scope` provides the alias, ie:

      scope "/admin", AppWeb.Admin do
        pipe_through :browser

        live "/users", UserLive, :index
      end

  the UserLive route would point to the `AppWeb.Admin.UserLive` module

- `Phoenix.View` no longer is needed or included with Phoenix, don't use it
<!-- phoenix:phoenix-end -->

<!-- phoenix:ecto-start -->
## Ecto Guidelines

- **Always** preload Ecto associations in queries when they'll be accessed in templates, ie a message that needs to reference the `message.user.email`
- Remember `import Ecto.Query` and other supporting modules when you write `seeds.exs`
- `Ecto.Schema` fields always use the `:string` type, even for `:text`, columns, ie: `field :name, :string`
- `Ecto.Changeset.validate_number/2` **DOES NOT SUPPORT the `:allow_nil` option**. By default, Ecto validations only run if a change for the given field exists and the change value is not nil, so such as option is never needed
- You **must** use `Ecto.Changeset.get_field(changeset, :field)` to access changeset fields
- Fields which are set programmatically, such as `user_id`, must not be listed in `cast` calls or similar for security purposes. Instead they must be explicitly set when creating the struct
- **Always** invoke `mix ecto.gen.migration migration_name_using_underscores` when generating migration files, so the correct timestamp and conventions are applied
<!-- phoenix:ecto-end -->

<!-- usage-rules-end -->