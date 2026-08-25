defmodule Loopctl.Knowledge.RetrievalEvalTest do
  use Loopctl.DataCase, async: true

  import Ecto.Query
  import ExUnit.CaptureIO

  setup :verify_on_exit!

  alias Loopctl.AdminRepo
  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.Article
  alias Loopctl.Knowledge.ArticleLink
  alias Loopctl.Knowledge.RetrievalEval
  alias Loopctl.Knowledge.RetrievalEval.Baseline
  alias Loopctl.Knowledge.RetrievalEval.GoldenSet
  alias Loopctl.Knowledge.RetrievalEval.Report
  alias Loopctl.Tenants
  alias Loopctl.Tenants.Tenant
  alias Mix.Tasks.Loopctl.Retrieval.Eval, as: EvalTask

  # A tiny in-memory golden set (two questions, three docs each) so the DB-backed tests
  # seed six articles instead of the committed corpus. Each question's relevant doc shares
  # distinctive vocabulary with the question so BOTH lanes (keyword and the synthetic
  # semantic projection) can find it; the distractors are plausible but off-topic.
  defp small_golden_set(opts \\ []) do
    relevant_1 = Keyword.get(opts, :relevant_1, ["adv-lock"])
    relevant_2 = Keyword.get(opts, :relevant_2, ["ecto-multi"])

    q1 =
      build(:retrieval_golden_question, %{
        id: "q-advisory-lock",
        question: "postgres advisory lock distributed coordination",
        relevant: relevant_1,
        graded: %{},
        corpus: [
          build(:retrieval_golden_doc, %{
            doc_id: "adv-lock",
            title: "Postgres advisory lock for distributed coordination",
            body:
              "Take a postgres advisory lock so concurrent nodes cannot run the same distributed coordination step twice."
          }),
          build(:retrieval_golden_doc, %{
            doc_id: "cache-ttl",
            title: "Cache entries expire on a sweep",
            body: "Cached entries carry an expiry and a periodic sweep removes the stale ones."
          }),
          build(:retrieval_golden_doc, %{
            doc_id: "presence",
            title: "Tracking connected users",
            body: "Presence tracks which users are currently connected across the cluster."
          })
        ]
      })

    q2 =
      build(:retrieval_golden_question, %{
        id: "q-ecto-multi",
        question: "ecto multi transaction rollback named steps",
        relevant: relevant_2,
        graded: %{},
        corpus: [
          build(:retrieval_golden_doc, %{
            doc_id: "ecto-multi",
            title: "Ecto multi runs named steps in one transaction",
            body:
              "Ecto multi runs named steps inside one transaction and a rollback undoes every earlier step."
          }),
          build(:retrieval_golden_doc, %{
            doc_id: "changeset",
            title: "Changesets cast and validate parameters",
            body: "A changeset casts external parameters and validates them before an insert."
          }),
          build(:retrieval_golden_doc, %{
            doc_id: "queue-concurrency",
            title: "Queue concurrency limits",
            body: "Queue concurrency bounds how many background jobs execute at the same time."
          })
        ]
      })

    build(:retrieval_golden_set, %{questions: [q1, q2]})
  end

  # Push ONE question's mrr down, leaving the rest of the run untouched.
  defp degrade_mrr(result, id, value \\ 0.25) do
    %{
      result
      | question_results:
          Enum.map(result.question_results, fn q ->
            if q.id == id, do: %{q | mrr: value}, else: q
          end)
    }
  end

  defp golden_jsonl(golden) do
    header = JSON.encode!(%{"kind" => "header", "version" => golden.version})

    questions =
      Enum.map_join(golden.questions, "\n", fn q ->
        JSON.encode!(%{
          "kind" => "question",
          "id" => q.id,
          "question" => q.question,
          "relevant" => q.relevant,
          "graded" => q.graded,
          "corpus" =>
            Enum.map(q.corpus, fn doc ->
              %{
                "doc_id" => doc.doc_id,
                "title" => doc.title,
                "body" => doc.body,
                "category" => Atom.to_string(doc.category),
                "tags" => doc.tags
              }
            end)
        })
      end)

    header <> "\n" <> questions <> "\n"
  end

  # =========================================================================
  # 1-2. Metric math + undefined-metric semantics (pure, hand-computed)
  # =========================================================================

  describe "recall_at_k/3" do
    test "is the share of relevant docs inside the top k" do
      ranked = ~w(a b c d e)
      assert RetrievalEval.recall_at_k(ranked, ~w(a c), 3) == 1.0
      assert RetrievalEval.recall_at_k(ranked, ~w(a d), 3) == 0.5
      assert RetrievalEval.recall_at_k(ranked, ~w(x y), 5) == 0.0
    end

    test "the k boundary is inclusive of rank k and excludes rank k+1" do
      ranked = ~w(x1 x2 x3 hit)
      assert RetrievalEval.recall_at_k(ranked, ["hit"], 4) == 1.0
      assert RetrievalEval.recall_at_k(ranked, ["hit"], 3) == 0.0
    end

    test "is nil (UNDEFINED), not 0.0, when there is nothing to recall" do
      assert RetrievalEval.recall_at_k(~w(a b), [], 5) == nil
      # No results is a well-defined 0.0 — the metric ran, it just found nothing.
      assert RetrievalEval.recall_at_k([], ["a"], 5) == 0.0
    end
  end

  describe "reciprocal_rank/2" do
    test "is 1/rank of the first relevant doc" do
      assert RetrievalEval.reciprocal_rank(~w(a b c), ["a"]) == 1.0
      assert RetrievalEval.reciprocal_rank(~w(a b c), ["b"]) == 0.5
      assert RetrievalEval.reciprocal_rank(~w(a b c), ["c", "b"]) == 0.5
    end

    test "is 0.0 when no relevant doc is retrieved and nil when nothing is labeled" do
      assert RetrievalEval.reciprocal_rank(~w(a b), ["z"]) == 0.0
      assert RetrievalEval.reciprocal_rank(~w(a b), []) == nil
    end
  end

  describe "ndcg_at_k/4" do
    test "is 1.0 for the ideal ordering and lower for a demoted relevant doc" do
      gains = %{"a" => 3, "b" => 1, "c" => 0}
      ideal = [3, 1]

      assert RetrievalEval.ndcg_at_k(~w(a b c), gains, ideal, 3) == 1.0

      demoted = RetrievalEval.ndcg_at_k(~w(c b a), gains, ideal, 3)
      assert demoted < 1.0
    end

    test "matches a hand-computed value with graded relevance" do
      gains = %{"a" => 3, "b" => 2}
      ideal = [3, 2]

      # ranked [b, a]: DCG = 2/log2(2) + 3/log2(3) = 2 + 1.8927 = 3.8927
      #        ideal   = 3/log2(2) + 2/log2(3) = 3 + 1.2618 = 4.2618
      expected = (2 / :math.log2(2) + 3 / :math.log2(3)) / (3 / :math.log2(2) + 2 / :math.log2(3))

      assert_in_delta RetrievalEval.ndcg_at_k(~w(b a), gains, ideal, 2), expected, 1.0e-12
    end

    test "the ideal normalizer is truncated at k" do
      gains = %{"a" => 3, "b" => 3}
      # Only one of the two relevant docs can fit at k=1, so retrieving it scores 1.0.
      assert RetrievalEval.ndcg_at_k(~w(a b), gains, [3, 3], 1) == 1.0
    end

    test "is nil (UNDEFINED) when there is no achievable gain" do
      assert RetrievalEval.ndcg_at_k(~w(a b), %{}, [], 5) == nil
      assert RetrievalEval.ndcg_at_k(~w(a b), %{}, [0, 0], 5) == nil
      assert RetrievalEval.ndcg_at_k([], %{"a" => 3}, [3], 5) == 0.0
    end
  end

  describe "mean/1" do
    test "ignores nils and is nil when every value is undefined" do
      assert RetrievalEval.mean([1.0, nil, 0.0]) == 0.5
      assert RetrievalEval.mean([nil, nil]) == nil
      assert RetrievalEval.mean([]) == nil
    end
  end

  describe "GoldenSet.grade/2" do
    test "a doc absent from relevant is grade 0 regardless of the graded map" do
      # The documented contract (golden_set moduledoc): "a doc not in relevant is grade 0
      # regardless". A graded distractor must NOT contribute a gain, or nDCG can exceed 1.
      q = %{relevant: ["a"], graded: %{"a" => 1, "d" => 3}}

      assert GoldenSet.grade(q, "a") == 1
      assert GoldenSet.grade(q, "d") == 0
      assert GoldenSet.grade(q, "unseen") == 0
    end

    test "a relevant doc with no explicit grade defaults to 1" do
      assert GoldenSet.grade(%{relevant: ["a"], graded: %{}}, "a") == 1
    end

    test "nDCG cannot exceed 1.0 even when a non-relevant distractor carries a grade" do
      # Reviewer's repro: corpus a (relevant, grade 1) + d (graded 3, NOT relevant),
      # ranked [d, a]. Before the fix grade/2 returned d's 3 and nDCG blew past 1.0.
      q = %{relevant: ["a"], graded: %{"d" => 3}}

      gains = Map.new(["a", "d"], &{&1, GoldenSet.grade(q, &1)})
      ideal = Enum.map(q.relevant, &GoldenSet.grade(q, &1))

      ndcg = RetrievalEval.ndcg_at_k(["d", "a"], gains, ideal, 2)

      assert ndcg <= 1.0
    end
  end

  describe "report rendering of undefined metrics" do
    test "prints n/a rather than 0.0 and does not crash" do
      assert Report.fmt(nil) == "n/a"
      assert Report.fmt_delta(nil) == "n/a"
      assert Report.fmt(0.0) == "0.000"
      assert Report.fmt_delta(0.25) == "+0.250"
      assert Report.fmt_delta(-0.25) == "-0.250"

      result = %{
        golden_version: "v",
        mode: :embeddings,
        observed_mode: "combined",
        fallback_reasons: %{},
        question_count: 1,
        k_values: [5],
        recall_at_k: %{5 => nil},
        ndcg_at_k: %{5 => nil},
        mrr: nil,
        answered: 0,
        answered_k: 5,
        no_retrieval: %{
          recall_at_k: %{5 => nil},
          ndcg_at_k: %{5 => nil},
          mrr: nil,
          answered: 0
        },
        spread: %{answered: 0, recall_at_k: %{5 => nil}, ndcg_at_k: %{5 => nil}, mrr: nil},
        question_results: [
          %{
            id: "q",
            question: "q?",
            observed_mode: "combined",
            fallback: false,
            fallback_reason: nil,
            ranked: [],
            relevant: [],
            recall_at_k: %{5 => nil},
            mrr: nil,
            ndcg_at_k: %{5 => nil},
            answered: false
          }
        ]
      }

      rendered = Report.render(result, nil)
      assert rendered =~ "n/a"
      refute rendered =~ "0.000"
    end
  end

  # =========================================================================
  # 3-4. Golden-set loader + committed-file label integrity
  # =========================================================================

  describe "GoldenSet loading" do
    test "parses the committed file, exposes the version and normalizes atom keys" do
      golden = fixture(:retrieval_golden_set)

      assert is_binary(golden.version)
      assert golden.questions != []

      question = hd(golden.questions)
      assert is_binary(question.id)
      assert is_binary(question.question)
      assert [%{doc_id: _, title: _, body: _, category: category} | _] = question.corpus
      assert is_atom(category)
    end

    test "every relevant doc_id exists in its own question's corpus (label integrity)" do
      golden = fixture(:retrieval_golden_set)

      Enum.each(golden.questions, fn question ->
        corpus_ids = MapSet.new(question.corpus, & &1.doc_id)

        assert question.relevant != [], "#{question.id} has no labels"

        Enum.each(question.relevant, fn doc_id ->
          assert MapSet.member?(corpus_ids, doc_id),
                 "#{question.id}: relevant #{doc_id} is missing from its corpus"
        end)
      end)
    end

    test "doc_ids and titles are unique across every question that OWNS a corpus" do
      golden = fixture(:retrieval_golden_set)

      # Scoped to own-corpus questions: a `corpus_ref` question holds a COPY of the docs
      # its pair owns (golden_v3), so counting it here compares every shared doc against
      # itself. The uniqueness that matters is over what is actually SEEDED, which is what
      # `GoldenSet.corpus/1` returns — asserted below so the exemption cannot widen into a
      # file where two owners collide.
      docs = golden.questions |> Enum.filter(&is_nil(&1.corpus_ref)) |> Enum.flat_map(& &1.corpus)

      assert length(Enum.uniq_by(docs, & &1.doc_id)) == length(docs)
      assert length(Enum.uniq_by(docs, & &1.title)) == length(docs)

      seeded = GoldenSet.corpus(golden)
      assert length(seeded) == length(docs), "every owned doc is seeded exactly once"
      assert length(Enum.uniq_by(seeded, & &1.title)) == length(seeded)
    end

    test "the committed baseline was measured against the committed golden version" do
      golden = fixture(:retrieval_golden_set)
      assert {:ok, baseline} = Baseline.load(Baseline.default_path())

      assert baseline["golden_version"] == golden.version,
             "baseline is stale — re-run mix loopctl.retrieval.eval --update-baseline"

      assert Map.has_key?(baseline["modes"], "embeddings")
      assert Map.has_key?(baseline["modes"], "keyword_only")
    end

    test "parses the optional per-doc age_days field (#471), rejecting a negative age" do
      header = ~s({"kind":"header","version":"x"})

      entry =
        ~s({"kind":"question","id":"q","question":"q","relevant":["d"],) <>
          ~s("corpus":[{"doc_id":"d","title":"t","body":"b","category":"pattern","age_days":400}]})

      golden = GoldenSet.parse!(header <> "\n" <> entry <> "\n")
      assert [%{age_days: 400}] = hd(golden.questions).corpus

      # Absent age_days normalizes to nil (updated now — the pre-#471 default).
      no_age =
        ~s({"kind":"question","id":"q2","question":"q","relevant":["d2"],) <>
          ~s("corpus":[{"doc_id":"d2","title":"t2","body":"b","category":"pattern"}]})

      golden2 = GoldenSet.parse!(header <> "\n" <> no_age <> "\n")
      assert [%{age_days: nil}] = hd(golden2.questions).corpus

      # A negative age would place the doc in the future and invert the recency prior.
      negative =
        ~s({"kind":"question","id":"q3","question":"q","relevant":["d3"],) <>
          ~s("corpus":[{"doc_id":"d3","title":"t3","body":"b","category":"pattern","age_days":-5}]})

      assert_raise ArgumentError, ~r/age_days must be a non-negative number/, fn ->
        GoldenSet.parse!(header <> "\n" <> negative <> "\n")
      end
    end

    test "corpus_ref borrows the referenced question's corpus and labels (golden_v3)" do
      header = ~s({"kind":"header","version":"golden_v3"})

      owner =
        ~s({"kind":"question","id":"q-own","question":"the prose question","relevant":["d1"],) <>
          ~s("graded":{"d1":3},) <>
          ~s("corpus":[{"doc_id":"d1","title":"t1","body":"b1","category":"pattern"},) <>
          ~s({"doc_id":"d2","title":"t2","body":"b2","category":"pattern"}]})

      paired =
        ~s({"kind":"question","id":"q-own-kwbag","question":"prose question",) <>
          ~s("corpus_ref":"q-own"})

      golden = GoldenSet.parse!(header <> "\n" <> owner <> "\n" <> paired <> "\n")
      [own, ref] = golden.questions

      assert ref.corpus_ref == "q-own"
      assert Enum.map(ref.corpus, & &1.doc_id) == Enum.map(own.corpus, & &1.doc_id)
      assert ref.relevant == own.relevant
      assert ref.graded == own.graded

      # Its own query text is what makes the pair a measurement, so it must NOT be copied.
      refute ref.question == own.question

      # The shared corpus seeds ONCE: two questions, two docs, not four. A doubled corpus
      # would make each copy the other's strongest distractor and measure the duplication.
      assert length(GoldenSet.corpus(golden)) == 2
    end

    test "links parse, default to relates_to, and dedupe across paired questions (golden_v4)" do
      header = ~s({"kind":"header","version":"golden_v4"})

      owner =
        ~s({"kind":"question","id":"q-own","question":"the prose question","relevant":["d2"],) <>
          ~s("links":[{"from":"d1","to":"d2"},) <>
          ~s({"from":"d1","to":"d3","type":"potential_conflict"}],) <>
          ~s("corpus":[{"doc_id":"d1","title":"t1","body":"b1","category":"pattern"},) <>
          ~s({"doc_id":"d2","title":"t2","body":"b2","category":"pattern"},) <>
          ~s({"doc_id":"d3","title":"t3","body":"b3","category":"pattern"}]})

      paired =
        ~s({"kind":"question","id":"q-own-kwbag","question":"prose question",) <>
          ~s("corpus_ref":"q-own"})

      golden = GoldenSet.parse!(header <> "\n" <> owner <> "\n" <> paired <> "\n")
      [own, ref] = golden.questions

      assert own.links == [
               %{from: "d1", to: "d2", type: :relates_to},
               %{from: "d1", to: "d3", type: :potential_conflict}
             ]

      # A paired question inherits the edge set with the corpus: the pair must differ in
      # the QUERY and nothing else, or it measures the topology instead of the query.
      assert ref.links == own.links

      # ...and the union seeds ONCE, for the same reason the corpus does — `article_links`
      # carries a unique index on exactly {source, target, type}.
      assert GoldenSet.links(golden) == own.links
    end

    test "rejects a link that is dangling, self-referential, duplicated, or wrongly typed" do
      header = ~s({"kind":"header","version":"golden_v4"})

      base =
        ~s("relevant":["d1"],) <>
          ~s("corpus":[{"doc_id":"d1","title":"t1","body":"b1","category":"pattern"},) <>
          ~s({"doc_id":"d2","title":"t2","body":"b2","category":"pattern"}])

      question = fn links ->
        header <>
          "\n" <>
          ~s({"kind":"question","id":"q-x","question":"q","links":) <>
          links <>
          "," <>
          base <> ~s(})
      end

      # An endpoint outside this question's own corpus names a doc it never seeds, so the
      # edge would either fail to insert or silently wire this question's seeds to another
      # question's docs and change what BOTH measure.
      assert_raise ArgumentError, ~r/link endpoint "d-nope" is not in its corpus/, fn ->
        GoldenSet.parse!(question.(~s([{"from":"d1","to":"d-nope"}])))
      end

      assert_raise ArgumentError, ~r/link from "d1" to itself/, fn ->
        GoldenSet.parse!(question.(~s([{"from":"d1","to":"d1"}])))
      end

      # The (tenant, source, target, type) unique index would otherwise reject this at
      # insert time with an opaque constraint error naming no question.
      assert_raise ArgumentError, ~r/duplicate link in question q-x/, fn ->
        GoldenSet.parse!(
          question.(~s([{"from":"d1","to":"d2"},{"from":"d1","to":"d2","type":"relates_to"}]))
        )
      end

      # An unknown type must be loud: silently dropping it would leave an untraversed edge
      # and a question that scores as if the lane had failed.
      assert_raise ArgumentError, ~r/unknown link type "sort_of_related"/, fn ->
        GoldenSet.parse!(question.(~s([{"from":"d1","to":"d2","type":"sort_of_related"}])))
      end
    end

    test "a corpus_ref question may not declare its own links" do
      header = ~s({"kind":"header","version":"golden_v4"})

      owner =
        ~s({"kind":"question","id":"q-own","question":"prose","relevant":["d1"],) <>
          ~s("corpus":[{"doc_id":"d1","title":"t1","body":"b1","category":"pattern"}]})

      bad =
        ~s({"kind":"question","id":"q-bad","question":"q","corpus_ref":"q-own",) <>
          ~s("links":[{"from":"d1","to":"d1"}]})

      assert_raise ArgumentError,
                   ~r/must not declare their own corpus, relevant, graded or links/,
                   fn ->
                     GoldenSet.parse!(header <> "\n" <> owner <> "\n" <> bad <> "\n")
                   end
    end

    test "the committed set carries multi-hop questions whose answer is ONLY link-reachable" do
      golden = fixture(:retrieval_golden_set)

      multi_hop = Enum.filter(golden.questions, &(&1.links != []))

      assert multi_hop != [],
             "golden_v4 must seed edges — with none, the graph lane is a strict no-op and " <>
               "a lane-on eval run scores an identical, uninformative delta"

      Enum.each(multi_hop, fn question ->
        link_targets = MapSet.new(question.links, & &1.to)

        # The point of a multi-hop question: its relevant doc is the FAR side of an edge,
        # not the doc the query text matches. A question whose answer is also its bridge
        # would be answerable without the lane and would measure nothing.
        Enum.each(question.relevant, fn doc_id ->
          assert MapSet.member?(link_targets, doc_id),
                 "#{question.id}: relevant #{doc_id} is not the target of any link, so the " <>
                   "graph lane cannot be what retrieves it"
        end)
      end)
    end

    test "a corpus_ref question is exempt from doc-id uniqueness, not a hole in it" do
      header = ~s({"kind":"header","version":"golden_v3"})

      owner =
        ~s({"kind":"question","id":"q-a","question":"qa","relevant":["dup"],) <>
          ~s("corpus":[{"doc_id":"dup","title":"tdup","body":"b","category":"pattern"}]})

      # Two OWN-corpus questions sharing a doc_id must still be rejected.
      other =
        ~s({"kind":"question","id":"q-b","question":"qb","relevant":["dup"],) <>
          ~s("corpus":[{"doc_id":"dup","title":"tdup2","body":"b","category":"pattern"}]})

      assert_raise ArgumentError, ~r/duplicate corpus doc_id/, fn ->
        GoldenSet.parse!(header <> "\n" <> owner <> "\n" <> other <> "\n")
      end
    end

    test "rejects a corpus_ref that is unresolvable, self-referential, chained, or shadowed" do
      header = ~s({"kind":"header","version":"golden_v3"})

      owner =
        ~s({"kind":"question","id":"q-own","question":"q","relevant":["d1"],) <>
          ~s("corpus":[{"doc_id":"d1","title":"t1","body":"b","category":"pattern"}]})

      missing = ~s({"kind":"question","id":"q-x","question":"q","corpus_ref":"q-nope"})

      assert_raise ArgumentError, ~r/names no question in this file/, fn ->
        GoldenSet.parse!(header <> "\n" <> owner <> "\n" <> missing <> "\n")
      end

      itself = ~s({"kind":"question","id":"q-self","question":"q","corpus_ref":"q-self"})

      # Pinned on the SPECIFIC message: a self-ref is also caught by the chain guard below
      # (it has a non-nil corpus_ref), so a loose regex here would pass with this guard
      # deleted and the reader would get "chains are not allowed" for a self-reference.
      assert_raise ArgumentError, ~r/points at itself/, fn ->
        GoldenSet.parse!(header <> "\n" <> owner <> "\n" <> itself <> "\n")
      end

      # A chain would resolve differently depending on file ORDER, so one hop only.
      hop1 = ~s({"kind":"question","id":"q-h1","question":"q","corpus_ref":"q-own"})
      hop2 = ~s({"kind":"question","id":"q-h2","question":"q","corpus_ref":"q-h1"})

      assert_raise ArgumentError, ~r/chains are not allowed/, fn ->
        GoldenSet.parse!(header <> "\n" <> owner <> "\n" <> hop1 <> "\n" <> hop2 <> "\n")
      end

      # Declaring both is ambiguous about which corpus scores.
      shadowed =
        ~s({"kind":"question","id":"q-both","question":"q","corpus_ref":"q-own",) <>
          ~s("relevant":["d9"],) <>
          ~s("corpus":[{"doc_id":"d9","title":"t9","body":"b","category":"pattern"}]})

      assert_raise ArgumentError, ~r/must not declare their own/, fn ->
        GoldenSet.parse!(header <> "\n" <> owner <> "\n" <> shadowed <> "\n")
      end
    end

    test "the committed set pairs every prose question with a DIFFERENT distilled query" do
      golden = fixture(:retrieval_golden_set)
      by_id = Map.new(golden.questions, &{&1.id, &1})
      {paired, prose} = Enum.split_with(golden.questions, & &1.corpus_ref)

      assert paired != [], "golden_v3 must carry paired -kwbag questions"

      # Every prose question has a pair, and every pair differs from its source in QUERY
      # only. A pair whose text drifted back to the prose form measures nothing, and this
      # is the one property no aggregate metric would reveal.
      Enum.each(prose, fn q ->
        pair =
          Map.get(by_id, q.id <> "-kwbag") ||
            flunk("#{q.id} has no -kwbag pair; the paired design is only valid as a full set")

        assert pair.corpus_ref == q.id
        refute pair.question == q.question, "#{pair.id} is not distilled — same text as #{q.id}"
        assert pair.relevant == q.relevant
      end)
    end

    test "raises with a clear message on a malformed entry" do
      valid_header = ~s({"kind":"header","version":"x"})

      assert_raise ArgumentError, ~r/invalid JSON/, fn ->
        GoldenSet.parse!(valid_header <> "\nnot json\n")
      end

      assert_raise ArgumentError, ~r/id must be a non-empty string/, fn ->
        GoldenSet.parse!(valid_header <> "\n" <> ~s({"kind":"question","question":"q"}) <> "\n")
      end

      assert_raise ArgumentError, ~r/unknown category/, fn ->
        entry =
          ~s({"kind":"question","id":"q","question":"q","relevant":["d"],) <>
            ~s("corpus":[{"doc_id":"d","title":"t","body":"b","category":"nope"}]})

        GoldenSet.parse!(valid_header <> "\n" <> entry <> "\n")
      end

      assert_raise ArgumentError, ~r/is not in its corpus/, fn ->
        entry =
          ~s({"kind":"question","id":"q","question":"q","relevant":["missing"],) <>
            ~s("corpus":[{"doc_id":"d","title":"t","body":"b","category":"pattern"}]})

        GoldenSet.parse!(valid_header <> "\n" <> entry <> "\n")
      end

      # A question over the 500-char search limit would silently score 0 — reject it loudly.
      assert_raise ArgumentError, ~r/over the 500-char limit/, fn ->
        long = String.duplicate("x", 501)

        entry =
          ~s({"kind":"question","id":"q","question":"#{long}","relevant":["d"],) <>
            ~s("corpus":[{"doc_id":"d","title":"t","body":"b","category":"pattern"}]})

        GoldenSet.parse!(valid_header <> "\n" <> entry <> "\n")
      end

      # A grade on a doc that is not `relevant` is inert (grade/2 returns 0) — reject it so
      # a contributor cannot believe a distractor is intentionally weighted.
      assert_raise ArgumentError, ~r/is not in `relevant`/, fn ->
        entry =
          ~s({"kind":"question","id":"q","question":"q","relevant":["d"],"graded":{"e":2},) <>
            ~s("corpus":[{"doc_id":"d","title":"t","body":"b","category":"pattern"},) <>
            ~s({"doc_id":"e","title":"t2","body":"b2","category":"pattern"}]})

        GoldenSet.parse!(valid_header <> "\n" <> entry <> "\n")
      end

      assert_raise ArgumentError, ~r/has no questions/, fn ->
        GoldenSet.parse!(valid_header <> "\n")
      end
    end
  end

  # =========================================================================
  # 5-6, 8. End-to-end scoring on a seeded tenant
  # =========================================================================

  describe "compute/2 end to end" do
    test "a well-labeled golden set scores high and a mislabeled one scores strictly lower" do
      tenant = fixture(:tenant)

      good = RetrievalEval.compute(tenant.id, golden_set: small_golden_set(), k_values: [1, 3])

      assert good.question_count == 2
      assert good.answered == 2
      assert good.mrr == 1.0
      assert good.recall_at_k[1] == 1.0
      assert good.ndcg_at_k[1] == 1.0

      # Adversarial labels: the SAME questions and corpus, but "relevant" now points at
      # the off-topic distractor. A ranking that is correct for the real labels must
      # score strictly worse against these.
      adversarial =
        RetrievalEval.compute(tenant.id,
          golden_set:
            small_golden_set(relevant_1: ["presence"], relevant_2: ["queue-concurrency"]),
          k_values: [1, 3]
        )

      assert adversarial.mrr < good.mrr
      assert adversarial.recall_at_k[1] < good.recall_at_k[1]
    end

    test "the recency prior surfaces the freshest correct note among near-tie distractors (#471)" do
      tenant = fixture(:tenant)

      # Three near-identical docs — same query-term coverage, differing only in a trailing
      # non-query word — so keyword rank and the synthetic semantic projection TIE. The only
      # thing that separates them is age, so the recency prior alone decides the ranking.
      question_terms = "widget lattice calibration telemetry across the sprocket"

      docs = fn ages ->
        [
          build(:retrieval_golden_doc, %{
            doc_id: "recency-correct",
            title: "Sprocket telemetry current",
            body: "#{question_terms} assembly",
            category: :decision,
            age_days: Keyword.fetch!(ages, :correct)
          }),
          build(:retrieval_golden_doc, %{
            doc_id: "recency-legacy-a",
            title: "Sprocket telemetry legacy a",
            body: "#{question_terms} housing",
            category: :decision,
            age_days: Keyword.fetch!(ages, :distractor)
          }),
          build(:retrieval_golden_doc, %{
            doc_id: "recency-legacy-b",
            title: "Sprocket telemetry legacy b",
            body: "#{question_terms} bearing",
            category: :decision,
            age_days: Keyword.fetch!(ages, :distractor)
          })
        ]
      end

      golden = fn ages ->
        build(:retrieval_golden_set, %{
          version: "recency_test_v1",
          questions: [
            build(:retrieval_golden_question, %{
              id: "q-recency",
              question: question_terms,
              relevant: ["recency-correct"],
              graded: %{"recency-correct" => 3},
              corpus: docs.(ages)
            })
          ]
        })
      end

      # Correct doc FRESH, distractors STALE → recency lifts it to rank 1.
      fresh_correct =
        RetrievalEval.compute(tenant.id,
          golden_set: golden.(correct: 0, distractor: 500),
          k_values: [1, 3]
        )

      # Correct doc STALE, distractors FRESH → recency demotes it below a fresh distractor.
      stale_correct =
        RetrievalEval.compute(tenant.id,
          golden_set: golden.(correct: 500, distractor: 0),
          k_values: [1, 3]
        )

      assert fresh_correct.mrr == 1.0
      assert fresh_correct.recall_at_k[1] == 1.0
      # Swapping the ages strictly degrades the score — the recency prior did the work.
      assert stale_correct.mrr < fresh_correct.mrr
    end

    test "reports the with-retrieval vs no-retrieval spread" do
      tenant = fixture(:tenant)

      result = RetrievalEval.compute(tenant.id, golden_set: small_golden_set(), k_values: [1, 3])

      # The no-retrieval arm is an empty result set: every metric is a well-defined 0.0.
      assert result.no_retrieval.answered == 0
      assert result.no_retrieval.mrr == 0.0
      assert result.no_retrieval.recall_at_k[3] == 0.0
      assert result.no_retrieval.ndcg_at_k[3] == 0.0

      assert result.spread.answered == 2
      assert result.spread.mrr > 0.0
      assert result.spread.recall_at_k[3] > 0.0
    end

    test "runs in embeddings mode and reports the mode it observed" do
      tenant = fixture(:tenant)

      result = RetrievalEval.compute(tenant.id, golden_set: small_golden_set(), k_values: [1, 3])

      assert result.mode == :embeddings
      assert result.observed_mode == "combined"
      assert result.fallback_reasons == %{}
      assert Enum.all?(result.question_results, &(&1.fallback == false))
    end

    test "a forced keyword-only run names the degraded mode and its fallback reason" do
      tenant = fixture(:tenant)

      result =
        RetrievalEval.compute(tenant.id,
          golden_set: small_golden_set(),
          k_values: [1, 3],
          mode: :keyword_only
        )

      assert result.mode == :keyword_only
      assert result.observed_mode == "keyword_only"
      assert result.fallback_reasons == %{"no_embedding_key" => 2}

      assert Enum.all?(result.question_results, fn q ->
               q.fallback and q.observed_mode == "keyword_only" and
                 q.fallback_reason == "no_embedding_key"
             end)
    end

    test "emits telemetry from run/2" do
      tenant = fixture(:tenant)
      test_pid = self()
      handler_id = "retrieval-eval-test-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:loopctl, :knowledge, :retrieval_eval],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:retrieval_eval_telemetry, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      RetrievalEval.run(tenant.id, golden_set: small_golden_set(), k_values: [1, 3])

      assert_receive {:retrieval_eval_telemetry, measurements, metadata}
      assert measurements.question_count == 2
      assert metadata.tenant_id == tenant.id
      assert metadata.observed_mode == "combined"
    end

    test "a hard search error scores 0 and a disagreeing observed mode aggregates to mixed" do
      tenant = fixture(:tenant)

      # One question over the 500-char search limit: search_combined/3 returns
      # {:error, :bad_request}, which score_question's catch-all turns into a 0 (recall 0,
      # mrr 0, observed_mode "unknown"). The other question scores "combined", so the
      # aggregate observed_mode disagrees and resolves to "mixed".
      base = small_golden_set()
      [q1, q2] = base.questions
      over_limit = %{q2 | question: String.duplicate("word ", 200)}
      golden = %{base | questions: [q1, over_limit]}

      {result, log} =
        ExUnit.CaptureLog.with_log(fn ->
          RetrievalEval.compute(tenant.id, golden_set: golden, k_values: [1, 3])
        end)

      assert log =~ "search failed for #{q2.id}"
      assert result.observed_mode == "mixed"

      errored = Enum.find(result.question_results, &(&1.id == q2.id))
      assert errored.ranked == []
      assert errored.mrr == 0.0
      assert errored.answered == false
      assert errored.observed_mode == "unknown"

      assert article_count(tenant.id) == 0
    end
  end

  # =========================================================================
  # 7. Baseline comparison
  # =========================================================================

  describe "baseline comparison" do
    setup do
      tenant = fixture(:tenant)
      result = RetrievalEval.compute(tenant.id, golden_set: small_golden_set(), k_values: [1, 3])
      %{result: result, baseline: Baseline.from_results([result])}
    end

    test "an identical run passes with zero deltas", %{result: result, baseline: baseline} do
      comparison = Baseline.compare(result, baseline)

      assert comparison.status == :ok
      assert comparison.regressions == []
      assert Enum.all?(comparison.aggregate, &(&1.delta == 0 or &1.delta == 0.0))
      assert comparison.losers == []
    end

    test "a drop beyond tolerance is a regression", %{result: result, baseline: baseline} do
      raised = put_in(baseline["modes"]["embeddings"]["mrr"], 1.0)
      raised = put_in(raised["modes"]["embeddings"]["recall_at_k"]["1"], 1.0)

      degraded = %{result | mrr: 0.4, recall_at_k: %{1 => 0.4, 3 => result.recall_at_k[3]}}

      comparison = Baseline.compare(degraded, raised)

      assert comparison.status == :regression
      assert "mrr" in comparison.regressions
      assert "recall@1" in comparison.regressions
    end

    test "a drop inside tolerance is not a regression", %{result: result, baseline: baseline} do
      nudged = %{result | mrr: result.mrr - 0.001}

      assert Baseline.compare(nudged, nudged |> then(fn _ -> baseline end)).status == :ok
    end

    test "an improvement passes and shows a positive delta", %{
      result: result,
      baseline: baseline
    } do
      lowered = put_in(baseline["modes"]["embeddings"]["mrr"], 0.5)
      lowered = put_in(lowered["modes"]["embeddings"]["questions"]["q-ecto-multi"]["mrr"], 0.5)

      comparison = Baseline.compare(result, lowered)

      assert comparison.status == :ok
      mrr_row = Enum.find(comparison.aggregate, &(&1.metric == "mrr"))
      assert mrr_row.delta > 0
      assert "q-ecto-multi" in comparison.winners
    end

    test "per-question deltas identify winners and losers", %{
      result: result,
      baseline: baseline
    } do
      shifted = put_in(baseline["modes"]["embeddings"]["questions"]["q-ecto-multi"]["mrr"], 0.25)
      shifted = put_in(shifted["modes"]["embeddings"]["questions"]["q-advisory-lock"]["mrr"], 2.0)

      comparison = Baseline.compare(result, shifted)

      assert "q-ecto-multi" in comparison.winners
      assert "q-advisory-lock" in comparison.losers
    end

    test "a golden-set version change blocks a meaningless comparison", %{
      result: result,
      baseline: baseline
    } do
      relabeled = Map.put(baseline, "golden_version", "golden_v99")

      comparison = Baseline.compare(result, relabeled)

      assert comparison.status == :golden_version_mismatch
      assert comparison.aggregate == []
      assert Report.render(result, comparison) =~ "re-baseline before comparing"
    end

    test "a metric that became undefined counts as a regression", %{
      result: result,
      baseline: baseline
    } do
      undefined = %{result | mrr: nil}

      comparison = Baseline.compare(undefined, baseline)

      assert comparison.status == :regression
      assert "mrr" in comparison.regressions
    end

    test "a changed question set blocks the AGGREGATE comparison but not the per-question one",
         %{result: result, baseline: baseline} do
      # Simulate a golden question added without re-baselining: the baseline covers fewer
      # questions than the run, but the free-text version header was left untouched.
      stale =
        update_in(baseline["modes"]["embeddings"]["questions"], &Map.delete(&1, "q-ecto-multi"))

      comparison = Baseline.compare(result, stale)

      # The aggregates average over different question sets, so they stay uncomparable and
      # the gate still fails closed on this status.
      assert comparison.status == :question_set_mismatch
      assert comparison.aggregate == []

      # But the questions on BOTH sides were still compared, and the report says how many.
      assert comparison.shared_question_count > 0
      refute Enum.any?(comparison.questions, &(&1.id == "q-ecto-multi"))
      assert Report.render(result, comparison) =~ "AGGREGATES INCOMPARABLE"
    end

    test "a shared question that regressed is NAMED even though the question set changed",
         %{result: result, baseline: baseline} do
      # This is the case the gate was blind to for three golden-set generations. Adding a
      # golden question forces a re-baseline (the runbook says so), and the all-or-nothing
      # mismatch threw away every comparable question to avoid mis-scoring the new one. A
      # controlled A/B on 2026-08-25 found three questions whose correct answer had moved
      # DOWN the ranking across golden_v3 -> v4 -> v5, all three present in every baseline.
      %{id: shared_id} = Enum.find(result.question_results, &(&1.id != "q-ecto-multi"))

      stale =
        baseline
        |> update_in(["modes", "embeddings", "questions"], &Map.delete(&1, "q-ecto-multi"))
        |> put_in(["modes", "embeddings", "questions", shared_id, "mrr"], 1.0)

      worse = degrade_mrr(result, shared_id)

      comparison = Baseline.compare(worse, stale)

      assert comparison.status == :question_set_mismatch
      assert shared_id in comparison.question_regressions

      rendered = Report.render(worse, comparison)
      assert rendered =~ "REGRESSED"
      assert rendered =~ shared_id
    end

    test "a question absent from the baseline is dropped from the comparison entirely",
         %{result: result, baseline: baseline} do
      # A brand-new golden question has no baseline row, so every delta against it is nil.
      # Counting that as a regression would make adding a question impossible; counting it
      # as a win would be just as wrong. It is not comparable at all, so it appears in
      # neither the compared set nor any verdict drawn from it.
      stale =
        update_in(baseline["modes"]["embeddings"]["questions"], &Map.delete(&1, "q-ecto-multi"))

      comparison = Baseline.compare(result, stale)

      refute Enum.any?(comparison.questions, &(&1.id == "q-ecto-multi"))
      refute "q-ecto-multi" in comparison.question_regressions
      refute "q-ecto-multi" in comparison.winners
      refute "q-ecto-multi" in comparison.losers
    end

    test "a shared question with no baseline value for a metric is UNCOMPARABLE, not clean",
         %{result: result, baseline: baseline} do
      # The per-question twin of the aggregate `uncomparable`: the baseline row kept mrr
      # but not recall@3, so recall@3 has nothing to compare against. regression?/3 says
      # "not a regression" for a nil baseline, and reporting that as "no shared question
      # regressed" would be an all-clear drawn from a comparison that did not happen.
      %{id: shared_id} = Enum.find(result.question_results, &(&1.id != "q-ecto-multi"))

      stale =
        baseline
        |> update_in(["modes", "embeddings", "questions"], &Map.delete(&1, "q-ecto-multi"))
        |> update_in(
          ["modes", "embeddings", "questions", shared_id, "recall_at_k"],
          &Map.delete(&1, "3")
        )

      comparison = Baseline.compare(result, stale)

      assert shared_id in comparison.question_uncomparable
      refute shared_id in comparison.question_regressions
      assert Report.render(result, comparison) =~ "uncomparable, not clean"
    end

    test "bumping the golden version still names a shared question that regressed",
         %{result: result, baseline: baseline} do
      # The version header IS bumped whenever a golden question is added (golden_v1..v5 in
      # priv/retrieval_eval/golden.jsonl), so this — not the stale-header case — is the
      # branch every real re-baseline lands in. Giving up on the whole comparison here left
      # the intersection unreachable in the only workflow that produces it.
      %{id: shared_id} = Enum.find(result.question_results, &(&1.id != "q-ecto-multi"))

      stale =
        baseline
        |> Map.put("golden_version", "golden_v99")
        |> update_in(["modes", "embeddings", "questions"], &Map.delete(&1, "q-ecto-multi"))
        |> put_in(["modes", "embeddings", "questions", shared_id, "mrr"], 1.0)

      worse = degrade_mrr(result, shared_id)

      comparison = Baseline.compare(worse, stale)

      assert comparison.status == :golden_version_mismatch
      assert comparison.aggregate == []
      assert shared_id in comparison.question_regressions

      rendered = Report.render(worse, comparison)
      assert rendered =~ "re-baseline before comparing"
      assert rendered =~ "REGRESSED"
      assert rendered =~ shared_id
    end

    test "an empty intersection never renders as an all-clear", %{result: result} do
      # Every question renamed: the mismatch fires, nothing is comparable, and "no shared
      # question regressed" would be a reassurance produced by comparing nothing.
      renamed =
        [result]
        |> Baseline.from_results()
        |> update_in(["modes", "embeddings", "questions"], fn questions ->
          Map.new(questions, fn {id, row} -> {"renamed-" <> id, row} end)
        end)

      comparison = Baseline.compare(result, renamed)

      assert comparison.status == :question_set_mismatch
      assert comparison.shared_question_count == 0

      rendered = Report.render(result, comparison)
      assert rendered =~ "nothing was comparable per-question"
      refute rendered =~ "no shared question regressed"
    end

    test "a per-question regression is reported even when the aggregates hold steady",
         %{result: result, baseline: baseline} do
      # One question loses a rank while another gains: the aggregate nets out and the
      # question set is unchanged, so nothing but the per-question comparison can see it.
      %{id: loser_id} = Enum.find(result.question_results, &(&1.id != "q-ecto-multi"))

      raised = put_in(baseline["modes"]["embeddings"]["questions"][loser_id]["mrr"], 1.0)
      worse = degrade_mrr(result, loser_id)

      comparison = Baseline.compare(worse, raised)

      assert comparison.status == :ok
      assert loser_id in comparison.question_regressions
      assert Report.render(worse, comparison) =~ "PER-QUESTION REGRESSION"
    end

    test "a per-question metric with no baseline value is not an all-clear on the OK path",
         %{result: result, baseline: baseline} do
      # The question set and version are unchanged, so the AGGREGATE guard never fires and
      # this is the only thing standing between "could not be compared" and a green run.
      stale =
        update_in(
          baseline["modes"]["embeddings"]["questions"]["q-ecto-multi"]["recall_at_k"],
          &Map.delete(&1, "3")
        )

      comparison = Baseline.compare(result, stale)

      assert comparison.status == :ok
      assert "q-ecto-multi" in comparison.question_uncomparable

      rendered = Report.render(result, comparison)
      refute rendered =~ "OK (no regression)"
      assert rendered =~ "uncomparable, not clean"
      assert Report.to_json_map(result, comparison)["baseline"]["status"] != "ok"
    end

    test "a regressed AND an uncomparable shared question are BOTH named",
         %{result: result, baseline: baseline} do
      # Two independent verdicts over the same intersection: naming only the regression
      # leaves the reader believing the other question was compared and was fine.
      stale =
        baseline
        |> put_in(["modes", "embeddings", "questions", "q-advisory-lock", "mrr"], 1.0)
        |> update_in(
          ["modes", "embeddings", "questions", "q-ecto-multi", "recall_at_k"],
          &Map.delete(&1, "3")
        )
        |> Map.put("golden_version", "golden_v99")

      worse = degrade_mrr(result, "q-advisory-lock")

      comparison = Baseline.compare(worse, stale)

      assert comparison.question_regressions == ["q-advisory-lock"]
      assert comparison.question_uncomparable == ["q-ecto-multi"]

      rendered = Report.render(worse, comparison)
      assert rendered =~ "q-advisory-lock"
      assert rendered =~ "uncomparable, not clean"
      assert rendered =~ "q-ecto-multi"
      refute rendered =~ "no shared question regressed"
    end

    test "a per-question regression keeps --json from answering ok",
         %{result: result, baseline: baseline} do
      # The gate exits non-zero and the text report says PER-QUESTION REGRESSION; a machine
      # consumer keying on `status` must not read the same run as clean.
      raised = put_in(baseline["modes"]["embeddings"]["questions"]["q-ecto-multi"]["mrr"], 1.0)
      worse = degrade_mrr(result, "q-ecto-multi")

      comparison = Baseline.compare(worse, raised)

      assert comparison.status == :ok
      assert Report.to_json_map(worse, comparison)["baseline"]["status"] == "question_regression"
    end

    test "a baseline whose questions map is null still reports the mismatch",
         %{result: result, baseline: baseline} do
      # A PRESENT-but-null key is not a missing key: `Map.get/3`'s default never fires, so
      # this shape used to crash the whole run after it had already seeded and scored.
      nulled = put_in(baseline["modes"]["embeddings"]["questions"], nil)

      comparison = Baseline.compare(%{result | golden_version: "golden_v99"}, nulled)

      assert comparison.status == :golden_version_mismatch
      assert comparison.shared_question_count == 0

      # The version MATCHING is the branch that reaches `question_set_changed?/2`, the one
      # reader of the same field that the version-mismatch clause short-circuits past.
      matched = Baseline.compare(result, nulled)

      assert matched.status == :question_set_mismatch
      assert matched.shared_question_count == 0
    end

    test "a malformed baseline reports a status instead of raising", %{result: result} do
      # `||` rescues only nil/false, so every other truthy hand-edit shape ([], "", a
      # number) used to reach `Map.keys/1` and raise BadMapError after the run had already
      # seeded the corpus and scored every question. Same one level up: a mode entry that
      # is not a map raised out of `Access.get/3`, and a document that is not a map at all
      # raised out of `get_in/2` instead of failing the gate by the baseline path.
      for shape <- [[], "", 0] do
        listed = %{
          "golden_version" => result.golden_version,
          "modes" => %{"embeddings" => %{"questions" => shape}}
        }

        assert Baseline.compare(result, listed).status == :question_set_mismatch

        assert Baseline.compare(result, %{"modes" => %{"embeddings" => shape}}).status ==
                 :missing_mode
      end

      path = Path.join(System.tmp_dir!(), "baseline-#{System.unique_integer([:positive])}.json")
      on_exit(fn -> File.rm(path) end)
      File.write!(path, JSON.encode!([]))

      assert Baseline.load(path) == {:error, :malformed_baseline}
    end

    test "the --json view carries the per-question verdict the text report does",
         %{result: result, baseline: baseline} do
      # --json is the machine-readable surface; a consumer keying on it must not read a
      # named regression as a clean run just because the aggregates were not comparable.
      %{id: shared_id} = Enum.find(result.question_results, &(&1.id != "q-ecto-multi"))

      stale =
        baseline
        |> update_in(["modes", "embeddings", "questions"], &Map.delete(&1, "q-ecto-multi"))
        |> put_in(["modes", "embeddings", "questions", shared_id, "mrr"], 1.0)

      worse = degrade_mrr(result, shared_id)
      json = Report.to_json_map(worse, Baseline.compare(worse, stale))

      assert json["baseline"]["question_regressions"] == [shared_id]
      assert json["baseline"]["shared_question_count"] == 1
      assert json["baseline"]["question_uncomparable"] == []
    end

    test "a metric with no baseline counterpart is INCOMPARABLE, not ok", %{result: result} do
      # A `--k` present in the run but absent from the baseline: recall@3 / ndcg@3 have no
      # baseline value, so the gate must fail closed rather than silently compare only mrr.
      stripped =
        result
        |> then(&Baseline.from_results([&1]))
        |> update_in(["modes", "embeddings", "recall_at_k"], &Map.delete(&1, "3"))
        |> update_in(["modes", "embeddings", "ndcg_at_k"], &Map.delete(&1, "3"))

      comparison = Baseline.compare(result, stripped)

      assert comparison.status == :incomparable
      assert "recall@3" in comparison.uncomparable
      assert "ndcg@3" in comparison.uncomparable
      assert Report.render(result, comparison) =~ "INCOMPARABLE"
    end

    test "comparing a mode absent from the baseline yields :missing_mode", %{
      result: result,
      baseline: baseline
    } do
      # The baseline holds only :embeddings; a keyword_only result has no counterpart.
      comparison = Baseline.compare(%{result | mode: :keyword_only}, baseline)

      assert comparison.status == :missing_mode
      assert comparison.aggregate == []
    end

    test "winners and losers span recall/nDCG deltas, not mrr alone", %{
      result: result,
      baseline: baseline
    } do
      # Raise ONLY q-advisory-lock's baseline recall@1 above its current value: recall
      # regresses for that question while its mrr delta stays 0. An mrr-only predicate
      # would miss it; the full-delta predicate flags it as a loser.
      shifted =
        put_in(
          baseline["modes"]["embeddings"]["questions"]["q-advisory-lock"]["recall_at_k"]["1"],
          2.0
        )

      comparison = Baseline.compare(result, shifted)

      adv = Enum.find(comparison.questions, &(&1.id == "q-advisory-lock"))
      assert adv.mrr_delta in [0, 0.0]
      assert adv.recall_delta[1] < 0

      assert "q-advisory-lock" in comparison.losers
    end

    test "the AGGREGATE table renders answered@k with its REGRESSION flag", %{
      result: result,
      baseline: baseline
    } do
      # answered@k is the strictest (zero-tolerance) gate metric, so it is the one most
      # likely to regress alone — it must carry the flag in the aggregate table, not only
      # in the one-line BASELINE status.
      raised = put_in(baseline["modes"]["embeddings"]["answered"], result.answered + 1)

      comparison = Baseline.compare(result, raised)
      rendered = Report.render(result, comparison)

      assert comparison.status == :regression
      assert rendered =~ ~r/AGGREGATE.*answered@#{result.answered_k}.*REGRESSION/s
    end
  end

  # =========================================================================
  # 7b. The mix task gate (non-zero exit on regression)
  # =========================================================================

  describe "mix loopctl.retrieval.eval" do
    setup do
      dir = Path.join(System.tmp_dir!(), "retrieval-eval-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      golden_path = Path.join(dir, "golden.jsonl")
      File.write!(golden_path, golden_jsonl(small_golden_set()))

      %{dir: dir, golden_path: golden_path, baseline_path: Path.join(dir, "baseline.json")}
    end

    test "writes a baseline, then passes the gate against it", ctx do
      args = [
        "--golden",
        ctx.golden_path,
        "--baseline",
        ctx.baseline_path,
        "--k",
        "1",
        "--k",
        "3"
      ]

      capture_io(fn -> EvalTask.run(args ++ ["--update-baseline"]) end)

      assert File.exists?(ctx.baseline_path)

      output =
        capture_io(fn ->
          EvalTask.run(args ++ ["--fail-on-regression"])
        end)

      assert output =~ "no regression against baseline"
      assert output =~ "PER-QUESTION"
      assert output =~ "HEADLINE"
    end

    test "raises (non-zero exit) when the run is below baseline", ctx do
      args = [
        "--golden",
        ctx.golden_path,
        "--baseline",
        ctx.baseline_path,
        "--k",
        "1",
        "--k",
        "3"
      ]

      capture_io(fn -> EvalTask.run(args ++ ["--update-baseline"]) end)

      # Re-run the SAME questions against adversarial labels — a genuine metric drop
      # (not a hand-edited baseline number), which is what a ranking regression looks
      # like from the gate's point of view.
      adversarial_path = Path.join(ctx.dir, "adversarial.jsonl")

      File.write!(
        adversarial_path,
        golden_jsonl(
          small_golden_set(relevant_1: ["presence"], relevant_2: ["queue-concurrency"])
        )
      )

      regressed_args = [
        "--golden",
        adversarial_path,
        "--baseline",
        ctx.baseline_path,
        "--k",
        "1",
        "--k",
        "3",
        "--fail-on-regression"
      ]

      output =
        capture_io(fn ->
          assert_raise Mix.Error, ~r/retrieval eval gate failed/, fn ->
            EvalTask.run(regressed_args)
          end
        end)

      assert output =~ "REGRESSION"
    end

    test "the gate fails closed when a requested mode has no baseline entry", ctx do
      base_args = [
        "--golden",
        ctx.golden_path,
        "--baseline",
        ctx.baseline_path,
        "--k",
        "1",
        "--k",
        "3"
      ]

      # Baseline written for embeddings only.
      capture_io(fn ->
        EvalTask.run(base_args ++ ["--mode", "embeddings", "--update-baseline"])
      end)

      # A keyword_only gate run has no baseline entry — the task must exit non-zero via the
      # "cannot compare (missing_mode)" branch, not print "no regression".
      output =
        capture_io(fn ->
          assert_raise Mix.Error, ~r/retrieval eval gate failed/, fn ->
            EvalTask.run(base_args ++ ["--mode", "keyword_only", "--fail-on-regression"])
          end
        end)

      assert output =~ "no baseline entry for this mode"
      refute output =~ "no regression against baseline"
    end

    test "a missing baseline is a hard failure in gate mode, never a silent pass", ctx do
      args = [
        "--golden",
        ctx.golden_path,
        "--baseline",
        Path.join(ctx.dir, "nope.json"),
        "--fail-on-regression"
      ]

      capture_io(fn ->
        assert_raise Mix.Error, ~r/cannot read baseline/, fn ->
          EvalTask.run(args)
        end
      end)
    end

    test "the gate fails on a shared question even when the aggregates hold", ctx do
      # The gating half of the per-question verdict: raising ONE question's baseline mrr in
      # the file leaves the mode-level aggregates untouched, so nothing but the per-question
      # branch of `maybe_fail/2` stands between this run and a green exit.
      args = ["--golden", ctx.golden_path, "--baseline", ctx.baseline_path, "--k", "1"]

      capture_io(fn -> EvalTask.run(args ++ ["--update-baseline"]) end)

      baseline = ctx.baseline_path |> File.read!() |> JSON.decode!()

      raised =
        update_in(
          baseline["modes"]["embeddings"]["questions"]["q-advisory-lock"]["mrr"],
          &(&1 + 0.5)
        )

      File.write!(ctx.baseline_path, JSON.encode!(raised))

      # The gate names its problems on STDERR (`Mix.shell().error/1`); the report goes to
      # stdout, so both have to be captured to see the whole verdict.
      stderr =
        capture_io(:stderr, fn ->
          stdout =
            capture_io(fn ->
              assert_raise Mix.Error, ~r/retrieval eval gate failed/, fn ->
                EvalTask.run(args ++ ["--fail-on-regression"])
              end
            end)

          refute stdout =~ "no regression against baseline"
        end)

      assert stderr =~ "aggregates OK, but"
      assert stderr =~ "q-advisory-lock"
    end

    test "emits machine-readable json with --json", ctx do
      args = ["--golden", ctx.golden_path, "--baseline", ctx.baseline_path, "--k", "1"]

      capture_io(fn -> EvalTask.run(args ++ ["--update-baseline"]) end)
      output = capture_io(fn -> EvalTask.run(args ++ ["--json"]) end)

      json = output |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "["))
      assert [%{"mode" => "embeddings"} = entry] = JSON.decode!(json)
      assert entry["observed_mode"] == "combined"
      assert entry["spread"]["answered"] == 2
      assert entry["baseline"]["status"] == "ok"
    end
  end

  # =========================================================================
  # 9. Tenant isolation + cleanup
  # =========================================================================

  describe "tenant isolation and cleanup" do
    test "a seeded corpus is invisible to another tenant" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      golden = small_golden_set()

      seeded = RetrievalEval.seed_corpus(tenant_a.id, golden)

      try do
        question = hd(golden.questions).question

        assert {:ok, %{results: results_a}} =
                 Knowledge.search_combined(tenant_a.id, question,
                   limit: 10,
                   embedding: {:ok, RetrievalEval.query_embedding(hd(golden.questions))}
                 )

        assert results_a != []

        assert {:ok, %{results: results_b}} =
                 Knowledge.search_combined(tenant_b.id, question,
                   limit: 10,
                   embedding: {:ok, RetrievalEval.query_embedding(hd(golden.questions))}
                 )

        assert results_b == []
      after
        RetrievalEval.delete_corpus(tenant_a.id, Map.keys(seeded))
      end

      assert article_count(tenant_a.id) == 0
    end

    test "seeded links are real article_links rows, and cleanup deletes them BEFORE the articles" do
      tenant = fixture(:tenant)
      golden = linked_golden_set()

      seeded = RetrievalEval.seed_corpus(tenant.id, golden)

      assert link_count(tenant.id) == 1,
             "the golden set's links must be seeded as real rows — without them the graph " <>
               "lane has nothing to traverse and is a strict no-op"

      # `article_links` FKs both endpoints with `on_delete: :restrict`, so deleting the
      # articles first raises a foreign-key violation from inside `compute/2`'s `after`,
      # where it would replace the real result with a constraint error AND leave the whole
      # corpus behind for every later run. Reverse the two deletes in `delete_corpus/2` and
      # this assertion is what fails.
      RetrievalEval.delete_corpus(tenant.id, Map.keys(seeded))

      assert link_count(tenant.id) == 0
      assert article_count(tenant.id) == 0
    end

    test "compute/2 cleans up its links too, on the path that raises" do
      tenant = fixture(:tenant)

      assert_raise Enum.EmptyError, fn ->
        RetrievalEval.compute(tenant.id, golden_set: linked_golden_set(), k_values: [])
      end

      assert link_count(tenant.id) == 0
      assert article_count(tenant.id) == 0
    end

    test "compute/2 leaves no rows behind on the happy path" do
      tenant = fixture(:tenant)

      RetrievalEval.compute(tenant.id, golden_set: small_golden_set(), k_values: [1, 3])

      assert article_count(tenant.id) == 0
    end

    test "compute/2 cleans up even when scoring raises" do
      tenant = fixture(:tenant)

      # A k_values of [] makes `Enum.max/1` raise inside scoring, after the corpus is
      # already seeded — exactly the mid-run crash the try/after exists for.
      assert_raise Enum.EmptyError, fn ->
        RetrievalEval.compute(tenant.id, golden_set: small_golden_set(), k_values: [])
      end

      assert article_count(tenant.id) == 0
    end

    test "cleanup deletes only this run's rows, never another tenant's" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      golden = small_golden_set()

      b_seeded = RetrievalEval.seed_corpus(tenant_b.id, golden)

      RetrievalEval.compute(tenant_a.id, golden_set: golden, k_values: [1, 3])

      assert article_count(tenant_a.id) == 0
      assert article_count(tenant_b.id) == map_size(b_seeded)

      RetrievalEval.delete_corpus(tenant_b.id, Map.keys(b_seeded))
      assert article_count(tenant_b.id) == 0
    end
  end

  # =========================================================================
  # 10. Deterministic seeded ids (reproducibility of the deploy gate)
  # =========================================================================

  # Minimal result shape for the report tests — every metric undefined, so a rendering
  # assertion cannot accidentally depend on a particular score.
  defp sample_result do
    %{
      golden_version: "v",
      mode: :embeddings,
      observed_mode: "combined",
      fallback_reasons: %{},
      question_count: 1,
      k_values: [5],
      recall_at_k: %{5 => nil},
      ndcg_at_k: %{5 => nil},
      mrr: nil,
      answered: 0,
      answered_k: 5,
      no_retrieval: %{recall_at_k: %{5 => nil}, ndcg_at_k: %{5 => nil}, mrr: nil, answered: 0},
      spread: %{answered: 0, recall_at_k: %{5 => nil}, ndcg_at_k: %{5 => nil}, mrr: nil},
      question_results: [
        %{
          id: "q",
          question: "q?",
          observed_mode: "combined",
          fallback: false,
          fallback_reason: nil,
          ranked: [],
          relevant: [],
          recall_at_k: %{5 => nil},
          mrr: nil,
          ndcg_at_k: %{5 => nil},
          answered: false
        }
      ]
    }
  end

  describe "provenance disclosure" do
    # These figures were quoted to the owner as production retrieval quality on 2026-08-25.
    # The limitation was documented in the runbook at the time and the session had read it,
    # so a doc is demonstrably not sufficient. The disclosure now rides the output itself,
    # and these tests are what stop it being tidied away again.
    test "the text report says the corpus is synthetic and must not be read as production" do
      rendered = Report.render(sample_result(), nil)

      assert rendered =~ "SYNTHETIC FIXTURE"
      assert rendered =~ "REGRESSION signal"

      # The CORPUS being invented is the half that misleads about absolute quality —
      # "synthetic embeddings" alone would read as a limitation of the semantic lane only.
      assert rendered =~ "invented corpus"

      assert rendered =~ "NOT a measurement of",
             "the report must say what it is not, not merely what it is"
    end

    test "the JSON output carries the same disclosure" do
      # JSON is what a script or another agent consumes; a banner only in the human report
      # leaves the machine path able to quote a bare number.
      json = Report.to_json_map(sample_result(), nil)

      assert json["provenance"] == "synthetic_fixture"
      assert json["provenance_note"] =~ "NOT a measurement of production"
    end
  end

  describe "seed_corpus/2 deterministic ids" do
    test "re-seeding the same tenant yields byte-identical ids (no random UUIDs)" do
      tenant = fixture(:tenant)
      golden = small_golden_set()

      map1 = RetrievalEval.seed_corpus(tenant.id, golden)
      RetrievalEval.delete_corpus(tenant.id, Map.keys(map1))
      map2 = RetrievalEval.seed_corpus(tenant.id, golden)
      RetrievalEval.delete_corpus(tenant.id, Map.keys(map2))

      assert map1 == map2
    end

    test "the same doc gets a UNIQUE id per tenant, yet a STABLE cross-tenant doc order" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      golden = small_golden_set()

      map_a = RetrievalEval.seed_corpus(tenant_a.id, golden)
      map_b = RetrievalEval.seed_corpus(tenant_b.id, golden)

      try do
        # Global PK uniqueness: the `articles` PK is `id` alone, so a purely doc-derived id
        # would collide when two tenants (or two concurrent runs) seed the same golden set.
        assert MapSet.disjoint?(MapSet.new(Map.keys(map_a)), MapSet.new(Map.keys(map_b)))

        # Reproducibility: the id is the merge / ORDER BY tiebreak, and its HIGH bytes derive
        # from doc_id alone — so sorting by id yields the SAME doc sequence for both tenants,
        # which is why a score tie resolves identically when the gate re-runs on a fresh
        # throwaway tenant against the committed baseline.
        order_a = map_a |> Enum.sort() |> Enum.map(&elem(&1, 1))
        order_b = map_b |> Enum.sort() |> Enum.map(&elem(&1, 1))
        assert order_a == order_b
      after
        RetrievalEval.delete_corpus(tenant_a.id, Map.keys(map_a))
        RetrievalEval.delete_corpus(tenant_b.id, Map.keys(map_b))
      end
    end
  end

  # =========================================================================
  # 11. --cleanup reaper: marker + age boundary (must not destroy customer data)
  # =========================================================================

  describe "mix loopctl.retrieval.eval --cleanup reaper safety" do
    test "refuses to reap a slug-prefix collision that lacks the programmatic eval marker" do
      # A customer/attacker who registers `retrieval-eval-*` (the slug is user-chosen and
      # unreserved) has settings %{} — no signup path can set the marker. It must survive.
      squatter = leaked_eval_tenant(settings: %{})
      backdate_tenant(squatter.id, 120)

      capture_io(fn -> EvalTask.run(["--cleanup"]) end)

      assert tenant_exists?(squatter.id)
    end

    test "refuses to reap a genuine eval tenant younger than the age guard (concurrent run)" do
      # Freshly created marked tenant simulates a concurrently in-flight run's throwaway
      # tenant — the default 15-minute guard must keep the sweep off it.
      fresh = leaked_eval_tenant([])

      capture_io(fn -> EvalTask.run(["--cleanup"]) end)

      assert tenant_exists?(fresh.id)
    end

    test "reaps a genuine eval tenant older than the age guard" do
      leaked = leaked_eval_tenant([])
      backdate_tenant(leaked.id, 120)

      capture_io(fn -> EvalTask.run(["--cleanup"]) end)

      refute tenant_exists?(leaked.id)
    end

    test "--min-age 0 reaps a marked fresh tenant when the operator knows none is in flight" do
      leaked = leaked_eval_tenant([])

      capture_io(fn -> EvalTask.run(["--cleanup", "--min-age", "0"]) end)

      refute tenant_exists?(leaked.id)
    end
  end

  # A tenant that looks like one this task minted: the user-choosable slug prefix PLUS the
  # programmatic `settings.retrieval_eval` marker (overridable to simulate a slug squatter).
  defp leaked_eval_tenant(overrides) do
    slug = "retrieval-eval-#{System.unique_integer([:positive])}"

    attrs =
      Enum.into(overrides, %{
        name: slug,
        slug: slug,
        email: "#{slug}@example.invalid",
        settings: %{"retrieval_eval" => true}
      })

    {:ok, tenant} = Tenants.create_tenant(attrs)
    tenant
  end

  defp backdate_tenant(tenant_id, minutes_ago) do
    ts = DateTime.add(DateTime.utc_now(), -minutes_ago * 60, :second)

    {1, _} =
      AdminRepo.update_all(from(t in Tenant, where: t.id == ^tenant_id), set: [inserted_at: ts])

    :ok
  end

  defp tenant_exists?(tenant_id) do
    AdminRepo.exists?(from(t in Tenant, where: t.id == ^tenant_id))
  end

  defp article_count(tenant_id) do
    AdminRepo.aggregate(from(a in Article, where: a.tenant_id == ^tenant_id), :count, :id)
  end

  defp link_count(tenant_id) do
    AdminRepo.aggregate(from(l in ArticleLink, where: l.tenant_id == ^tenant_id), :count, :id)
  end

  # A two-doc question carrying ONE edge — the minimum that exercises link seeding and the
  # ordering of the two deletes in `delete_corpus/2`.
  defp linked_golden_set do
    question =
      build(:retrieval_golden_question, %{
        id: "q-linked",
        question: "postgres advisory lock distributed coordination",
        relevant: ["adv-lock-far"],
        graded: %{},
        links: [%{from: "adv-lock", to: "adv-lock-far", type: :relates_to}],
        corpus: [
          build(:retrieval_golden_doc, %{
            doc_id: "adv-lock",
            title: "Postgres advisory lock for distributed coordination",
            body:
              "Take a postgres advisory lock so concurrent nodes cannot run the same step twice."
          }),
          build(:retrieval_golden_doc, %{
            doc_id: "adv-lock-far",
            title: "Releasing the lock on node death",
            body: "A session scoped lock is released automatically when its connection dies."
          })
        ]
      })

    %{version: "golden_v4_test", description: nil, questions: [question]}
  end
end
