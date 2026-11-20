defmodule LoopctlRunner.FetchLock do
  @moduledoc """
  One fetch of a repository at a time in this BEAM, first come first served
  (`LoopctlRunner.Worktree.fetch_base/3`).

  A holder is monitored: its death releases the key, a killed task included. Waiters queue in
  arrival order and each is answered the moment the key is theirs. A waiter that stops waiting
  (its caller's deadline passed) cancels its place; if the key was granted to it in the meantime,
  the cancel releases it, so a grant nobody takes never holds the key. Not reentrant: a holder that
  asks again queues behind itself until its wait runs out.
  """

  use GenServer

  @doc false
  def start_link(opts),
    do: GenServer.start_link(__MODULE__, :ok, name: Keyword.fetch!(opts, :name))

  @doc """
  Waits up to `wait_ms` for `key` in `server`: `:ok` once it is this process's, `:timeout` when it
  was not granted in time.
  """
  @spec acquire(GenServer.server(), term(), non_neg_integer()) :: :ok | :timeout
  def acquire(server, key, wait_ms) do
    GenServer.call(server, {:acquire, key}, wait_ms)
  catch
    :exit, {:timeout, _} ->
      release(server, key)
      :timeout
  end

  @doc "Gives `key` up, or this process's place in its queue."
  @spec release(GenServer.server(), term()) :: :ok
  def release(server, key), do: GenServer.call(server, {:release, key, self()})

  @impl true
  def init(:ok), do: {:ok, %{}}

  # State: key => {holder pid, holder monitor, queue of waiting {from, pid}}.
  @impl true
  def handle_call({:acquire, key}, {pid, _tag} = from, state) do
    case state do
      %{^key => {holder, ref, queue}} ->
        {:noreply, Map.put(state, key, {holder, ref, :queue.in({from, pid}, queue)})}

      _ ->
        {:reply, :ok, Map.put(state, key, {pid, Process.monitor(pid), :queue.new()})}
    end
  end

  def handle_call({:release, key, pid}, _from, state) do
    case state do
      %{^key => {^pid, ref, queue}} ->
        Process.demonitor(ref, [:flush])
        {:reply, :ok, grant_next(state, key, queue)}

      %{^key => {holder, ref, queue}} ->
        queue = :queue.filter(fn {_from, waiter} -> waiter != pid end, queue)
        {:reply, :ok, Map.put(state, key, {holder, ref, queue})}

      _ ->
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Enum.find(state, fn {_key, {_holder, held, _queue}} -> held == ref end) do
      {key, {_holder, _ref, queue}} -> {:noreply, grant_next(state, key, queue)}
      nil -> {:noreply, state}
    end
  end

  # The next waiter still alive gets the key; with none, the key is free.
  defp grant_next(state, key, queue) do
    case :queue.out(queue) do
      {{:value, {from, pid}}, rest} ->
        if Process.alive?(pid) do
          GenServer.reply(from, :ok)
          Map.put(state, key, {pid, Process.monitor(pid), rest})
        else
          grant_next(state, key, rest)
        end

      {:empty, _} ->
        Map.delete(state, key)
    end
  end
end
