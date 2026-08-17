defmodule Loopctl.Knowledge.RetrievalEval.GoldenSet do
  @moduledoc """
  Loader + validator for the COMMITTED golden-question set (#469) used by
  `Loopctl.Knowledge.RetrievalEval`.

  The golden set is a stable, committed data file (`priv/retrieval_eval/golden.jsonl`) —
  NOT code — so its relevance labels are versioned and reviewable in a diff.

  ## Why the labels are SELF-CONTAINED (and not production article UUIDs)

  Articles are per-tenant DB rows and CI starts with an EMPTY database, so a label
  written as a production article UUID would be unscoreable anywhere but the machine
  that mined it. Every question therefore carries its OWN corpus: a list of documents
  with a stable string `doc_id`, plus the `relevant` doc_ids. The runner seeds that
  corpus into a throwaway tenant, maps `doc_id -> inserted article id`, runs the search,
  and maps result ids BACK to `doc_id` to score. Provenance (where a question came from)
  lives in the free-text `source` field for documentation — it is never a runtime
  dependency, and the eval never calls a network or an LLM.

  ## File format

  JSONL. **Line 1 is a header object**; every subsequent line is one question.

      {"kind":"header","version":"golden_v1","description":"..."}
      {"kind":"question","id":"q-...", ...}

  ### Header fields

    * `kind` — must be `"header"`.
    * `version` — the golden-set version string. A baseline records the version it
      was measured against, so re-labelling forces a re-baseline instead of silently
      comparing against stale numbers.
    * `description` — free text.

  ### Question fields

    * `id` — stable question identifier, unique across the file. It is the row key in
      the per-question report table, so renaming one breaks its baseline history.
    * `question` — the query string handed to `search_combined/3` verbatim. Must be at
      most #{500} characters — `search_combined/3` hard-rejects a longer query, which the
      scorer would silently turn into a 0, so the loader rejects it loudly instead.
    * `source` — free text provenance ("mined from article_access_events", "hand-authored
      from <doc>"). Documentation only.
    * `corpus` — the documents seeded for this question. Each carries:
      * `doc_id` — stable id, unique across the WHOLE file (all corpora are seeded into
        one tenant, so ids and titles must not collide).
      * `title`, `body` — the article text. Titles must be unique file-wide.
      * `category` — one of `Loopctl.Knowledge.Categories.all/0`.
      * `tags` — optional list of tag strings.
      * `age_days` — optional non-negative number. How many days BEFORE the seed instant
        the article was last updated, so the seeded `updated_at`/`inserted_at` reflect it.
        Absent/`0` means "updated now" (the default all docs used before #471). This is
        what makes the recency prior testable: a recency-sensitive question can seed the
        correct answer fresh among older near-tie distractors.
    * `relevant` — the doc_ids that SHOULD be retrieved for this question. Must be a
      non-empty subset of this question's own `corpus`.
    * `graded` — optional map of `doc_id => grade` (integer 0..3) used as the nDCG gain.
      A relevant doc missing from `graded` defaults to grade 1; a doc not in `relevant`
      is grade 0 regardless. Because a grade on a non-relevant doc is therefore inert (and
      almost always a mistake), the loader rejects a `graded` key that is not also in
      `relevant`.
    * `links` — optional list of directed edges seeded into `article_links` for this
      question, each `{"from": doc_id, "to": doc_id, "type": relationship_type}` with
      `type` optional (default `relates_to`). Both endpoints must be in this question's own
      corpus. This is what makes the graph lane evaluable: without edges the lane is a
      strict no-op and enabling it scores an identical, entirely uninformative delta. See
      below.
    * `corpus_ref` — optional id of ANOTHER question whose `corpus`, `relevant`, `graded`
      and `links` this question borrows (golden_v3). A question using it supplies only its
      own `question` text and must declare none of those four itself. See below.

  ## Paired questions: measuring query SHAPE (`corpus_ref`, golden_v3)

  Production traffic is not shaped like a hand-authored question. 71% of this KB's search
  volume is the injected recall hook, which distils the user's prompt into a stop-word-
  stripped salience bag of at most 8 terms — "enable row level security new tenant scoped
  table", not "how do I enable row level security on a new tenant scoped table". Whether
  retrieval survives that transformation was unmeasurable while every golden question was
  prose.

  `corpus_ref` makes it a controlled experiment. The paired question carries the hook's
  output verbatim as its `question` and points at the prose question's corpus, so both are
  scored against an IDENTICAL corpus with IDENTICAL labels and the per-question delta is
  attributable to the query alone. Duplicating the corpus under fresh doc_ids would instead
  seed two near-identical article sets into the one shared tenant, where each copy becomes
  the other's strongest distractor — that measures the duplication, not the query.

  Refs are resolved at load time and are deliberately restricted: one hop only (no chains,
  whose resolution would depend on file order), no self-reference, and the referring
  question may not declare its own corpus/labels.

  ## Multi-hop questions: measuring the graph lane (`links`, golden_v4)

  The optional RRF graph lane (#470) takes the top merged candidates as seeds and adds their
  `article_links` neighbours as a third lane. It cannot help a question whose answer is
  already retrievable lexically or semantically — the research is explicit that graph
  retrieval WINS on multi-hop and LOSES on single-fact lookups, so an eval that only asks
  single-fact questions can measure the loss and never the win.

  A multi-hop question is therefore built so the relevant document is deliberately NOT
  reachable from the query text: the query names a bridge document, and the answer hangs off
  that bridge by a link. Both documents live in the same corpus, both are seeded, and the
  ONLY thing connecting the query to the answer is the edge. A run with the lane off scores
  such a question near zero by construction; that is the point, and it is what makes the
  lane-on run a measurement rather than a demonstration.

  Because the lane's `list_links_for_seed_set/3` filters by neither relationship type nor
  direction, `links` can express any of the five types and the lane will traverse it either
  way round. Production is 96% `relates_to`, which is the default.

  ## Adding a labeled question

  Append one JSON object per line (never reformat the file to pretty JSON — it is JSONL)
  with globally-unique `id`, `doc_id`s and titles, then re-baseline. The full runbook is
  `docs/runbooks/retrieval_eval.md`.

  ## Validation

  `load!/1` (and therefore `default/0`) RAISES on a malformed file rather than silently
  scoring fewer questions: a missing/duplicate id, an empty question or corpus, a
  question over #{500} characters (which `search_combined/3` rejects outright), a
  duplicate `doc_id`/title, a `relevant` entry absent from that question's corpus, a
  `graded` key that is not also `relevant`, an out-of-range grade, or an unknown
  category. A silently unscoreable question is worse than a loud failure — it moves the
  aggregate without anyone noticing.
  """

  alias Loopctl.Knowledge.Categories

  @type doc :: %{
          doc_id: String.t(),
          title: String.t(),
          body: String.t(),
          category: atom(),
          tags: [String.t()],
          age_days: number() | nil
        }

  @type link :: %{from: String.t(), to: String.t(), type: atom()}

  @type question :: %{
          id: String.t(),
          question: String.t(),
          source: String.t() | nil,
          corpus: [doc()],
          relevant: [String.t()],
          graded: %{String.t() => non_neg_integer()},
          links: [link()],
          corpus_ref: String.t() | nil
        }

  @type t :: %{version: String.t(), description: String.t() | nil, questions: [question()]}

  @relative_path "retrieval_eval/golden.jsonl"

  @max_grade 3

  # Mirrors `Loopctl.Knowledge` `validate_query_string/1` (knowledge.ex ~6571): a query
  # over 500 chars is hard-rejected by `search_combined/3` as `{:error, :bad_request}`,
  # which the scorer would turn into a silent 0. Reject it at load time instead.
  @max_question_length 500

  @doc "The default committed golden set (`priv/retrieval_eval/golden.jsonl`)."
  @spec default() :: t()
  def default, do: load!(default_path())

  @doc "Absolute path of the committed golden set."
  @spec default_path() :: String.t()
  def default_path do
    :loopctl
    |> :code.priv_dir()
    |> Path.join(@relative_path)
  end

  @doc """
  Load and validate a golden set from `path`. Raises `ArgumentError` on a malformed file.
  """
  @spec load!(String.t()) :: t()
  def load!(path) do
    path
    |> File.read!()
    |> parse!()
  end

  @doc """
  Parse and validate golden-set JSONL `contents`. Raises `ArgumentError` when malformed.
  """
  @spec parse!(String.t()) :: t()
  def parse!(contents) when is_binary(contents) do
    lines =
      contents
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    case lines do
      [] ->
        raise ArgumentError, "golden set is empty"

      [header_line | question_lines] ->
        header = decode_line!(header_line, 1)
        questions = Enum.map(Enum.with_index(question_lines, 2), &decode_question!/1)

        set = %{
          version: fetch_string!(header, "version", "header"),
          description: header["description"],
          questions: resolve_corpus_refs!(questions)
        }

        validate!(set)
    end
  end

  @doc """
  The de-duplicated UNION of every question's corpus, in file order.

  All questions are scored against ONE seeded tenant, so each question's non-relevant
  documents act as distractors for the others — a more honest ranking test than seeding
  each question in isolation, and far cheaper than a tenant per question.
  """
  @spec corpus(t()) :: [doc()]
  def corpus(%{questions: questions}) do
    questions
    |> Enum.flat_map(& &1.corpus)
    |> Enum.uniq_by(& &1.doc_id)
  end

  @doc """
  The de-duplicated UNION of every question's `links`, in file order.

  De-duplicated on `{from, to, type}` for the same reason `corpus/1` de-duplicates on
  `doc_id`: paired (`corpus_ref`) questions share one edge set, and `article_links` carries
  a unique index on exactly that triple, so seeding it twice is an insert error rather than
  a second edge.
  """
  @spec links(t()) :: [link()]
  def links(%{questions: questions}) do
    questions
    # `Map.get/3`, not `.links`: a question map built in memory by a test never passes
    # through `decode_question!/1` and so carries no `:links` key. Seeding must treat that
    # as "no edges", exactly as `grade/2` treats a missing `:graded`, rather than raising
    # from inside the corpus seeder.
    |> Enum.flat_map(&Map.get(&1, :links, []))
    |> Enum.uniq_by(&{&1.from, &1.to, &1.type})
  end

  @doc """
  The nDCG gain for `doc_id` under `question`: the graded value when present, 1 for a
  relevant doc with no explicit grade, 0 otherwise.
  """
  @spec grade(question(), String.t()) :: non_neg_integer()
  def grade(%{relevant: relevant, graded: graded}, doc_id) do
    # Relevance membership is checked FIRST so the documented contract holds no matter
    # what `graded` contains: "a doc not in relevant is grade 0 regardless". Checking
    # `graded` first (as an earlier version did) let a graded-but-not-relevant distractor
    # contribute a positive gain to DCG without contributing to IDCG (which is built from
    # `relevant` only), so nDCG@k could exceed 1.0. `validate_question!/1` also rejects a
    # graded doc_id that is not relevant, so this branch is belt-and-suspenders — but the
    # metric must be correct on any question map, including in-memory ones built in tests
    # that never pass through the loader.
    cond do
      doc_id not in relevant -> 0
      Map.has_key?(graded, doc_id) -> Map.fetch!(graded, doc_id)
      true -> 1
    end
  end

  # ===========================================================================
  # corpus_ref — a PAIRED question (golden_v3)
  # ===========================================================================

  # A `corpus_ref` question supplies only its own `question` text and borrows the corpus
  # AND labels of the question it names. That is what makes query SHAPE measurable: the
  # prose question and the keyword-bag the recall hook distils it into are scored against
  # an identical corpus with identical labels, so the per-question delta between the pair
  # is attributable to the query alone. Duplicating the corpus under fresh doc_ids instead
  # would seed two near-identical article sets into one tenant, and each copy would become
  # the other's strongest distractor — measuring the duplication, not the query.
  #
  # Resolution happens at LOAD time, so every consumer downstream (`compute/2`,
  # `corpus/1`, `grade/2`, the report) sees an ordinary fully-populated question and needed
  # no change. `corpus/1` de-duplicates by doc_id, so a shared corpus is still seeded once.
  defp resolve_corpus_refs!(questions) do
    by_id = Map.new(questions, &{&1.id, &1})

    Enum.map(questions, fn
      %{corpus_ref: nil} = question ->
        question

      %{corpus_ref: ref, id: id} = question ->
        # A ref question declaring its own corpus/labels is ambiguous about which set
        # scores, so it is rejected rather than silently resolved one way.
        if question.corpus != [] or question.relevant != [] or question.graded != %{} or
             question.links != [] do
          raise ArgumentError,
                "golden question #{id}: corpus_ref questions must not declare their own " <>
                  "corpus, relevant, graded or links (they borrow the referenced " <>
                  "question's)"
        end

        target =
          Map.get(by_id, ref) ||
            raise ArgumentError,
                  "golden question #{id}: corpus_ref #{inspect(ref)} names no question in " <>
                    "this file"

        if ref == id do
          raise ArgumentError, "golden question #{id}: corpus_ref points at itself"
        end

        # No chains: resolving A -> B -> C would depend on file ORDER, and a cycle would
        # not terminate. One hop keeps the reference relation trivially total.
        if target.corpus_ref != nil do
          raise ArgumentError,
                "golden question #{id}: corpus_ref #{inspect(ref)} is itself a corpus_ref " <>
                  "question (chains are not allowed — point at the question that owns the " <>
                  "corpus)"
        end

        # `links` is inherited with the corpus for the same reason the corpus is shared:
        # the pair must differ in the QUERY and nothing else. A paired question that saw a
        # different edge set would be measuring the topology, not the query shape.
        %{
          question
          | corpus: target.corpus,
            relevant: target.relevant,
            graded: target.graded,
            links: target.links
        }
    end)
  end

  # ===========================================================================
  # Decoding — a FIXED set of string keys mapped to atom keys. Never
  # `String.to_atom/1` on file content.
  # ===========================================================================

  defp decode_question!({line, line_no}) do
    raw = decode_line!(line, line_no)

    if raw["kind"] not in [nil, "question"] do
      raise ArgumentError,
            "golden set line #{line_no}: expected kind \"question\", got #{inspect(raw["kind"])}"
    end

    %{
      id: fetch_string!(raw, "id", "line #{line_no}"),
      question: fetch_string!(raw, "question", "line #{line_no}"),
      source: raw["source"],
      corpus: Enum.map(raw["corpus"] || [], &normalize_doc!(&1, line_no)),
      relevant: raw["relevant"] || [],
      graded: raw["graded"] || %{},
      links: Enum.map(raw["links"] || [], &normalize_link!(&1, line_no)),
      corpus_ref: raw["corpus_ref"]
    }
  end

  # The five `ArticleLink` relationship types, as a FIXED string->atom map. Never
  # `String.to_atom/1` on file content, and an unknown type is a loud failure rather than a
  # silently-untraversed edge.
  @relationship_types %{
    "relates_to" => :relates_to,
    "derived_from" => :derived_from,
    "contradicts" => :contradicts,
    "supersedes" => :supersedes,
    "potential_conflict" => :potential_conflict
  }

  defp normalize_link!(raw, line_no) when is_map(raw) do
    context = "line #{line_no}"
    from = fetch_string!(raw, "from", context)
    to = fetch_string!(raw, "to", context)
    raw_type = raw["type"] || "relates_to"

    type =
      Map.get(@relationship_types, raw_type) ||
        raise ArgumentError,
              "golden set #{context}: unknown link type #{inspect(raw_type)} " <>
                "(expected one of #{Enum.join(Map.keys(@relationship_types), ", ")})"

    %{from: from, to: to, type: type}
  end

  defp normalize_link!(raw, line_no) do
    raise ArgumentError,
          "golden set line #{line_no}: each link must be an object with from/to, " <>
            "got #{inspect(raw)}"
  end

  defp decode_line!(line, line_no) do
    case JSON.decode(line) do
      {:ok, %{} = map} ->
        map

      {:ok, other} ->
        raise ArgumentError,
              "golden set line #{line_no}: expected a JSON object, got #{inspect(other)}"

      {:error, reason} ->
        raise ArgumentError, "golden set line #{line_no}: invalid JSON (#{inspect(reason)})"
    end
  end

  defp normalize_doc!(%{} = doc, line_no) do
    %{
      doc_id: fetch_string!(doc, "doc_id", "line #{line_no} corpus"),
      title: fetch_string!(doc, "title", "line #{line_no} corpus"),
      body: fetch_string!(doc, "body", "line #{line_no} corpus"),
      category: category!(doc["category"], line_no),
      tags: doc["tags"] || [],
      age_days: age_days!(doc["age_days"], line_no)
    }
  end

  defp normalize_doc!(other, line_no) do
    raise ArgumentError,
          "golden set line #{line_no}: corpus entry must be an object, got #{inspect(other)}"
  end

  # Optional per-doc age (days before the seed instant). Absent → nil (updated now).
  # A negative age would place the doc in the FUTURE and silently invert the recency
  # prior, so reject it loudly like every other malformed field.
  defp age_days!(nil, _line_no), do: nil

  defp age_days!(value, _line_no) when is_number(value) and value >= 0, do: value

  defp age_days!(other, line_no) do
    raise ArgumentError,
          "golden set line #{line_no} corpus: age_days must be a non-negative number, " <>
            "got #{inspect(other)}"
  end

  defp fetch_string!(map, key, where) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" ->
        value

      other ->
        raise ArgumentError,
              "golden set #{where}: #{key} must be a non-empty string, got #{inspect(other)}"
    end
  end

  # The category is matched against the canonical taxonomy by STRING comparison, so an
  # unknown value raises instead of minting an atom from file content.
  defp category!(value, line_no) when is_binary(value) do
    case Enum.find(Categories.all(), &(Atom.to_string(&1) == value)) do
      nil ->
        raise ArgumentError, "golden set line #{line_no}: unknown category #{inspect(value)}"

      category ->
        category
    end
  end

  defp category!(other, line_no) do
    raise ArgumentError,
          "golden set line #{line_no}: category must be a string, got #{inspect(other)}"
  end

  # ===========================================================================
  # Validation
  # ===========================================================================

  defp validate!(%{questions: questions} = set) do
    if questions == [], do: raise(ArgumentError, "golden set has no questions")

    validate_unique!(Enum.map(questions, & &1.id), "question id")

    # Only questions that DECLARE a corpus contribute to doc-id/title uniqueness. A
    # `corpus_ref` question was handed a copy of another question's docs by
    # `resolve_corpus_refs!/1`, so counting it here would flag every shared doc as a
    # duplicate of itself.
    all_docs = questions |> Enum.filter(&is_nil(&1.corpus_ref)) |> Enum.flat_map(& &1.corpus)
    validate_doc_uniqueness!(all_docs)
    Enum.each(questions, &validate_question!/1)

    set
  end

  defp validate_question!(%{
         id: id,
         question: question,
         corpus: corpus,
         relevant: relevant,
         graded: graded,
         links: links
       }) do
    if corpus == [], do: raise(ArgumentError, "golden question #{id}: corpus is empty")
    if relevant == [], do: raise(ArgumentError, "golden question #{id}: relevant is empty")

    validate_question_length!(id, question)

    corpus_ids = MapSet.new(corpus, & &1.doc_id)
    relevant_ids = MapSet.new(relevant)

    # Label integrity: a `relevant` doc_id that is not in this question's own corpus can
    # never be retrieved, so the question would silently score 0 forever.
    Enum.each(relevant, fn doc_id ->
      unless MapSet.member?(corpus_ids, doc_id) do
        raise ArgumentError,
              "golden question #{id}: relevant doc_id #{inspect(doc_id)} is not in its corpus"
      end
    end)

    validate_unique!(relevant, "relevant doc_id in question #{id}")

    Enum.each(graded, &validate_graded!(id, &1, corpus_ids, relevant_ids))
    validate_links!(id, links, corpus_ids)
  end

  # A link endpoint outside this question's own corpus names a doc this question never
  # seeds, so the edge would either fail to insert or (worse) wire this question's seeds to
  # another question's docs and silently change what BOTH measure.
  defp validate_links!(id, links, corpus_ids) do
    Enum.each(links, &validate_link!(id, &1, corpus_ids))

    # The `(tenant, source, target, type)` unique index would reject a duplicate at insert
    # time with an opaque constraint error; reject it here, naming the question.
    validate_unique!(
      Enum.map(links, &{&1.from, &1.to, &1.type}),
      "link in question #{id}"
    )
  end

  defp validate_link!(id, %{from: from, to: to}, corpus_ids) do
    Enum.each([from, to], fn doc_id ->
      unless MapSet.member?(corpus_ids, doc_id) do
        raise ArgumentError,
              "golden question #{id}: link endpoint #{inspect(doc_id)} is not in its corpus"
      end
    end)

    if from == to do
      raise ArgumentError,
            "golden question #{id}: link from #{inspect(from)} to itself " <>
              "(article_links rejects self-links)"
    end
  end

  defp validate_question_length!(id, question) do
    if String.length(question) > @max_question_length do
      raise ArgumentError,
            "golden question #{id}: question is #{String.length(question)} chars, " <>
              "over the #{@max_question_length}-char limit search_combined/3 enforces " <>
              "(it would silently score 0)"
    end
  end

  defp validate_graded!(id, {doc_id, gradev}, corpus_ids, relevant_ids) do
    unless MapSet.member?(corpus_ids, doc_id) do
      raise ArgumentError,
            "golden question #{id}: graded doc_id #{inspect(doc_id)} is not in its corpus"
    end

    # A grade on a non-relevant doc is inert (grade/2 returns 0 for it) and would let a
    # distractor look intentionally weighted — reject it so the labels stay honest.
    unless MapSet.member?(relevant_ids, doc_id) do
      raise ArgumentError,
            "golden question #{id}: graded doc_id #{inspect(doc_id)} is not in `relevant` " <>
              "(a grade on a non-relevant doc is ignored)"
    end

    unless is_integer(gradev) and gradev >= 0 and gradev <= @max_grade do
      raise ArgumentError,
            "golden question #{id}: grade for #{doc_id} must be an integer 0..#{@max_grade}, " <>
              "got #{inspect(gradev)}"
    end
  end

  # doc_ids AND titles must be globally unique: the whole file is seeded into ONE tenant,
  # where titles carry a per-tenant uniqueness constraint and doc_id is the scoring key.
  defp validate_doc_uniqueness!(docs) do
    validate_unique!(Enum.map(docs, & &1.doc_id), "corpus doc_id")
    validate_unique!(Enum.map(docs, & &1.title), "corpus title")
  end

  defp validate_unique!(values, label) do
    dupes =
      values
      |> Enum.frequencies()
      |> Enum.filter(fn {_v, count} -> count > 1 end)
      |> Enum.map(&elem(&1, 0))

    if dupes != [] do
      raise ArgumentError, "golden set: duplicate #{label}: #{inspect(dupes)}"
    end
  end
end
