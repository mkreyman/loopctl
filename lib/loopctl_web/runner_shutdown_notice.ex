defmodule LoopctlWeb.RunnerShutdownNotice do
  @moduledoc """
  Tells every runner connected to a stopping node why its socket is about to close
  (issue #815).

  On shutdown Phoenix's socket drainer sends `phx_drain` to each channel, and
  `Phoenix.Channel.Server` handles that message itself — the channel's own code never sees
  it — by closing the transport. So the notice goes out one step earlier: the drainer emits
  `[:phoenix, :socket_drain]` synchronously, before it sends a single `phx_drain`, and this
  handler turns that event, for `LoopctlWeb.RunnerSocket`, into a node-local
  `:server_shutdown` broadcast. Each runner channel pushes `disconnecting` with reason
  `server_shutdown` when it receives it.

  The handler then waits `@grace_ms` before returning, so the channels push while their
  transports are still open. It runs only when the runner socket is being drained, once per
  drain batch, so it lengthens a shutdown by at most that grace per batch. That requires a
  graceful stop at all: `fly.toml`'s `kill_signal = "SIGTERM"`.

  The topic and the grace are the handler's config (`attach/1`), so a test calls
  `handle_event/4` with its own topic instead of broadcasting to every runner on the node.
  """

  require Logger

  alias Loopctl.Runners

  @handler_id {__MODULE__, :socket_drain}
  @grace_ms 500

  @doc "Attaches the drain handler, broadcasting on `config.topic`. Idempotent."
  @spec attach(%{topic: String.t(), grace_ms: non_neg_integer()}) :: :ok
  def attach(config \\ default_config()) do
    :telemetry.detach(@handler_id)

    :ok =
      :telemetry.attach(
        @handler_id,
        [:phoenix, :socket_drain],
        &__MODULE__.handle_event/4,
        config
      )
  end

  @doc "The production config: the runner shutdown topic every runner channel subscribes to."
  @spec default_config() :: %{topic: String.t(), grace_ms: non_neg_integer()}
  def default_config, do: %{topic: Runners.shutdown_topic(), grace_ms: @grace_ms}

  @doc "The id the drain handler is attached under."
  @spec handler_id() :: term()
  def handler_id, do: @handler_id

  @doc "How long the drainer is held after the notice goes out."
  @spec grace_ms() :: non_neg_integer()
  def grace_ms, do: @grace_ms

  @doc false
  def handle_event(
        [:phoenix, :socket_drain],
        measurements,
        %{socket: LoopctlWeb.RunnerSocket},
        %{topic: topic, grace_ms: grace_ms}
      ) do
    Logger.info(
      "runner socket draining: node=#{Runners.node_name()} machine=#{inspect(Runners.machine_id())} " <>
        "sockets=#{inspect(Map.get(measurements, :count))}"
    )

    Phoenix.PubSub.local_broadcast(Loopctl.PubSub, topic, :server_shutdown)
    Process.sleep(grace_ms)
  end

  def handle_event(_event, _measurements, _metadata, _config), do: :ok
end
