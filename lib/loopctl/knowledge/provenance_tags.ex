defmodule Loopctl.Knowledge.ProvenanceTags do
  @moduledoc """
  The tag prefixes that identify WHERE an article came from rather than what it is about.

  Topical tags are LLM-generated once at ingest (`Loopctl.Workers.ContentIngestionWorker`
  hands the content to the configured extractor, which returns title/body/category/tags in
  one shot); nothing re-tags an existing article. Alongside those, the harvest sourcers mint
  opaque per-source ids as tags — `url-42516bb95051`, `book-0be008289fe8`, `yt-bH722QgRlhQ`,
  `pp-1-12` (pages 1-12), `chunk-7` — and since #583 those move into the reserved
  `idem-<family>-<digest>` namespace owned by `Loopctl.Knowledge.IdempotencyTag`.

  ## Why this is one list and not three

  Two subsystems need the same answer and had grown their own:

    * `Loopctl.Workers.KnowledgeMocWorker` — an `Index: url-42516bb95051` hub is noise.
    * `articles.search_vector` (migration `20260817212906`) — Postgres tokenizes a
      hyphenated word into the compound AND its parts, so indexing `url-42516bb95051` puts
      the bare lexeme `url` on thousands of rows. `url`, `book`, `doc`, `page`, `part` and
      `idem` are ordinary query words, so the cost is PRECISION on real queries, not index
      size.

  A third, hand-written copy was drafted for the index and omitted `idem-` entirely, which
  would have indexed every future capture id. Hence one owner.

  **The two consumers ask different questions and only happen to share an answer.** MOC
  eligibility asks "should this become an index HUB"; the keyword index asks "should this be
  SEARCHABLE" — a repository name is a bad hub and a defensible search term. If they need to
  diverge, split this into two lists rather than widening one.

  ## Changing the list

  The index side is baked into a GENERATED column by a migration (a generated column cannot
  call Elixir, the same constraint that made `20260724190000` bake in the regconfig), so
  editing `prefixes/0` does NOT change what is indexed. `Loopctl.Knowledge.ProvenanceTagsTest`
  fails when the stored pattern and this list diverge; the remedy is a new migration.
  """

  alias Loopctl.Knowledge.IdempotencyTag

  # Kept to concrete OBSERVED patterns: a broad `p-` would wrongly drop real hyphenated
  # topics (`p-value`). `chapter-`/`part-` are the same chunk-coordinate class as `pp-` and
  # `chunk-` — book structure, not subject — measured on the live corpus at 3,536 and 3,459
  # instances across 296 and 284 distinct tags.
  #
  # `idem-` must be listed in its OWN right: matching is by prefix, and `url-` does not
  # match `idem-url-…`. It comes from `IdempotencyTag.reserved_prefix/0` so it cannot drift
  # from the namespace it suppresses.
  @prefixes ~w(
              yt- doc- repo- url- book- img- file- vid- web- chunk- pp- www-
              chapter- part-
            ) ++ [IdempotencyTag.reserved_prefix()]

  # Whole tags that describe an article's FORMAT or SOURCE TYPE rather than its subject.
  # Distinct from the prefixes above, which are opaque per-source ids: these are ordinary
  # words that are simply not what an article is ABOUT. `KnowledgeMocWorker` has excluded
  # them from hub topics since it was written; the re-tagger needs the same answer, because
  # showing a model `reference, document, pdf, book, youtube` as the vocabulary to PREFER
  # teaches it to tag format instead of subject. Measured 2026-08-18: those five were the
  # top of the hosted corpus's most-used tags, and a verification run of the backfill added
  # `document` and `code` to articles because of it.
  @structural ~w(
                hub moc reference document documents doc book books code repo repository
                web web-article webpage url file pdf md markdown html htm xml docx txt text
                epub csv json yaml image png jpg jpeg gif svg video audio youtube newsletter
                manual agent session_log session-log skill ingestion review_finding
                review-finding readme gdrive gdoc gsheet onedrive dropbox notion confluence
                chunk page unknown untagged uncategorized misc miscellaneous general other
                none na tbd todo
              )

  @doc """
  Whole tags naming an article's format or source type rather than its subject.

  Consumers: `KnowledgeMocWorker` (a hub called `Index: pdf` is noise) and
  `TagBackfillWorker`'s vocabulary (a model told to prefer `pdf` will tag format).
  """
  @spec structural() :: [String.t()]
  def structural, do: @structural

  @doc """
  Whether a tag names a SUBJECT — neither a provenance id nor a structural descriptor.

  The single predicate both consumers should use, so a tag cannot be topical to one and not
  the other.
  """
  @spec topical?(String.t()) :: boolean()
  def topical?(tag) when is_binary(tag) do
    tag not in @structural and not Enum.any?(@prefixes, &String.starts_with?(tag, &1))
  end

  def topical?(_tag), do: false

  @doc "The provenance/chunk-coordinate tag prefixes, each including its trailing hyphen."
  @spec prefixes() :: [String.t()]
  def prefixes, do: @prefixes

  @doc """
  `prefixes/0` as a POSIX regular expression anchored at the start of a tag, for the
  `loopctl_searchable_tags/1` SQL function.

  Sorted so the pattern is byte-stable across releases — the drift test compares the
  STORED pattern against this string, and a list reordering must not read as a change.
  """
  @spec sql_pattern() :: String.t()
  def sql_pattern do
    alternation = @prefixes |> Enum.sort() |> Enum.join("|")
    "^(" <> alternation <> ")"
  end
end
