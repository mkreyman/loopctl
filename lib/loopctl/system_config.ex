defmodule Loopctl.SystemConfig do
  @moduledoc """
  DB-backed, live-tunable system configuration for operational knobs
  (timeout/retry budgets) that were previously hardcoded module attributes.

  Changing a value is now an `UPDATE` of a `system_configs` row — no code change,
  no redeploy. The change is picked up immediately on the WRITING node (`put/2`).
  Other nodes refresh their node-local cache from the DB asynchronously via the
  `SystemConfigRefreshWorker` Oban cron. That cron enqueues ONE job per tick
  CLUSTER-WIDE (run by a single node), so "within a minute" holds for a
  SINGLE-NODE deployment; on a MULTI-NODE cluster a given node's adoption latency
  is unbounded (it may lag many ticks). Callers that need a per-node propagation
  guarantee must not assume ~60s fleet-wide — confirm per node.

  ## Hot-path read

  `get_int/2` reads from `:persistent_term` (a near-zero-cost VM-global read) and
  MUST NEVER raise — it is called on the ingestion/extraction hot path. A cache
  miss OR any error returns the caller-supplied default, so a missing DB row (or a
  DB the cache was never primed from) behaves exactly like the pre-existing
  in-code default.

  That fallback is NOT neutral for every key. For the US-41.1 embeddings
  read-routing flag (`"embedding_side_table_reads"`, see
  `Loopctl.Embeddings.SystemConfigReadPath`) the in-code default is `0` = the
  RETIRED legacy `articles.embedding` column, so an unprimed cache silently
  reverts a completed cutover for as long as it stays unprimed. That is why the
  boot prime is now ORDERED ahead of every consumer rather than run after the
  supervision tree is up (GH #588).

  ## Refresh lifecycle

  The cache is (re)loaded from the DB via `Loopctl.AdminRepo`:

    * once at boot by the supervised one-shot child
      `Loopctl.SystemConfig.CachePrimer`, which primes SYNCHRONOUSLY inside its
      `start_link/1` and then returns `:ignore`. It is listed in
      `Loopctl.Application.children/0` after `Loopctl.AdminRepo` (its data
      source) and before `Oban` and `LoopctlWeb.Endpoint` — because a supervisor
      starts children synchronously in list order, that placement GUARANTEES the
      cache is authoritative before either of those consumers accepts work, and
    * every cron tick by `Loopctl.Workers.SystemConfigRefreshWorker` — but that
      job runs on ONE node per tick, so on a multi-node cluster a given node's
      refresh cadence is not bounded to one minute, and
    * immediately for a single key on `put/2` (the writing node only).

  `refresh/0` is `try/rescue`-wrapped so a DB blip can never crash boot or the
  cron worker; the previously-cached values simply persist. It REPORTS the
  failure as `{:error, reason}` (rather than swallowing it into `:ok`) so the
  primer can make a failed boot prime loud — a silently empty cache is what turns
  a bounded startup window into an unbounded one.

  The `:persistent_term` key is `{__MODULE__, key_string}` — string keys are used
  verbatim (never `String.to_atom/1` on them).
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Loopctl.AdminRepo
  alias Loopctl.SystemConfig.Setting

  @doc """
  Reads an integer config value from the `:persistent_term` cache.

  Returns `default` on a cache miss, a non-integer cached value, or any error.
  Never raises — safe to call on the hot path.
  """
  @spec get_int(String.t(), integer()) :: integer()
  def get_int(key, default) when is_binary(key) and is_integer(default) do
    case :persistent_term.get(pt_key(key), :__miss__) do
      value when is_integer(value) -> value
      _ -> default
    end
  rescue
    _ -> default
  end

  @doc """
  Loads ALL settings from the DB (via `AdminRepo`) into `:persistent_term`.

  Wrapped in `try/rescue`: a DB error logs and returns `{:error, reason}` — it
  never raises, so it can never crash boot or the refresh cron, and the existing
  cache is left untouched. Callers that must react to a failed prime (see
  `Loopctl.SystemConfig.CachePrimer`) match on the error tuple; callers that only
  want best-effort propagation (the cron worker, `Loopctl.Release`) ignore it.
  """
  @spec refresh() :: :ok | {:error, term()}
  def refresh do
    Setting
    |> AdminRepo.all()
    |> Enum.each(fn %Setting{key: key, value: value} ->
      :persistent_term.put(pt_key(key), value)
    end)

    :ok
  rescue
    e ->
      Logger.warning(
        "Loopctl.SystemConfig.refresh/0 failed; keeping existing cache: " <>
          Exception.message(e)
      )

      {:error, e}
  end

  @doc """
  Upserts a setting row (via `AdminRepo`) AND updates the `:persistent_term`
  cache immediately, so the new value is live on this node without waiting for the
  refresh cron. For a future admin API.
  """
  @spec put(String.t(), integer()) :: {:ok, Setting.t()} | {:error, Ecto.Changeset.t()}
  def put(key, value) when is_binary(key) and is_integer(value) do
    now = DateTime.utc_now()

    %Setting{}
    |> Setting.changeset(%{key: key, value: value})
    |> AdminRepo.insert(
      on_conflict: [set: [value: value, updated_at: now]],
      conflict_target: :key,
      returning: true
    )
    |> case do
      {:ok, setting} ->
        :persistent_term.put(pt_key(key), value)
        {:ok, setting}

      {:error, _changeset} = error ->
        error
    end
  end

  @doc """
  Lists all settings (via `AdminRepo`), ordered by key. For observability.
  """
  @spec all() :: [Setting.t()]
  def all do
    AdminRepo.all(from s in Setting, order_by: [asc: s.key])
  end

  defp pt_key(key), do: {__MODULE__, key}
end
