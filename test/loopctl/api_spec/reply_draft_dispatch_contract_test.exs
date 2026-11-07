defmodule Loopctl.ApiSpec.ReplyDraftDispatchContractTest do
  @moduledoc """
  US-48.9, runner contract 1.26.0: `reply_draft` is a dispatchable kind, and its dispatch
  carries the fenced intake report in the same `triage` object a triage dispatch does — it
  must carry it, and only those two kinds may.
  """

  use Loopctl.DataCase, async: true

  alias Loopctl.ApiSpec.RunnerContract
  alias Loopctl.ApiSpec.RunnerContract.Kinds
  alias Loopctl.Delivery.TriagePayload
  alias Loopctl.Intake

  setup do
    tenant = fixture(:tenant, %{trust_tier: :human_anchored})
    story = fixture(:set_aside_story, %{tenant_id: tenant.id})
    story = Loopctl.AdminRepo.get!(Loopctl.WorkBreakdown.Story, story.id)
    {:ok, record} = Intake.get_record(tenant.id, story.intake_record_id)
    {:ok, triage} = TriagePayload.build(record)
    triage = Map.new(triage, fn {k, v} -> {to_string(k), v} end)

    %{story: story, triage: triage}
  end

  defp dispatch(ctx, kind, attrs) do
    build(
      :runner_dispatch,
      Map.merge(
        %{"kind" => kind, "story_id" => ctx.story.id, "branch" => "master"},
        attrs
      )
    )
  end

  test "reply_draft is in the published and dispatchable kinds, sharing the fenced report" do
    assert "reply_draft" in Kinds.all()
    assert "reply_draft" in Kinds.dispatchable()
    assert Enum.sort(Kinds.fenced_report_kinds()) == ["reply_draft", "triage"]
    assert RunnerContract.version() == "1.26.0"
  end

  test "a reply_draft dispatch carrying the fenced report casts", ctx do
    assert {:ok, cast} =
             RunnerContract.cast_dispatch(dispatch(ctx, "reply_draft", %{"triage" => ctx.triage}))

    assert cast.kind == "reply_draft"
    assert cast.triage.untrusted =~ "UNTRUSTED DATA"
  end

  test "a reply_draft dispatch without it is refused, naming the kind", ctx do
    assert {:error, {:invalid, messages}} =
             RunnerContract.cast_dispatch(dispatch(ctx, "reply_draft", %{}))

    assert "a reply_draft dispatch must carry the triage object" in messages
  end

  test "an implement dispatch may still not carry it", ctx do
    assert {:error, {:invalid, messages}} =
             RunnerContract.cast_dispatch(dispatch(ctx, "implement", %{"triage" => ctx.triage}))

    assert Enum.any?(messages, &(&1 =~ "triage is only allowed when kind is"))
  end
end
