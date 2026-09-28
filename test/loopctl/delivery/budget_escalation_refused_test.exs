defmodule Loopctl.Delivery.BudgetEscalationRefusedTest do
  @moduledoc """
  US-44.3: `Loopctl.Delivery.RunnerStages.budget_escalation_refused/4`, the mapping from a
  refused budget escalation to what the runner is answered, and what it logs.

  The escalation's own clause in `take_budget_edge/6` sends every refusal that is not the
  row moving or the claim ending through this. A behavioural test of that clause needs a
  tenant hash chain that REFUSES an append, and none can be built: the only
  `:audit_chain_append_failed` `Stages.advance/4` produces comes from an entry changeset a
  caller breaks with a malformed lineage, and the escalation hard-codes an empty one; a
  chain the trigger rejects raises instead. So the mapping is asserted here, and the
  clause's wiring by the lock-busy test in `Loopctl.Delivery.SessionEndReleaseTest`, which
  reaches this function through `end_session/4`.

  `async: false` because two of these tests assert on what is logged at error, and
  `capture_log` collects EVERY process's logs. ExUnit runs sync modules one at a time after
  all the async ones, so nothing else is logging during the capture and the whole capture
  is this call's. In an async module, an unrelated test's error line landed in the capture
  and failed `log == ""` at random.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Loopctl.Delivery.RunnerStages

  @refused_session %{story_id: Ecto.UUID.generate()}
  @refused_msg %{dispatch_id: Ecto.UUID.generate()}

  test "a chain that refuses appends is answered PERMANENTLY, and logged at error" do
    log =
      capture_log([level: :error], fn ->
        assert {:error, :audit_chain_append_failed} =
                 RunnerStages.budget_escalation_refused(
                   :audit_chain_append_failed,
                   Ecto.UUID.generate(),
                   @refused_session,
                   @refused_msg
                 )
      end)

    assert log =~ "answered permanently"
  end

  test "a message fault is answered as the invalid payload it is, not as a retry" do
    assert {:error, {:invalid, ["invalid_transition"]}} =
             RunnerStages.budget_escalation_refused(
               :invalid_transition,
               Ecto.UUID.generate(),
               @refused_session,
               @refused_msg
             )
  end

  test "a lock that was not free is the one retry, and is not logged at error" do
    log =
      capture_log([level: :error], fn ->
        assert {:error, :busy} =
                 RunnerStages.budget_escalation_refused(
                   :busy,
                   Ecto.UUID.generate(),
                   @refused_session,
                   @refused_msg
                 )
      end)

    assert log == ""
  end
end
