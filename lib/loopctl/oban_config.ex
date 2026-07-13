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

  # Default widths are derived directly from config/config.exs's compile-time
  # `config :loopctl, Oban, queues: [...]` (AC-32.2.3) rather than hand-copied, so
  # adding/removing/resizing a queue there flows here automatically with zero drift
  # risk. Sum = 38 (10+5+2+3+2+5+5+3+3).
  @default_queues Application.compile_env(:loopctl, Oban)[:queues]

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
