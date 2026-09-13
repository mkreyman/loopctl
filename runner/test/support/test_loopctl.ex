defmodule LoopctlRunner.TestLoopctl do
  @moduledoc """
  A real Phoenix endpoint standing in for loopctl's runner transport, so the client is
  tested over an actual websocket rather than a simulated one.

  It mirrors the parts of loopctl `RunnerSocket` / `RunnerChannel` (PR #806) the client
  depends on: the token only from the `x-loopctl-runner-token` header, a 403 upgrade on
  any other credential, `runner:<id>` as the only joinable topic, the contract cast on
  join, `status` replies, and `"disconnect"` broadcast to the socket id. Join replies can
  be scripted per test to exercise refusals.
  """

  use Agent

  @spec start(pid()) :: {:ok, pos_integer()}
  def start(test_pid) do
    state = %{
      test_pid: test_pid,
      token: "lc_test_token",
      runner_id: "0b1c7a52-6a4c-4f7e-9d7b-1a2b3c4d5e6f",
      join_replies: [],
      last_status_ms: nil,
      # :ok, {:delay, ms} for a slow link, :none for a push that is never answered, {:body, map}
      # for an ok reply carrying a body, or a list of those consumed one push at a time (the
      # last one then repeats).
      status_reply: :ok
    }

    case Agent.start(fn -> state end, name: __MODULE__) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> Agent.update(__MODULE__, fn _ -> state end)
    end

    {:ok, {_ip, port}} = __MODULE__.Endpoint.server_info(:http)
    {:ok, port}
  end

  def get(key), do: Agent.get(__MODULE__, &Map.fetch!(&1, key))
  def put(key, value), do: Agent.update(__MODULE__, &Map.put(&1, key, value))

  @doc "Scripts the next join replies, oldest first: `:ok` or `{:error, reason_map}`."
  def script_joins(replies), do: put(:join_replies, replies)

  def next_status_reply do
    Agent.get_and_update(__MODULE__, fn
      %{status_reply: [reply]} = state -> {reply, state}
      %{status_reply: [reply | rest]} = state -> {reply, %{state | status_reply: rest}}
      %{status_reply: reply} = state -> {reply, state}
    end)
  end

  def next_join_reply do
    Agent.get_and_update(__MODULE__, fn
      %{join_replies: [reply | rest]} = state -> {reply, %{state | join_replies: rest}}
      state -> {:ok, state}
    end)
  end

  def notify(message), do: send(get(:test_pid), {:test_loopctl, message})

  @doc "What loopctl does on revocation: broadcast disconnect to the runner's socket id."
  def disconnect_runner do
    __MODULE__.Endpoint.broadcast("runner_socket:" <> get(:runner_id), "disconnect", %{})
  end

  defmodule Socket do
    @moduledoc false
    use Phoenix.Socket

    channel("runner:*", LoopctlRunner.TestLoopctl.Channel)

    @impl true
    def connect(params, socket, connect_info) do
      LoopctlRunner.TestLoopctl.notify({:connect, params})
      expected = LoopctlRunner.TestLoopctl.get(:token)

      case for({"x-loopctl-runner-token", token} <- connect_info.x_headers, do: token) do
        [^expected] ->
          {:ok, assign(socket, :runner_id, LoopctlRunner.TestLoopctl.get(:runner_id))}

        _ ->
          :error
      end
    end

    @impl true
    def id(socket), do: "runner_socket:" <> socket.assigns.runner_id
  end

  defmodule Channel do
    @moduledoc false
    use Phoenix.Channel

    alias LoopctlRunner.{Contract, TestLoopctl}

    @impl true
    def join("runner:" <> id, payload, socket) do
      TestLoopctl.notify({:join, id, payload})

      cond do
        id != socket.assigns.runner_id ->
          {:error, %{reason: "forbidden_topic"}}

        Contract.validate("RunnerJoin", payload) != :ok ->
          {:error, %{reason: "invalid_payload"}}

        true ->
          scripted_reply(TestLoopctl.next_join_reply(), socket)
      end
    end

    defp scripted_reply(:ok, socket), do: {:ok, %{contract_version: "1.0.0"}, socket}

    # What loopctl does on not_authorized: refuse, then close the socket.
    defp scripted_reply(:not_authorized_disconnect, _socket) do
      spawn(fn ->
        Process.sleep(50)
        TestLoopctl.disconnect_runner()
      end)

      {:error, %{reason: "not_authorized"}}
    end

    defp scripted_reply({:delay, ms, reply}, socket) do
      Process.sleep(ms)
      scripted_reply(reply, socket)
    end

    defp scripted_reply({:error, reply}, _socket), do: {:error, reply}

    # loopctl's 1s floor between status updates, measured on the monotonic clock.
    @impl true
    def handle_in("status", payload, socket) do
      now = System.monotonic_time(:millisecond)
      last = TestLoopctl.get(:last_status_ms)

      if last && now - last < 1_000 do
        TestLoopctl.notify({:status_rate_limited, payload})
        {:reply, {:error, %{reason: "rate_limited", min_interval_ms: 1_000}}, socket}
      else
        TestLoopctl.put(:last_status_ms, now)
        accept_status(payload, socket)
      end
    end

    def handle_in(_event, _payload, socket),
      do: {:reply, {:error, %{reason: "unknown_event"}}, socket}

    defp accept_status(payload, socket) do
      TestLoopctl.notify({:status, payload})

      case TestLoopctl.next_status_reply() do
        {:body, body} ->
          {:reply, {:ok, body}, socket}

        :none ->
          {:noreply, socket}

        {:delay, ms} ->
          Process.sleep(ms)
          status_reply(payload, socket)

        :ok ->
          status_reply(payload, socket)
      end
    end

    defp status_reply(payload, socket) do
      case Contract.validate("RunnerStatus", payload) do
        :ok ->
          {:reply, :ok, socket}

        {:error, details} ->
          {:reply, {:error, %{reason: "invalid_payload", details: details}}, socket}
      end
    end

    @impl true
    def handle_info({:push, event, payload}, socket) do
      push(socket, event, payload)
      {:noreply, socket}
    end
  end

  defmodule Endpoint do
    @moduledoc false
    use Phoenix.Endpoint, otp_app: :loopctl_runner

    socket("/runner/socket", LoopctlRunner.TestLoopctl.Socket,
      websocket: [connect_info: [:x_headers]],
      longpoll: false
    )
  end
end
