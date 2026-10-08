defmodule LoopctlWeb.ChannelCase do
  @moduledoc """
  The test case for Phoenix channel tests (issue #801, the runner channel).

  Same sandbox, Mox and default-stub setup as `LoopctlWeb.ConnCase`, with
  `Phoenix.ChannelTest` imported instead of `Phoenix.ConnTest`. Channel processes started
  by `connect/3` and `subscribe_and_join/3` inherit the test's `$callers`, so their DB
  calls run on the test's sandbox connection under `async: true`.
  """

  use ExUnit.CaseTemplate

  alias Loopctl.ApiSpec.RunnerContract
  alias LoopctlWeb.RunnerSocket

  using do
    quote do
      @endpoint LoopctlWeb.Endpoint

      import Phoenix.ChannelTest
      import LoopctlWeb.ChannelCase
      import Loopctl.Fixtures
      import Mox
    end
  end

  setup tags do
    sandbox = Loopctl.DataCase.setup_sandbox(tags)
    Mox.set_mox_from_context(tags)
    Loopctl.DataCase.stub_all_defaults()
    {:ok, sandbox}
  end

  @doc """
  The bound on a runner channel round trip (a reply, a push, an `eventually/2` poll). A BOUND,
  never a delay: the assertion returns the moment the reply lands. 10 s because the runner
  channel modules run in the async phase of the full suite, where a reply that waits on a
  database transaction missed a 2 s bound (commit gate, 2026-10-07).
  """
  @spec reply_timeout() :: pos_integer()
  def reply_timeout, do: 10_000

  @doc "The connect info a runner presents: its token header and a loopback peer."
  @spec runner_connect_info(String.t()) :: map()
  def runner_connect_info(token) do
    %{
      x_headers: [{RunnerSocket.token_header(), token}],
      peer_data: %{address: {127, 0, 0, 1}, port: 40_000, ssl_cert: nil}
    }
  end

  @doc "Connects `LoopctlWeb.RunnerSocket` with `token`."
  defmacro connect_runner_socket(token) do
    quote do
      connect(LoopctlWeb.RunnerSocket, %{},
        connect_info: LoopctlWeb.ChannelCase.runner_connect_info(unquote(token))
      )
    end
  end

  @doc "A conforming join payload for a runner on `machine`, with `overrides` merged in."
  @spec runner_join_payload(String.t(), map()) :: map()
  def runner_join_payload(machine, overrides \\ %{}) do
    Map.merge(
      %{
        "contract_version" => RunnerContract.version(),
        "machine" => machine,
        "cores" => 16,
        "memory_mb" => 28_000,
        "repos" => ["mkreyman/home_care_billing"],
        "max_sessions" => 2,
        "in_flight" => 0,
        "draining" => false
      },
      overrides
    )
  end

  @doc """
  Polls `fun` until it returns a truthy value or `timeout_ms` elapses, and returns the
  last value. For state that converges asynchronously, like a Presence entry removed
  when its tracked process exits.
  """
  @spec eventually((-> term()), non_neg_integer()) :: term()
  def eventually(fun, timeout_ms \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_eventually(fun, deadline)
  end

  defp do_eventually(fun, deadline) do
    case fun.() do
      falsy when falsy in [nil, false] ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(10)
          do_eventually(fun, deadline)
        else
          falsy
        end

      truthy ->
        truthy
    end
  end
end
