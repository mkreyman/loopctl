defmodule Loopctl.RateLimiter.FailOpenLog do
  @moduledoc """
  Node-local, throttled, PII-safe logger for rate-limiter fail-open events
  (US-38.2).

  When the limiter cannot reach its store (a DB fault under the Postgres impl, a
  Hammer soft-error, an unexpected return shape) callers degrade to "no gate".
  Emitting one `:warning` per failed check is a log FLOOD under a sustained
  outage — every authenticated request, every provider-admission check, every
  signup/enroll action fires one — exactly when the system is already unhealthy,
  drowning the real incident and pressuring disk. Worse, some buckets embed the
  client IP (`api_signup:ip:1.2.3.4`, `enroll:actions:...`), so a naive log would
  write client IPs into warnings at high volume.

  This module fixes both:

    * **Throttled** — at most one warning per `(source, bucket-family)` per
      `@throttle_ms` window, backed by a public ETS table this GenServer owns.
      Under an outage the log settles to a bounded heartbeat per family instead
      of one line per request.
    * **PII-safe** — the bucket is reduced to its non-identifying *family* prefix
      (e.g. `api_signup:ip`, `signup:webauthn`, `key`, `tenant`) before it
      touches the log, dropping the trailing IP / tenant-UUID / key-UUID segment.

  If the ETS table is somehow unavailable (e.g. a test that calls a limiter
  before the app tree is up) `warn/3` falls back to logging directly rather than
  crashing the caller's fail-open path.
  """

  use GenServer

  require Logger

  @table :rate_limiter_fail_open_log
  # One warning per (source, family) per minute is plenty to alert on a limiter
  # outage without flooding.
  @throttle_ms 60_000

  @doc false
  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    {:ok, %{}}
  end

  @doc """
  Log a rate-limiter fail-open warning, throttled per `(source, bucket-family)`
  and with the identifying suffix (IP / UUID) stripped from the message.

  `source` is a short atom identifying the call site (e.g. `:postgres`, `:plug`,
  `:capacity`, `:security`). Always returns `:ok`.
  """
  @spec warn(atom(), String.t(), String.t()) :: :ok
  def warn(source, bucket, detail) when is_atom(source) and is_binary(bucket) do
    family = family(bucket)

    if should_emit?(source, family) do
      Logger.warning(
        "RateLimiter fail-open [#{source}]: limiter unavailable for bucket family=" <>
          "#{family}; allowing/denying per the gate's fail policy: #{detail}"
      )
    end

    :ok
  end

  @doc false
  # Test seam: clear the throttle entry for one `(source, family)` so a test that
  # asserts a fail-open warning IS emitted cannot be silently throttled by a
  # concurrent async test that tripped the SAME node-local `(source, family)`
  # window first (the ETS table is process-independent and lives for the whole
  # run). Best-effort — a missing table is a no-op, mirroring `should_emit?/2`.
  @spec reset(atom(), String.t()) :: :ok
  def reset(source, family) when is_atom(source) and is_binary(family) do
    :ets.delete(@table, {source, family})
    :ok
  rescue
    ArgumentError -> :ok
  end

  # Reduce a bucket to a NON-identifying family token by dropping the trailing
  # id/IP segment. Bucket shapes: "key:<uuid>", "tenant:<uuid>",
  # "api_signup:ip:1.2.3.4", "signup:webauthn:<key>", "signup:actions:<key>",
  # "enroll:actions:<tenant>", "cr_retrieve:tenant:<tenant>",
  # "provider_admission:embedding:<uuid>". Keeping everything but the last
  # colon-segment yields a stable, non-PII family (e.g. "api_signup:ip").
  defp family(bucket) do
    case String.split(bucket, ":") do
      [single] -> single
      segments -> segments |> Enum.drop(-1) |> Enum.join(":")
    end
  end

  # True at most once per (source, family) per throttle window. Best-effort: if
  # the ETS table is not available, emit (never suppress a warning because the
  # throttle itself failed).
  defp should_emit?(source, family) do
    now = System.monotonic_time(:millisecond)
    key = {source, family}

    case :ets.lookup(@table, key) do
      [{^key, last}] when now - last < @throttle_ms ->
        false

      _ ->
        :ets.insert(@table, {key, now})
        true
    end
  rescue
    ArgumentError -> true
  end
end
