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
      status_reply: :ok,
      # Replies to dispatch_reply pushes, oldest first: :ok, {:error, reason_map}, or :none for
      # a push left unanswered.
      dispatch_reply_replies: [],
      # When set, a dispatch_reply within this many ms of the last accepted one is refused
      # rate_limited, like loopctl's burst bucket once it is empty.
      dispatch_reply_floor_ms: nil,
      last_dispatch_reply_ms: nil,
      # Stored trace seqs per run_id, and scripted replies to trace pushes, oldest first:
      # :ok (store and ack) or {:error, reason_map}.
      trace_seqs: %{},
      trace_replies: [],
      # run_id => a refusal returned for every trace batch of that run
      trace_refuse_runs: %{},
      last_trace_ms: %{},
      # Replies to stage pushes, oldest first: :ok (validate and ack), :none for a push left
      # unanswered, or {:error, reason_map}; once used up every stage is acknowledged.
      stage_replies: []
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

  def next_dispatch_reply_reply do
    Agent.get_and_update(__MODULE__, fn
      %{dispatch_reply_replies: [reply | rest]} = state ->
        {reply, %{state | dispatch_reply_replies: rest}}

      state ->
        {:ok, state}
    end)
  end

  def next_stage_reply do
    Agent.get_and_update(__MODULE__, fn
      %{stage_replies: [reply | rest]} = state -> {reply, %{state | stage_replies: rest}}
      state -> {:ok, state}
    end)
  end

  def next_trace_reply do
    Agent.get_and_update(__MODULE__, fn
      %{trace_replies: [reply | rest]} = state -> {reply, %{state | trace_replies: rest}}
      state -> {:ok, state}
    end)
  end

  @doc "The contiguous acknowledgement for a run: the highest seq with every seq below stored."
  def acked_seq(run_id) do
    seqs = Map.get(get(:trace_seqs), run_id, MapSet.new())
    Stream.iterate(0, &(&1 + 1)) |> Enum.find(&(not MapSet.member?(seqs, &1))) |> Kernel.-(1)
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
          TestLoopctl.put(:channel_pid, self())
          scripted_reply(TestLoopctl.next_join_reply(), socket)
      end
    end

    defp scripted_reply(:ok, socket), do: {:ok, %{contract_version: "1.5.0"}, socket}

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

    # What loopctl 1.2 does when a join is refused because the credential no longer works.
    defp scripted_reply(:not_authorized_disconnecting, _socket),
      do: {:error, %{reason: "not_authorized", disconnecting: "join_refused_not_authorized"}}

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

    # loopctl's per-event floors: a push inside the interval is refused, not queued.
    def handle_in(event, payload, socket) when event in ["trace", "trace_cursor"] do
      now = System.monotonic_time(:millisecond)
      last = Map.get(TestLoopctl.get(:last_trace_ms), event)

      if last && now - last < 50 do
        TestLoopctl.notify({:trace_rate_limited, event})
        {:reply, {:error, %{reason: "rate_limited", min_interval_ms: 50}}, socket}
      else
        TestLoopctl.put(:last_trace_ms, Map.put(TestLoopctl.get(:last_trace_ms), event, now))
        trace_in(event, payload, socket)
      end
    end

    def handle_in("dispatch_reply", payload, socket) do
      TestLoopctl.notify({:dispatch_reply, payload})

      case Contract.validate("RunnerDispatchReply", payload) do
        :ok ->
          case {floored?(), TestLoopctl.next_dispatch_reply_reply()} do
            {true, _} ->
              {:reply, {:error, %{reason: "rate_limited"}}, socket}

            {false, :ok} ->
              TestLoopctl.put(:last_dispatch_reply_ms, System.monotonic_time(:millisecond))
              {:reply, :ok, socket}

            {false, :none} ->
              {:noreply, socket}

            # An error reply with an empty body, which Slipstream hands over as a bare :error.
            {false, :bare_error} ->
              {:reply, :error, socket}

            {false, {:error, reply}} ->
              {:reply, {:error, reply}, socket}
          end

        {:error, details} ->
          {:reply, {:error, %{reason: "invalid_payload", details: details}}, socket}
      end
    end

    # loopctl's compare-and-set on the story's stage row is not modelled: the reply is scripted.
    def handle_in("stage", payload, socket) do
      TestLoopctl.notify({:stage, payload})

      case Contract.validate("RunnerStageReport", payload) do
        :ok ->
          case TestLoopctl.next_stage_reply() do
            :ok -> {:reply, {:ok, %{stage: payload["to"]}}, socket}
            :none -> {:noreply, socket}
            {:error, reply} -> {:reply, {:error, reply}, socket}
          end

        {:error, details} ->
          {:reply, {:error, %{reason: "invalid_payload", details: details}}, socket}
      end
    end

    def handle_in(_event, _payload, socket),
      do: {:reply, {:error, %{reason: "unknown_event"}}, socket}

    defp trace_in("trace_cursor", %{"run_id" => run_id} = payload, socket) do
      TestLoopctl.notify({:trace_cursor, payload})
      {:reply, {:ok, %{acked_seq: TestLoopctl.acked_seq(run_id)}}, socket}
    end

    defp trace_in("trace", payload, socket) do
      TestLoopctl.notify({:trace, payload})

      case trace_problem(payload) do
        nil -> scripted_trace_reply(payload, socket)
        refusal -> {:reply, {:error, refusal}, socket}
      end
    end

    defp trace_problem(payload) do
      alias LoopctlRunner.ByteRule

      too_big? = fn event ->
        ByteRule.bytes(Map.get(event, "data", %{})) > 6_000 or ByteRule.bytes(event) > 12_000
      end

      cond do
        Contract.validate("RunnerTraceBatch", payload) != :ok -> %{reason: "invalid_payload"}
        Enum.any?(payload["events"], too_big?) -> %{reason: "event_data_too_large"}
        ByteRule.bytes(payload) > 60_000 -> %{reason: "batch_too_large"}
        true -> Map.get(TestLoopctl.get(:trace_refuse_runs), payload["run_id"])
      end
    end

    defp scripted_trace_reply(payload, socket) do
      case TestLoopctl.next_trace_reply() do
        :ok ->
          run_id = payload["run_id"]
          seqs = TestLoopctl.get(:trace_seqs)

          stored =
            Enum.reduce(
              payload["events"],
              Map.get(seqs, run_id, MapSet.new()),
              &MapSet.put(&2, &1["seq"])
            )

          TestLoopctl.put(:trace_seqs, Map.put(seqs, run_id, stored))
          {:reply, {:ok, %{acked_seq: TestLoopctl.acked_seq(run_id)}}, socket}

        # An acknowledgement that does not reflect the batch, as if a gap were left.
        {:ack, acked} ->
          {:reply, {:ok, %{acked_seq: acked}}, socket}

        {:error, reply} ->
          {:reply, {:error, reply}, socket}
      end
    end

    defp floored? do
      floor = TestLoopctl.get(:dispatch_reply_floor_ms)
      last = TestLoopctl.get(:last_dispatch_reply_ms)
      floor != nil and last != nil and System.monotonic_time(:millisecond) - last < floor
    end

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

    # The channel closing on the server while the socket stays up.
    @impl true
    def handle_info(:close_channel, socket), do: {:stop, {:shutdown, :closed}, socket}

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
