defmodule LoopctlWeb.MergePreconditionControllerTest do
  @moduledoc """
  `POST /api/v1/stories/:id/merge-precondition` (issue #803, design §5 and §9).

  ## Why this module is `async: false` with committed rows

  The same reason `Loopctl.Delivery.MergePreconditionIntegrationTest` is, and its moduledoc
  has the measurement: the precondition reads the story on `AdminRepo` and the stage row on
  `Loopctl.Repo`, which are two separate sandbox owners with two separate transactions, so
  a sandboxed row one repo wrote is invisible to the other. A request that returns a
  VERDICT — the endpoint's whole purpose, and the only thing that would catch a verdict
  this controller cannot encode as JSON — therefore needs the rows committed.

  `Phoenix.ConnTest.dispatch/5` runs the endpoint in the CALLING process, so the
  `sandbox: false` connections this module checks out are the ones the request uses.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import Loopctl.Fixtures
  import Phoenix.ConnTest
  import Plug.Conn

  alias Ecto.Adapters.SQL.Sandbox
  alias Loopctl.AdminRepo
  alias Loopctl.Delivery.Stages
  alias Loopctl.Dispatches
  alias Loopctl.MockPullRequestSource
  alias Loopctl.Repo

  @endpoint LoopctlWeb.Endpoint

  @repo "acme/widgets"
  @head String.duplicate("a", 40)
  @base String.duplicate("b", 40)
  @repo_files ["priv/rates/2026.csv", "lib/widgets_web/router.ex", "lib/widgets/thing.ex"]

  setup_all do
    full_sweep()
    on_exit(&full_sweep/0)
    :ok
  end

  setup do
    # This module is on `ExUnit.Case`, so it gets none of ConnCase's default stubs, and the
    # request pipeline resolves the rate limiter, the clock and the secrets adapter through
    # Mox. `stub_all_defaults/0` is the shared set, called directly as the `:scale` modules
    # do. Global mode is safe in an `async: false` module.
    Mox.set_mox_global()
    Loopctl.DataCase.stub_all_defaults()
    stub_source(files: ["lib/widgets/thing.ex"], diffstat: %{files: 1, changed_lines: 3})

    # Both committed tenants are made HERE: `fixture(:committed_tenant)` runs its own
    # unboxed AdminRepo checkout, which cannot happen while this process holds the
    # `sandbox: false` connections below.
    tenant = fixture(:committed_tenant, %{})
    other_tenant = fixture(:committed_tenant, %{})
    :ok = Sandbox.checkout(Repo, sandbox: false)
    :ok = Sandbox.checkout(AdminRepo, sandbox: false)

    # `fixture(:committed_tenant)` writes the DEFAULT tier, `:agent_rooted`, and the
    # delivery loop is work-breakdown surface behind `RequireHumanAnchor`.
    human_anchor(tenant.id)
    human_anchor(other_tenant.id)

    ctx = tenant |> build_story() |> Map.put(:other_tenant_id, other_tenant.id)

    on_exit(fn ->
      purge_tenant(tenant.id)
      purge_tenant(other_tenant.id)
    end)

    Map.put(ctx, :conn, base_conn())
  end

  describe "the role gate" do
    test "an AGENT key is 403'd before any controller code runs", ctx do
      # The implementer's own key shape. An implementer asking whether its own work may
      # merge is the self-approval the product exists to prevent.
      {key, _} = fixture(:api_key, %{tenant_id: ctx.tenant_id, role: :agent})

      assert %{status: 403} = post_precondition(ctx, key)
      # Nothing was decided, so nothing was escalated.
      assert Stages.get(ctx.tenant_id, ctx.story_id).stage == :ci
    end

    test "an ORCHESTRATOR key is accepted", ctx do
      {key, _} = orchestrator_key(ctx)
      assert %{status: 200} = post_precondition(ctx, key)
    end

    test "an AGENT-ROOTED tenant is 403'd — the delivery loop is human-anchored surface", ctx do
      {1, _} =
        AdminRepo.query!("UPDATE tenants SET trust_tier = 'agent_rooted' WHERE id = $1", [
          Ecto.UUID.dump!(ctx.tenant_id)
        ])
        |> then(fn %{num_rows: n} -> {n, nil} end)

      {key, _} = orchestrator_key(ctx)

      assert %{status: 403} = post_precondition(ctx, key)
      assert Stages.get(ctx.tenant_id, ctx.story_id).stage == :ci
    end

    test "a USER key is accepted", ctx do
      {key, _} = fixture(:api_key, %{tenant_id: ctx.tenant_id, role: :user})
      assert %{status: 200} = post_precondition(ctx, key)
    end
  end

  describe "the verdict" do
    test "an allow renders the whole verdict and writes nothing", ctx do
      stub_source(files: ["lib/widgets/thing.ex"], diffstat: %{files: 1, changed_lines: 3})
      {key, _} = orchestrator_key(ctx)

      assert %{"data" => data} = ctx |> post_precondition(key) |> json_response(200)

      assert data["decision"] == "allow"
      assert data["reasons"] == []
      assert data["repo"] == @repo
      assert data["pr_number"] == 4242
      assert data["head_sha"] == @head
      assert data["merge_base_sha"] == @base
      assert data["custody"] == "ok"
      assert data["hard_bound"] == %{"max_files" => 12, "max_changed_lines" => 1000}
      assert data["gate_a"]["decision"] == "proceed"
      assert data["gate_b"]["outcome"] == "clear"
      assert data["gate_b"]["merge_precondition"] == true

      assert Stages.get(ctx.tenant_id, ctx.story_id).stage == :ci
    end

    test "a refusal renders every reason AND has already escalated the story", ctx do
      stub_source(files: ["lib/widgets_web/router.ex"], diffstat: %{files: 13, changed_lines: 3})
      {key, _} = orchestrator_key(ctx)

      assert %{"data" => data} = ctx |> post_precondition(key) |> json_response(200)

      assert data["decision"] == "refuse"
      kinds = Enum.map(data["reasons"], & &1["kind"])
      assert "gate_b" in kinds
      assert "hard_bound_files_exceeded" in kinds
      assert Enum.all?(data["reasons"], &is_binary(&1["detail"]))

      row = Stages.get(ctx.tenant_id, ctx.story_id)
      assert row.stage == :escalated
      assert row.escalation_reason =~ "merge_gate"
    end

    test "a refusal is 200 — an answer, not a request error", ctx do
      stub_source(files: ["lib/widgets_web/router.ex"], diffstat: %{files: 1, changed_lines: 3})
      {key, _} = orchestrator_key(ctx)

      assert %{status: 200} = post_precondition(ctx, key)
    end
  end

  describe "request validation" do
    test "a missing claim_epoch is 422 and decides nothing", ctx do
      {key, _} = orchestrator_key(ctx)

      response =
        ctx.conn
        |> auth(key)
        |> post("/api/v1/stories/#{ctx.story_id}/merge-precondition", %{
          "trio_outputs" => [trio(), trio(), trio()]
        })

      assert %{status: 422} = response
      assert Stages.get(ctx.tenant_id, ctx.story_id).stage == :ci
    end

    test "trio_outputs that is not an array is 422", ctx do
      {key, _} = orchestrator_key(ctx)

      response =
        ctx.conn
        |> auth(key)
        |> post("/api/v1/stories/#{ctx.story_id}/merge-precondition", %{
          "claim_epoch" => 0,
          "trio_outputs" => "three of them"
        })

      assert %{status: 422} = response
    end

    test "a MALFORMED trio inside the array reaches Gate A, which escalates it", ctx do
      # Not a 422: Gate A is what judges the trio, and a malformed one has to be RECORDED
      # as an escalation rather than handed back as a request error the loop retries past.
      {key, _} = orchestrator_key(ctx)

      response =
        ctx.conn
        |> auth(key)
        |> post("/api/v1/stories/#{ctx.story_id}/merge-precondition", %{
          "claim_epoch" => 0,
          "trio_outputs" => [%{"verdict" => "story"}]
        })

      assert %{"data" => data} = json_response(response, 200)
      assert data["decision"] == "refuse"
      assert Enum.any?(data["reasons"], &(&1["kind"] == "gate_a"))
      assert Stages.get(ctx.tenant_id, ctx.story_id).stage == :escalated
    end
  end

  describe "asking at the wrong moment" do
    test "an unknown story is 404", ctx do
      {key, _} = orchestrator_key(ctx)

      response =
        ctx.conn
        |> auth(key)
        |> post("/api/v1/stories/#{Ecto.UUID.generate()}/merge-precondition", body())

      assert %{status: 404} = response
    end

    test "a story that is not at the ci stage is 422", ctx do
      {:ok, {1, _}} =
        Repo.with_tenant(ctx.tenant_id, fn ->
          from(s in Loopctl.Delivery.StoryStage, where: s.story_id == ^ctx.story_id)
          |> Repo.update_all(set: [stage: :implementing])
        end)

      {key, _} = orchestrator_key(ctx)
      assert %{status: 422} = post_precondition(ctx, key)
    end
  end

  describe "tenant isolation" do
    test "a key of another tenant cannot reach this story", ctx do
      {key, _} = fixture(:api_key, %{tenant_id: ctx.other_tenant_id, role: :orchestrator})

      assert %{status: 404} = post_precondition(ctx, key)
      assert Stages.get(ctx.tenant_id, ctx.story_id).stage == :ci
    end
  end

  # -- helpers ---------------------------------------------------------------------------

  defp base_conn do
    build_conn()
    |> put_req_header("x-loopctl-last-known-sth", "0:AAAAAAAAAAAAAAAAAAAAAA")
  end

  defp auth(conn, raw_key), do: put_req_header(conn, "authorization", "Bearer #{raw_key}")

  defp post_precondition(ctx, key) do
    ctx.conn
    |> auth(key)
    |> post("/api/v1/stories/#{ctx.story_id}/merge-precondition", body())
  end

  defp body, do: %{"claim_epoch" => 0, "trio_outputs" => [trio(), trio(), trio()]}

  defp orchestrator_key(ctx) do
    agent = fixture(:agent, %{tenant_id: ctx.tenant_id, agent_type: :orchestrator})
    fixture(:api_key, %{tenant_id: ctx.tenant_id, role: :orchestrator, agent_id: agent.id})
  end

  defp trio do
    %{
      "verdict" => "story",
      "escalation_reasons" => [],
      "contradicts" => [],
      "confidence" => 0.9
    }
  end

  defp stub_source(opts) do
    Mox.stub(MockPullRequestSource, :pull_request, fn @repo, _number ->
      {:ok,
       %{
         state: "open",
         merged?: false,
         merge_sha: nil,
         head_sha: @head,
         merge_base_sha: @base,
         diffstat: Keyword.fetch!(opts, :diffstat),
         diff: {:ok, %{files: Keyword.get(opts, :files, []), renames: []}}
       }}
    end)

    Mox.stub(MockPullRequestSource, :repo_files, fn @repo, _ref -> {:ok, @repo_files} end)
  end

  defp build_story(tenant) do
    project = fixture(:project, %{tenant_id: tenant.id})
    epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
    agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})
    verifier_agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :orchestrator})

    fixture(:intake_source, %{
      tenant_id: tenant.id,
      project_id: project.id,
      repo_full_name: @repo
    })

    {:ok, %{dispatch: implementer}} =
      Dispatches.create_dispatch(tenant.id, %{role: :agent, agent_id: agent.id})

    {:ok, %{dispatch: verifier}} =
      Dispatches.create_dispatch(tenant.id, %{role: :orchestrator, agent_id: verifier_agent.id})

    story =
      fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id, project_id: project.id})
      |> Ecto.Changeset.change(%{
        agent_status: :reported_done,
        verified_status: :verified,
        assigned_agent_id: agent.id,
        implementer_dispatch_id: implementer.id,
        verifier_dispatch_id: verifier.id
      })
      |> AdminRepo.update!()

    fixture(:story_stage, %{
      tenant_id: tenant.id,
      story_id: story.id,
      stage: :ci,
      claim_epoch: 0,
      pr_number: 4242,
      head_sha: @head
    })

    %{tenant_id: tenant.id, project_id: project.id, story_id: story.id}
  end

  # See `Loopctl.Delivery.MergePreconditionIntegrationTest` for why each of these blocks the
  # sweep of a committed tenant.
  defp purge_tenant(tenant_id) do
    checkout_admin()
    purge_dependents("tenant_id = $1", [Ecto.UUID.dump!(tenant_id)])
  end

  defp full_sweep do
    Sandbox.unboxed_run(AdminRepo, fn ->
      purge_dependents(
        "tenant_id IN (SELECT id FROM tenants WHERE slug LIKE 'committed-runner-%')",
        []
      )
    end)

    sweep_committed_runner_tenants()
  end

  defp purge_dependents(predicate, params) do
    {:ok, :ok} =
      AdminRepo.transaction(fn ->
        AdminRepo.query!(
          "ALTER TABLE audit_chain DISABLE TRIGGER audit_chain_prevent_delete_trigger"
        )

        AdminRepo.query!("DELETE FROM audit_chain WHERE #{predicate}", params)

        AdminRepo.query!(
          "UPDATE stories SET implementer_dispatch_id = NULL, verifier_dispatch_id = NULL " <>
            "WHERE #{predicate}",
          params
        )

        AdminRepo.query!("DELETE FROM dispatches WHERE #{predicate}", params)
        AdminRepo.query!("DELETE FROM api_keys WHERE #{predicate}", params)

        AdminRepo.query!(
          "ALTER TABLE audit_chain ENABLE TRIGGER audit_chain_prevent_delete_trigger"
        )

        :ok
      end)

    :ok
  end

  defp human_anchor(tenant_id) do
    {1, _} =
      AdminRepo.query!("UPDATE tenants SET trust_tier = 'human_anchored' WHERE id = $1", [
        Ecto.UUID.dump!(tenant_id)
      ])
      |> then(fn %{num_rows: n} -> {n, nil} end)

    :ok
  end

  defp checkout_admin do
    case Sandbox.checkout(AdminRepo, sandbox: false) do
      :ok -> :ok
      {:already, :owner} -> :ok
    end
  end
end
