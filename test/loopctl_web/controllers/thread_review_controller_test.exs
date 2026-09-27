defmodule LoopctlWeb.ThreadReviewControllerTest do
  @moduledoc """
  US-45.3: the review endpoints — requesting a review, reading its payload, recording a fix.
  The rules are in `Loopctl.Threads.ReviewsTest` and the push in
  `Loopctl.Delivery.ReviewPlacementTest`; this pins the HTTP surface: role gates, statuses,
  refusal codes and the untrusted markers. There is no endpoint for a finding or a verdict.

  `async: false` for the reason `LoopctlWeb.ThreadControllerTest` gives: keys resolve on
  `AdminRepo` and the story lives on the RLS `Repo`, so the tenant and the keys are committed.
  """

  use LoopctlWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.ChannelTest, only: [subscribe_and_join: 3]

  require Phoenix.ChannelTest

  alias Loopctl.ApiSpec.RunnerContract
  alias Loopctl.Repo
  alias Loopctl.Threads
  alias Loopctl.WorkBreakdown.Story
  alias LoopctlWeb.RunnerSocket

  setup :verify_on_exit!

  setup_all do
    sweep_committed_runner_tenants()
    on_exit(&sweep_committed_runner_tenants/0)
    :ok
  end

  @epoch 4
  @tree String.duplicate("e", 40)

  setup do
    tenant = fixture(:committed_tenant, %{trust_tier: :human_anchored})
    {impl_raw, _impl_key, implementer} = fixture(:committed_agent_key, %{tenant_id: tenant.id})
    {operator_raw, _operator} = fixture(:committed_operator_key, %{tenant_id: tenant.id})
    {runner_raw, runner} = fixture(:committed_runner, %{tenant_id: tenant.id, name: "reviewer"})
    story = fixture(:ledger_story, %{tenant_id: tenant.id, claim_epoch: @epoch})
    session = fixture(:stage_dispatch, %{tenant_id: tenant.id, agent_id: implementer.id})

    {:ok, _} =
      Repo.with_tenant(tenant.id, fn ->
        from(s in Story, where: s.id == ^story.id)
        |> Repo.update_all(
          set: [
            assigned_agent_id: implementer.id,
            implementer_dispatch_id: session.id,
            agent_status: :implementing,
            claimed_until: DateTime.add(DateTime.utc_now(), 3_600)
          ]
        )
      end)

    %{
      tenant_id: tenant.id,
      story: story,
      impl_raw: impl_raw,
      implementer: implementer,
      operator_raw: operator_raw,
      runner: runner,
      runner_raw: runner_raw,
      session: session
    }
  end

  # The runner on a live socket declaring `review`, so a placement gets past the push's
  # pre-checks to the thread's own rules.
  defp join_runner(ctx) do
    {:ok, socket} =
      Phoenix.ChannelTest.connect(RunnerSocket, %{},
        connect_info: %{
          x_headers: [{RunnerSocket.token_header(), ctx.runner_raw}],
          peer_data: %{address: {127, 0, 0, 1}, port: 40_000, ssl_cert: nil}
        }
      )

    {:ok, _reply, channel} =
      subscribe_and_join(socket, "runner:" <> ctx.runner.id, %{
        "contract_version" => RunnerContract.version(),
        "machine" => "reviewer",
        "cores" => 4,
        "memory_mb" => 8_000,
        "repos" => ["acme/widgets"],
        "max_sessions" => 2,
        "in_flight" => 0,
        "draining" => false,
        "kinds" => ["implement", "review"]
      })

    _ = :sys.get_state(channel.channel_pid)
    channel
  end

  defp auth(conn, raw_key), do: put_req_header(conn, "authorization", "Bearer #{raw_key}")
  defp post_as(raw, path, body), do: build_conn() |> auth(raw) |> post(path, body)
  defp get_as(raw, path), do: build_conn() |> auth(raw) |> get(path)

  defp checkpoint(ctx, n) do
    {:ok, cp, :created} =
      Threads.record_checkpoint(ctx.tenant_id, ctx.story.id,
        agent_id: ctx.implementer.id,
        claim_epoch: @epoch,
        commit_sha: n |> Integer.to_string() |> String.pad_leading(40, "0"),
        tree_sha: @tree,
        author_principal: "agent:#{ctx.implementer.id}",
        actor_lineage: ctx.session.lineage_path
      )

    cp
  end

  # A review recorded (as a placement records it before the push), with one finding and a
  # verdict, for the read and the fix.
  defp judged_review(ctx) do
    reviewer = fixture(:stage_agent, %{tenant_id: ctx.tenant_id})

    {:ok, review, :created} =
      Threads.record_review(ctx.tenant_id, ctx.story.id,
        dispatch_id: Ecto.UUID.generate(),
        runner_id: reviewer.id,
        agent_id: reviewer.id,
        placed_by: "t"
      )

    judge = fn attrs ->
      {:ok, %{entry: entry}, :created} =
        Threads.record_judgement(ctx.tenant_id, ctx.story.id, review.dispatch_id, attrs,
          runner_id: reviewer.id,
          author_principal: "agent:#{reviewer.id}"
        )

      entry
    end

    finding =
      judge.(%{
        "kind" => "finding",
        "idempotency_key" => "f",
        "body" => "breaks",
        "severity" => "high",
        "location" => "a.ex:1"
      })

    judge.(%{"kind" => "verdict", "idempotency_key" => "v", "body" => "done"})
    %{review: review, finding: finding}
  end

  test "requesting a review needs an orchestrator key; the push's refusal is the review's", ctx do
    checkpoint(ctx, 1)
    path = "/api/v1/stories/#{ctx.story.id}/thread/reviews"
    body = %{"runner_id" => ctx.runner.id, "repo" => "acme/widgets", "base_branch" => "master"}

    assert %{"error" => %{"code" => "insufficient_role"}} =
             post_as(ctx.impl_raw, path, body) |> json_response(403)

    # The runner has no socket: nothing was claimed, and the same id pushes it later.
    assert %{"error" => %{"code" => "runner_not_connected", "message" => message}} =
             post_as(
               ctx.operator_raw,
               path,
               Map.merge(body, %{"wall_clock_seconds" => 600, "max_turns" => 20})
             )
             |> json_response(409)

    assert message =~ "Nothing was claimed"
  end

  test "a review placement refusal carries its own code", ctx do
    join_runner(ctx)
    path = "/api/v1/stories/#{ctx.story.id}/thread/reviews"

    assert %{"error" => %{"code" => "no_checkpoint"}} =
             post_as(ctx.operator_raw, path, %{
               "runner_id" => ctx.runner.id,
               "repo" => "acme/widgets",
               "base_branch" => "master",
               "wall_clock_seconds" => 600,
               "max_turns" => 20
             })
             |> json_response(409)
  end

  test "the payload marks bodies and locations untrusted, and the thread read does too", ctx do
    checkpoint(ctx, 1)
    %{review: review, finding: finding} = judged_review(ctx)

    payload =
      ctx.impl_raw
      |> get_as("/api/v1/stories/#{ctx.story.id}/thread/reviews/#{review.id}")
      |> json_response(200)

    assert %{"review" => %{"round" => 1}, "fixes_truncated" => false} = payload
    assert Enum.all?(payload["entries"], & &1["body_untrusted"])

    %{"entries" => entries} =
      ctx.impl_raw |> get_as("/api/v1/stories/#{ctx.story.id}/thread") |> json_response(200)

    assert %{"location" => "a.ex:1", "location_untrusted" => true, "severity" => "high"} =
             Enum.find(entries, &(&1["id"] == finding.id))

    assert get_as(ctx.impl_raw, "/api/v1/stories/#{ctx.story.id}/thread/reviews/nope")
           |> json_response(404)
  end

  test "the claimant records a fix; another key or no epoch is refused", ctx do
    checkpoint(ctx, 1)
    %{finding: finding} = judged_review(ctx)
    cp2 = checkpoint(ctx, 2)
    path = "/api/v1/stories/#{ctx.story.id}/thread/fixes"

    fix = %{
      "claim_epoch" => @epoch,
      "checkpoint_id" => cp2.id,
      "finding_ids" => [finding.id],
      "idempotency_key" => "x1",
      "body" => "retried idempotently"
    }

    assert post_as(ctx.impl_raw, path, Map.delete(fix, "claim_epoch")) |> json_response(400)
    assert post_as(ctx.operator_raw, path, fix) |> json_response(403)

    assert %{"entry" => %{"kind" => "fix", "finding_ids" => [id]}} =
             post_as(ctx.impl_raw, path, fix) |> json_response(201)

    assert id == finding.id
    assert post_as(ctx.impl_raw, path, fix) |> json_response(200)

    assert %{"error" => %{"code" => "unknown_finding"}} =
             post_as(ctx.impl_raw, path, %{
               fix
               | "finding_ids" => [Ecto.UUID.generate()],
                 "idempotency_key" => "x2"
             })
             |> json_response(422)
  end

  test "there is no HTTP path for a finding or a verdict", ctx do
    assert post_as(ctx.impl_raw, "/api/v1/stories/#{ctx.story.id}/thread/findings", %{})
           |> response(404)

    assert %{"error" => %{"message" => message}} =
             post_as(ctx.impl_raw, "/api/v1/stories/#{ctx.story.id}/thread/entries", %{
               "kind" => "verdict",
               "idempotency_key" => "v",
               "body" => "b"
             })
             |> json_response(422)

    assert message =~ "runner socket"
  end
end
