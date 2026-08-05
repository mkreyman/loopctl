defmodule Loopctl.Knowledge.HeatIndexTest do
  @moduledoc """
  #554 — the heat-ranked, topic-less stub index.

  The point of this surface is that it takes NO query, so its misses are uncorrelated with
  embedding similarity. That makes two properties load-bearing and worth testing directly:

    * ordering really is cumulative USAGE, not recency or relevance — otherwise it is just
      another ranked list with the same blind spots as the route it exists to complement; and
    * visibility scoping holds. An index is where a leak is easiest and least likely to be
      noticed: a stub looks innocuous, and nobody reads an index the way they read a body.
  """
  use Loopctl.DataCase, async: true

  alias Loopctl.AdminRepo
  alias Loopctl.DbCapacity
  alias Loopctl.HeavyRead
  alias Loopctl.HeavyRead.TenantGate
  alias Loopctl.Knowledge

  setup :verify_on_exit!

  defp published_article(tenant_id, attrs \\ %{}) do
    base = %{
      title: "Article #{System.unique_integer([:positive])}",
      body: "Body text for the article.",
      category: :pattern,
      status: :draft,
      tags: []
    }

    fixture(:article, Map.merge(base, Map.put(attrs, :tenant_id, tenant_id)))
    |> Ecto.Changeset.change(%{status: :published})
    |> AdminRepo.update!()
  end

  # `heat` is the count of DISTINCT READERS, so heat of N means N events from N DIFFERENT api
  # keys. The `:article_access_event` fixture mints a fresh key per event when none is given,
  # which is why these read naturally — but see `reads_from_one_key/3` for the case that
  # distinguishes distinct-reader counting from raw-row counting.
  # `attrs` overrides the event shape (its `access_type`, its `accessed_at`).
  defp heat(tenant_id, article, n, attrs \\ %{}) do
    base = %{tenant_id: tenant_id, article_id: article.id}
    for _ <- 1..n, do: fixture(:article_access_event, Map.merge(base, attrs))

    article
  end

  # N reads of one article by ONE key — the shape a loop produces.
  defp reads_from_one_key(tenant_id, article, n) do
    {_raw, key} = fixture(:api_key, %{tenant_id: tenant_id, role: :agent})

    for _ <- 1..n do
      fixture(:article_access_event, %{
        tenant_id: tenant_id,
        article_id: article.id,
        api_key_id: key.id
      })
    end

    article
  end

  describe "ordering is by cumulative usage" do
    test "the most-read article ranks first, regardless of insertion order" do
      tenant = fixture(:tenant)

      cold = published_article(tenant.id, %{title: "Cold"})
      hot = published_article(tenant.id, %{title: "Hot"})
      warm = published_article(tenant.id, %{title: "Warm"})

      heat(tenant.id, cold, 1)
      heat(tenant.id, warm, 3)
      heat(tenant.id, hot, 9)

      assert {:ok, %{results: results}} = Knowledge.heat_index(tenant.id)

      assert Enum.map(results, & &1.title) == ["Hot", "Warm", "Cold"]
      assert Enum.map(results, & &1.heat) == [9, 3, 1]
    end

    test "#567: one key looping cannot outrank genuine readership" do
      # Counting event ROWS made this ranking self-serve: an agent could pin its own article
      # at rank 1 by calling knowledge_get on it in a loop, and because this index is designed
      # to be pasted into a cached prefix, that ranking propagated into every OTHER agent's
      # context. Heat counts DISTINCT api keys, so a loop contributes exactly 1.
      tenant = fixture(:tenant)

      spammed = published_article(tenant.id, %{title: "Spammed"})
      genuine = published_article(tenant.id, %{title: "Genuine"})

      # 50 reads from ONE key vs 3 reads from 3 DIFFERENT keys. Under row-counting the
      # spammer wins 50-3; under reader-counting it loses 1-3.
      reads_from_one_key(tenant.id, spammed, 50)
      heat(tenant.id, genuine, 3)

      assert {:ok, %{results: results}} = Knowledge.heat_index(tenant.id)

      assert Enum.map(results, & &1.title) == ["Genuine", "Spammed"]
      assert Enum.map(results, & &1.heat) == [3, 1]
    end

    test "#567: repeat reads by an established reader do not inflate its article" do
      # The other half of the same rule, so it cannot be satisfied by capping at 1 event per
      # article: a key that legitimately re-reads still counts once, and an article's heat
      # equals the size of its readership, not its traffic.
      tenant = fixture(:tenant)
      article = published_article(tenant.id, %{title: "Re-read"})

      reads_from_one_key(tenant.id, article, 12)
      reads_from_one_key(tenant.id, article, 7)

      assert {:ok, %{results: [%{heat: 2}]}} = Knowledge.heat_index(tenant.id)
    end

    test "#567: one agent's many dispatch keys are ONE reader" do
      # v2 mints a fresh ephemeral key per dispatch, so counting KEYS counted DISPATCHES:
      # re-dispatching N times was N votes — the pinning distinct counting exists to prevent,
      # one cheap API call away. A reader is the AGENT behind the key.
      tenant = fixture(:tenant)
      agent = fixture(:agent, %{tenant_id: tenant.id})

      churned = published_article(tenant.id, %{title: "Churned"})
      genuine = published_article(tenant.id, %{title: "Genuine"})

      # One active key per (agent, role) at a time, so this is the real dispatch lifecycle:
      # mint, read, revoke, mint again. Six dispatches leave six key rows behind.
      for _ <- 1..6 do
        {_raw, key} =
          fixture(:api_key, %{tenant_id: tenant.id, role: :agent, agent_id: agent.id})

        fixture(:article_access_event, %{
          tenant_id: tenant.id,
          article_id: churned.id,
          api_key_id: key.id
        })

        key
        |> Ecto.Changeset.change(%{revoked_at: DateTime.utc_now()})
        |> AdminRepo.update!()
      end

      heat(tenant.id, genuine, 2)

      assert {:ok, %{results: results}} = Knowledge.heat_index(tenant.id)

      assert Enum.map(results, & &1.title) == ["Genuine", "Churned"]
      assert Enum.map(results, & &1.heat) == [2, 1]
    end

    test "#567: a tie is broken by distinct read DAYS, which a loop cannot inflate" do
      # Readership is a small integer (fleet size), so ties are the norm — and a fleet reading
      # through one shared MCP key ties EVERY article at 1, which makes the tie-break the real
      # ranking. Breaking it on raw event rows handed that ranking straight back to the ranked
      # party: 9 knowledge_get calls in a loop outrank an article read on 3 separate days.
      tenant = fixture(:tenant)
      looped = published_article(tenant.id, %{title: "Looped"})
      sustained = published_article(tenant.id, %{title: "Sustained"})

      {_raw, key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      now = DateTime.utc_now()

      # 9 reads, all today, from one key vs 3 reads on 3 different days from the same key.
      for _ <- 1..9,
          do:
            fixture(:article_access_event, %{
              tenant_id: tenant.id,
              article_id: looped.id,
              api_key_id: key.id,
              accessed_at: now
            })

      for d <- 1..3,
          do:
            fixture(:article_access_event, %{
              tenant_id: tenant.id,
              article_id: sustained.id,
              api_key_id: key.id,
              accessed_at: DateTime.add(now, -d, :day)
            })

      assert {:ok, %{results: results}} = Knowledge.heat_index(tenant.id)

      assert Enum.map(results, & &1.title) == ["Sustained", "Looped"]
      assert Enum.map(results, & &1.heat) == [1, 1]
    end

    test "an article nobody has read does not appear at all" do
      # Heat comes from a JOIN on access events, so a never-read article has no row. Asserted
      # explicitly because "absent" and "present with heat 0" are different contracts and a
      # future change to an outer join would silently swap them.
      tenant = fixture(:tenant)
      read = published_article(tenant.id, %{title: "Read"})
      _unread = published_article(tenant.id, %{title: "Never read"})

      heat(tenant.id, read, 2)

      assert {:ok, %{results: results}} = Knowledge.heat_index(tenant.id)

      assert Enum.map(results, & &1.title) == ["Read"]
    end

    test ":since moves the window; the default one is bounded, not all-time" do
      tenant = fixture(:tenant)
      article = published_article(tenant.id, %{title: "Old favourite"})

      old = DateTime.add(DateTime.utc_now(), -200, :day)
      heat(tenant.id, article, 5, %{accessed_at: old})

      # The default window bounds the request-path aggregate, so reads older than it are not
      # counted — the endpoint degrades to a shorter list rather than to a statement timeout.
      assert {:ok, %{results: [], meta: %{heat_window: window}}} = Knowledge.heat_index(tenant.id)
      assert {:ok, _, _} = DateTime.from_iso8601(window)

      # An explicit older `:since` widens it back deliberately.
      wide = DateTime.add(DateTime.utc_now(), -300, :day)
      assert {:ok, %{results: [%{heat: 5}]}} = Knowledge.heat_index(tenant.id, since: wide)
    end

    test ":since is clamped to the ceiling, so it cannot reinstate the all-time scan" do
      # The default window is only a bound if a caller cannot widen past what the aggregate can
      # serve: an arbitrary `since` would otherwise scan the whole read history under the
      # heavy-read statement timeout and 500 on exactly the tenant with the most of it.
      tenant = fixture(:tenant)
      ceiling = Knowledge.heat_max_window_days()

      assert {:ok, %{meta: %{heat_window: window}}} =
               Knowledge.heat_index(tenant.id,
                 since: DateTime.add(DateTime.utc_now(), -(ceiling * 3), :day)
               )

      assert {:ok, effective, _} = DateTime.from_iso8601(window)
      assert DateTime.diff(DateTime.utc_now(), effective, :day) <= ceiling
    end

    test "#567: an explicit :since is never widened back to the start of its UTC day" do
      # The snap ran AFTER the clamp and always floored, so a caller that narrowed the window
      # silently got up to 24 hours MORE history than it asked for — and it looks correct.
      # The snap narrows instead, which also keeps the 365-day ceiling from being overshot.
      tenant = fixture(:tenant)
      article = published_article(tenant.id, %{title: "Excluded"})

      given = DateTime.add(DateTime.utc_now(), -30, :day)
      heat(tenant.id, article, 2, %{accessed_at: DateTime.add(given, -1, :second)})

      assert {:ok, %{results: results, meta: %{heat_window: window}}} =
               Knowledge.heat_index(tenant.id, since: given)

      assert {:ok, effective, _} = DateTime.from_iso8601(window)

      assert DateTime.compare(effective, given) != :lt,
             "the served window must never start earlier than the caller asked for"

      assert results == [], "a read the caller's :since excluded must not be counted"
    end

    test "#572: an explicit :since is not NARROWED either — it is served verbatim" do
      # The other half, and the half that had no coverage: the test above only asserts that
      # reads BEFORE `:since` stay excluded, which a window that starts LATER than asked also
      # satisfies. So ceiling to the next day boundary — #567's fix for the widening — passed
      # it while silently dropping up to 24h of reads the caller explicitly asked for.
      # Rounding in either direction is dishonest when the exact value costs nothing.
      tenant = fixture(:tenant)
      article = published_article(tenant.id, %{title: "Inside the asked-for window"})

      # Mid-day, comfortably inside the window but AFTER the start of its own UTC day, so a
      # ceil moves it forward a whole day and a floor moves it back several hours.
      given = DateTime.add(DateTime.utc_now(), -30, :day)
      heat(tenant.id, article, 2, %{accessed_at: DateTime.add(given, 1, :hour)})

      assert {:ok, %{results: results, meta: %{heat_window: window}}} =
               Knowledge.heat_index(tenant.id, since: given)

      assert {:ok, effective, _} = DateTime.from_iso8601(window)

      assert DateTime.compare(effective, given) == :eq,
             "an explicit :since must be echoed exactly, neither floored nor ceiled"

      assert [%{heat: 2}] = results
    end

    test "#567: a :since inside the current UTC day is not widened back to 00:00" do
      # The snap ceiled the caller's value and an upper clamp then pulled it back to today's
      # start, so a 09:00 `:since` counted reads from 00:00 again — the same widening the snap
      # was added to remove, relocated from the floor to the clamp. Inside the current day the
      # next boundary has not happened yet, so the caller's timestamp is used as given.
      tenant = fixture(:tenant)
      article = published_article(tenant.id, %{title: "Excluded"})

      today = DateTime.new!(Date.utc_today(), ~T[00:00:00], "Etc/UTC")
      heat(tenant.id, article, 2, %{accessed_at: today})

      given = DateTime.add(DateTime.utc_now(), -1, :second)

      assert {:ok, %{results: results, meta: %{heat_window: window}}} =
               Knowledge.heat_index(tenant.id, since: given)

      assert {:ok, effective, _} = DateTime.from_iso8601(window)

      assert DateTime.compare(effective, given) != :lt,
             "an intra-day :since must not be pulled back to the start of its UTC day"

      assert results == [], "reads before the caller's :since must not be counted"
    end

    test "#567: the default window is the advertised number of whole days" do
      # Ceiling the SYSTEM-derived bounds served 89 days under a 90-day constant that the
      # OpenAPI and MCP copy are generated from. They are anchored at today's start instead.
      tenant = fixture(:tenant)
      article = published_article(tenant.id, %{title: "Old"})

      edge = DateTime.add(DateTime.utc_now(), -Knowledge.heat_default_window_days(), :day)
      heat(tenant.id, article, 1, %{accessed_at: edge})

      assert {:ok, %{results: [%{title: "Old"}]}} = Knowledge.heat_index(tenant.id)
    end

    test "#567: the window is snapped to a UTC day boundary, so the payload is byte-identical" do
      # This index exists to be pasted into a CACHED PREFIX. The window was
      # `utc_now() - 90d` at microsecond precision, so `meta.heat_window` differed on every
      # single call and no two responses were ever byte-identical — the route advertised
      # cacheability while guaranteeing a miss.
      tenant = fixture(:tenant)
      article = published_article(tenant.id, %{title: "Stable"})
      heat(tenant.id, article, 2)

      assert {:ok, first} = Knowledge.heat_index(tenant.id)
      assert {:ok, second} = Knowledge.heat_index(tenant.id)

      assert first == second, "two calls with no intervening read must return the same payload"

      # Specifically a day boundary, not merely equal-because-fast.
      assert {:ok, window, _} = DateTime.from_iso8601(first.meta.heat_window)
      assert %DateTime{hour: 0, minute: 0, second: 0, microsecond: {0, 0}} = window
    end

    test "#567: a FUTURE :since is clamped, not answered with an empty index" do
      # Only the lower bound was clamped, so a future `since` returned 200 with an empty list
      # and a future `heat_window` — which reads as "the corpus has nothing", the exact
      # misreading this whole route exists to prevent, self-inflicted.
      tenant = fixture(:tenant)
      article = published_article(tenant.id, %{title: "Readable"})
      heat(tenant.id, article, 2)

      future = DateTime.add(DateTime.utc_now(), 30, :day)

      assert {:ok, %{results: results, meta: %{heat_window: window}}} =
               Knowledge.heat_index(tenant.id, since: future)

      assert {:ok, effective, _} = DateTime.from_iso8601(window)

      assert DateTime.compare(effective, DateTime.utc_now()) != :gt,
             "meta.heat_window must never advertise a window that has not happened yet"

      # Clamped to today, so today's reads are still visible rather than the caller getting a
      # silent empty index.
      assert Enum.map(results, & &1.title) == ["Readable"]
    end

    test "ranker output is not a read, so a search hit or a context pack adds no heat" do
      # Both `search` and `context` write one row per RESULT of one query, so counting either
      # would make the ordering a running tally of past ranker output — the correlation with
      # embedding similarity this route exists to be free of.
      tenant = fixture(:tenant)
      impressions = published_article(tenant.id, %{title: "Only ever matched"})
      packed = published_article(tenant.id, %{title: "Only ever packed"})
      read = published_article(tenant.id, %{title: "Actually read"})

      heat(tenant.id, impressions, 20, %{access_type: "search"})
      heat(tenant.id, packed, 20, %{access_type: "context"})
      heat(tenant.id, read, 1)

      assert {:ok, %{results: results}} = Knowledge.heat_index(tenant.id)
      assert Enum.map(results, & &1.title) == ["Actually read"]
    end

    test "#569: a DRILL adds no heat, so the index cannot feed its own ranking" do
      # The loop this closes: heat ranks on `get`, and the tool the payload's own `meta.drill`
      # names recorded a `get` — so an article gained heat from having been SHOWN here.
      # Visibility produced reads, reads rank, rank visibility, and material that never
      # surfaced could not overtake material that already had. Unlike `search`/`context`, a
      # drill IS a genuine single-article body read; it is excluded because of where it comes
      # FROM, not what shape it is.
      tenant = fixture(:tenant)
      shown = published_article(tenant.id, %{title: "Kept getting shown"})
      read = published_article(tenant.id, %{title: "Actually sought out"})

      # 20 drills by 20 different readers — the strongest form of the loop, since distinct
      # readers is exactly what heat counts.
      heat(tenant.id, shown, 20, %{access_type: "drill"})
      heat(tenant.id, read, 1)

      assert {:ok, %{results: results}} = Knowledge.heat_index(tenant.id)
      assert Enum.map(results, & &1.title) == ["Actually sought out"]
    end

    test "#572: the uncounted label is derived from the read path, and is UNIFORM across scopes" do
      # Two halves of the same rule. The read still matters for analytics and follow-through,
      # so a fix that just dropped the event would pass the test above and lose data. And a
      # caller-declared origin cannot carry the rule — it binds only the clients that send it
      # — so a drill that says NOTHING must still be excluded.
      #
      # #569 shipped this for tenant-owned articles only: a canon's drill recorded a counted
      # `get`, because the drill was then its ONLY body path. That left `heat_index/2` ranking
      # a counted class against an uncounted one on one `heat` number, and since drilling is
      # the DOCUMENTED path, following the docs raised only canonicals.
      tenant = fixture(:tenant)
      {_raw, key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      own = published_article(tenant.id, %{title: "Tenant-owned, drilled"})

      canon =
        published_article(tenant.id, %{title: "Canon"})
        |> Ecto.Changeset.change(%{scope: :system, tenant_id: nil})
        |> AdminRepo.update!()

      assert {:ok, _} = Knowledge.progressive_drill(tenant.id, own.id, api_key_id: key.id)
      assert {:ok, _} = Knowledge.progressive_drill(tenant.id, canon.id, api_key_id: key.id)

      # `config/test.exs` sets `:analytics_recording_mode, :sync`, so the events are already
      # written when the calls return — no drain needed.
      assert recorded_types(tenant.id, own.id) == ["drill"]

      assert recorded_types(tenant.id, canon.id) == ["drill"],
             "a canonical's drill must be uncounted like any other, or heat ranks two units"
    end

    test "#572: a canonical earns heat the same way a tenant article does — a caller-named get" do
      # The canon must still PARTICIPATE, which is what made counting its drill tempting. The
      # fix gives it the read path it lacked instead of counting the one it had: get_article/3
      # now resolves a published canonical, so `knowledge_get` is a real caller-named read for
      # it and no longer 404s on a canon stub.
      #
      # Driven through the public API rather than by inserting events: fabricated `get` rows
      # would keep passing even if no production call could produce one, which is exactly how
      # the canon silently fell out of this index in the first place.
      tenant = fixture(:tenant)

      canonical =
        published_article(tenant.id, %{title: "Canon"})
        |> Ecto.Changeset.change(%{scope: :system, tenant_id: nil})
        |> AdminRepo.update!()

      own = published_article(tenant.id, %{title: "Own"})

      for _ <- 1..2 do
        {_raw, key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
        assert {:ok, _} = Knowledge.get_article(tenant.id, canonical.id, api_key_id: key.id)
      end

      heat(tenant.id, own, 1)

      assert {:ok, %{results: results}} = Knowledge.heat_index(tenant.id)
      assert Enum.map(results, & &1.title) == ["Canon", "Own"]
      assert Enum.map(results, & &1.heat) == [2, 1]
    end

    test "#572: drilling every article leaves the ranking EMPTY — no class accrues" do
      # The regression the split created, stated directly: with a canonical counted and a
      # tenant article not, a fleet following `meta.drill` drove the index monotonically
      # toward the shared canon, self-reinforcingly (shown -> drilled -> still shown). The
      # invariant is that the documented path moves NOTHING, whatever the scope.
      tenant = fixture(:tenant)
      own = published_article(tenant.id, %{title: "Own"})

      canon =
        published_article(tenant.id, %{title: "Canon"})
        |> Ecto.Changeset.change(%{scope: :system, tenant_id: nil})
        |> AdminRepo.update!()

      for _ <- 1..5 do
        {_raw, key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
        assert {:ok, _} = Knowledge.progressive_drill(tenant.id, canon.id, api_key_id: key.id)
        assert {:ok, _} = Knowledge.progressive_drill(tenant.id, own.id, api_key_id: key.id)
      end

      assert {:ok, %{results: []}} = Knowledge.heat_index(tenant.id)
    end
  end

  defp recorded_types(tenant_id, article_id) do
    Loopctl.AdminRepo.all(
      from(e in Loopctl.Knowledge.ArticleAccessEvent,
        where: e.tenant_id == ^tenant_id and e.article_id == ^article_id,
        select: e.access_type
      )
    )
  end

  describe "visibility scoping (#163) — the leak this surface makes easy" do
    test "an agent never sees another agent's private article, even as a stub" do
      tenant = fixture(:tenant)
      mine = "agent-mine"
      theirs = "agent-theirs"

      secret =
        published_article(tenant.id, %{
          title: "Their private memory",
          metadata: %{"visibility" => "private", "agent_id" => theirs}
        })

      ours = published_article(tenant.id, %{title: "Shared"})

      # The private one is HOTTER, so if ordering were applied before scoping it would be the
      # first thing in the index.
      heat(tenant.id, secret, 50)
      heat(tenant.id, ours, 1)

      assert {:ok, %{results: results}} =
               Knowledge.heat_index(tenant.id, visibility_agent_id: mine)

      titles = Enum.map(results, & &1.title)
      assert titles == ["Shared"]
      refute "Their private memory" in titles
      # Not even the id leaks — a stub list is still an enumeration of what exists.
      refute Enum.any?(results, &(&1.id == secret.id))
    end

    test "an agent DOES see its own private article" do
      tenant = fixture(:tenant)
      mine = "agent-mine"

      own =
        published_article(tenant.id, %{
          title: "My own memory",
          metadata: %{"visibility" => "owner", "agent_id" => mine}
        })

      heat(tenant.id, own, 4)

      assert {:ok, %{results: [%{title: "My own memory"}]}} =
               Knowledge.heat_index(tenant.id, visibility_agent_id: mine)
    end

    test "a non-agent caller (nil) sees everything, as elsewhere" do
      tenant = fixture(:tenant)

      secret =
        published_article(tenant.id, %{
          title: "Private",
          metadata: %{"visibility" => "private", "agent_id" => "someone"}
        })

      heat(tenant.id, secret, 2)

      assert {:ok, %{results: [%{title: "Private"}]}} = Knowledge.heat_index(tenant.id)
    end
  end

  describe "tenant isolation (repo rule)" do
    test "tenant A never sees tenant B's articles or their heat" do
      a = fixture(:tenant)
      b = fixture(:tenant)

      a_article = published_article(a.id, %{title: "A's article"})
      b_article = published_article(b.id, %{title: "B's article"})

      heat(a.id, a_article, 1)
      heat(b.id, b_article, 99)

      assert {:ok, %{results: results}} = Knowledge.heat_index(a.id)

      assert Enum.map(results, & &1.title) == ["A's article"]
      refute Enum.any?(results, &(&1.id == b_article.id))
    end
  end

  describe "the payload is bounded and self-describing" do
    test "top_k is clamped, so an explicit override cannot flood context" do
      tenant = fixture(:tenant)

      for i <- 1..4 do
        tenant.id |> published_article(%{title: "A#{i}"}) |> then(&heat(tenant.id, &1, i))
      end

      assert {:ok, %{results: results, meta: %{top_k: 2}}} =
               Knowledge.heat_index(tenant.id, limit: 2)

      assert length(results) == 2

      # Clamped at both ends, exactly like progressive_index/3.
      assert {:ok, %{meta: %{top_k: 1}}} = Knowledge.heat_index(tenant.id, limit: 0)
      assert {:ok, %{meta: %{top_k: 100}}} = Knowledge.heat_index(tenant.id, limit: 10_000)
    end

    test "the response says how to drill, so the payload is not just prose" do
      tenant = fixture(:tenant)
      tenant.id |> published_article() |> then(&heat(tenant.id, &1, 1))

      assert {:ok, %{meta: meta}} = Knowledge.heat_index(tenant.id)

      # `knowledge_get` filters by tenant_id, so it 404s on the published system canonicals
      # this index also lists — the named tool has to be one that opens every listed id.
      assert meta.drill.tool == "knowledge_progressive_drill"
      assert meta.drill.parameter == "article_id"
      # The ordering basis is stated, so a reader does not mistake heat for relevance.
      assert meta.drill.note =~ "heat_window"
      # And the note does NOT ask the caller to declare an origin: the exclusion is derived
      # server-side, so an instruction to opt in would misdescribe it (and bind nobody).
      refute meta.drill.note =~ "from="
      assert is_integer(meta.char_budget)
      assert is_integer(meta.chars)
      assert meta.counted_access_types == ["get"]
      # The ranking and the projection run on separate connections, so a ranked article can
      # vanish between them. The count of dropped ids is STATED, because a short list with
      # `truncated: false` would otherwise read as an exhausted one.
      assert meta.unresolved == 0
    end

    test "char_budget tracks the effective top_k and actually bounds the payload" do
      tenant = fixture(:tenant)

      # A title at the schema's 500-char ceiling: the budget is only a budget if the widest
      # legal stub still fits under it.
      article = published_article(tenant.id, %{title: String.duplicate("t", 500)})
      heat(tenant.id, article, 1)

      assert {:ok, %{results: [stub], meta: meta}} = Knowledge.heat_index(tenant.id, limit: 5)

      assert String.length(stub.title) <= 100
      assert meta.chars <= meta.char_budget
      # Derived from the ASKED-FOR cap, not the ceiling — limit: 5 must not advertise 100.
      # Not an exact 10x: the budget now includes the JSON array framing `chars` measures
      # (two brackets plus n-1 commas), which does not scale linearly with n (#572).
      assert {:ok, %{meta: %{char_budget: wider}}} = Knowledge.heat_index(tenant.id, limit: 50)
      assert wider == meta.char_budget * 10 - 9
    end

    test "#572: char_budget covers the array FRAMING, not just the stubs" do
      # `chars` summed per-stub sizes, so it omitted the two brackets and the n-1 commas the
      # caller actually receives: the number advertised as an ENFORCED budget was under by
      # n+1 on every response, and `char_budget` had the same hole. A budget that is wrong by
      # a predictable amount is worse than no budget, because it is trusted.
      tenant = fixture(:tenant)

      for i <- 1..3,
          do: tenant.id |> published_article(%{title: "A#{i}"}) |> then(&heat(tenant.id, &1, i))

      assert {:ok, %{results: stubs, meta: meta}} = Knowledge.heat_index(tenant.id, limit: 3)
      assert length(stubs) == 3

      # The reported figure is the whole encoded array, framing included.
      assert meta.chars == stubs |> Jason.encode!() |> byte_size()
      assert meta.chars > stubs |> Enum.map(&(&1 |> Jason.encode!() |> byte_size())) |> Enum.sum()
      assert meta.chars <= meta.char_budget
    end

    test "#572: chars is measured in BYTES, so multibyte content is not under-reported" do
      # `String.length/1` counts graphemes, so a CJK or emoji title under-reported the wire
      # size by 3-4x — the unsafe direction, on the one number a caller sizes a cached prefix
      # against, and nothing downstream of it (HTTP body, token estimate, context window)
      # counts graphemes.
      tenant = fixture(:tenant)

      multibyte = String.duplicate("日本語", 100)
      article = published_article(tenant.id, %{title: multibyte, body: multibyte})
      heat(tenant.id, article, 1)

      assert {:ok, %{results: [stub], meta: meta}} = Knowledge.heat_index(tenant.id, limit: 1)

      encoded = Jason.encode!([stub])
      assert meta.chars == byte_size(encoded)
      assert byte_size(encoded) > String.length(encoded), "the fixture must be multibyte"
      assert meta.chars <= meta.char_budget

      # The cap is a real BYTE bound now, so trimming must not shred the value to nothing
      # either — a byte overage used to be spent one grapheme (up to 3 bytes) at a time.
      # The SUMMARY is the assertion that matters: it is the padding `fit_stub_to_cap/1`
      # spends first, so grapheme-sliced fields against a byte cap emptied it outright while
      # a title-only check still passed.
      assert stub.title != ""
      assert stub.summary != "", "a multibyte stub must keep its summary, not just its title"
      assert String.valid?(stub.title) and String.valid?(stub.summary)
    end

    test "#567: chars is the ENCODED size, and the budget still bounds escape-heavy content" do
      # `chars` summed String.length over the RAW fields while the fixed-overhead constant it
      # added was measured off the ENCODED shape — two units in one number. Every character
      # below doubles when JSON-encoded, so a stub whose raw fields sit exactly on their caps
      # goes over the advertised budget on the wire. It under-reported, which is the unsafe
      # direction for the one number a caller sizes a cached prefix against.
      tenant = fixture(:tenant)

      escapey = String.duplicate("\"\\", 250)
      article = published_article(tenant.id, %{title: escapey, body: escapey})
      heat(tenant.id, article, 1)

      assert {:ok, %{results: [stub], meta: meta}} = Knowledge.heat_index(tenant.id, limit: 1)

      # The reported figure IS the wire size of what was returned — the whole array, in bytes.
      assert meta.chars == [stub] |> Jason.encode!() |> byte_size()

      # ...and the budget still holds, which is what it claims to do.
      assert meta.chars <= meta.char_budget
    end

    test "#572: only a DEMONSTRABLE pool exit degrades to an overload" do
      # The blanket `catch :exit` translated every exit into the gate's 429. A node
      # :shutdown mid-deploy, a sandbox ownership exit, a {:timeout, {GenServer, :call, _}}
      # from something that is not the pool — each was reported to the caller as "you are
      # reading too much" and to the operator as ordinary shedding, so a systemic fault wore
      # the costume of one tenant reading hard.
      tenant = fixture(:tenant)
      pool_reason = {:noproc, {DBConnection, :execute, []}}

      # Each call warns by design; capture so the deliberate log stays out of suite output.
      ExUnit.CaptureLog.capture_log(fn ->
        assert_raise Loopctl.HeavyRead.OverloadedError, fn ->
          Knowledge.heat_projection_exit(tenant.id, pool_reason)
        end

        # Anything unplaceable is re-exited untouched to whoever actually owns it.
        for foreign <- [:shutdown, {:timeout, {GenServer, :call, [:some_pid, :req]}}, :killed] do
          assert catch_exit(Knowledge.heat_projection_exit(tenant.id, foreign)) == foreign
        end
      end)
    end

    test "#572: a projection fault is logged by CLASS, never by raw reason" do
      # #562 sanitised exactly this one module over; the heat path was written after and did
      # not inherit it. A DBConnection.ConnectionError message names the backend host and
      # port, and inspect/1 on an exit reason leaks the checkout tuple — both into a log
      # stream that is not the place for backend topology.
      import ExUnit.CaptureLog

      tenant = fixture(:tenant)
      reason = {:noproc, {DBConnection, :execute, ["SELECT secret FROM t", ["bound-param"]]}}

      log =
        capture_log(fn ->
          assert_raise Loopctl.HeavyRead.OverloadedError, fn ->
            Knowledge.heat_projection_exit(tenant.id, reason)
          end
        end)

      assert log =~ "error_class=exit:noproc"
      assert log =~ tenant.id
      refute log =~ "bound-param", "bound parameters must never reach the log"
      refute log =~ "SELECT secret", "the failing statement must never reach the log"
    end

    test "#572: only a SATURATION fault degrades to an overload, and it logs the numeric code" do
      # The exit arm got a seam and two tests; the raise arm shipped with neither. Both rescued
      # classes carry permanent faults as well as load — a rotated credential is not "you are
      # reading too much", and neither is a column a not-yet-run migration adds. 08P01 is what
      # pgbouncer rejects with, and the earlier three-code 08 list dropped it into a 500.
      tenant = fixture(:tenant)
      pg = &Postgrex.Error.exception(postgres: %{code: &1, severity: "ERROR", message: "x"})

      # EVERY ConnectionError sheds, including the `:closed` and default-`:error` reasons.
      # This was briefly narrowed to `reason: :queue_timeout`, which misses the shape this
      # path produces BY DESIGN: driving `AdminRepo.query!(…, timeout: 30)` past a `pg_sleep`
      # raises `reason: :closed` ("tcp send: closed … possibly due to a timeout"), a value the
      # struct's own `:error | :queue_timeout` typespec does not list. The bounded wait
      # `@heat_stub_timeout_ms` imposes then answered 500 against a documented 429 — the one
      # case the rescue exists for. A Postgrex.Error carries an exact SQLSTATE and IS split;
      # a ConnectionError carries nothing that can carry the distinction.
      shed = [
        %DBConnection.ConnectionError{message: "checkout", reason: :queue_timeout},
        %DBConnection.ConnectionError{message: "tcp send: closed", reason: :closed},
        %DBConnection.ConnectionError{message: "econnrefused", reason: :error},
        pg.("53300"),
        pg.("08P01")
      ]

      permanent = [pg.("42703")]

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          for e <- shed do
            assert_raise Loopctl.HeavyRead.OverloadedError, fn ->
              Knowledge.heat_projection_raise(tenant.id, e, [])
            end
          end

          for e <- permanent do
            assert_raise e.__struct__, fn -> Knowledge.heat_projection_raise(tenant.id, e, []) end
          end
        end)

      # BOTH arms log, under the SQLSTATE spelling every other DB line uses — `postgres.code`
      # is Postgrex's atom NAME, which no operator alert is keyed on.
      assert log =~ "error_class=raise:Postgrex.Error"
      assert log =~ "sqlstate=53300"
      assert log =~ "sqlstate=42703"
      refute log =~ "sqlstate=too_many_connections"
    end

    test "the node-level admin gate sheds at its cap, and gives the slot back either way" do
      # This gate is the only thing keeping a per-turn endpoint off the LAST of AdminRepo's 3
      # connections, which custody writes and the per-request auth SELECT share. Saturate it
      # from outside and the endpoint must shed rather than queue behind them.
      #
      # Non-vacuous by construction: delete the gate from `heat_stub_projection/2` and
      # `heat_index/2` succeeds here instead of raising, so this test fails.
      tenant = fixture(:tenant)
      article = published_article(tenant.id, %{title: "Readable"})
      heat(tenant.id, article, 2)

      key = "knowledge.heat_stub_projection"
      cap = max(1, DbCapacity.runtime_pool_sizes().admin_repo - 1)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          :ok = TenantGate.acquire(key, cap, cap)

          try do
            assert_raise HeavyRead.OverloadedError, fn -> Knowledge.heat_index(tenant.id) end
          after
            TenantGate.release(key, cap)
          end
        end)

      # A NODE-wide shed must not be logged as one tenant reading too much — that is how
      # saturation of a shared pool gets mistaken for ordinary per-tenant backpressure.
      assert log =~ "admin_pool_node_gate_shed"

      # And the slot comes back on BOTH paths: the index answers again, and the node-wide
      # counter is back to zero rather than leaking a permit per shed.
      assert {:ok, %{results: [%{title: "Readable"}]}} = Knowledge.heat_index(tenant.id)
      assert TenantGate.count(key) == 0
    end

    test "truncated says the list is partial, since nothing else in the payload would" do
      tenant = fixture(:tenant)

      for i <- 1..3,
          do: tenant.id |> published_article(%{title: "A#{i}"}) |> then(&heat(tenant.id, &1, i))

      assert {:ok, %{meta: %{truncated: true}}} = Knowledge.heat_index(tenant.id, limit: 2)
      assert {:ok, %{meta: %{truncated: false}}} = Knowledge.heat_index(tenant.id, limit: 3)
    end

    test "a summary is one line and bounded, whatever the body looks like" do
      tenant = fixture(:tenant)

      article =
        published_article(tenant.id, %{
          body:
            "First line.\n\nSecond paragraph with   irregular\twhitespace. " <>
              String.duplicate("padding ", 200)
        })

      heat(tenant.id, article, 1)

      assert {:ok, %{results: [stub]}} = Knowledge.heat_index(tenant.id)

      refute stub.summary =~ "\n"
      refute stub.summary =~ "  "
      assert String.length(stub.summary) <= 120
    end

    test ":category narrows the index" do
      tenant = fixture(:tenant)

      pattern = published_article(tenant.id, %{title: "P", category: :pattern})
      decision = published_article(tenant.id, %{title: "D", category: :decision})

      heat(tenant.id, pattern, 5)
      heat(tenant.id, decision, 5)

      assert {:ok, %{results: results}} = Knowledge.heat_index(tenant.id, category: :decision)

      assert Enum.map(results, & &1.title) == ["D"]
    end
  end
end

defmodule Loopctl.Knowledge.HeatIndexEndpointTest do
  @moduledoc """
  #554 — the HTTP surface for the heat index.

  Covers the two things unit tests on `Knowledge.heat_index/2` cannot: that the route is
  actually wired, and that visibility scoping is derived from the CALLER'S KEY rather than
  from a caller-supplied parameter. The second matters more — a scope you can pass in is not
  a scope.
  """
  use LoopctlWeb.ConnCase, async: true

  alias Loopctl.AdminRepo

  setup :verify_on_exit!

  defp published(tenant_id, attrs) do
    base = %{
      title: "T#{System.unique_integer([:positive])}",
      body: "b",
      category: :pattern,
      status: :draft,
      tags: []
    }

    fixture(:article, Map.merge(base, Map.put(attrs, :tenant_id, tenant_id)))
    |> Ecto.Changeset.change(%{status: :published})
    |> AdminRepo.update!()
  end

  defp heat(tenant_id, article, n) do
    for _ <- 1..n,
        do: fixture(:article_access_event, %{tenant_id: tenant_id, article_id: article.id})

    article
  end

  test "returns heat-ranked stubs with the drill instruction", %{conn: conn} do
    tenant = fixture(:tenant)
    {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

    hot = published(tenant.id, %{title: "Hot"})
    cold = published(tenant.id, %{title: "Cold"})
    heat(tenant.id, hot, 7)
    heat(tenant.id, cold, 1)

    body =
      conn
      |> put_req_header("authorization", "Bearer #{raw_key}")
      |> get(~p"/api/v1/knowledge/heat_index")
      |> json_response(200)

    assert Enum.map(body["data"], & &1["title"]) == ["Hot", "Cold"]
    assert Enum.map(body["data"], & &1["heat"]) == [7, 1]
    # Self-describing: the payload says how to act on an id.
    assert body["meta"]["drill"]["tool"] == "knowledge_progressive_drill"
    assert {:ok, _, _} = DateTime.from_iso8601(body["meta"]["heat_window"])
    assert body["meta"]["counted_access_types"] == ["get"]
    assert body["meta"]["unresolved"] == 0
  end

  test "a malformed `since` is a 400, not a silent widening of the window", %{conn: conn} do
    tenant = fixture(:tenant)
    {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

    conn
    |> put_req_header("authorization", "Bearer #{raw_key}")
    |> get(~p"/api/v1/knowledge/heat_index?since=not-a-date")
    |> json_response(400)
  end

  test "a list-shaped `since` is a 400, not a FunctionClauseError 500", %{conn: conn} do
    tenant = fixture(:tenant)
    {raw_key, _} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})

    conn
    |> put_req_header("authorization", "Bearer #{raw_key}")
    |> get("/api/v1/knowledge/heat_index?since[]=2026-01-01T00:00:00Z")
    |> json_response(400)
  end

  test "visibility comes from the KEY, so another tenant's articles never appear", %{conn: conn} do
    a = fixture(:tenant)
    b = fixture(:tenant)
    {a_key, _} = fixture(:api_key, %{tenant_id: a.id, role: :agent})

    a_art = published(a.id, %{title: "A"})
    b_art = published(b.id, %{title: "B"})
    heat(a.id, a_art, 1)
    heat(b.id, b_art, 50)

    body =
      conn
      |> put_req_header("authorization", "Bearer #{a_key}")
      |> get(~p"/api/v1/knowledge/heat_index")
      |> json_response(200)

    titles = Enum.map(body["data"], & &1["title"])
    assert titles == ["A"]
    refute "B" in titles
  end
end
