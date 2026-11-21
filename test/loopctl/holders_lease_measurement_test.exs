defmodule Loopctl.HoldersLeaseMeasurementTest do
  @moduledoc """
  TC-52.19.8: the holder lease defaults shipped in `Loopctl.Holders` are the ones the
  measurement recorded, and the lease is five heartbeat intervals.
  """

  use ExUnit.Case, async: true

  alias Loopctl.Holders

  @doc_path Path.expand("../../docs/factory/measurements/session-holder-lease.md", __DIR__)

  defp recorded(name) do
    [_, value] = Regex.run(~r/^#{name}: (\d+)$/m, File.read!(@doc_path))
    String.to_integer(value)
  end

  test "the shipped defaults are the measured ones, and lease = 5 x heartbeat" do
    heartbeat = recorded("HOLDER_HEARTBEAT_SECONDS")
    lease = recorded("HOLDER_LEASE_SECONDS")

    assert Holders.default_heartbeat_seconds() == heartbeat
    assert Holders.default_lease_seconds() == lease
    assert lease == 5 * heartbeat
  end
end
