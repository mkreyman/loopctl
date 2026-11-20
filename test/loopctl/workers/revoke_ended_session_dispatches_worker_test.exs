defmodule Loopctl.Workers.RevokeEndedSessionDispatchesWorkerTest do
  @moduledoc """
  An implement session's key is revoked once its story has left that session, so it stops
  holding its runner agent's one-key-per-role slot (the 2026-11-20 e2e stall).
  """
  use Loopctl.DataCase, async: true

  import Ecto.Query
  import Loopctl.Fixtures

  alias Loopctl.AdminRepo
  alias Loopctl.Auth.ApiKey
  alias Loopctl.Delivery.StageMachine
  alias Loopctl.Dispatches
  alias Loopctl.Dispatches.Dispatch
  alias Loopctl.WorkBreakdown.Story
  alias Loopctl.Workers.RevokeEndedSessionDispatchesWorker, as: Worker

  @old -3_600

  # A runner, a story placed on it at `stage`, and the session dispatch minted for the
  # runner's agent, `age` seconds old. `implementer?` decides whether the story names it.
  defp session(tenant, stage, opts \\ []) do
    {_raw, runner} = fixture(:runner, tenant_id: tenant.id)
    story = fixture(:story, tenant_id: tenant.id)
    role = Keyword.get(opts, :role, :agent)

    {:ok, %{dispatch: dispatch}} =
      Dispatches.create_dispatch(tenant.id, %{
        role: role,
        agent_id: runner.agent_id,
        story_id: story.id
      })

    age = Keyword.get(opts, :age, @old)

    {1, _} =
      from(d in Dispatch, where: d.id == ^dispatch.id)
      |> AdminRepo.update_all(set: [created_at: DateTime.add(DateTime.utc_now(), age, :second)])

    if Keyword.get(opts, :implementer?, true) do
      {1, _} =
        from(s in Story, where: s.id == ^story.id)
        |> AdminRepo.update_all(set: [implementer_dispatch_id: dispatch.id])
    end

    if stage, do: stage_row(tenant, story, stage)

    AdminRepo.get!(Dispatch, dispatch.id)
  end

  # `escalated` carries a reason (the `story_stages_escalation_reason` CHECK).
  defp stage_row(tenant, story, stage) do
    reason = if stage == :escalated, do: [escalation_reason: "session escalated"], else: []

    fixture(
      :story_stage,
      [tenant_id: tenant.id, story_id: story.id, stage: stage] ++ reason
    )
  end

  defp revoked?(%Dispatch{id: id, api_key_id: key_id}) do
    d = AdminRepo.get!(Dispatch, id)
    k = AdminRepo.get!(ApiKey, key_id)
    d.revoked_at != nil and k.revoked_at != nil
  end

  defp run, do: :ok = Worker.perform(%Oban.Job{args: %{}})

  test "a session whose story escalated is revoked, key included" do
    tenant = fixture(:tenant)
    d = session(tenant, :escalated)

    run()

    assert revoked?(d)
  end

  test "terminal and deployed stories release their session, and so does a re-placed one" do
    tenant = fixture(:tenant)
    done = session(tenant, :done)
    deployed = session(tenant, :deployed)
    replaced = session(tenant, :implementing, implementer?: false)

    run()

    assert revoked?(done)
    assert revoked?(deployed)
    assert revoked?(replaced)
  end

  test "the story's live session keeps its key at every live stage" do
    tenant = fixture(:tenant)

    live =
      for stage <- StageMachine.in_flight_stages() ++ [:merged],
          do: session(tenant, stage)

    run()

    for d <- live, do: refute(revoked?(d), "a #{inspect(d.id)} session at a live stage")
  end

  test "a re-placed story keeps its new session's key and loses the superseded one" do
    tenant = fixture(:tenant)
    old = session(tenant, :implementing)

    {_raw, runner} = fixture(:runner, tenant_id: tenant.id)

    {:ok, %{dispatch: new}} =
      Dispatches.create_dispatch(tenant.id, %{
        role: :agent,
        agent_id: runner.agent_id,
        story_id: old.story_id
      })

    {1, _} =
      from(d in Dispatch, where: d.id == ^new.id)
      |> AdminRepo.update_all(set: [created_at: DateTime.add(DateTime.utc_now(), @old, :second)])

    {1, _} =
      from(s in Story, where: s.id == ^old.story_id)
      |> AdminRepo.update_all(set: [implementer_dispatch_id: new.id])

    run()

    assert revoked?(old)
    refute revoked?(AdminRepo.get!(Dispatch, new.id))
  end

  test "candidates rank within each tenant, so one tenant's backlog cannot fill the batch" do
    busy = fixture(:tenant)
    quiet = fixture(:tenant)
    for _ <- 1..3, do: session(busy, :escalated, age: -7_200)
    lone = session(quiet, :escalated)

    picked = Worker.candidates(DateTime.utc_now(), 2)

    assert length(picked) == 2
    assert lone.id in Enum.map(picked, & &1.id)
  end

  test "a dispatch younger than the placement window is left alone" do
    tenant = fixture(:tenant)
    fresh = session(tenant, :escalated, age: -60)

    run()

    refute revoked?(fresh)
  end

  test "a verifier's orchestrator dispatch and a story outside the delivery loop are left alone" do
    tenant = fixture(:tenant)
    verifier = session(tenant, :ci, role: :orchestrator, implementer?: false)
    no_stage = session(tenant, nil, implementer?: false)

    run()

    refute revoked?(verifier)
    refute revoked?(no_stage)
  end

  test "a story-scoped agent dispatch for an agent that is no runner's is left alone" do
    tenant = fixture(:tenant)
    agent = fixture(:agent, tenant_id: tenant.id)
    story = fixture(:story, tenant_id: tenant.id)
    stage_row(tenant, story, :escalated)

    {:ok, %{dispatch: d}} =
      Dispatches.create_dispatch(tenant.id, %{
        role: :agent,
        agent_id: agent.id,
        story_id: story.id
      })

    {1, _} =
      from(x in Dispatch, where: x.id == ^d.id)
      |> AdminRepo.update_all(set: [created_at: DateTime.add(DateTime.utc_now(), @old, :second)])

    run()

    refute revoked?(d)
  end

  test "sweeps every tenant, each revoke scoped to its own" do
    a = session(fixture(:tenant), :escalated)
    b = session(fixture(:tenant), :failed)

    run()

    assert revoked?(a)
    assert revoked?(b)
  end

  test "once revoked, the runner's agent can be minted a new key" do
    tenant = fixture(:tenant)
    d = session(tenant, :escalated)

    assert {:error, _} =
             Dispatches.create_dispatch(tenant.id, %{role: :agent, agent_id: d.agent_id})

    run()

    assert {:ok, _} = Dispatches.create_dispatch(tenant.id, %{role: :agent, agent_id: d.agent_id})
  end
end
