defmodule LoopctlRunner.Control do
  @moduledoc """
  The runner's outbound connection to loopctl (build order step 1b, design §2 and §7).

  A client, never a cluster peer. It connects to `/runner/socket/websocket` with the
  token in the `x-loopctl-runner-token` header, joins its own topic `runner:<runner_id>`
  with a `RunnerJoin` payload, and pushes a `RunnerStatus` every `status_interval_s`.
  loopctl tracks the joined channel in its tenant-scoped Presence set; the channel dying
  with the socket IS the liveness signal, so there is nothing here to deregister.

  Every outgoing payload is validated against the vendored contract first, and every join
  — rejoins included — carries a freshly built payload: a rejoin that replayed the first
  join's payload would tell loopctl stale `draining`, `in_flight` and sample values.

  ## Draining until dispatches are accepted

  This runner has no dispatch accept path yet (loopctl#803). While `:accepts_dispatches` is
  false — the default, and the only production setting until then — it reports
  `draining: true` whatever `set_draining/2` was told, so the control plane never reserves
  capacity here for a session that would not start. `dispatch` pushes are validated and
  refused.

  ## Refusals

  Join replies are read by `reason` (loopctl `RunnerChannel`):

    * `rate_limited` — the 30-joins-per-minute budget; rejoin after a backoff.
    * `not_authorized` — revoked runner or key, or inactive tenant. loopctl also closes the
      socket, and the reconnect path backs off.
    * `machine_mismatch`, `unsupported_contract_version`, `invalid_payload`,
      `forbidden_topic`, `unknown_topic` — this machine's configuration or build is wrong,
      and retrying cannot fix it. The client calls its `:on_fatal` hook, which by default
      stops the VM with `fatal_exit_status/0`. A runner that silently stayed "active" with
      no connection inside would be worse than a stopped one: the systemd unit does not
      restart on 78 (`RestartPreventExitStatus`), and the launchd agent exits 0, which
      `KeepAlive` does not restart.
      Re-enrolment gives a NEW runner id, so it is a config change plus a restart.

  A refused upgrade is an HTTP 403 with an empty body and no reason; it is retried with a
  backoff capped at two minutes. The token file is re-read on every attempt: an unreadable
  one is retried three times, for a rewrite in progress, and then treated as fatal. The
  backoff resets only on a successful join, so a server that accepts the upgrade and then
  drops the socket cannot hold the client on its fastest retry.
  """

  use Slipstream

  require Logger

  alias LoopctlRunner.{Config, Contract, ControlConfig, Health, Runs}

  @reconnect_backoff_ms [1_000, 2_000, 5_000, 10_000, 30_000, 60_000, 120_000]
  # The join budget is 30 per minute; this ladder never approaches it.
  @rejoin_backoff_ms [2_000, 5_000, 10_000, 30_000, 60_000]
  @fatal_reasons ~w(machine_mismatch unsupported_contract_version invalid_payload forbidden_topic unknown_topic)
  @ex_config 78
  # An empty or mid-rewrite token file gets a few attempts; a file that stays unreadable is
  # a misconfiguration, and fatal, so the service does not sit "active" with no connection.
  @max_token_failures 3

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    Slipstream.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :transient}
  end

  @doc "Marks this runner draining (no new dispatches) or not, and reports it."
  @spec set_draining(GenServer.server(), boolean()) :: :ok
  def set_draining(server, draining?) when is_boolean(draining?),
    do: GenServer.cast(server, {:set_draining, draining?})

  @doc "The client's current view, for diagnostics and tests."
  @spec info(GenServer.server()) :: map()
  def info(server), do: GenServer.call(server, :info)

  @doc "The draining flag loopctl is told: true while no dispatch can be accepted."
  @spec reported_draining(boolean(), boolean()) :: boolean()
  def reported_draining(draining?, accepts_dispatches?), do: draining? or not accepts_dispatches?

  @doc "The `RunnerJoin` payload for this machine, validated against the contract."
  @spec join_payload(Config.t(), map(), boolean(), boolean()) ::
          {:ok, map()} | {:error, [String.t()]}
  def join_payload(%Config{control: control} = config, capacity, draining?, accepts? \\ false) do
    payload =
      %{
        "contract_version" => Contract.version(),
        "machine" => control.machine,
        "cores" => capacity["cores"],
        "memory_mb" => capacity["memory_mb"],
        "repos" => control.repos,
        "max_sessions" => control.max_sessions,
        "in_flight" => Runs.in_flight(config.runs_dir),
        "draining" => reported_draining(draining?, accepts?)
      }
      |> put_sample(config)

    with :ok <- Contract.validate("RunnerJoin", payload), do: {:ok, payload}
  end

  @doc "The `RunnerStatus` payload, validated against the contract."
  @spec status_payload(Config.t(), boolean(), boolean()) :: {:ok, map()} | {:error, [String.t()]}
  def status_payload(%Config{} = config, draining?, accepts? \\ false) do
    payload =
      %{
        "in_flight" => Runs.in_flight(config.runs_dir),
        "draining" => reported_draining(draining?, accepts?)
      }
      |> put_sample(config)

    with :ok <- Contract.validate("RunnerStatus", payload), do: {:ok, payload}
  end

  # An unreadable metric omits the sample rather than reporting a healthy-looking zero;
  # loopctl treats a stale sample as a breached threshold.
  defp put_sample(payload, config) do
    case Health.sample(config.runs_dir, Runs.last_success_at(config.runs_dir)) do
      nil -> payload
      sample -> Map.put(payload, "sample", sample)
    end
  end

  @impl Slipstream
  def init(opts) do
    %Config{control: %ControlConfig{} = control} = config = Keyword.fetch!(opts, :config)

    case Health.capacity() do
      {:ok, capacity} ->
        socket =
          new_socket()
          |> assign(
            config: config,
            control: control,
            capacity: capacity,
            on_fatal: Keyword.get(opts, :on_fatal, &halt/1),
            # No dispatch accept path exists yet (loopctl#803); an option so the draining
            # value is observable in tests before it does.
            accepts_dispatches: Keyword.get(opts, :accepts_dispatches, false),
            token_failures: 0,
            topic: "runner:" <> control.runner_id,
            draining: false,
            joined: false,
            connect_attempts: 0,
            status_timer: nil,
            last_refusal: nil
          )

        {:ok, socket, {:continue, :connect}}

      {:error, reason} ->
        {:stop, {:shutdown, {:capacity_unreadable, reason}}}
    end
  end

  defp halt(reason) do
    Logger.error("loopctl runner stopping: #{inspect(reason)}")
    System.stop(fatal_exit_status())
  end

  @doc """
  The exit status for a fatal refusal: 78 (EX_CONFIG) by default, which the systemd unit
  does not restart; `LOOPCTL_RUNNER_FATAL_EXIT` overrides it. The launchd agent sets 0,
  because `KeepAlive` restarts every non-zero exit and has no way to exempt one — and a
  wrapper shell to translate the code would stand between launchd and the BEAM, swallowing
  the SIGTERM that lets the runner shut its sessions down in order.
  """
  @spec fatal_exit_status() :: non_neg_integer()
  def fatal_exit_status do
    case Integer.parse(System.get_env("LOOPCTL_RUNNER_FATAL_EXIT", "")) do
      {status, ""} when status in 0..255 -> status
      _ -> @ex_config
    end
  end

  @impl Slipstream
  def handle_continue(:connect, socket), do: connect_now(socket)

  @impl Slipstream
  def handle_connect(socket) do
    case fresh_join_payload(socket) do
      {:ok, payload} -> {:ok, join(socket, socket.assigns.topic, payload)}
      {:error, errors} -> fatal(socket, {:invalid_join_payload, errors})
    end
  end

  @impl Slipstream
  def handle_join(topic, response, socket) do
    Logger.info("loopctl runner joined #{topic}: #{inspect(response)}")

    {:ok,
     socket
     |> assign(joined: true, last_refusal: nil, connect_attempts: 0)
     |> schedule_status()}
  end

  @impl Slipstream
  def handle_topic_close(topic, {:failed_to_join, %{"reason" => reason} = response}, socket)
      when reason in @fatal_reasons do
    Logger.error("loopctl refused #{topic} (#{reason}): #{inspect(response)}")
    fatal(assign(socket, last_refusal: reason), {:join_refused, reason, response})
  end

  def handle_topic_close(topic, reason, socket) do
    Logger.warning("loopctl channel #{topic} closed: #{inspect(reason)}; rejoining")
    socket = socket |> cancel_status() |> assign(joined: false, last_refusal: refusal(reason))

    with {:ok, payload} <- fresh_join_payload(socket),
         {:ok, socket} <- rejoin(socket, topic, payload) do
      {:ok, socket}
    else
      {:error, errors} when is_list(errors) -> fatal(socket, {:invalid_join_payload, errors})
      # Disconnected meanwhile: the reconnect path will join again, freshly.
      {:error, _} -> {:ok, socket}
    end
  end

  defp refusal({:failed_to_join, %{"reason" => reason}}), do: reason
  defp refusal(_), do: nil

  @impl Slipstream
  def handle_disconnect(reason, socket) do
    Logger.warning("loopctl socket disconnected: #{inspect(reason)}")
    {:ok, socket |> cancel_status() |> assign(joined: false) |> schedule_reconnect()}
  end

  @impl Slipstream
  def handle_info(:reconnect, socket), do: connect_now(socket)

  def handle_info(:status, %{assigns: %{joined: true}} = socket) do
    socket = assign(socket, status_timer: nil)

    case status_payload(
           socket.assigns.config,
           socket.assigns.draining,
           socket.assigns.accepts_dispatches
         ) do
      {:ok, payload} ->
        {:ok, _ref} = push(socket, socket.assigns.topic, "status", payload)
        {:noreply, schedule_status(socket)}

      {:error, errors} ->
        fatal(socket, {:invalid_status_payload, errors})
    end
  end

  def handle_info(:status, socket), do: {:noreply, assign(socket, status_timer: nil)}

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl Slipstream
  def handle_cast({:set_draining, draining?}, socket) do
    send(self(), :status)
    {:noreply, socket |> assign(draining: draining?) |> cancel_status()}
  end

  @impl Slipstream
  def handle_call(:info, _from, socket) do
    info =
      Map.take(socket.assigns, [:joined, :draining, :connect_attempts, :last_refusal, :topic])

    {:reply, info, socket}
  end

  # A status that landed inside loopctl's 1s floor is sent again once the floor has passed,
  # so a change such as draining is delayed, never dropped until the next tick.
  @impl Slipstream
  def handle_reply(_ref, {:error, %{"reason" => "rate_limited"} = reply}, socket) do
    retry_ms = Map.get(reply, "min_interval_ms", 1_000)
    Logger.info("loopctl rate-limited a status push; resending in #{retry_ms}ms")
    socket = cancel_status(socket)
    {:ok, assign(socket, status_timer: Process.send_after(self(), :status, retry_ms))}
  end

  def handle_reply(_ref, {:error, %{"reason" => reason} = reply}, socket) do
    Logger.warning("loopctl refused a push (#{reason}): #{inspect(reply)}")
    {:ok, socket}
  end

  def handle_reply(_ref, _reply, socket), do: {:ok, socket}

  @impl Slipstream
  def handle_message(_topic, "dispatch", payload, socket) do
    case Contract.validate("RunnerDispatch", payload) do
      :ok ->
        Logger.warning(
          "dispatch #{payload["dispatch_id"]} refused: this runner accepts no dispatches yet"
        )

      {:error, errors} ->
        Logger.warning("malformed dispatch ignored: #{inspect(errors)}")
    end

    {:ok, socket}
  end

  # Contract minor versions add optional fields and events; unknown ones are ignored.
  def handle_message(_topic, _event, _payload, socket), do: {:ok, socket}

  defp fresh_join_payload(socket) do
    a = socket.assigns
    join_payload(a.config, a.capacity, a.draining, a.accepts_dispatches)
  end

  # The token is re-read on every attempt, so a corrected file is picked up without a
  # restart. An unreadable one is retried a few times (a rewrite in progress), then fatal.
  defp connect_now(socket) do
    control = socket.assigns.control

    case ControlConfig.read_token(control) do
      {:ok, token} ->
        {:noreply,
         socket
         |> assign(token_failures: 0)
         |> connect!(
           uri: control.url,
           headers: [{"x-loopctl-runner-token", token}],
           rejoin_after_msec: @rejoin_backoff_ms,
           reconnect_after_msec: @reconnect_backoff_ms
         )}

      {:error, reason} ->
        failures = socket.assigns.token_failures + 1
        Logger.error("loopctl runner cannot read its token (#{failures}): #{reason}")
        socket = assign(socket, last_refusal: "token_unreadable", token_failures: failures)

        if failures >= @max_token_failures,
          do: fatal(socket, {:token_unreadable, reason}),
          else: {:noreply, schedule_reconnect(socket)}
    end
  end

  defp schedule_reconnect(socket) do
    attempt = socket.assigns.connect_attempts
    delay = Enum.at(@reconnect_backoff_ms, attempt, List.last(@reconnect_backoff_ms))
    Process.send_after(self(), :reconnect, delay)
    assign(socket, connect_attempts: attempt + 1)
  end

  defp fatal(socket, reason) do
    socket.assigns.on_fatal.(reason)
    {:stop, {:shutdown, reason}, socket}
  end

  defp schedule_status(socket) do
    socket = cancel_status(socket)
    interval = socket.assigns.control.status_interval_s * 1000
    assign(socket, status_timer: Process.send_after(self(), :status, interval))
  end

  defp cancel_status(%{assigns: %{status_timer: nil}} = socket), do: socket

  defp cancel_status(socket) do
    Process.cancel_timer(socket.assigns.status_timer)
    assign(socket, status_timer: nil)
  end
end
