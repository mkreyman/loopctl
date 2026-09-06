defmodule Loopctl.Knowledge.SuppressionGuardTest do
  @moduledoc """
  Drift guard for the reversible retrieval tombstone.

  A read path that FORGETS the suppression predicate does not fail — it silently serves an
  article a caller asked the system to forget. Nothing in review reliably catches that, and
  the corpus carries roughly forty places that filter articles to `:published`, so this test
  is the durable half of the feature: it scans `lib/` and fails on any published-status
  filter site that neither applies the predicate nor is named in
  `Loopctl.Knowledge.Suppression.exempt_sites/0` with a reason.

  ## What it can and cannot see

  It matches the LITERAL `<binding>.status == :published` form, which is how a new read path
  is written. It is BLIND to a parametrized status (`a.status == ^status`,
  `maybe_filter_by_status/2`) and to raw SQL, so the paths that take their status from the
  caller or spell it as a string are pinned by their own named assertions below rather than
  by the scan. It is also blind to a filter site introduced through a macro. Read "do not relax this test" as "this
  floor is lower than it looks — raise it, never lower it".

  The scan itself is asserted NON-EMPTY and above a floor, because a classifier that matches
  nothing passes vacuously — the failure mode a previous loopctl guard shipped with.
  """

  use ExUnit.Case, async: true

  alias Loopctl.Knowledge.Suppression

  # The scan found 47 sites when this guard was written. The floor is deliberately well
  # below that: it exists to catch a regex that stopped matching (a rename, a formatter
  # change), not to pin a count that grows. See CLAUDE.md's "never record inventory counts".
  @minimum_expected_sites 30

  @published_marker ~r/\.status\s*==\s*:published/

  describe "the scan itself" do
    test "matches a non-empty set of published-status filter sites" do
      sites = scan_sites()

      refute sites == [],
             "the published-status classifier matched NOTHING. A guard that matches nothing " <>
               "passes vacuously — fix the regex, do not delete the test."

      assert length(sites) >= @minimum_expected_sites,
             "the classifier matched only #{length(sites)} sites, below the #{@minimum_expected_sites} floor. " <>
               "Either a large refactor moved these filters, or the regex stopped matching."
    end

    test "matches the sites we know are there, so a silent regex break is visible" do
      keys = sites_by_key() |> Map.keys() |> MapSet.new()

      for known <- [
            "lib/loopctl/knowledge.ex:list_index",
            "lib/loopctl/knowledge.ex:curated_sources_base_query",
            "lib/loopctl/knowledge.ex:heat_article_ids",
            "lib/loopctl/knowledge/consolidation.ex:published_base",
            "lib/loopctl/knowledge/okf.ex:export_query"
          ] do
        assert MapSet.member?(keys, known),
               "the classifier no longer sees #{known}. It is a real published-status " <>
                 "filter site; if it moved, update this list — do not drop the assertion."
      end
    end
  end

  describe "coverage" do
    test "coverage is judged on code — not on a comment, and not on filter(_, :include)" do
      # A deleted predicate whose explanation survives must NOT keep the guard green, and
      # `:include` RETURNS suppressed rows, so a call that hardcodes it is not coverage.
      refute covered?("  # Suppression.exclude/1 belongs here; is_nil(a.suppressed_at) went.")
      refute covered?("Suppression.filter(query, :include)")
      assert covered?("|> Suppression.exclude()")
      assert covered?("Suppression.filter(base, Keyword.get(opts, :suppressed, :exclude))")
    end

    test "every published-status filter site either applies the predicate or is exempt" do
      uncovered =
        sites_by_key()
        |> Enum.reject(fn {key, %{body: body}} ->
          covered?(body) or Map.has_key?(Suppression.exempt_sites(), key)
        end)
        |> Enum.map(&elem(&1, 0))
        |> Enum.sort()

      assert uncovered == [],
             """
             These functions filter articles to :published but never exclude suppressed ones,
             so a suppressed article is still returned from them:

             #{Enum.map_join(uncovered, "\n", &"  - #{&1}")}

             Fix by applying the predicate (Suppression.exclude/1, Suppression.filter/2, or an
             inline is_nil(<binding>.suppressed_at) for a middle binding). Exempt it in
             Suppression.exempt_sites/0 ONLY if it is genuinely not a retrieval path, and say
             which category (inspect / backup / maintenance / system-scope) and why.
             """
    end

    test "no exemption names a site that no longer exists" do
      keys = sites_by_key() |> Map.keys() |> MapSet.new()

      stale =
        Suppression.exempt_sites()
        |> Map.keys()
        |> Enum.reject(&MapSet.member?(keys, &1))
        |> Enum.sort()

      assert stale == [],
             """
             These exemptions name sites the scan no longer finds:

             #{Enum.map_join(stale, "\n", &"  - #{&1}")}

             A stale exemption is how this list turns into an escape hatch: it accumulates
             entries nobody can check, and the next uncovered site gets added beside them.
             Delete them, or fix the key if the function was renamed.
             """
    end

    test "every exemption states a category and a reason" do
      categories = ~w(inspect backup maintenance system-scope)

      for {key, reason} <- Suppression.exempt_sites() do
        assert is_binary(reason) and String.length(reason) > 40,
               "#{key}: an exemption needs a reason someone can disagree with, not a label."

        assert Enum.any?(categories, &String.contains?(reason, &1)),
               "#{key}: the reason names none of #{inspect(categories)}. " <>
                 "Naming the category is what makes an exemption reviewable."
      end
    end
  end

  describe "the parametrized-status retrieval paths the scan cannot see" do
    test "VectorSearch excludes suppressed articles on BOTH ANN branches" do
      source = File.read!("lib/loopctl/knowledge/vector_search.ex")

      assert source =~ "Suppression.exclude()",
             "the legacy ANN branch no longer excludes suppressed articles — semantic " <>
               "search would return them."

      assert source =~ "Suppression.exclude_last()",
             "the side-table ANN branch no longer excludes suppressed articles. The cutover " <>
               "flag must never decide whether a suppressed article is retrievable."
    end

    test "the shared search filter chain applies the predicate" do
      body = function_body!("lib/loopctl/knowledge.ex", "apply_search_filters")

      assert covered?(body),
             "apply_search_filters/3 is where the keyword lane, the semantic pool " <>
               "hydration, the combined lanes, list_filtered/2 and keyset_query/2 all " <>
               "converge. Without the predicate here, every one of them leaks."
    end

    test "the shared article-filter chain applies the predicate" do
      body = function_body!("lib/loopctl/knowledge.ex", "apply_article_filters")

      assert covered?(body),
             "apply_article_filters/2 is the enumeration chain behind GET /api/v1/articles, " <>
               "count_articles/2 and tag_facets/2. Without the predicate here that endpoint " <>
               "disagrees with GET /knowledge/index about what is in the corpus."
    end

    test "the raw-SQL graph traversal and bridge filter carry the predicate" do
      # Comments stripped for the same reason covered?/1 strips them: the paragraph
      # explaining the predicate sits above it and would count as one of the two.
      source = strip_comment_lines(File.read!("lib/loopctl/knowledge.ex"))

      assert length(Regex.scan(~r/a\.suppressed_at IS NULL/, source)) >= 2,
             "the recursive graph CTE must carry the predicate on BOTH arms — filtering " <>
               "only at hydration lets suppressed rows spend the node budget."

      assert length(Regex.scan(~r/m\.suppressed_at IS NULL/, source)) >= 2,
             "both bridge fragments must exclude a suppressed middle node, or a pair is " <>
               "reported bridgeable through an article the tenant asked us to forget."
    end

    test "the RRF graph lane hydrates through the predicate" do
      body = function_body!("lib/loopctl/knowledge.ex", "fetch_graph_lane_articles")

      assert covered?(body),
             "the RRF graph lane takes a parametrized status, so the scan above cannot see " <>
               "it. Its predicate is written by hand and must stay."
    end
  end

  # --- the scanner ---

  # Coverage is judged on CODE, never on prose. `body_has_filter_site?/1` already refuses to
  # DETECT a site on a comment line; judging coverage on raw source was the other half of the
  # same mistake, and it is the half that fails open — a predicate deleted while the comment
  # explaining it survives would keep reporting the site as covered while the leak shipped.
  defp covered?(body) do
    code = strip_comment_lines(body)

    Enum.any?(Suppression.predicate_markers(), &Regex.match?(&1, code))
  end

  defp strip_comment_lines(body) do
    body
    |> String.split("\n")
    |> Enum.reject(&Regex.match?(~r/^\s*#/, &1))
    |> Enum.join("\n")
  end

  defp sites_by_key do
    scan_sites()
    |> Enum.group_by(& &1.key, & &1.body)
    |> Map.new(fn {key, bodies} -> {key, %{body: Enum.join(bodies, "\n")}} end)
  end

  defp scan_sites do
    "lib/**/*.ex"
    |> Path.wildcard()
    |> Enum.flat_map(&sites_in_file/1)
    # The predicate module declares the markers; it is not itself a filter site.
    |> Enum.reject(&(&1.key =~ "knowledge/suppression.ex"))
  end

  # Grouped by NAME first: a multi-clause function composes one query across its clauses, so
  # a predicate applied in clause 2 covers a filter site written in clause 1. Judging clauses
  # independently reported a covered function as uncovered — and the reverse error, judging a
  # site by the first clause alone, is the one that would let a leak through.
  defp sites_in_file(path) do
    path
    |> clauses_in()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.filter(fn {_name, bodies} -> Enum.any?(bodies, &body_has_filter_site?/1) end)
    |> Enum.map(fn {name, bodies} ->
      %{key: "#{path}:#{name}", body: Enum.join(bodies, "\n")}
    end)
  end

  # A filter site is a published-status comparison on a line that is not a comment and not
  # inside a heredoc. Comments are where this feature's own explanations live, so counting
  # them would mark a site covered by its own prose — the exact substring-classifier failure
  # loopctl has already shipped once.
  defp body_has_filter_site?(body) do
    body
    |> String.split("\n")
    |> Enum.any?(fn line ->
      Regex.match?(@published_marker, line) and not Regex.match?(~r/^\s*#/, line)
    end)
  end

  # Splits a file into `{function_name, clause_body}` pairs, one per `def`/`defp` head. A
  # body runs from its head to the next one, so a multi-clause function yields several pairs;
  # every consumer regroups them by name.
  defp clauses_in(path) do
    path
    |> File.read!()
    |> strip_doc_heredocs()
    |> String.split("\n")
    |> Enum.reduce({[], nil, []}, fn line, {done, current, acc} ->
      case Regex.run(~r/^\s*(?:def|defp|defmacro|defmacrop)\s+([a-z_][a-zA-Z0-9_?!]*)/, line) do
        [_, name] ->
          {flush(done, current, acc), name, [line]}

        nil ->
          {done, current, [line | acc]}
      end
    end)
    |> then(fn {done, current, acc} -> flush(done, current, acc) end)
    |> Enum.reverse()
  end

  defp flush(done, nil, _acc), do: done
  defp flush(done, name, acc), do: [{name, acc |> Enum.reverse() |> Enum.join("\n")} | done]

  # `@doc`/`@moduledoc` heredocs describe filters in prose and would otherwise be attributed
  # to whatever function precedes them.
  defp strip_doc_heredocs(source) do
    Regex.replace(~r/@(?:module)?doc\s+(?:false\s*$|"""\n.*?""")/ms, source, "@doc_stripped")
  end

  defp function_body!(path, name) do
    case path |> clauses_in() |> Enum.filter(fn {n, _body} -> n == name end) do
      [_ | _] = clauses ->
        clauses |> Enum.map_join("\n", &elem(&1, 1))

      [] ->
        flunk(
          "#{path} no longer defines #{name}/_. This assertion pins a retrieval path the " <>
            "source scan cannot see; find where the function went and re-point it."
        )
    end
  end
end
