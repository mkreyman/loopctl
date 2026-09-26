defmodule LoopctlWeb.ThreadReviewControllerTest do
  @moduledoc """
  US-45.3: the review endpoints. The authority, the rounds and the ceiling are tested in
  `Loopctl.Threads.ReviewsTest`; this module pins the HTTP surface — the role gates, the
  status codes, the refusal codes and the untrusted markers.

  `async: false` and COMMITTED, for the reason `Loopctl.Threads.ReviewsTest` gives: a
  placement mints on `AdminRepo` while the thread is written on the RLS `Repo`, and both append
  to the tenant's audit chain. Every request runs through `unboxed/1`.
  """

  use LoopctlWeb.ConnCase, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Loopctl.AdminRepo
  alias Loopctl.Repo
  alias Loopctl.Tenants.Tenant
  alias Loopctl.Threads

  setup :verify_on_exit!

  setup_all do
    sweep_committed_runner_tenants()
    on_exit(&sweep_committed_runner_tenants/0)
    :ok
  end

  @tree String.duplicate("e", 40)

  setup do
    tenant = fixture(:committed_tenant, %{trust_tier: :human_anchored})
    ctx = fixture(:review_story, %{tenant_id: tenant.id, claim_epoch: 5})
    {operator_raw, _operator} = fixture(:committed_operator_key, %{tenant_id: tenant.id})
    {:ok, Map.put(ctx, :operator_raw, operator_raw)}
  end

  defp unboxed(fun) do
    Sandbox.unboxed_run(AdminRepo, fn -> Sandbox.unboxed_run(Repo, fun) end)
  end

  defp auth(conn, raw_key), do: put_req_header(conn, "authorization", "Bearer #{raw_key}")

  defp post_as(raw_key, path, body) do
    unboxed(fn -> build_conn() |> auth(raw_key) |> post(path, body) end)
  end

  defp get_as(raw_key, path), do: unboxed(fn -> build_conn() |> auth(raw_key) |> get(path) end)

  defp checkpoint(ctx, n) do
    {:ok, cp, :created} =
      unboxed(fn ->
        Threads.record_checkpoint(ctx.tenant_id, ctx.story.id,
          agent_id: ctx.implementer.id,
          claim_epoch: ctx.epoch,
          commit_sha: String.pad_leading(Integer.to_string(n), 40, "0"),
          tree_sha: @tree,
          author_principal: "agent:#{ctx.implementer.id}",
          actor_lineage: ctx.session.lineage_path
        )
      end)

    cp
  end

  defp place(ctx, raw_key \\ nil) do
    post_as(raw_key || ctx.orch_raw, "/api/v1/stories/#{ctx.story.id}/thread/reviews", %{
      "agent_id" => ctx.reviewer.id
    })
  end

  defp placed!(ctx) do
    %{"raw_key" => raw, "review" => review} = ctx |> place() |> json_response(201)
    {raw, review}
  end

  defp finding(ctx, raw_key, attrs \\ %{}) do
    post_as(
      raw_key,
      "/api/v1/stories/#{ctx.story.id}/thread/findings",
      Map.merge(
        %{"idempotency_key" => "f1", "body" => "breaks on retry", "severity" => "high"},
        attrs
      )
    )
  end

  defp verdict(ctx, raw_key) do
    post_as(raw_key, "/api/v1/stories/#{ctx.story.id}/thread/verdicts", %{
      "idempotency_key" => "v-#{:erlang.phash2(raw_key)}",
      "body" => "changes requested"
    })
  end

  test "an orchestrator places a review: 201 with the key, once; an agent key is 403", ctx do
    checkpoint(ctx, 1)

    assert ctx |> place(ctx.impl_raw) |> json_response(403)

    assert %{"raw_key" => raw, "review" => %{"round" => 1, "agent_id" => agent_id}} =
             ctx |> place() |> json_response(201)

    assert is_binary(raw)
    assert agent_id == ctx.reviewer.id
  end

  test "placement refusals carry their own codes", ctx do
    assert %{"error" => %{"code" => "no_checkpoint"}} = ctx |> place() |> json_response(409)

    checkpoint(ctx, 1)

    assert %{"error" => %{"code" => "reviewer_not_separate"}} =
             ctx.orch_raw
             |> post_as("/api/v1/stories/#{ctx.story.id}/thread/reviews", %{
               "agent_id" => ctx.implementer.id
             })
             |> json_response(409)

    assert %{"error" => %{"code" => "invalid_agent_id"}} =
             ctx.orch_raw
             |> post_as("/api/v1/stories/#{ctx.story.id}/thread/reviews", %{"agent_id" => "x"})
             |> json_response(422)

    unboxed(fn ->
      AdminRepo.update_all(from(t in Tenant, where: t.id == ^ctx.tenant_id),
        set: [custody_halted_at: DateTime.utc_now()]
      )
    end)

    assert %{"error" => %{"code" => "tenant_halted"}} = ctx |> place() |> json_response(503)
  end

  test "only the review dispatch's key writes a finding; never self_review_blocked", ctx do
    cp = checkpoint(ctx, 1)
    {raw, review} = placed!(ctx)

    refused = ctx |> finding(ctx.impl_raw) |> json_response(403)
    assert %{"error" => %{"code" => "review_dispatch_required"}} = refused
    refute inspect(refused) =~ "self_review_blocked"

    # exact_role: :agent — a user key never reaches the context.
    assert %{"error" => %{"code" => "insufficient_role"}} =
             ctx |> finding(ctx.operator_raw) |> json_response(403)

    assert %{"entry" => entry} =
             ctx |> finding(raw, %{"location" => "a.ex:1"}) |> json_response(201)

    assert entry["kind"] == "finding"
    assert entry["severity"] == "high"
    assert entry["review_id"] == review["id"]
    assert entry["checkpoint_id"] == cp.id
    assert entry["body_untrusted"] == true
    assert entry["location_untrusted"] == true

    assert %{"entry" => %{"id" => same}} =
             ctx |> finding(raw, %{"location" => "a.ex:1"}) |> json_response(200)

    assert same == entry["id"]

    assert %{"error" => %{"code" => "invalid_severity"}} =
             ctx
             |> finding(raw, %{"idempotency_key" => "f2", "severity" => "x"})
             |> json_response(422)
  end

  test "the verdict completes the round and closes the key", ctx do
    checkpoint(ctx, 1)
    {raw, _review} = placed!(ctx)

    assert %{"entry" => %{"kind" => "verdict"}, "escalation" => nil} =
             ctx |> verdict(raw) |> json_response(201)

    assert ctx |> verdict(raw) |> json_response(401)

    %{"entries" => entries} =
      ctx.orch_raw |> get_as("/api/v1/stories/#{ctx.story.id}/thread") |> json_response(200)

    assert %{"review_id" => review_id} = Enum.find(entries, &(&1["kind"] == "verdict"))
    assert is_binary(review_id)
  end

  test "the claimant records a fix; the review payload carries it with its finding", ctx do
    checkpoint(ctx, 1)
    {raw, _review} = placed!(ctx)
    %{"entry" => %{"id" => finding_id}} = ctx |> finding(raw) |> json_response(201)
    ctx |> verdict(raw) |> json_response(201)
    cp2 = checkpoint(ctx, 2)

    fix = %{
      "claim_epoch" => ctx.epoch,
      "checkpoint_id" => cp2.id,
      "finding_ids" => [finding_id],
      "idempotency_key" => "x1",
      "body" => "retried idempotently"
    }

    path = "/api/v1/stories/#{ctx.story.id}/thread/fixes"
    assert post_as(ctx.impl_raw, path, Map.delete(fix, "claim_epoch")) |> json_response(400)
    assert post_as(ctx.orch_raw, path, fix) |> json_response(403)

    assert %{"entry" => %{"kind" => "fix", "finding_ids" => [^finding_id]}} =
             post_as(ctx.impl_raw, path, fix) |> json_response(201)

    %{"review" => %{"id" => review_id}} = ctx |> place() |> json_response(201)

    payload =
      ctx.impl_raw
      |> get_as("/api/v1/stories/#{ctx.story.id}/thread/reviews/#{review_id}")
      |> json_response(200)

    assert %{"review" => %{"round" => 2}, "checkpoint" => %{"commit_sha" => sha}} = payload
    assert sha == cp2.commit_sha

    assert [%{"fix" => %{"kind" => "fix"}, "findings" => [%{"id" => ^finding_id}]}] =
             payload["fixes"]

    assert Enum.all?(payload["entries"], & &1["body_untrusted"])

    assert get_as(ctx.impl_raw, "/api/v1/stories/#{ctx.story.id}/thread/reviews/nope")
           |> json_response(404)
  end

  test "the ceiling is a 409 of its own", ctx do
    checkpoint(ctx, 1)
    {raw1, _} = placed!(ctx)
    ctx |> finding(raw1) |> json_response(201)
    ctx |> verdict(raw1) |> json_response(201)

    {raw2, _} = placed!(ctx)

    ctx
    |> finding(raw2, %{"idempotency_key" => "f2", "introduced_by" => "none", "severity" => "low"})
    |> json_response(201)

    assert %{"escalation" => nil} = ctx |> verdict(raw2) |> json_response(201)

    assert %{"error" => %{"code" => "review_ceiling_reached"}} =
             ctx |> place() |> json_response(409)
  end
end
