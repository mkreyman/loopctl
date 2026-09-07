defmodule Loopctl.MemoryRecallContextTest do
  @moduledoc """
  #411 Gap 2 (PR B): `Loopctl.Memory.recall_context/2` — the merged, re-ranked
  `global ∪ active-project` recall combining long-term MEMORY and KNOWLEDGE in one call.

  Covers: both sides merge global with the active project and EXCLUDE another project;
  the merged list is tagged per-source and sorted by score DESC; the per-source
  envelopes are returned unchanged; and a knowledge fault degrades gracefully to a
  memory-only result with `degraded?: true` (never a crash).

  Async: memory OLTP + recall route through `Loopctl.AdminRepo`/`Loopctl.HeavyRead`
  (AdminRepo in test) and knowledge through `AdminRepo`, so every path shares the one
  sandbox connection; the embedding worker runs inline during `remember/2`.
  """
  use Loopctl.DataCase, async: true
  use Oban.Testing, repo: Loopctl.Repo

  setup :verify_on_exit!

  import ExUnit.CaptureLog

  alias Loopctl.Knowledge
  alias Loopctl.Memory
  alias Loopctl.Memory.Scope
  alias LoopctlWeb.Outcome

  defp article(tenant_id, project_id, title) do
    art =
      fixture(:article, %{
        tenant_id: tenant_id,
        project_id: project_id,
        status: :published,
        title: title,
        body: "reshipment policy notes for #{title}"
      })

    {:ok, updated} = Knowledge.update_embedding(tenant_id, art.id, distinct_embedding())
    updated
  end

  # Every article here used to be embedded at the IDENTICAL `[0.1] * 1536`, which is
  # cosine 1.0 between any two of them — so once #792's near-duplicate removal landed, a
  # test about SCOPE merging started failing on redundancy it had accidentally
  # manufactured. Each article now gets a vector that is still close to the others (they
  # must all match one query) but distinguishable: a shared 0.1 base with a 2.0 spike at
  # its own index, which is cosine ~0.80 between any two, comfortably under the 0.95
  # threshold. Tests that want to exercise the duplicate path build the collision
  # deliberately.
  defp distinct_embedding do
    # A PROCESS-LOCAL counter, not `System.unique_integer/1`: that counter has a large,
    # scheduler-dependent stride, so `rem(unique_integer, 1536)` collided on 12 of 24
    # articles here and half the corpus vanished as near-duplicates. Each test runs in its
    # own process, so 0, 1, 2, ... is collision-free within a test and independent across.
    index = rem(Process.get(:diversity_spike_index, 0), 1536)
    Process.put(:diversity_spike_index, index + 1)

    0.1
    |> List.duplicate(1536)
    |> List.replace_at(index, 2.1)
  end

  defp mem(scope, project_id, text) do
    {:ok, m} = Memory.remember(%{scope | project_id: project_id}, %{tier: :long_term, text: text})
    m
  end

  defp memory_ids(env), do: env.results |> Enum.map(fn {m, _} -> m.id end) |> MapSet.new()
  defp knowledge_ids(env), do: env.results |> Enum.map(& &1.id) |> MapSet.new()

  setup do
    tenant = fixture(:tenant)
    project = fixture(:project, %{tenant_id: tenant.id})
    other_project = fixture(:project, %{tenant_id: tenant.id})
    Knowledge.reset_circuit_breaker(tenant.id)

    scope = %Scope{
      tenant_id: tenant.id,
      subject_id: "subject-#{System.unique_integer([:positive])}",
      project_id: project.id
    }

    %{tenant: tenant, project: project, other_project: other_project, scope: scope}
  end

  describe "recall_context/2 - merged global ∪ active-project" do
    test "merges memory + knowledge, both scopes, excludes another project", ctx do
      # Memory: global + this project + another project.
      global_mem = mem(ctx.scope, nil, "reshipment for delayed orders global")
      project_mem = mem(ctx.scope, ctx.project.id, "reshipment for delayed orders project")
      other_mem = mem(ctx.scope, ctx.other_project.id, "reshipment for delayed orders other")

      # Knowledge: global + this project + another project.
      global_art = article(ctx.tenant.id, nil, "global article")
      project_art = article(ctx.tenant.id, ctx.project.id, "project article")
      other_art = article(ctx.tenant.id, ctx.other_project.id, "other project article")

      result = Memory.recall_context(ctx.scope, query: "reshipment", limit: 20)

      # Per-source memory: global ∪ project, NOT another project.
      m_ids = memory_ids(result.memory)
      assert MapSet.member?(m_ids, global_mem.id)
      assert MapSet.member?(m_ids, project_mem.id)
      refute MapSet.member?(m_ids, other_mem.id)

      # Per-source knowledge: global ∪ project, NOT another project.
      k_ids = knowledge_ids(result.knowledge)
      assert MapSet.member?(k_ids, global_art.id)
      assert MapSet.member?(k_ids, project_art.id)
      refute MapSet.member?(k_ids, other_art.id)

      # Merged list carries BOTH source tags.
      sources = result.results |> Enum.map(& &1.source) |> MapSet.new()
      assert MapSet.equal?(sources, MapSet.new([:memory, :knowledge]))

      # Merged sorted by score DESC.
      scores = Enum.map(result.results, & &1.score)
      assert scores == Enum.sort(scores, :desc)

      # Meta accounting.
      assert result.meta.query == "reshipment"
      assert result.meta.project_id == ctx.project.id
      assert result.meta.degraded? == false
      assert result.meta.memory_count == 2
      assert result.meta.knowledge_count == 2
      assert result.meta.total_count == length(result.results)

      # Merged item shapes.
      mem_item = Enum.find(result.results, &(&1.source == :memory))
      assert %{memory: %Memory.Memory{}, score: score} = mem_item
      assert is_number(score)

      know_item = Enum.find(result.results, &(&1.source == :knowledge))
      assert %{article: %{final_score: _}, score: _} = know_item
    end

    test "a nil-project scope is global-only on BOTH memory and knowledge" do
      # With no active project the `global ∪ active-project` union is GLOBAL-ONLY on
      # BOTH sides (matching the published RecallContextRequest / MCP recall_context
      # contract). Memory's nil semantics scope to `project_id IS NULL`; knowledge's
      # `:with_global` mode ALSO scopes a nil project to `project_id IS NULL` (rather
      # than the former no-op that flooded the merged limit with every project's rows).
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      Knowledge.reset_circuit_breaker(tenant.id)

      global_scope = %Scope{
        tenant_id: tenant.id,
        subject_id: "subject-#{System.unique_integer([:positive])}",
        project_id: nil
      }

      project_scope = %{global_scope | project_id: project.id}

      global_mem = mem(global_scope, nil, "reshipment global only")
      project_mem = mem(project_scope, project.id, "reshipment project only")
      global_art = article(tenant.id, nil, "global only article")
      project_art = article(tenant.id, project.id, "project only article")

      result = Memory.recall_context(global_scope, query: "reshipment", limit: 20)

      # Memory: global-only (excludes the project-tagged memory).
      assert MapSet.equal?(memory_ids(result.memory), MapSet.new([global_mem.id]))
      refute MapSet.member?(memory_ids(result.memory), project_mem.id)

      # Knowledge: global-only too → the global article, NOT the project-tagged one.
      k_ids = knowledge_ids(result.knowledge)
      assert MapSet.member?(k_ids, global_art.id)
      refute MapSet.member?(k_ids, project_art.id)
    end
  end

  describe "recall_context/2 - graceful knowledge degradation" do
    test "an empty query degrades knowledge to memory-only with degraded?: true", ctx do
      # An empty query is a knowledge fault (`search_combined/3` → {:error, :empty_query})
      # but memory recall still returns rows — the merged call must not crash.
      project_mem = mem(ctx.scope, ctx.project.id, "reshipment kept on empty query")

      result = Memory.recall_context(ctx.scope, query: "", limit: 10)

      assert result.knowledge.results == []
      assert result.meta.knowledge_count == 0
      assert result.meta.degraded? == true

      # Memory side survived.
      assert MapSet.member?(memory_ids(result.memory), project_mem.id)
      assert Enum.all?(result.results, &(&1.source == :memory))
    end

    test "an error reason outside the mapped contract still renders the degraded envelope",
         ctx do
      # Proven able to go red, by deleting the fallback clause under it:
      #   bin/mutate.sh lib/loopctl/memory.ex --old-file <the clause> --delete \
      #     -- mix test test/loopctl/memory_recall_context_test.exs
      # exit 0 — the check failed under the mutation (FunctionClauseError on
      # `knowledge_degraded_reason_tag/1`) and passed without it.
      #
      # `Knowledge.search_combined/3` is specced to return `{:error, atom(), String.t()}`,
      # so its error contract can grow past the three reasons the tag clauses map. A
      # fourth reason must degrade `/recall` exactly like the mapped ones, never raise
      # `FunctionClauseError` on the way to building the envelope.
      log =
        capture_log(fn ->
          env = Memory.degraded_knowledge_env(ctx.tenant.id, :a_reason_nobody_mapped_yet, 10)

          assert env.results == []
          assert env.meta.total_count == 0
          assert env.meta.limit == 10
          assert env.meta.degraded? == true
          assert env.meta.fallback == true

          # The tag is generic and BOUNDED — the unmapped atom never reaches the client
          # meta — and it is one `LoopctlWeb.Outcome` already classifies, so the caller
          # still reads "the retrieval could not run" rather than a plain empty result.
          assert env.meta.fallback_reason == "request_error"
          assert env.meta.fallback_reason in Memory.knowledge_degraded_reason_tags()
          assert Outcome.derive(env.meta, length(env.results)) == "error"
        end)

      # The reason itself is logged, so the first unmapped one is visible to an operator.
      assert log =~ "a_reason_nobody_mapped_yet"
    end

    test "every mapped reason renders a tag the outcome classifier calls an error", ctx do
      for reason <- [:empty_query, :invalid_weights, :bad_request] do
        env = Memory.degraded_knowledge_env(ctx.tenant.id, reason, 5)

        assert env.meta.fallback_reason == Atom.to_string(reason)
        assert Outcome.derive(env.meta, 0) == "error"
      end
    end
  end

  describe "merged_degradation/2 — one tag, ordered by remedy" do
    # Both halves can degrade at once and the merged meta carries ONE tag, so whichever
    # is reported is the only remedy the caller ever sees. Each case below is a pair that
    # co-occurs in practice, asserted with what `LoopctlWeb.Outcome` makes of it.
    test "a knowledge half that never RAN outranks a memory shed" do
      # The shed's remedy is to wait; no wait fixes a request the caller must change.
      assert {"bad_request", nil} =
               Memory.merged_degradation(memory_shed_env(), knowledge_unrunnable_env())
    end

    test "a memory configuration fault outranks a knowledge keyword-only fallback" do
      # Both are caused by an embedding change, so co-occurrence is the expected case.
      # Reported the other way round the agent retries a half only an operator restores.
      {reason, lane} =
        Memory.merged_degradation(
          memory_unavailable_env(),
          knowledge_fallback_env("embedding_timeout", "keyword_only")
        )

      assert {"embedding_dimension_mismatch", nil} == {reason, lane}
      assert merged_outcome(reason, lane, 0) == "error"
    end

    test "a memory shed outranks a knowledge keyword-only fallback" do
      assert {"heavy_read_overloaded", nil} =
               Memory.merged_degradation(
                 memory_shed_env(),
                 knowledge_fallback_env("embedding_timeout", "keyword_only")
               )
    end

    test "a knowledge shed that DID serve keyword-only reports the lane it served" do
      # The SAME tag as the memory shed, and the opposite remedy. The lane is what tells
      # them apart on the merged meta, which carries no per-half envelope to read.
      {reason, lane} =
        Memory.merged_degradation(
          healthy_env(),
          knowledge_fallback_env("heavy_read_overloaded", "keyword_only")
        )

      assert {"heavy_read_overloaded", "keyword_only"} == {reason, lane}
      assert merged_outcome(reason, lane, 3) == "fallback"
    end

    test "two healthy halves report nothing" do
      assert {nil, nil} = Memory.merged_degradation(healthy_env(), healthy_env())
    end

    # The ledger arm is the one reason that is NOT about the results: both halves
    # answered, but the surfacing rows were not written, so the `recall_id` this response
    # publishes names no rows and `/referenced` refuses every id under it. Reported LAST
    # for exactly that reason — a degraded half carries a remedy for the results the
    # caller is holding, which outranks a remedy for a follow-up call it may never make.
    test "a failed surfacing ledger is reported when both halves are healthy" do
      assert {"recall_ledger_unavailable", nil} =
               Memory.merged_degradation(
                 healthy_env(),
                 healthy_env(),
                 {:error, :recording_failed}
               )
    end

    test "a degraded half outranks a failed ledger" do
      assert {"heavy_read_overloaded", nil} =
               Memory.merged_degradation(
                 memory_shed_env(),
                 healthy_env(),
                 {:error, :recording_failed}
               )
    end

    test "a written ledger adds no tag" do
      assert {nil, nil} = Memory.merged_degradation(healthy_env(), healthy_env(), :ok)
    end
  end

  # The merged meta as `RecallJSON` renders it, reduced to the keys `Outcome` reads.
  defp merged_outcome(reason, lane, count),
    do: Outcome.derive(%{degraded: true, degraded_reason: reason, search_mode: lane}, count)

  defp envelope(meta), do: %{results: [], meta: meta}

  defp memory_shed_env,
    do: envelope(%{total_count: 0, fallback: true, reason: "heavy_read_overloaded"})

  defp memory_unavailable_env,
    do: envelope(%{total_count: 0, fallback: true, reason: "embedding_dimension_mismatch"})

  defp healthy_env, do: envelope(%{total_count: 0, degraded?: false})

  defp knowledge_fallback_env(reason, mode),
    do:
      envelope(%{
        total_count: 0,
        degraded?: true,
        fallback: true,
        fallback_reason: reason,
        search_mode: mode
      })

  defp knowledge_unrunnable_env,
    do:
      envelope(%{total_count: 0, degraded?: true, fallback: true, fallback_reason: "bad_request"})

  describe "recall_context/2 - overall merged limit" do
    test "clamps the merged, re-ranked list to `limit`", ctx do
      for i <- 1..4, do: mem(ctx.scope, ctx.project.id, "reshipment memory #{i}")
      for i <- 1..4, do: article(ctx.tenant.id, ctx.project.id, "reshipment article #{i}")

      result = Memory.recall_context(ctx.scope, query: "reshipment", limit: 3)

      assert length(result.results) == 3
      assert result.meta.total_count == 3
    end
  end

  # --- #470: cross-source ranking must use the ABSOLUTE knowledge score, not RRF final_score
  describe "recall_context/2 - cross-source ranking uses the absolute knowledge score (#470)" do
    test "a knowledge merged score is the absolute per-row relevance, not the tiny RRF final_score",
         ctx do
      # A query embedding equal to the article embedding (0.1 vector) makes the knowledge
      # article a near-perfect semantic match (cosine similarity ≈ 1.0).
      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _t, _text ->
        {:ok, List.duplicate(0.1, 1536)}
      end)

      art = article(ctx.tenant.id, ctx.project.id, "reshipment strong match")
      _mem = mem(ctx.scope, ctx.project.id, "reshipment memory note")

      result = Memory.recall_context(ctx.scope, query: "reshipment", limit: 20)

      know_item =
        Enum.find(result.results, &(&1.source == :knowledge and &1.article.id == art.id))

      assert know_item

      # The merged cross-source score is the ABSOLUTE relevance (cosine similarity ≈ 1.0 here)
      # — the SAME 0..1 scale as memory's cosine — NOT the fused RRF final_score
      # (`Σ weight/(k+rank)`, top ~0.008-0.016). Reading final_score here would sink every
      # knowledge row below every memory row (#470 review).
      assert know_item.score == Knowledge.absolute_result_score(know_item.article)
      assert know_item.score > 0.5
      assert know_item.score > (know_item.article[:final_score] || 0.0)

      # The merged list is still sorted by that single score DESC across both sources.
      scores = Enum.map(result.results, & &1.score)
      assert scores == Enum.sort(scores, :desc)
      assert result.meta.results_ranking == "heuristic_cross_source"
    end
  end

  describe "recall_context/2 - diversity selection (#792)" do
    # A shared 0.1 base with a 2.1 spike at ONE index. Two articles built on the same index
    # are cosine 1.0 (identical vectors); two on different indexes are ~0.80, comfortably
    # under the 0.95 threshold. Every collision here is therefore constructed on purpose —
    # nothing depends on the fixture defaults happening to collide.
    defp spiked(index) do
      0.1 |> List.duplicate(1536) |> List.replace_at(index, 2.1)
    end

    defp embedded_article(tenant_id, title, vector, content_hash \\ nil) do
      art =
        fixture(:article, %{
          tenant_id: tenant_id,
          project_id: nil,
          status: :published,
          title: title,
          body: "#{title} body text"
        })

      {:ok, _} = Knowledge.update_embedding(tenant_id, art.id, vector, content_hash)
      art
    end

    defp knowledge_result_ids(result) do
      result.results
      |> Enum.filter(&(&1.source == :knowledge))
      |> Enum.map(& &1.article.id)
    end

    test "two near-duplicates yield ONE of them PLUS the next distinct candidate", ctx do
      marker = "neardup#{System.unique_integer([:positive])}"

      # The QUERY embeds to the twins' own vector, so the semantic lane ranks both of them
      # above the distinct article — the topically-clustered corpus this feature exists for,
      # built deliberately rather than hoped for. The baseline below PROVES the clustering.
      Mox.stub(Loopctl.MockEmbeddingClient, :generate_embedding, fn _t, _text ->
        {:ok, spiked(1)}
      end)

      # BOTH lanes have to favour the twins, not just one: `search_combined/3` fuses
      # keyword and semantic ranks with RRF, and a distinct article that wins the keyword
      # lane can out-fuse a twin that only wins the semantic one. So the twins carry the
      # marker three times as well as owning the query's exact vector.
      twin_a =
        embedded_article(ctx.tenant.id, "#{marker} #{marker} #{marker} alpha", spiked(1))

      twin_b = embedded_article(ctx.tenant.id, "#{marker} #{marker} #{marker} beta", spiked(1))
      distinct = embedded_article(ctx.tenant.id, "#{marker} gamma", spiked(900))

      # NON-VACUITY, and the whole reason this baseline is in the test rather than assumed:
      # if the twins did NOT already occupy both slots, the assertion below would pass
      # without diversity having done anything at all.
      baseline =
        Memory.recall_context(ctx.scope, query: marker, limit: 2, diversity_enabled: false)

      assert Enum.sort(knowledge_result_ids(baseline)) == Enum.sort([twin_a.id, twin_b.id]),
             "the corpus must actually be clustered at the top, or the refill is untested"

      result = Memory.recall_context(ctx.scope, query: marker, limit: 2)
      ids = knowledge_result_ids(result)

      # THE REFILL. Removing a near-duplicate is only half the fix: without the refill this
      # is a one-row answer and the second slot — one of the three a session ever sees — is
      # simply wasted. Assert BOTH that a twin went AND that `distinct` took the freed slot.
      assert length(ids) == 2
      assert distinct.id in ids
      assert Enum.count(ids, &(&1 in [twin_a.id, twin_b.id])) == 1
      assert result.meta.diversity.dropped_near_duplicates >= 1
      assert result.meta.diversity.enabled == true
    end

    test "the freed slot is refilled from the OVER-FETCHED pool, not from the page", ctx do
      # `candidates_considered.knowledge` must exceed the returned count, or there was
      # nothing to refill FROM and the previous test passed by accident of pool size.
      marker = "overfetch#{System.unique_integer([:positive])}"

      for i <- 1..4, do: embedded_article(ctx.tenant.id, "#{marker} a#{i}", spiked(i * 7))

      result = Memory.recall_context(ctx.scope, query: marker, limit: 2)

      assert result.meta.candidates_considered.knowledge > length(knowledge_result_ids(result))
      assert result.meta.diversity.candidates == result.meta.candidates_considered.knowledge
    end

    test "an exact content-hash duplicate collapses to one row", ctx do
      marker = "exactdup#{System.unique_integer([:positive])}"
      hash = "sha-#{System.unique_integer([:positive])}"

      a = embedded_article(ctx.tenant.id, "#{marker} one", spiked(11), hash)
      b = embedded_article(ctx.tenant.id, "#{marker} two", spiked(500), hash)
      c = embedded_article(ctx.tenant.id, "#{marker} three", spiked(1200), "other-#{hash}")

      result = Memory.recall_context(ctx.scope, query: marker, limit: 3)
      ids = knowledge_result_ids(result)

      assert c.id in ids
      assert Enum.count(ids, &(&1 in [a.id, b.id])) == 1
      assert result.meta.diversity.dropped_exact_duplicates == 1
    end

    test "containment-in-history: a second recall in the same session skips what it showed",
         ctx do
      marker = "history#{System.unique_integer([:positive])}"
      session = "sess-#{System.unique_integer([:positive])}"

      for i <- 1..3, do: embedded_article(ctx.tenant.id, "#{marker} a#{i}", spiked(i * 13))

      first = Memory.recall_context(ctx.scope, query: marker, limit: 1, session_id: session)
      first_ids = knowledge_result_ids(first)
      assert length(first_ids) == 1

      second = Memory.recall_context(ctx.scope, query: marker, limit: 1, session_id: session)
      second_ids = knowledge_result_ids(second)

      assert length(second_ids) == 1
      assert second_ids != first_ids
      assert second.meta.diversity.dropped_already_seen >= 1
    end

    test "containment is per-tenant: another tenant's identical session token is inert", ctx do
      marker = "histiso#{System.unique_integer([:positive])}"
      session = "sess-#{System.unique_integer([:positive])}"

      other_tenant = fixture(:tenant)
      Knowledge.reset_circuit_breaker(other_tenant.id)

      mine = embedded_article(ctx.tenant.id, "#{marker} mine", spiked(21))
      theirs = embedded_article(other_tenant.id, "#{marker} theirs", spiked(21))

      other_scope = %Scope{
        tenant_id: other_tenant.id,
        subject_id: "subject-#{System.unique_integer([:positive])}",
        project_id: nil
      }

      first = Memory.recall_context(ctx.scope, query: marker, limit: 1, session_id: session)
      assert knowledge_result_ids(first) == [mine.id]

      # The SAME session token under a different tenant. `session_id` is client-chosen, so a
      # collision is trivially forgeable; `tenant_id` being in the history key is what makes
      # it harmless.
      other = Memory.recall_context(other_scope, query: marker, limit: 1, session_id: session)

      assert knowledge_result_ids(other) == [theirs.id]
      assert other.meta.diversity.dropped_already_seen == 0
    end

    test "no session_id means no containment — a repeat recall returns the same row", ctx do
      marker = "nosession#{System.unique_integer([:positive])}"

      for i <- 1..3, do: embedded_article(ctx.tenant.id, "#{marker} a#{i}", spiked(i * 17))

      first = Memory.recall_context(ctx.scope, query: marker, limit: 1)
      second = Memory.recall_context(ctx.scope, query: marker, limit: 1)

      assert knowledge_result_ids(first) == knowledge_result_ids(second)
      assert first.meta.diversity.dropped_already_seen == 0
    end

    test "lambda 1.0 with the dedup stages off reproduces the pre-#792 selection exactly",
         ctx do
      marker = "lambda#{System.unique_integer([:positive])}"

      for i <- 1..4, do: embedded_article(ctx.tenant.id, "#{marker} a#{i}", spiked(i * 23))

      off = Memory.recall_context(ctx.scope, query: marker, limit: 3, diversity_enabled: false)

      pure =
        Memory.recall_context(ctx.scope,
          query: marker,
          limit: 3,
          diversity_lambda: 1.0,
          diversity_near_dup_threshold: 2.0
        )

      assert knowledge_result_ids(pure) == knowledge_result_ids(off)
      assert Enum.map(pure.results, & &1.score) == Enum.map(off.results, & &1.score)
      assert pure.meta.diversity.lambda == 1.0
      assert off.meta.diversity.enabled == false
    end

    test "selection does not decide render order — the merged list is still score DESC", ctx do
      marker = "order#{System.unique_integer([:positive])}"

      for i <- 1..4, do: embedded_article(ctx.tenant.id, "#{marker} a#{i}", spiked(i * 29))

      result = Memory.recall_context(ctx.scope, query: marker, limit: 3, diversity_lambda: 0.3)

      scores = Enum.map(result.results, & &1.score)
      assert scores == Enum.sort(scores, :desc)
      assert Enum.map(result.results, & &1.rank) == Enum.to_list(1..length(result.results))
    end

    test "the knowledge envelope publishes the SELECTED set, never the over-fetched pool",
         ctx do
      marker = "envelope#{System.unique_integer([:positive])}"

      for i <- 1..5, do: embedded_article(ctx.tenant.id, "#{marker} a#{i}", spiked(i * 31))

      result = Memory.recall_context(ctx.scope, query: marker, limit: 2)

      assert length(result.knowledge.results) <= 2
      assert result.meta.knowledge_count == length(result.knowledge.results)
      assert result.meta.candidates_considered.knowledge >= result.meta.knowledge_count
    end

    test "an unembedded article is never dropped as a duplicate", ctx do
      marker = "unembedded#{System.unique_integer([:positive])}"

      twin_a = embedded_article(ctx.tenant.id, "#{marker} alpha", spiked(41))
      twin_b = embedded_article(ctx.tenant.id, "#{marker} beta", spiked(41))

      bare =
        fixture(:article, %{
          tenant_id: ctx.tenant.id,
          project_id: nil,
          status: :published,
          title: "#{marker} bare",
          body: "#{marker} bare body text"
        })

      result = Memory.recall_context(ctx.scope, query: marker, limit: 3)
      ids = knowledge_result_ids(result)

      assert bare.id in ids
      assert Enum.count(ids, &(&1 in [twin_a.id, twin_b.id])) == 1
    end
  end
end
