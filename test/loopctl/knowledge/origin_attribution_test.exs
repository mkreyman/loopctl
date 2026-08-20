defmodule Loopctl.Knowledge.OriginAttributionTest do
  @moduledoc """
  Which search surfaced the article an agent then opened.

  The measurement this exists to fix was made on prod on 2026-08-17: the injected recall
  hook made 1,071 searches under one key while the session that reads made 2,535 reads under
  a DIFFERENT key, so every key-correlated follow-through metric scored that channel — 71% of
  all traffic — at exactly zero. A zero there means "unmeasurable", not "unread", and the
  tests below pin the difference.
  """
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.AdminRepo
  alias Loopctl.Knowledge.Analytics
  alias Loopctl.Knowledge.ArticleAccessEvent

  defp surfacing_row(tenant_id, article_id, api_key_id, search_id, opts \\ []) do
    ago = Keyword.get(opts, :seconds_ago, 10)

    fixture(:article_access_event, %{
      tenant_id: tenant_id,
      article_id: article_id,
      api_key_id: api_key_id,
      access_type: "search",
      metadata: if(search_id, do: %{"search_id" => search_id, "rank" => 1}, else: %{}),
      accessed_at: DateTime.add(DateTime.utc_now(), -ago, :second)
    })
  end

  defp key_for(tenant_id) do
    {_raw, key} = fixture(:api_key, %{tenant_id: tenant_id, role: :agent})
    key.id
  end

  defp read_row(tenant_id, article_id, api_key_id, access_type \\ "get") do
    Analytics.do_record_sync([{article_id, %{}}], tenant_id, api_key_id, access_type)

    AdminRepo.one(
      from(e in ArticleAccessEvent,
        where: e.tenant_id == ^tenant_id and e.access_type == ^access_type,
        order_by: [desc: e.accessed_at],
        limit: 1
      )
    )
  end

  describe "resolve_origin/5" do
    test "a read after the reader's OWN search is attributed same_key, with that search id" do
      tenant = fixture(:tenant)
      article = fixture(:article, %{tenant_id: tenant.id})
      key = key_for(tenant.id)
      search_id = Ecto.UUID.generate()

      surfacing_row(tenant.id, article.id, key, search_id)
      row = read_row(tenant.id, article.id, key)

      assert row.origin_attribution == "same_key"
      assert row.origin_search_id == search_id
    end

    test "a read after ANOTHER key's search is attributed cross_key — the injected-hook shape" do
      tenant = fixture(:tenant)
      article = fixture(:article, %{tenant_id: tenant.id})
      hook_key = key_for(tenant.id)
      session_key = key_for(tenant.id)
      search_id = Ecto.UUID.generate()

      surfacing_row(tenant.id, article.id, hook_key, search_id)
      row = read_row(tenant.id, article.id, session_key)

      assert row.origin_attribution == "cross_key",
             "the hook searches under one key and the session reads under another; " <>
               "refusing to cross keys is what made this channel a structural zero"

      assert row.origin_search_id == search_id
    end

    test "the reader's OWN search wins over a more RECENT search by another key" do
      tenant = fixture(:tenant)
      article = fixture(:article, %{tenant_id: tenant.id})
      own_key = key_for(tenant.id)
      other_key = key_for(tenant.id)
      own_search = Ecto.UUID.generate()
      newer_other_search = Ecto.UUID.generate()

      # Own search is OLDER. Recency alone would pick the other key's.
      surfacing_row(tenant.id, article.id, own_key, own_search, seconds_ago: 600)
      surfacing_row(tenant.id, article.id, other_key, newer_other_search, seconds_ago: 5)

      row = read_row(tenant.id, article.id, own_key)

      assert row.origin_attribution == "same_key",
             "direct evidence outranks recency — otherwise a concurrent agent's search " <>
               "silently steals attribution for a read it had nothing to do with"

      assert row.origin_search_id == own_search
    end

    test "a read with nothing surfacing it is `none`, which is not a failure" do
      tenant = fixture(:tenant)
      article = fixture(:article, %{tenant_id: tenant.id})
      key = key_for(tenant.id)

      row = read_row(tenant.id, article.id, key)

      assert row.origin_attribution == "none"
      assert is_nil(row.origin_search_id)
    end

    test "a surfacing older than the write-time window no longer attributes" do
      tenant = fixture(:tenant)
      article = fixture(:article, %{tenant_id: tenant.id})
      key = key_for(tenant.id)

      surfacing_row(tenant.id, article.id, key, Ecto.UUID.generate(),
        seconds_ago: Analytics.origin_window_seconds() + 60
      )

      row = read_row(tenant.id, article.id, key)

      assert row.origin_attribution == "none"
      assert is_nil(row.origin_search_id)
    end

    test "a pre-#582 surfacing row with no search_id is UNCLASSIFIED, never `none`" do
      tenant = fixture(:tenant)
      article = fixture(:article, %{tenant_id: tenant.id})
      key = key_for(tenant.id)

      surfacing_row(tenant.id, article.id, key, nil)
      row = read_row(tenant.id, article.id, key)

      assert is_nil(row.origin_attribution),
             "the article WAS surfaced, so `none` would be false; there is no id to " <>
               "attribute to, so the attributed bucket would be false too"

      assert is_nil(row.origin_search_id)
    end

    test "a surfacing in ANOTHER tenant never attributes a read" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      article_a = fixture(:article, %{tenant_id: tenant_a.id})
      article_b = fixture(:article, %{tenant_id: tenant_b.id})
      key_a = key_for(tenant_a.id)
      key_b = key_for(tenant_b.id)

      surfacing_row(tenant_b.id, article_b.id, key_b, Ecto.UUID.generate())
      row = read_row(tenant_a.id, article_a.id, key_a)

      assert row.origin_attribution == "none"
    end

    test "a DRILL nothing surfaced is UNCLASSIFIED, never a direct open" do
      # `progressive_index/3` runs its inner search with `_skip_record_access`, so the index
      # that surfaced the stub writes no row to attribute to. Calling the DOCUMENTED way of
      # following an index a `direct_open` — "the agent went straight to an article by link
      # or cited id" — would populate that counter with its own opposite.
      tenant = fixture(:tenant)
      article = fixture(:article, %{tenant_id: tenant.id})
      key = key_for(tenant.id)

      assert {nil, nil} =
               Analytics.resolve_origin(tenant.id, article.id, key, "drill", DateTime.utc_now())
    end

    test "a batch resolves every item's origin in ONE lookup" do
      # `do_record_sync/5` used to issue a point query PER ROW on the 3-connection AdminRepo
      # pool that every authenticated request also checks out of. The batch form must return
      # the same verdicts it did per row.
      tenant = fixture(:tenant)
      surfaced_article = fixture(:article, %{tenant_id: tenant.id})
      unsurfaced = fixture(:article, %{tenant_id: tenant.id})
      key = key_for(tenant.id)
      search_id = Ecto.UUID.generate()

      surfacing_row(tenant.id, surfaced_article.id, key, search_id)

      origins =
        Analytics.resolve_origins(
          tenant.id,
          [surfaced_article.id, unsurfaced.id],
          key,
          "get",
          DateTime.utc_now()
        )

      assert origins[surfaced_article.id] == {search_id, "same_key"}
      refute Map.has_key?(origins, unsurfaced.id)

      assert {nil, "none"} =
               Analytics.resolve_origin(tenant.id, unsurfaced.id, key, "get", DateTime.utc_now())
    end

    test "surfacing rows themselves are never attributed" do
      tenant = fixture(:tenant)
      article = fixture(:article, %{tenant_id: tenant.id})
      key = key_for(tenant.id)

      assert {nil, nil} =
               Analytics.resolve_origin(tenant.id, article.id, key, "search", DateTime.utc_now())

      assert {nil, nil} =
               Analytics.resolve_origin(tenant.id, article.id, key, "index", DateTime.utc_now())
    end

    test "every attributable access type resolves, and the two lists agree" do
      tenant = fixture(:tenant)
      key = key_for(tenant.id)

      Enum.each(Analytics.attributable_access_types(), fn type ->
        article = fixture(:article, %{tenant_id: tenant.id})
        search_id = Ecto.UUID.generate()
        surfacing_row(tenant.id, article.id, key, search_id)

        row = read_row(tenant.id, article.id, key, type)

        assert row.origin_attribution == "same_key", "#{type} must be attributable"
        assert row.origin_search_id == search_id
      end)

      # Drift guard: every value the writer can produce must be a declared one.
      assert Enum.all?(
               ["same_key", "cross_key", "none"],
               &(&1 in ArticleAccessEvent.origin_attributions())
             )

      assert Enum.all?(
               Analytics.attributable_access_types(),
               &(&1 in Analytics.valid_access_types())
             )
    end
  end

  describe "metrics: attribution split and search disposition" do
    alias Loopctl.Knowledge.RetrievalMetrics

    defp seeded_open(tenant_id, article_id, api_key_id, attribution, at) do
      fixture(:article_access_event, %{
        tenant_id: tenant_id,
        article_id: article_id,
        api_key_id: api_key_id,
        access_type: "get",
        accessed_at: at,
        origin_attribution: attribution,
        origin_search_id: if(attribution in ["same_key", "cross_key"], do: Ecto.UUID.generate())
      })
    end

    test "cross_key opens are counted — the population the correlated metric cannot see" do
      tenant = fixture(:tenant)
      article = fixture(:article, %{tenant_id: tenant.id})
      key = key_for(tenant.id)
      day = Date.utc_today()
      at = DateTime.new!(day, ~T[12:00:00.000000], "Etc/UTC")

      seeded_open(tenant.id, article.id, key, "same_key", at)
      seeded_open(tenant.id, article.id, key, "cross_key", at)
      seeded_open(tenant.id, article.id, key, "cross_key", at)
      seeded_open(tenant.id, article.id, key, "none", at)

      m = RetrievalMetrics.compute(tenant.id, day)

      assert m.attributed_opens == 3, "same_key + cross_key, and nothing else"
      assert m.cross_key_opens == 2
      assert m.direct_opens == 1
    end

    test "an UNCLASSIFIED open lands in no bucket at all" do
      tenant = fixture(:tenant)
      article = fixture(:article, %{tenant_id: tenant.id})
      key = key_for(tenant.id)
      day = Date.utc_today()
      at = DateTime.new!(day, ~T[12:00:00.000000], "Etc/UTC")

      # No origin_attribution: a pre-migration row, or the deliberate refusal to classify.
      fixture(:article_access_event, %{
        tenant_id: tenant.id,
        article_id: article.id,
        api_key_id: key,
        access_type: "get",
        accessed_at: at
      })

      m = RetrievalMetrics.compute(tenant.id, day)

      assert m.attributed_opens == 0
      assert m.cross_key_opens == 0

      assert m.direct_opens == 0,
             "an unclassified read is not a direct read — putting it in `none` would " <>
               "assert nothing surfaced it, which is exactly what is unknown"
    end

    test "opens in another tenant never count" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      article_b = fixture(:article, %{tenant_id: tenant_b.id})
      key_b = key_for(tenant_b.id)
      day = Date.utc_today()
      at = DateTime.new!(day, ~T[12:00:00.000000], "Etc/UTC")

      seeded_open(tenant_b.id, article_b.id, key_b, "cross_key", at)

      m = RetrievalMetrics.compute(tenant_a.id, day)

      assert m.attributed_opens == 0
      assert m.cross_key_opens == 0
    end

    # `session_id` DEFAULTS TO ONE DERIVED FROM THE KEY, so every test written before #711
    # keeps exactly the meaning it had: same key means same session, different keys mean
    # different sessions. The default `query` is derived from the search id so that two
    # distinct calls are two distinct questions unless a test says otherwise — which is what
    # "asked again" meant before the query text was compared at all.
    defp search_call(tenant_id, article_id, api_key_id, search_id, at, opts \\ []) do
      optional =
        [
          {"session_id", Keyword.get(opts, :session_id, "sess-" <> api_key_id)},
          {"query", Keyword.get(opts, :query, "q-" <> search_id)},
          {"entrypoint", Keyword.get(opts, :entrypoint)}
        ]
        |> Enum.reject(fn {_k, v} -> is_nil(v) end)
        |> Map.new()

      meta = Map.merge(%{"search_id" => search_id, "rank" => 1, "mode" => "combined"}, optional)

      fixture(:article_access_event, %{
        tenant_id: tenant_id,
        article_id: article_id,
        api_key_id: api_key_id,
        access_type: "search",
        accessed_at: at,
        metadata: meta
      })
    end

    test "the three dispositions partition `searches` exactly" do
      tenant = fixture(:tenant)
      article = fixture(:article, %{tenant_id: tenant.id})
      other_article = fixture(:article, %{tenant_id: tenant.id})
      key = key_for(tenant.id)
      day = Date.utc_today()
      base = DateTime.new!(day, ~T[12:00:00.000000], "Etc/UTC")

      # 1. OPENED — surfaced, then read inside the window.
      search_call(tenant.id, article.id, key, Ecto.UUID.generate(), base)

      fixture(:article_access_event, %{
        tenant_id: tenant.id,
        article_id: article.id,
        api_key_id: key,
        access_type: "get",
        accessed_at: DateTime.add(base, 60, :second)
      })

      # 2. REFORMULATED — no read, but the same key asked again inside the window.
      reformed_at = DateTime.add(base, 900, :second)
      search_call(tenant.id, other_article.id, key, Ecto.UUID.generate(), reformed_at)

      search_call(
        tenant.id,
        other_article.id,
        key,
        Ecto.UUID.generate(),
        DateTime.add(reformed_at, 120, :second)
      )

      m = RetrievalMetrics.compute(tenant.id, day)

      assert m.searches_scored ==
               m.searches_scored_with_follow_through + m.searches_reformulated +
                 m.searches_quiet,
             "the three must partition `searches_scored`; `quiet` is derived by " <>
               "subtraction, so a drift between the disposition population and its own " <>
               "denominator shows up here"

      assert m.searches_scored == m.searches,
             "every row here carries a session and a scoreable entrypoint, so nothing is " <>
               "unscoreable; if this drifts the partition above is measuring a subset " <>
               "without saying so"

      assert m.searches_with_follow_through == 1
      assert m.searches_scored_with_follow_through == 1
      assert m.searches_reformulated == 1
    end

    test "a search that is opened is NOT also counted as reformulated" do
      tenant = fixture(:tenant)
      article = fixture(:article, %{tenant_id: tenant.id})
      key = key_for(tenant.id)
      day = Date.utc_today()
      base = DateTime.new!(day, ~T[12:00:00.000000], "Etc/UTC")

      # Surfaced, opened, AND followed by another query — the open takes precedence.
      search_call(tenant.id, article.id, key, Ecto.UUID.generate(), base)

      fixture(:article_access_event, %{
        tenant_id: tenant.id,
        article_id: article.id,
        api_key_id: key,
        access_type: "get",
        accessed_at: DateTime.add(base, 30, :second)
      })

      search_call(
        tenant.id,
        article.id,
        key,
        Ecto.UUID.generate(),
        DateTime.add(base, 300, :second)
      )

      m = RetrievalMetrics.compute(tenant.id, day)

      assert m.searches_with_follow_through >= 1

      assert m.searches_reformulated == 0,
             "opened outranks reformulated; the buckets are disjoint"
    end

    test "a MULTI-RESULT search that was opened is not also a reformulation" do
      # The shape the single-result tests could not see, and the one production has: a
      # search surfaces several results and the agent opens ONE. The remaining rows are
      # unopened, so a ROW-level `not follow_through_exists` matched them and counted the
      # search in `reformulated` as well as `with_follow_through` — while `quiet`, derived
      # by subtraction and clamped at 0, silently swallowed the double count and lost the
      # genuinely quiet search.
      tenant = fixture(:tenant)
      opened = fixture(:article, %{tenant_id: tenant.id})
      ignored = fixture(:article, %{tenant_id: tenant.id})
      quiet_hit = fixture(:article, %{tenant_id: tenant.id})
      key = key_for(tenant.id)
      day = Date.utc_today()
      base = DateTime.new!(day, ~T[12:00:00.000000], "Etc/UTC")

      # S1 surfaces two results; only one is opened.
      s1 = Ecto.UUID.generate()
      search_call(tenant.id, opened.id, key, s1, base)
      search_call(tenant.id, ignored.id, key, s1, base)

      fixture(:article_access_event, %{
        tenant_id: tenant.id,
        article_id: opened.id,
        api_key_id: key,
        access_type: "get",
        accessed_at: DateTime.add(base, 300, :second)
      })

      # S2, later and in-window, opens nothing — this is the quiet one.
      search_call(
        tenant.id,
        quiet_hit.id,
        key,
        Ecto.UUID.generate(),
        DateTime.add(base, 600, :second)
      )

      m = RetrievalMetrics.compute(tenant.id, day)

      assert m.searches == 2
      assert m.searches_with_follow_through == 1

      assert m.searches_reformulated == 0,
             "S1 was opened; its unopened ROWS must not make the CALL a reformulation"

      assert m.searches_quiet == 1, "S2 is the quiet search and must not be clamped away"

      assert m.searches_scored ==
               m.searches_scored_with_follow_through + m.searches_reformulated +
                 m.searches_quiet
    end

    test "a lone search with no read and no follow-up query is quiet, not reformulated" do
      tenant = fixture(:tenant)
      article = fixture(:article, %{tenant_id: tenant.id})
      key = key_for(tenant.id)
      day = Date.utc_today()
      base = DateTime.new!(day, ~T[12:00:00.000000], "Etc/UTC")

      search_call(tenant.id, article.id, key, Ecto.UUID.generate(), base)

      m = RetrievalMetrics.compute(tenant.id, day)

      assert m.searches == 1
      assert m.searches_reformulated == 0
      assert m.searches_quiet == 1
    end

    test "a VERBATIM retry is not a reformulation" do
      tenant = fixture(:tenant)
      article = fixture(:article, %{tenant_id: tenant.id})
      key = key_for(tenant.id)
      day = Date.utc_today()
      base = DateTime.new!(day, ~T[12:00:00.000000], "Etc/UTC")

      search_call(tenant.id, article.id, key, Ecto.UUID.generate(), base, query: "same question")

      search_call(
        tenant.id,
        article.id,
        key,
        Ecto.UUID.generate(),
        DateTime.add(base, 120, :second),
        query: "same question"
      )

      m = RetrievalMetrics.compute(tenant.id, day)

      assert m.searches_scored == 2
      assert m.searches_quiet == 2

      assert m.searches_reformulated == 0,
             "re-running the identical query is a retry, not a reformulation; scoring it " <>
               "on `search_id` alone flagged 142 of 311 rows on 2026-08-17"
    end

    test "another SESSION on the SAME KEY is not a reformulation" do
      tenant = fixture(:tenant)
      article = fixture(:article, %{tenant_id: tenant.id})
      key = key_for(tenant.id)
      day = Date.utc_today()
      base = DateTime.new!(day, ~T[12:00:00.000000], "Etc/UTC")

      search_call(tenant.id, article.id, key, Ecto.UUID.generate(), base, session_id: "sess-a")

      search_call(
        tenant.id,
        article.id,
        key,
        Ecto.UUID.generate(),
        DateTime.add(base, 120, :second),
        session_id: "sess-b"
      )

      m = RetrievalMetrics.compute(tenant.id, day)

      assert m.searches_scored == 2

      assert m.searches_reformulated == 0,
             "one shared MCP key serves every session and subagent, and the median gap " <>
               "between searches on it is ~2 minutes — scoring on `api_key_id` made this " <>
               "metric a function of search DENSITY (97% observed, 27% session-scoped)"
    end

    test "a search with NO session identity is unscoreable, not quiet" do
      tenant = fixture(:tenant)
      article = fixture(:article, %{tenant_id: tenant.id})
      key = key_for(tenant.id)
      day = Date.utc_today()
      base = DateTime.new!(day, ~T[12:00:00.000000], "Etc/UTC")

      search_call(tenant.id, article.id, key, Ecto.UUID.generate(), base, session_id: nil)

      m = RetrievalMetrics.compute(tenant.id, day)

      assert m.searches == 1, "it is still a search everywhere else"

      assert m.searches_scored == 0,
             "no session identity means the comparison cannot be scoped at all"

      assert m.searches_quiet == 0,
             "an `n/a` folded into `quiet` publishes a blind spot as an observation"
    end

    test "the recall hook is counted everywhere but scored nowhere" do
      tenant = fixture(:tenant)
      article = fixture(:article, %{tenant_id: tenant.id})
      key = key_for(tenant.id)
      day = Date.utc_today()
      base = DateTime.new!(day, ~T[12:00:00.000000], "Etc/UTC")

      for {entry, offset} <- [{"hook", 0}, {"session-start", 120}] do
        search_call(
          tenant.id,
          article.id,
          key,
          Ecto.UUID.generate(),
          DateTime.add(base, offset, :second),
          entrypoint: entry,
          session_id: "sess-shared"
        )
      end

      m = RetrievalMetrics.compute(tenant.id, day)

      assert m.searches == 2,
             "these are NOT `@infra_entrypoints` — real traffic, still in every other " <>
               "denominator including precision"

      assert m.searches_scored == 0,
             "a shell script emitting one distilled query per prompt never sees what came " <>
               "back, so it cannot reformulate by construction"

      assert m.searches_reformulated == 0
    end

    test "another KEY's later query is not a reformulation of mine" do
      tenant = fixture(:tenant)
      article = fixture(:article, %{tenant_id: tenant.id})
      mine = key_for(tenant.id)
      theirs = key_for(tenant.id)
      day = Date.utc_today()
      base = DateTime.new!(day, ~T[12:00:00.000000], "Etc/UTC")

      search_call(tenant.id, article.id, mine, Ecto.UUID.generate(), base)

      search_call(
        tenant.id,
        article.id,
        theirs,
        Ecto.UUID.generate(),
        DateTime.add(base, 60, :second)
      )

      m = RetrievalMetrics.compute(tenant.id, day)

      assert m.searches_reformulated == 0,
             "reformulation is one agent asking again, not two agents searching concurrently"
    end

    test "the snapshot persists the new counters" do
      tenant = fixture(:tenant)
      article = fixture(:article, %{tenant_id: tenant.id})
      key = key_for(tenant.id)
      day = Date.utc_today()
      at = DateTime.new!(day, ~T[12:00:00.000000], "Etc/UTC")

      seeded_open(tenant.id, article.id, key, "cross_key", at)
      seeded_open(tenant.id, article.id, key, "none", at)

      assert {:ok, snap} = RetrievalMetrics.snapshot(tenant.id, day)
      assert snap.cross_key_opens == 1
      assert snap.attributed_opens == 1
      assert snap.direct_opens == 1

      # The API serves persisted snapshots, so a counter that does not round-trip here is
      # invisible to every consumer including the MCP tool.
      %{data: [served | _]} = RetrievalMetrics.list_snapshots(tenant.id)
      assert served.cross_key_opens == 1
      assert served.direct_opens == 1
    end
  end
end
