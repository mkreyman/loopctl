defmodule Loopctl.RateLimiter.Server do
  @moduledoc """
  GenServer that owns the ETS table for API-key and tenant rate limiting.

  Uses `:ets.update_counter` for atomic, lock-free increments.
  Periodically cleans expired window counters.

  ## ETS key format

      {identifier, window_timestamp} -> count

  Where `window_timestamp` is `div(unix_seconds, 60)` for 1-minute windows.
  """

  use GenServer

  @table :loopctl_rate_limits
  @cleanup_interval_ms 60_000

  # --- Client API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Checks the rate for a given identifier (api_key_id or tenant_id).

  Returns `{:allow, count}` or `{:deny, limit}`.
  """
  @spec check_rate(String.t(), non_neg_integer()) ::
          {:allow, non_neg_integer()} | {:deny, non_neg_integer()}
  def check_rate(identifier, limit) do
    window = current_window()
    key = {identifier, window}

    count =
      :ets.update_counter(@table, key, {2, 1}, {key, 0})

    if count <= limit do
      {:allow, count}
    else
      {:deny, limit}
    end
  end

  @doc """
  Returns the current window timestamp and when it resets (Unix timestamp).
  """
  @spec window_info() :: %{window: non_neg_integer(), reset_at: non_neg_integer()}
  def window_info do
    window = current_window()
    reset_at = (window + 1) * 60
    %{window: window, reset_at: reset_at}
  end

  @doc """
  Returns the current count for an identifier in the current window.
  """
  @spec current_count(String.t()) :: non_neg_integer()
  def current_count(identifier) do
    window = current_window()
    key = {identifier, window}

    case :ets.lookup(@table, key) do
      [{_key, count}] -> count
      [] -> 0
    end
  end

  @doc """
  Returns the ETS table name (for test inspection).
  """
  def table_name, do: @table

  # --- Server callbacks ---

  @impl true
  def init(_opts) do
    table =
      :ets.new(@table, [
        :set,
        :public,
        :named_table,
        read_concurrency: true,
        write_concurrency: true
      ])

    schedule_cleanup()
    {:ok, %{table: table}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cleanup_expired_windows()
    schedule_cleanup()
    {:noreply, state}
  end

  # --- Private ---

  defp current_window do
    now = clock().utc_now()
    DateTime.to_unix(now) |> div(60)
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end

  defp cleanup_expired_windows do
    current = current_window()

    # Delete all entries with window timestamps older than current - 1
    # Keep current and previous window for in-flight requests
    :ets.select_delete(@table, [
      {{{:"$1", :"$2"}, :_}, [{:<, :"$2", current - 1}], [true]}
    ])
  end

  defp clock do
    Application.get_env(:loopctl, :clock, Loopctl.Clock.Default)
  end
end
