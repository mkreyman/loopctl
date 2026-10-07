defmodule Loopctl.TelemetryHelpers do
  @moduledoc """
  RECEIVE-UNTIL-MATCH for telemetry assertions in `async: true` tests.

  ## Why `assert_receive` on the first event is a flake

  `:telemetry_test.attach_event_handlers/2` installs a GLOBAL (VM-wide) handler.
  The `^ref` pin does NOT scope it to the calling test: the handler IS this test's
  own, and it forwards EVERY process's emission of that event carrying that ref.
  So under `async: true`, a concurrent test enabling `local_only` (or triggering a
  blocked decision) for ITS tenant delivers the first message, and an
  `assert_receive` that asserts on that first message fails — order- and
  timing-dependently, i.e. only on some seeds.

  `receive_matching/4` drains messages until one SATISFIES the predicate (normally
  "this event is for MY tenant"), so a foreign test's event is skipped instead of
  failing the assertion.
  """

  import ExUnit.Assertions

  @default_timeout 1_000

  @doc """
  Attaches a handler for `events` that forwards ONLY the emissions this test caused, and
  returns the ref the forwarded messages carry.

  Messages have the `:telemetry_test` shape — `{event, ref, measurements, metadata}` — so
  `assert_receive`/`refute_received` patterns written for `attach_event_handlers/2` work
  unchanged. A telemetry handler runs synchronously in the EMITTING process, so the handler
  can tell whose emission it is: it forwards when that process is the attaching test, or a
  process the test started (`Task`s record their starter in `:"$callers"`). That is the key
  only this test produces, which is what lets a `refute_received` on an event with no tenant
  in its metadata (`[:loopctl, :llm, :provider_error]`) run beside other tests emitting it.

  The handler id is unique per call and detached when the test exits.
  """
  @spec attach_own([[atom()]]) :: reference()
  def attach_own(events) do
    ref = make_ref()
    handler_id = {__MODULE__, ref}
    config = %{pid: self(), ref: ref}

    :ok = :telemetry.attach_many(handler_id, events, &__MODULE__.forward_own/4, config)
    ExUnit.Callbacks.on_exit(fn -> :telemetry.detach(handler_id) end)

    ref
  end

  @doc false
  def forward_own(event, measurements, metadata, %{pid: pid, ref: ref}) do
    if self() == pid or pid in Process.get(:"$callers", []) do
      send(pid, {event, ref, measurements, metadata})
    end

    :ok
  end

  @doc """
  Waits for a `:telemetry_test` message for `event`/`ref` whose METADATA satisfies
  `match_fun`, and returns `{measurements, metadata}`.

  Messages for the same event from OTHER concurrent tests are drained and ignored.
  """
  @spec receive_matching(
          [atom()],
          reference(),
          (map() -> boolean()),
          non_neg_integer()
        ) :: {map(), map()}
  def receive_matching(event, ref, match_fun, timeout \\ @default_timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_receive_matching(event, ref, match_fun, deadline)
  end

  defp do_receive_matching(event, ref, match_fun, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^event, ^ref, measurements, metadata} ->
        if match_fun.(metadata) do
          {measurements, metadata}
        else
          do_receive_matching(event, ref, match_fun, deadline)
        end
    after
      remaining ->
        flunk("no matching #{inspect(event)} telemetry event within the timeout")
    end
  end

  @doc """
  Counts matching `:telemetry_test` messages for `event`/`ref` already in the
  mailbox (non-blocking drain), ignoring other tests' events for the same event.
  """
  @spec count_matching([atom()], reference(), (map() -> boolean())) :: non_neg_integer()
  def count_matching(event, ref, match_fun), do: do_count(event, ref, match_fun, 0)

  defp do_count(event, ref, match_fun, acc) do
    receive do
      {^event, ^ref, _measurements, metadata} ->
        do_count(event, ref, match_fun, if(match_fun.(metadata), do: acc + 1, else: acc))
    after
      0 -> acc
    end
  end
end
