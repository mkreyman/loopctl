defmodule Loopctl.Knowledge.InfraTrafficExcludedTest do
  @moduledoc """
  #673: `scripts/smoke.sh` issues two searches per run and NEVER opens a result, so it can
  only ever add to the denominator of precision and follow-through. It was 66% of recorded
  searches on the first day of data — which is most of why precision read 1-4% and looked
  like a catastrophic retrieval failure.

  A metric a health check can only drag down is not measuring retrieval, so infra traffic is
  excluded from every figure `RetrievalMetrics.compute/3` returns.
  """
  use Loopctl.DataCase, async: true

  import Ecto.Query

  setup :verify_on_exit!

  alias Loopctl.AdminRepo
  alias Loopctl.Knowledge.Analytics
  alias Loopctl.Knowledge.ArticleAccessEvent
  alias Loopctl.Knowledge.RetrievalMetrics

  setup do
    tenant = fixture(:tenant)
    {_raw, api_key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
    article = fixture(:article, %{tenant_id: tenant.id, status: :published})
    %{tenant: tenant, api_key: api_key, article: article, day: Date.utc_today()}
  end

  defp surfaced(ctx, meta) do
    AdminRepo.insert!(%ArticleAccessEvent{
      tenant_id: ctx.tenant.id,
      article_id: ctx.article.id,
      api_key_id: ctx.api_key.id,
      access_type: "search",
      metadata: Map.merge(%{"mode" => "combined", "results_returned" => 1}, meta),
      accessed_at: DateTime.utc_now()
    })
  end

  test "a search declaring an entrypoint records it on every surfaced row", ctx do
    # The half that connects `scripts/smoke.sh`'s header to the exclusion above. Without it
    # the predicate is correct and matches nothing, which is the shape of an inert guard.
    fixture(:article, %{
      tenant_id: ctx.tenant.id,
      status: :published,
      title: "entrypoint propagation note",
      body: "entrypoint propagation body"
    })

    {:ok, _} =
      Loopctl.Knowledge.search_combined(ctx.tenant.id, "entrypoint propagation",
        api_key_id: ctx.api_key.id,
        _client_context: %{client_entrypoint: "smoke"}
      )

    events =
      AdminRepo.all(
        from(e in ArticleAccessEvent,
          where: e.tenant_id == ^ctx.tenant.id and e.access_type == "search"
        )
      )

    refute events == []
    assert Enum.all?(events, &(&1.metadata["entrypoint"] == "smoke"))
  end

  test "a smoke-test search is in no denominator", ctx do
    surfaced(ctx, %{"entrypoint" => "smoke"})

    assert %{searched: 0, results_recorded: 0} = RetrievalMetrics.compute(ctx.tenant.id, ctx.day)
  end

  test "an agent search still counts", ctx do
    surfaced(ctx, %{"entrypoint" => "cli"})

    assert %{searched: 1} = RetrievalMetrics.compute(ctx.tenant.id, ctx.day)
  end

  test "a row with no entrypoint at all still counts", ctx do
    # Every row written before the smoke test began declaring itself. Excluding these too
    # would silently drop all historical traffic and make the series look like a cliff.
    surfaced(ctx, %{})

    assert %{searched: 1} = RetrievalMetrics.compute(ctx.tenant.id, ctx.day)
  end

  test "a skill-eval search is in no denominator either", ctx do
    # `bin/skill-trigger-eval.py` runs each eval query through a real `claude -p` subject
    # whose recall hooks search for real, and the subject is KILLED at its first tool call.
    # Structurally the same defect as the smoke test: it can never contribute to a numerator
    # while contributing to every denominator (claude-config#322).
    surfaced(ctx, %{"entrypoint" => "skill-eval"})

    assert %{searched: 0, results_recorded: 0} = RetrievalMetrics.compute(ctx.tenant.id, ctx.day)
  end

  test "session-start is COUNTED, not excluded", ctx do
    # One auto-query per session from `hooks/session-start.sh` — a real session that goes on
    # to do real work, so it is a channel to measure rather than infrastructure to drop.
    # It began declaring itself in claude-config#322; before that it sat in the NULL bucket.
    # The runbook briefly claimed it belonged with `smoke`; this asserts the opposite so the
    # claim cannot drift back.
    surfaced(ctx, %{"entrypoint" => "session-start"})

    assert %{searched: 1} = RetrievalMetrics.compute(ctx.tenant.id, ctx.day)
  end

  test "an excluded entrypoint's OPEN is out of the attribution counters too", ctx do
    # The two families on this payload must describe ONE population. `attributed_opens` /
    # `direct_opens` are built straight off `article_access_events`, so without the same
    # exclusion an infra channel's reads counted while its searches did not, and an operator
    # comparing them read a gap that is bookkeeping rather than behaviour.
    #
    # The row is built the way PRODUCTION builds it, not by hand: `entrypoint` is written by
    # `search_access_meta/3` onto SEARCH rows only, so a `get` carrying that key is a shape
    # nothing can write, and a test asserting on it passes while the metric is unchanged.
    # A read's link to the channel is `origin_search_id`, resolved server-side at write time.
    search_id = Ecto.UUID.generate()
    surfaced(ctx, %{"entrypoint" => "smoke", "search_id" => search_id})

    Analytics.do_record_sync([{ctx.article.id, %{}}], ctx.tenant.id, ctx.api_key.id, "get")

    assert [%{origin_search_id: ^search_id, origin_attribution: "same_key"}] =
             AdminRepo.all(
               from(e in ArticleAccessEvent,
                 where: e.tenant_id == ^ctx.tenant.id and e.access_type == "get"
               )
             )

    assert %{direct_opens: 0, attributed_opens: 0} =
             RetrievalMetrics.compute(ctx.tenant.id, ctx.day)
  end

  test "an ordinary channel's OPEN still counts", ctx do
    # The other half of the exclusion: a predicate that dropped every open would pass the
    # test above and report zero reads forever.
    search_id = Ecto.UUID.generate()
    surfaced(ctx, %{"entrypoint" => "cli", "search_id" => search_id})

    Analytics.do_record_sync([{ctx.article.id, %{}}], ctx.tenant.id, ctx.api_key.id, "get")

    assert %{attributed_opens: 1} = RetrievalMetrics.compute(ctx.tenant.id, ctx.day)
  end

  test "smoke rows do not dilute a real search's precision", ctx do
    # The exact shape of the defect: one agent search, many smoke searches, none of which
    # can ever be opened. Undeleted, precision here would be 1/6; the agent row is the only
    # one that belongs in the denominator.
    surfaced(ctx, %{"entrypoint" => "cli"})
    for _ <- 1..5, do: surfaced(ctx, %{"entrypoint" => "smoke"})

    assert %{searched: 1} = RetrievalMetrics.compute(ctx.tenant.id, ctx.day)
  end
end
