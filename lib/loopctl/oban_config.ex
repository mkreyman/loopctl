defmodule Loopctl.ObanConfig do
  @moduledoc """
  Env-driven Oban queue widths (US-32.2).

  Queue concurrency is retuned during an incident via `OBAN_QUEUE_<NAME>` env vars
  (e.g. `fly secrets set OBAN_QUEUE_DEFAULT=20` + restart) WITHOUT a code change or
  deploy — the substrate for Epic 4 per-tenant fairness (#351). Scope is queue WIDTHS
  ONLY; plugins/cron stay compile-time in `config/config.exs`.

  `config/runtime.exs` sets `config :loopctl, Oban, queues: Loopctl.ObanConfig.queues()`
  at the top level (outside any prod-only guard) so every queue is re-listed from
  env-or-default in every environment. Elixir `Config` DEEP-MERGES (rather than
  replaces) the `queues:` value, so a queue key present in config.exs but omitted here
  would actually be PRESERVED, not dropped — `queues/0` still always returns the full
  keyword list, one entry per default queue, so every queue stays env-tunable rather
  than silently falling back to its compile-time (non-tunable) width.
  """

  # Default widths are a literal, hand-maintained mirror of config/config.exs's
  # compile-time `config :loopctl, Oban, queues: [...]` (AC-32.2.3). Sum = 38
  # (10+5+2+3+2+5+5+3+3). Keep the two lists in sync when adding/removing/resizing
  # a queue (`TC-32.2.1` in oban_config_test.exs asserts they match).
  #
  # MUST NOT be `Application.compile_env(:loopctl, Oban)[:queues]`. That recorded a
  # compile-time consistency dependency on the WHOLE `[:loopctl, Oban]` app-env key,
  # and `config/runtime.exs` reassigns that exact key to `Loopctl.ObanConfig.queues()`
  # (deep-merged). At release boot, `Config.Provider.validate_compile_env/1` (on by
  # default; not disabled in `mix.exs` `releases/0`) compares the compile-time and
  # runtime values for every recorded key and ABORTS the node when they differ —
  # i.e. the instant an operator sets ANY `OBAN_QUEUE_*` env var (exactly the lever
  # this module exists to provide), the release refuses to boot. Reading a
  # runtime-overridden key at compile time defeats the entire feature; hardcoding
  # (or reading via `Application.get_env/2` at call time) avoids recording that
  # dependency in the first place.
  @default_queues [
    default: 10,
    webhooks: 5,
    cleanup: 2,
    analytics: 3,
    maintenance: 2,
    embeddings: 5,
    knowledge: 5,
    memory: 3,
    audit: 3
  ]

  @doc """
  Resolves the full Oban `queues` keyword list from `OBAN_QUEUE_<NAME>` env vars,
  falling back to the compile-time default for any queue whose env var is unset.
  """
  @spec queues() :: keyword(pos_integer())
  def queues do
    Enum.map(@default_queues, fn {queue, default} ->
      env_var = "OBAN_QUEUE_" <> String.upcase(Atom.to_string(queue))
      {queue, queue_size(System.get_env(env_var), default)}
    end)
  end

  @doc """
  Parses a queue-width env value, falling back to `default` when `value` is `nil`.

  Raises `ArgumentError` (never silently returns `0` or the default) when `value` is
  present but not a positive integer — invalid config must fail loud at boot, not
  produce a starved (0-concurrency) or silently-defaulted queue.
  """
  @spec queue_size(String.t() | nil, pos_integer()) :: pos_integer()
  def queue_size(nil, default) when is_integer(default) and default > 0, do: default

  def queue_size(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {size, ""} when size > 0 ->
        size

      _ ->
        raise ArgumentError,
              "OBAN queue size must be a positive integer, got: #{inspect(value)} (default: #{default})"
    end
  end
end
