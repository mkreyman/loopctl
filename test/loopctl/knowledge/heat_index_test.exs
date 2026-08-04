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

    test "#569: only a drill FROM this index is uncounted; the read is always recorded" do
      # Two halves of the same rule. The read still matters for analytics and follow-through,
      # so a fix that just dropped the event would pass the test above and lose data. And the
      # exclusion is the index HOP, not the tool: labelling every drill made the topic-seeded
      # route silent and left the canon (drilled below) with no way to earn heat at all.
      tenant = fixture(:tenant)
      {_raw, key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
      from_index = published_article(tenant.id, %{title: "Drilled from the index"})
      from_topic = published_article(tenant.id, %{title: "Drilled from a topic"})

      assert {:ok, _} =
               Knowledge.progressive_drill(tenant.id, from_index.id,
                 api_key_id: key.id,
                 from: :heat_index
               )

      assert {:ok, _} =
               Knowledge.progressive_drill(tenant.id, from_topic.id, api_key_id: key.id)

      # `config/test.exs` sets `:analytics_recording_mode, :sync`, so the events are already
      # written when the calls return — no drain needed.
      assert recorded_types(tenant.id, from_index.id) == ["drill"]
      assert recorded_types(tenant.id, from_topic.id) == ["get"]
    end

    test "a published system canonical earns heat from the only read path it has" do
      # A canon's body is readable ONLY through progressive_drill (get_article filters on
      # tenant_id, and a canon row's is NULL), so this drives that path rather than inserting
      # events: fabricated `get` rows would keep passing even if no production call could ever
      # produce one, which is exactly how the canon silently fell out of this index.
      tenant = fixture(:tenant)

      canonical =
        published_article(tenant.id, %{title: "Canon"})
        |> Ecto.Changeset.change(%{scope: :system, tenant_id: nil})
        |> AdminRepo.update!()

      own = published_article(tenant.id, %{title: "Own"})

      for _ <- 1..2 do
        {_raw, key} = fixture(:api_key, %{tenant_id: tenant.id, role: :agent})
        assert {:ok, _} = Knowledge.progressive_drill(tenant.id, canonical.id, api_key_id: key.id)
      end

      heat(tenant.id, own, 1)

      assert {:ok, %{results: results}} = Knowledge.heat_index(tenant.id)
      assert Enum.map(results, & &1.title) == ["Canon", "Own"]
      assert Enum.map(results, & &1.heat) == [2, 1]
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
      # And the parameter that keeps this index out of its own ranking is NAMED — the
      # exclusion is cooperative, so an instruction nobody can read is no exclusion at all.
      assert meta.drill.note =~ "from=heat_index"
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
      assert {:ok, %{meta: %{char_budget: wider}}} = Knowledge.heat_index(tenant.id, limit: 50)
      assert wider == meta.char_budget * 10
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

      # The reported figure IS the wire size of what was returned.
      assert meta.chars == stub |> Jason.encode!() |> String.length()

      # ...and the budget still holds, which is what it claims to do.
      assert meta.chars <= meta.char_budget
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
