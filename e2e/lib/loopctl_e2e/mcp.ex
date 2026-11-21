defmodule LoopctlE2e.Mcp do
  @moduledoc """
  One real loopctl MCP server process (`mcp-server/index.js`), spawned with node and driven
  over stdio as Claude Code drives it (US-52.20). The process is the session holder
  (US-52.13): it registers at startup, heartbeats on its own timer and opens the work item
  for its worktree's branch, so a scenario that runs two of these runs two sessions without
  spending model tokens.

  The MCP stdio transport is newline-delimited JSON-RPC 2.0. A GenServer owns the Port; a
  call writes one request and replies when the line carrying its id arrives, or with
  `{:error, :timeout}` after `timeout_ms` (the slow case: a hung server fails the call, never
  the run's process). A line that is not JSON or carries another id is skipped. A tool
  result is the JSON text of its first content block, decoded; a result flagged `isError` is
  `{:error, decoded}`.

  `kill/1` sends SIGKILL to the OS process, so nothing in it runs (no holder_end): the crash
  the lapse test needs. `stop/1` closes stdin, which the server treats as shutdown.
  """

  use GenServer

  @default_timeout_ms 60_000

  @doc """
  Starts the server. `opts`: `:node` (the node executable), `:index` (path to index.js),
  `:cwd` (the session's worktree) and `:env`, a list of `{name, value}` where a `false` value
  UNSETS that inherited variable. Answers once `initialize` has been answered.
  """
  @spec start(keyword()) :: {:ok, pid()} | {:error, term()}
  def start(opts) do
    case GenServer.start(__MODULE__, opts) do
      {:ok, pid} ->
        case GenServer.call(pid, {:request, "initialize", init_params()}, :infinity) do
          {:ok, _} ->
            GenServer.cast(pid, {:notify, "notifications/initialized"})
            {:ok, pid}

          {:error, _} = error ->
            stop(pid)
            error
        end

      {:error, _} = error ->
        error
    end
  end

  @doc "Calls tool `name` with `args`: `{:ok, decoded}` or `{:error, decoded_or_reason}`."
  @spec call(pid(), String.t(), map(), pos_integer()) :: {:ok, term()} | {:error, term()}
  def call(pid, name, args \\ %{}, timeout_ms \\ @default_timeout_ms) do
    case GenServer.call(
           pid,
           {:request, "tools/call", %{name: name, arguments: args}, timeout_ms},
           timeout_ms + 5_000
         ) do
      {:ok, %{"content" => [%{"text" => text} | _]} = result} ->
        decoded = decode(text)
        if result["isError"], do: {:error, decoded}, else: {:ok, decoded}

      {:ok, other} ->
        {:error, other}

      {:error, _} = error ->
        error
    end
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  @doc "SIGKILLs the server: no shutdown code runs, so its holder is never ended."
  @spec kill(pid()) :: :ok
  def kill(pid), do: GenServer.call(pid, :kill, 10_000)

  @doc "Closes stdin and stops; a no-op for a server already gone."
  @spec stop(pid()) :: :ok
  def stop(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal, 10_000)
    :ok
  catch
    :exit, _ -> :ok
  end

  defp init_params do
    %{
      protocolVersion: "2025-06-18",
      capabilities: %{},
      clientInfo: %{name: "loopctl-e2e", version: "0.1.0"}
    }
  end

  # --- server ---

  @impl true
  def init(opts) do
    env =
      for {k, v} <- Keyword.fetch!(opts, :env),
          do: {to_charlist(k), if(v == false, do: false, else: to_charlist(v))}

    port =
      Port.open({:spawn_executable, Keyword.fetch!(opts, :node)}, [
        :binary,
        :exit_status,
        :use_stdio,
        {:line, 1_048_576},
        {:args, [Keyword.fetch!(opts, :index)]},
        {:cd, Keyword.fetch!(opts, :cwd)},
        {:env, env}
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    {:ok, %{port: port, os_pid: os_pid, next_id: 1, buffer: "", waiting: %{}, exited: nil}}
  end

  @impl true
  def handle_call({:request, method, params}, from, state),
    do: handle_call({:request, method, params, @default_timeout_ms}, from, state)

  def handle_call({:request, _method, _params, _timeout}, _from, %{exited: status} = state)
      when status != nil,
      do: {:reply, {:error, {:exited, status}}, state}

  def handle_call({:request, method, params, timeout_ms}, from, state) do
    id = state.next_id
    write(state.port, %{jsonrpc: "2.0", id: id, method: method, params: params})
    timer = Process.send_after(self(), {:timeout, id}, timeout_ms)
    waiting = Map.put(state.waiting, id, {from, timer})
    {:noreply, %{state | next_id: id + 1, waiting: waiting}}
  end

  def handle_call(:kill, _from, %{exited: nil} = state) do
    System.cmd("kill", ["-9", Integer.to_string(state.os_pid)])
    port = state.port

    status =
      receive do
        {^port, {:exit_status, status}} -> status
      after
        5_000 -> :killed
      end

    {:reply, :ok, fail_all(%{state | exited: status})}
  end

  def handle_call(:kill, _from, state), do: {:reply, :ok, state}

  @impl true
  def handle_cast({:notify, method}, state) do
    if state.exited == nil, do: write(state.port, %{jsonrpc: "2.0", method: method})
    {:noreply, state}
  end

  @impl true
  def handle_info({port, {:data, {:noeol, chunk}}}, %{port: port} = state),
    do: {:noreply, %{state | buffer: state.buffer <> chunk}}

  def handle_info({port, {:data, {:eol, chunk}}}, %{port: port} = state) do
    line = state.buffer <> chunk
    state = %{state | buffer: ""}

    case Jason.decode(line) do
      {:ok, %{"id" => id} = message} when is_map_key(state.waiting, id) ->
        {{from, timer}, waiting} = Map.pop(state.waiting, id)
        Process.cancel_timer(timer)
        GenServer.reply(from, reply(message))
        {:noreply, %{state | waiting: waiting}}

      _other ->
        {:noreply, state}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state),
    do: {:noreply, fail_all(%{state | exited: status})}

  def handle_info({:timeout, id}, state) do
    case Map.pop(state.waiting, id) do
      {nil, _} ->
        {:noreply, state}

      {{from, _timer}, waiting} ->
        GenServer.reply(from, {:error, :timeout})
        {:noreply, %{state | waiting: waiting}}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.exited == nil and Port.info(state.port), do: Port.close(state.port)
    :ok
  end

  defp reply(%{"result" => result}), do: {:ok, result}
  defp reply(%{"error" => error}), do: {:error, {:rpc, error}}

  defp fail_all(state) do
    for {_id, {from, timer}} <- state.waiting do
      Process.cancel_timer(timer)
      GenServer.reply(from, {:error, {:exited, state.exited}})
    end

    %{state | waiting: %{}}
  end

  defp write(port, message), do: Port.command(port, [Jason.encode!(message), "\n"])

  defp decode(text) do
    case Jason.decode(text) do
      {:ok, value} -> value
      {:error, _} -> text
    end
  end
end
