defmodule Loopctl.SystemConfig.RefreshListenerTest do
  @moduledoc """
  The refresh cron runs on one node per tick; the listener is how every other node of the
  cluster re-reads the table. A second node cannot run here, so a refresh from a peer is
  the message a peer's worker broadcasts.
  """

  use Loopctl.DataCase, async: true

  alias Ecto.Adapters.SQL.Sandbox
  alias Loopctl.SystemConfig
  alias Loopctl.SystemConfig.RefreshListener

  setup do
    name = :"refresh_listener_#{System.unique_integer([:positive])}"
    pid = start_supervised!({RefreshListener, name: name})
    Sandbox.allow(Loopctl.AdminRepo, self(), pid)
    %{listener: pid}
  end

  test "a refresh broadcast from another node re-reads the table on this one", %{listener: pid} do
    # Uniquely keyed and written straight to the table, so only a refresh can cache it.
    setting = fixture(:system_config, value: 4242)
    assert SystemConfig.get_int(setting.key, -1) == -1

    # Sent to this listener only: a real broadcast would also reach the app's own listener,
    # which has no sandbox connection. The subscription is asserted in its own test.
    send(pid, {:system_config_refresh, :"loopctl-peer@fdaa::2"})

    _ = :sys.get_state(pid)
    assert SystemConfig.get_int(setting.key, -1) == 4242
  end

  test "this node's own broadcast is not re-read: its worker already refreshed", %{listener: pid} do
    setting = fixture(:system_config, value: 5151)

    send(pid, {:system_config_refresh, node()})
    _ = :sys.get_state(pid)

    assert SystemConfig.get_int(setting.key, -1) == -1
  end

  test "the listener is subscribed to the topic the worker broadcasts on", %{listener: pid} do
    subscribers =
      for {sub, _} <- Registry.lookup(Loopctl.PubSub, SystemConfig.refresh_topic()), do: sub

    assert pid in subscribers
  end
end
