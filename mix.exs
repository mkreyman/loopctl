defmodule Loopctl.MixProject do
  use Mix.Project

  def project do
    [
      app: :loopctl,
      version: "1.0.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      usage_rules: usage_rules(),
      escript: escript(),
      releases: releases(),
      listeners: [Phoenix.CodeReloader],
      # `mix hex.audit` (hex.pm's official EEF advisory feed) is the dependency
      # security gate, in `precommit` and the Security CI job. It caught the
      # 2026-07 postgrex/decimal/cowlib advisories that the previously-wired
      # mix_audit (curated GHSA mirror) missed and that its runtime clone could
      # fail-open on. Acknowledged here: advisories with no published fix, and
      # ones whose fix is DECLINED for a stated reason, each with its recheck
      # condition inline. hex.audit only WARNS when an entry stops matching, so a
      # stale entry does not fail CI; the mint pin in deps/0 is what keeps the
      # declined fix from arriving silently.
      hex: [
        ignore_advisories: [
          # cowlib 2.20.0 — no patched release exists for either advisory below:
          # each is introduced at an old version with no `fixed` event, and as of
          # 2026-09-28 2.20.0 (which fixed CVE-2026-43971) is the newest cowlib on hex.
          # cowlib is compiled in as a hard transitive of telemetry_metrics_prometheus
          # (via plug_cowboy and cowboy), but the ONLY Cowboy listener is that
          # reporter on the internal :9568 metrics port (prod-only, Fly private 6PN);
          # the public API serves on Bandit (config/config.exs, Bandit.PhoenixAdapter).
          # Recheck when cowlib > 2.20.0.
          # CVE-2026-43966 (GHSA-w4f7-4cxr-rv3c, MEDIUM): HTTP response splitting in
          # cow_http_struct_hd:escape_string/2. The metrics endpoint emits no
          # structured headers built from untrusted input.
          "CVE-2026-43966",
          # CVE-2026-43969 (GHSA-g2wm-735q-3f56, LOW): Cookie REQUEST header injection
          # in cow_cookie:cookie/1, the client-side encoder. Nothing in the release
          # calls it: there is no cowlib-based HTTP client (no gun).
          "CVE-2026-43969",
          # mint 1.10.1 — the fix, 1.11.0, is DECLINED and pinned out in deps/0.
          # 1.11.0 stopped closing a connection on a receive timeout, and Finch 0.23.0
          # (the newest as of 2026-09-28) returns that connection to its pool, so the
          # next request on it crashes with a CaseClauseError on the late response
          # (test/loopctl/net/finch_timeout_reuse_test.exs pins it). That would turn
          # every outbound timeout into a crash. Recheck when a Finch release closes a
          # connection on a receive timeout: that test then passes on mint >= 1.11.0.
          # CVE-2026-91043 (HIGH): HTTP/2 HPACK cookie fields bypass
          # max_header_list_size. HTTP/2 only; Req's Finch pools fall back to
          # `protocols: [:http1]` and no Req call opts into :http2
          # (test/loopctl/net/no_outbound_http2_test.exs fails if one does).
          "CVE-2026-91043",
          # CVE-2026-92103 (MEDIUM): HTTP/2 oversized frames buffered before
          # max_frame_size is enforced. HTTP/2 only, as above.
          "CVE-2026-92103",
          # CVE-2026-94194 (MEDIUM): HTTP/1 chunked framing when chunked is not the
          # final coding, enabling response smuggling THROUGH AN INTERMEDIARY. That is
          # REACHABLE in principle: a tenant's webhook URL may sit behind a CDN or a
          # relay that other tenants' URLs share (one Finch pool per host). The
          # impact is bounded to the delivery log: a webhook response is recorded
          # (status and body, `Loopctl.Webhooks.ReqDelivery`) and never acted on, so a
          # smuggled response can at worst put one tenant's relay response in
          # another's delivery record. Accepted against the crash above.
          "CVE-2026-94194"
        ]
      ],
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit, :ecto, :ecto_sql],
        plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
        # Unset locally, so the core PLT stays in MIX_HOME and is shared across worktrees.
        # CI sets it to priv/plts: on the self-hosted runner MIX_HOME is shared by every
        # slot while OTP is installed per slot under _work/_temp, so a core PLT built by
        # one slot names beam files another slot cannot see ("File not found:
        # slot-N/.../erl_bif_types.beam").
        plt_core_path: System.get_env("DIALYZER_PLT_CORE_PATH"),
        ignore_warnings: "priv/plts/dialyzer_ignore.exs"
      ]
    ]
  end

  def application do
    [
      mod: {Loopctl.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [
        precommit: :test,
        "test.e2e": :test,
        # The snapshot is asserted byte-for-byte by an ExUnit test, which runs in :test.
        # Generating it in another env would render a route table from a different
        # compile_env and put the file permanently at odds with its own guard.
        "loopctl.routes_snapshot": :test
      ]
    ]
  end

  defp escript do
    [
      main_module: Loopctl.CLI.Main,
      name: :loopctl
    ]
  end

  defp releases do
    [
      loopctl: [
        include_executables_for: [:unix],
        strip_beams: [keep: ["Docs"]],
        applications: [runtime_tools: :permanent],
        overlays: "rel/overlays"
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Phoenix
      {:phoenix, "~> 1.8.4"},
      {:phoenix_ecto, "~> 4.5"},
      {:phoenix_html, "~> 4.2"},
      {:phoenix_live_view, "~> 1.1.0"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      # decimal 3.x fixes CVE-2026-32686 (unbounded-exponent DoS). ecto already
      # allows ~> 3.0; the override lifts open_api_spex's stale optional cap
      # (~> 1.0 or ~> 2.0), which has no 3.0 support yet. open_api_spex only uses
      # Decimal for JSON-schema number casting, a 3.x-compatible surface.
      {:decimal, "~> 3.1", override: true},
      {:esbuild, "~> 0.8", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.2", runtime: Mix.env() == :dev},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      # US-27.15: Prometheus reporter on an INTERNAL port (9568) scraped by Fly's
      # managed Prometheus over the private 6PN network. Bundles a standalone
      # Plug.Cowboy server so the /metrics endpoint is isolated from the public
      # 8080 http_service. Started only when :metrics_reporter_enabled (prod), not test.
      {:telemetry_metrics_prometheus, "~> 1.1"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},

      # HTTP client
      {:req, "~> 0.5"},
      # Pinned below 1.11.0: see the mint entry in hex ignore_advisories above.
      {:mint, ">= 1.10.1 and < 1.11.0"},

      # Background jobs
      {:oban, "~> 2.19"},

      # Encryption at rest (webhook signing secrets, API key idempotency cache)
      {:cloak, "~> 1.1"},
      {:cloak_ecto, "~> 1.3"},

      # OpenAPI spec and Swagger UI
      {:open_api_spex, "~> 3.21"},

      # Structured JSON logging
      {:logger_json, "~> 7.0"},

      # Rate limiting
      {:hammer, "~> 6.2"},

      # Remote IP resolution behind reverse proxy
      {:remote_ip, "~> 1.2"},

      # Vector similarity search (pgvector)
      {:pgvector, "~> 0.3"},

      # WebAuthn / FIDO2 attestation verification (US-26.0.1)
      {:wax_, "~> 0.6"},

      # Markdown rendering for wiki articles (US-26.0.3). MDEx (comrak) OMITS
      # raw/dangerous HTML from untrusted bodies by default (render: [unsafe: true]
      # is not set), so article bodies render XSS-safe on the public /wiki route
      # without a separate sanitizer library; MDEx's built-in ammonia sanitize
      # option is layered on top as defense-in-depth (sec-2).
      {:mdex, "~> 0.13"},

      # YAML frontmatter parsing for OKF (Open Knowledge Format) interchange (#110)
      {:yaml_elixir, "~> 2.11"},

      # Testing
      {:mox, "~> 1.2", only: :test},
      # 0.1.13 and later: EEF-CVE-2026-92106 (mutation XSS through unescaped SVG/MathML text).
      {:lazy_html, ">= 0.1.13", only: :test},

      # Code quality
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false},

      # Dev tooling — runtime introspection MCP (dev-only; mounts /tidewave/mcp)
      {:tidewave, "~> 0.6", only: :dev},

      # Keeps the managed block in AGENTS.md in sync with the usage-rules our
      # dependencies actually ship. That block was written once by phx.new and
      # then froze. Dev-only — never ships.
      {:usage_rules, "~> 1.1", only: :dev, runtime: false}
    ]
  end

  # Which dependency usage-rules get synced into AGENTS.md, and how.
  #
  # INLINE rather than `link:` on purpose. Claude Code hardcodes AGENTS.md
  # discovery, so this content is already loaded into every session and every
  # subagent — linking would save context but only by making the rules
  # conditional on an agent choosing to go read them. These are the "what the
  # model gets wrong" rules; they are the last thing to make optional.
  #
  # NOTE: `mix usage_rules.sync` owns everything between the
  # usage-rules-start/end markers and rewrites that region wholesale. Never put
  # hand-written content inside it — in cron_books a hand-written migration-safety
  # section had been placed there and the first sync silently deleted it.
  #
  # This is an EXPLICIT package list, not `:all`, and the CI drift gate (#556) can only
  # ever be as wide as it is: adding a dependency that ships usage-rules (igniter and
  # mdex both do) changes nothing here and the gate stays green. Widen this list to widen
  # the gate.
  defp usage_rules do
    [
      file: "AGENTS.md",
      usage_rules: [:usage_rules, :phoenix]
    ]
  end

  @doc false
  # The `test` aliases' migrate step. `Ecto.Migrator` `Code.compile_file`s every pending
  # migration into the VM it runs in, and the migration tests that later
  # `Code.require_file` the same files redefine those modules: "redefining module" fails
  # `--warnings-as-errors` after a green suite, on any fresh test database. So a pending
  # migration is run in a VM of its own. Which are pending is read from file names, which
  # compiles nothing, and on an already-migrated database no second VM starts. The child is
  # this install's own `elixir` and `mix`, with this install's ERTS first on its PATH, so it
  # runs the toolchain the parent runs even where a shell would not find one.
  # Bound to `Loopctl.TestAliasMigrateTest`.
  def migrate_out_of_vm(_args) do
    Mix.Task.run("app.config")

    if Enum.any?(Application.get_env(:loopctl, :ecto_repos, []), &pending_migrations?/1) do
      elixir_bin = :elixir |> :code.lib_dir() |> Path.join("../../bin") |> Path.expand()

      {_, status} =
        System.cmd(
          Path.join(elixir_bin, "elixir"),
          [Path.join(elixir_bin, "mix"), "ecto.migrate", "--quiet"],
          env: [
            {"MIX_ENV", to_string(Mix.env())},
            # The elixir script execs `erl` by PATH, so this ERTS goes first on it.
            {"PATH",
             Enum.join(
               [Path.join(:code.root_dir(), "bin"), elixir_bin, System.get_env("PATH", "")],
               ":"
             )}
          ],
          into: IO.stream(),
          stderr_to_stdout: true
        )

      if status != 0, do: Mix.raise("ecto.migrate in its own VM exited with status #{status}")
    end
  end

  defp pending_migrations?(repo) do
    {:ok, pending?, _} =
      Ecto.Migrator.with_repo(repo, fn repo ->
        Enum.any?(Ecto.Migrator.migrations(repo), &match?({:down, _, _}, &1))
      end)

    pending?
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.create", "ecto.migrate"],
      # Pending migrations run in a VM of their own: see migrate_out_of_vm/1.
      test: ["ecto.create --quiet", &__MODULE__.migrate_out_of_vm/1, "test"],
      # Run ONLY the cross-context journey tests (test/e2e/*, tagged :e2e). `--only`
      # overrides the default :e2e exclude in test_helper.exs.
      "test.e2e": ["ecto.create --quiet", &__MODULE__.migrate_out_of_vm/1, "test --only e2e"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.deploy": ["tailwind loopctl --minify", "esbuild loopctl --minify", "phx.digest"],
      precommit: [
        # hex.audit MUST run BEFORE `compile`: `compile` purges the archive code
        # path, after which a chained `hex.audit` (a Hex archive task) fails with
        # "task could not be found" — which silently broke every local `mix precommit`
        # (CI was unaffected: it runs `mix hex.audit` as its own step). Running it
        # first also fails fast on a retired/advised dependency.
        "hex.audit",
        "compile --warnings-as-errors",
        "deps.unlock --check-unused",
        "format --check-formatted",
        "credo --strict",
        "loopctl.check_skill_citations",
        "loopctl.check_env_docs",
        # NB (#556): the AGENTS.md usage-rules drift check is deliberately NOT here. This
        # alias runs under `preferred_envs: [precommit: :test]` and `usage_rules` is
        # `only: :dev`, so `mix usage_rules.sync --check` would fail with "task could not
        # be found" — the same breakage the hex.audit note above records. It runs in the
        # CI Retrieval Eval job instead — the only job that sets MIX_ENV=dev, and so the
        # only one where the task exists.
        "dialyzer",
        # `--warnings-as-errors` here as well as in CI, and the local copy is the one that
        # matters: it covers warnings from LOADING the test suite, and the one it exists
        # for is "redefining module X (current version defined in memory)" — two test files
        # with one module name, which the parallel compiler resolves EITHER as a hard
        # CompileError OR as that warning plus a green suite that ran only one of the two
        # files' tests. #824 shipped the second kind to master. Catching it at the commit
        # hook means it never reaches CI. Measured zero load-time warnings when this was
        # added. Bound to `Loopctl.CiWarningsAsErrorsTest`.
        "test --warnings-as-errors"
      ]
    ]
  end
end
