defmodule Loopctl.Memory.RecallHistoryCache do
  @moduledoc """
  Node-local, in-process record of which article ids a recall session has ALREADY been
  shown (#792, containment-in-history).

  ## Why the server keeps this and not the client

  The claude-config hook already filters ids it has seen this session, client-side. What it
  cannot do is REFILL: by the time the block is rendered the server has already spent the
  slot, so a repeat costs a row rather than yielding one. Holding the shown-set here lets
  `Loopctl.Memory.recall_context/2` drop the repeat BEFORE selection and take the next
  distinct candidate from the over-fetched pool instead — the whole point of moving the
  check.

  ## Keying and isolation

  Entries are keyed `{tenant_id, session_id, article_id}`. `session_id` is a CLIENT-chosen
  opaque token, so it is never trusted as a scope on its own: `tenant_id` is in the key, so
  two tenants that pick the same session string cannot see each other's history. A recall
  with no `session_id` reads and writes nothing — containment is opt-in, and a client that
  does not identify its session gets exactly today's behaviour.

  ## What it is NOT

  Node-local and lost on restart, like `Loopctl.Memory.RecallBumpCache`, whose ETS-owner
  shape this mirrors. There is no correctness claim behind it: a miss (another node, a
  restart, an expired entry) means an article the session already saw may surface again,
  which is the pre-#792 behaviour and not a fault. That is why the shown-set is a cache and
  not a table — the cost of a miss is one redundant row, and the cost of a table would be a
  write on every recall.

  Entries expire after `ttl_seconds/0` and a periodic sweep evicts them, so the table stays
  bounded to the sessions active within roughly one window.
  """

  use GenServer

  @table :loopctl_recall_shown_articles
  @sweep_interval_ms :timer.minutes(5)
  @default_ttl_seconds 7_200

  # --- Client API ---

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  The subset of `ids` this `(tenant_id, session_id)` has already been shown on THIS node,
  in the order given.

  A lock-free `:ets.lookup` per id, bypassing the owner GenServer. Fails OPEN — an empty
  list — when there is no session, no ids, or no table (owner not yet booted), so a missing
  cache can only cost containment, never results.

  A LIST rather than a `MapSet`: the one consumer
  (`Loopctl.Knowledge.Diversity.select/4`'s `:exclude_ids`) builds its own set anyway, and
  returning `MapSet.t()` from a function whose clauses mix `MapSet.new/0` and
  `MapSet.new/1` puts two different internal representations in one success typing, which
  dialyzer reports as an opaqueness violation. Handing back a plain list fixes the cause
  rather than suppressing the warning.
  """
  @spec shown_ids(String.t(), String.t() | nil, [String.t()]) :: [String.t()]
  def shown_ids(tenant_id, session_id, ids)

  def shown_ids(_tenant_id, nil, _ids), do: []
  def shown_ids(_tenant_id, _session_id, []), do: []

  def shown_ids(tenant_id, session_id, ids)
      when is_binary(tenant_id) and is_binary(session_id) and is_list(ids) do
    now = now_ms()

    Enum.filter(ids, fn id -> shown?(tenant_id, session_id, id, now) end)
  rescue
    ArgumentError -> []
  end

  def shown_ids(_tenant_id, _session_id, _ids), do: []

  @doc """
  Records that `ids` were RENDERED to this `(tenant_id, session_id)`.

  Called with the ids the merge actually published, never the candidate pool: marking a
  candidate the cap dropped would suppress an article the session was never shown.
  Best-effort; a missing table is swallowed.
  """
  @spec mark_shown(String.t(), String.t() | nil, [String.t()]) :: :ok
  def mark_shown(tenant_id, session_id, ids)

  def mark_shown(_tenant_id, nil, _ids), do: :ok
  def mark_shown(_tenant_id, _session_id, []), do: :ok

  def mark_shown(tenant_id, session_id, ids)
      when is_binary(tenant_id) and is_binary(session_id) and is_list(ids) do
    expires_at = now_ms() + ttl_seconds() * 1_000

    Enum.each(ids, fn id ->
      if is_binary(id), do: :ets.insert(@table, {{tenant_id, session_id, id}, expires_at})
    end)

    :ok
  rescue
    ArgumentError -> :ok
  end

  def mark_shown(_tenant_id, _session_id, _ids), do: :ok

  @doc """
  How long a shown id suppresses itself, in seconds (config `:recall_history_ttl_seconds`,
  default #{@default_ttl_seconds}).

  Sized to a working session rather than to a day: past it, re-surfacing an article the
  agent saw hours ago is a reminder, not a redundancy.
  """
  @spec ttl_seconds() :: pos_integer()
  def ttl_seconds do
    case Application.get_env(:loopctl, :recall_history_ttl_seconds, @default_ttl_seconds) do
      seconds when is_integer(seconds) and seconds > 0 -> seconds
      _ -> @default_ttl_seconds
    end
  end

  @doc false
  def table_name, do: @table

  # --- Server callbacks ---

  @impl true
  def init(_opts) do
    table =
      case :ets.whereis(@table) do
        :undefined ->
          :ets.new(@table, [
            :set,
            :public,
            :named_table,
            read_concurrency: true,
            write_concurrency: true
          ])

        existing ->
          existing
      end

    schedule_sweep()
    {:ok, %{table: table}}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep_expired()
    schedule_sweep()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Private ---

  defp shown?(tenant_id, session_id, id, now) when is_binary(id) do
    case :ets.lookup(@table, {tenant_id, session_id, id}) do
      [{_key, expires_at}] -> now < expires_at
      [] -> false
    end
  end

  defp shown?(_tenant_id, _session_id, _id, _now), do: false

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)

  defp sweep_expired do
    now = now_ms()
    :ets.select_delete(@table, [{{:_, :"$1"}, [{:"=<", :"$1", now}], [true]}])
  rescue
    ArgumentError -> 0
  end

  # Monotonic clock: entries store `now_ms() + ttl`, compared against `now_ms()`. Never
  # `System.system_time/1` — a clock step would expire a live session or resurrect a dead
  # one.
  defp now_ms, do: System.monotonic_time(:millisecond)
end
