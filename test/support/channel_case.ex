defmodule LoopctlWeb.ChannelCase do
  @moduledoc """
  The test case for Phoenix channel tests (issue #801, the runner channel).

  Same sandbox, Mox and default-stub setup as `LoopctlWeb.ConnCase`, with
  `Phoenix.ChannelTest` imported instead of `Phoenix.ConnTest`. Channel processes started
  by `connect/3` and `subscribe_and_join/3` inherit the test's `$callers`, so their DB
  calls run on the test's sandbox connection under `async: true`.
  """

  use ExUnit.CaseTemplate

  import Ecto.Query, only: [from: 2]

  alias Loopctl.AdminRepo
  alias Loopctl.Runners
  alias Loopctl.Runners.Runner

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

  @doc "Connects `LoopctlWeb.RunnerSocket` with `token` (`build(:runner_connect_info, ...)`)."
  defmacro connect_runner_socket(token) do
    quote do
      connect(LoopctlWeb.RunnerSocket, %{},
        connect_info: Loopctl.Fixtures.build(:runner_connect_info, %{token: unquote(token)})
      )
    end
  end

  @doc "The runner's own channel topic."
  @spec runner_topic(Phoenix.Socket.t()) :: String.t()
  def runner_topic(socket), do: "runner:" <> socket.assigns.runner.id

  @doc """
  Joins the runner's channel declaring `overrides` and waits for `:after_join` (the Presence
  track). Returns `{reply, channel}`. A macro, like `connect_runner_socket/1`, because the
  channel test helpers it calls belong to the test module.
  """
  defmacro join_pool(socket, machine, overrides \\ quote(do: %{})) do
    quote do
      socket = unquote(socket)

      {:ok, reply, channel} =
        subscribe_and_join(
          socket,
          LoopctlWeb.ChannelCase.runner_topic(socket),
          Loopctl.Fixtures.build(
            :runner_join_payload,
            Map.put(unquote(overrides), "machine", unquote(machine))
          )
        )

      _ = :sys.get_state(channel.channel_pid)
      {reply, channel}
    end
  end

  @doc "Whether a runner named `name` is in `tenant_id`'s pool."
  def in_pool?(tenant_id, name), do: Map.has_key?(Runners.pool(tenant_id), name)

  @doc """
  The capacity loopctl DECIDES from, as Postgres holds it on the connection the channel writes
  on, not the meta the runner reported.
  """
  def held_capacity(runner) do
    AdminRepo.one!(
      from r in Runner,
        where: r.id == ^runner.id,
        select: %{
          max_sessions: r.max_sessions,
          in_flight: r.in_flight,
          enrolled_max_sessions: r.enrolled_max_sessions,
          updated_at: r.updated_at
        }
    )
  end

  @doc """
  The machine drops its socket and connects again declaring `overrides`. Capacity is
  per-CONNECTION, so a rejoin is the only way to change one. Returns the new channel.
  """
  defmacro rejoin(runner, raw, channel, overrides) do
    quote do
      runner = unquote(runner)
      channel = unquote(channel)
      Process.unlink(channel.channel_pid)
      ref = leave(channel)
      assert_reply ref, :ok, _, LoopctlWeb.ChannelCase.reply_timeout()

      assert LoopctlWeb.ChannelCase.eventually(
               fn -> not LoopctlWeb.ChannelCase.in_pool?(runner.tenant_id, "minis") end,
               LoopctlWeb.ChannelCase.reply_timeout()
             )

      {:ok, socket} = connect_runner_socket(unquote(raw))
      {_reply, channel} = join_pool(socket, "minis", unquote(overrides))
      channel
    end
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
