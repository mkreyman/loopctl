defmodule LoopctlWeb.CoordinationRateCapsRemovedTest do
  @moduledoc """
  US-52.26 (TC-52.26.4, AC-52.26.5): the per-key coordination caps are gone. A holder
  credential sends more channel writes, locks and claims in one window than the old caps
  allowed (120 posts, 120 locks, 60 claims) and is never 429'd; none of the three
  controllers declares a rate plug any more.

  The limiter is a counting stub (post-increment per bucket, allow while count <= limit),
  so a cap that still checked its bucket would trip exactly as it did in production.
  """
  use LoopctlWeb.ConnCase, async: true

  alias Loopctl.Holders

  setup :verify_on_exit!

  @sth_header "0:AAAAAAAAAAAAAAAAAAAAAA"

  setup do
    {:ok, counts} = Agent.start_link(fn -> %{} end)

    stub(Loopctl.MockRateLimiter, :check_rate, fn bucket, _window_ms, limit ->
      count =
        Agent.get_and_update(counts, fn m ->
          c = Map.get(m, bucket, 0) + 1
          {c, Map.put(m, bucket, c)}
        end)

      if count <= limit, do: {:allow, count}, else: {:deny, limit}
    end)

    tenant =
      fixture(:tenant, %{
        trust_tier: :human_anchored,
        settings: %{"rate_limit_tenant_requests_per_minute" => 1000}
      })

    project = fixture(:project, %{tenant_id: tenant.id})
    agent = fixture(:agent, %{tenant_id: tenant.id})

    # A writable member: membership is derived from a story assignment (US-40.D3).
    fixture(:story, %{
      tenant_id: tenant.id,
      project_id: project.id,
      assigned_agent_id: agent.id,
      agent_status: :assigned
    })

    {:ok, %{raw_key: raw}} =
      Holders.register(tenant.id, agent.id, %{
        "kind" => "interactive",
        "session_id" => "s1",
        "host" => "minis"
      })

    %{raw: raw, project: project, counts: counts}
  end

  defp post_json(raw, path, params) do
    build_conn()
    |> put_req_header("x-loopctl-last-known-sth", @sth_header)
    |> put_req_header("authorization", "Bearer #{raw}")
    |> post(path, params)
  end

  test "121 channel writes from one holder credential in a window: none is 429", ctx do
    statuses =
      for n <- 1..121 do
        post_json(ctx.raw, "/api/v1/channel/posts", %{
          "project_id" => ctx.project.id,
          "body" => "status #{n}"
        }).status
      end

    assert Enum.all?(statuses, &(&1 == 201)), inspect(Enum.frequencies(statuses))
  end

  test "121 lock writes: none is 429", ctx do
    statuses =
      for n <- 1..121 do
        post_json(ctx.raw, "/api/v1/channel/locks", %{
          "project_id" => ctx.project.id,
          "target" => "lib/f#{n}.ex",
          "session_id" => "s1"
        }).status
      end

    assert Enum.all?(statuses, &(&1 in [200, 201])), inspect(Enum.frequencies(statuses))
  end

  test "61 claims on distinct refs: none is 429", ctx do
    statuses =
      for n <- 1..61 do
        post_json(ctx.raw, "/api/v1/channel/claims", %{
          "project_id" => ctx.project.id,
          "ref" => "handoff:repo##{n}"
        }).status
      end

    # The concurrent-claim budget (409 claim_budget_exhausted) still applies: it limits
    # open claims, not request rate. What must be absent is a 429.
    refute 429 in statuses, inspect(Enum.frequencies(statuses))
    assert Enum.count(statuses, &(&1 == 201)) >= 50
  end

  test "no coordination bucket is ever counted; the tenant bucket is", ctx do
    post_json(ctx.raw, "/api/v1/channel/posts", %{"project_id" => ctx.project.id, "body" => "x"})

    buckets = Agent.get(ctx.counts, &Map.keys/1)
    assert Enum.any?(buckets, &String.starts_with?(&1, "tenant:"))
    refute Enum.any?(buckets, &String.starts_with?(&1, "channel_"))
    refute Enum.any?(buckets, &String.starts_with?(&1, "key:"))
  end

  test "none of the three controllers declares a rate plug" do
    for path <- [
          "lib/loopctl_web/controllers/channel_post_controller.ex",
          "lib/loopctl_web/controllers/channel_lock_controller.ex",
          "lib/loopctl_web/controllers/channel_claim_controller.ex"
        ] do
      source = File.read!(path)
      plugs = Regex.scan(~r/^\s*plug\s+(\S+)/m, source, capture: :all_but_first)

      # Non-vacuous: the scan finds each controller's RequireRole plug.
      assert ["LoopctlWeb.Plugs.RequireRole,"] in plugs, path
      refute Enum.any?(plugs, fn [name] -> name =~ "rate_limit" end), path
      refute source =~ "Loopctl.RateLimiter", path
    end
  end
end
