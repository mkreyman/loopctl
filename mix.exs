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
      escript: escript(),
      releases: releases(),
      listeners: [Phoenix.CodeReloader],
      # `mix hex.audit` (hex.pm's official EEF advisory feed) is the dependency
      # security gate, in `precommit` and the Security CI job. It caught the
      # 2026-07 postgrex/decimal/cowlib advisories that the previously-wired
      # mix_audit (curated GHSA mirror) missed and that its runtime clone could
      # fail-open on. Advisories with NO reachable fix are acknowledged here;
      # hex.audit warns when an entry stops matching, so stale ones surface.
      hex: [
        ignore_advisories: [
          # cowlib 2.18.0 — no patched release exists (2.18.0 is the latest
          # cowlib), so there is nothing to bump to. cowlib is compiled into the
          # release as an optional transitive of phoenix / websock_adapter /
          # open_api_spex / telemetry_metrics_prometheus, but the ONLY component
          # that starts a Cowboy listener is the TelemetryMetricsPrometheus
          # reporter on the internal :9568 metrics port (prod-only, Fly private
          # 6PN). The public API serves on Bandit, never cowboy. That metrics
          # endpoint sets no cookies and reflects no untrusted structured
          # headers, so neither vector is reachable. Recheck when cowlib > 2.18.0.
          # CVE-2026-43966 (GHSA-w4f7-4cxr-rv3c, MEDIUM): HTTP response splitting.
          "CVE-2026-43966",
          # CVE-2026-43969 (GHSA-g2wm-735q-3f56, LOW): cookie header injection.
          "CVE-2026-43969"
        ]
      ],
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit, :ecto, :ecto_sql],
        plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
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
      preferred_envs: [precommit: :test, "test.e2e": :test]
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
      {:phoenix_live_view, "~> 1.0"},
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
      {:lazy_html, ">= 0.1.0", only: :test},

      # Code quality
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false},

      # Dev tooling — runtime introspection MCP (dev-only; mounts /tidewave/mcp)
      {:tidewave, "~> 0.6", only: :dev}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.create", "ecto.migrate"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      # Run ONLY the cross-context journey tests (test/e2e/*, tagged :e2e). `--only`
      # overrides the default :e2e exclude in test_helper.exs.
      "test.e2e": ["ecto.create --quiet", "ecto.migrate --quiet", "test --only e2e"],
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
        "dialyzer",
        "test"
      ]
    ]
  end
end
