defmodule Loopctl.Knowledge.ProvenanceTagsTest do
  use Loopctl.DataCase, async: true

  alias Loopctl.AdminRepo
  alias Loopctl.Knowledge.IdempotencyTag
  alias Loopctl.Knowledge.ProvenanceTags

  describe "sql_pattern/0" do
    test "matches the provenance shapes and leaves ordinary topical tags alone" do
      {:ok, regex} = Regex.compile(ProvenanceTags.sql_pattern())

      for tag <- [
            "url-42516bb95051",
            "book-0be008289fe8",
            "yt-bH722QgRlhQ",
            "pp-1-12",
            "chunk-7",
            "chapter-4",
            "part-ii-web-mining-part-9-20",
            "www-anthropic-com",
            IdempotencyTag.reserved_prefix() <> "url-42516bb95051"
          ] do
        assert Regex.match?(regex, tag), "#{tag} should be excluded from the keyword index"
      end

      for tag <- [
            "contextual-embeddings",
            "rls",
            "bing-liu",
            "zettelkasten",
            "p-value",
            "structured-concurrency"
          ] do
        refute Regex.match?(regex, tag), "#{tag} is vocabulary and must stay searchable"
      end
    end

    test "the reserved idempotency namespace is covered in its OWN right" do
      {:ok, regex} = Regex.compile(ProvenanceTags.sql_pattern())

      # Matching is by PREFIX, so `url-` does NOT match `idem-url-…`. Drop `idem-` from the
      # list and this fails — which is exactly the omission the first hand-written version
      # of the index's exclusion list shipped with.
      assert IdempotencyTag.reserved_prefix() in ProvenanceTags.prefixes()
      assert Regex.match?(regex, IdempotencyTag.reserved_prefix() <> "doc-0be008289fe8")
    end
  end

  describe "drift between the list and what the database actually indexes" do
    test "the stored loopctl_searchable_tags pattern matches sql_pattern/0" do
      %{rows: [[source]]} =
        AdminRepo.query!("SELECT prosrc FROM pg_proc WHERE proname = 'loopctl_searchable_tags'")

      # A generated column cannot call Elixir, so migration 20260817212906 BAKED this
      # pattern into the database. Editing `ProvenanceTags.prefixes/0` therefore changes
      # what MOCs exclude but NOT what the keyword index excludes, and nothing else would
      # notice. The remedy when this fails is a new migration that re-creates the function
      # and rebuilds the column — not loosening this assertion.
      assert String.contains?(source, ProvenanceTags.sql_pattern()),
             """
             `articles.search_vector` is built from a pattern baked in by a migration, and
             it no longer matches `ProvenanceTags.sql_pattern/0`.

             stored:   #{inspect(source)}
             expected: #{inspect(ProvenanceTags.sql_pattern())}

             Add a migration that re-runs `create_searchable_tags_function` and rebuilds
             the generated column. Note the rebuild takes an ACCESS EXCLUSIVE lock on
             `articles` (measured 2026-08-17: 85,294 rows, 138 MB heap, 59 MB index).
             """
    end

    test "every excluded prefix ends in a hyphen, so no prefix can swallow a topic" do
      # A prefix without its hyphen would match by substring-at-start: `part` would drop
      # `partitioning`, `web` would drop `webhooks`, `doc` would drop `docker`.
      Enum.each(ProvenanceTags.prefixes(), fn prefix ->
        assert String.ends_with?(prefix, "-"), "#{prefix} must end in a hyphen"
      end)

      {:ok, regex} = Regex.compile(ProvenanceTags.sql_pattern())
      refute Regex.match?(regex, "partitioning")
      refute Regex.match?(regex, "webhooks")
      refute Regex.match?(regex, "docker")
    end
  end

  describe "opaque_only_prefixes/0 — the families that may only be matched by shape" do
    test "a bare capture id under one of them is refused admission" do
      # #733: `email`/`corpus` became capture families in IdempotencyTag, and the re-tagger
      # would otherwise mint one article's capture identity onto an unrelated one — after
      # which the "have I captured this source?" query answers about the wrong row.
      for prefix <- ProvenanceTags.opaque_only_prefixes() do
        refute ProvenanceTags.admissible_suggestion?("#{prefix}a1b2c3d4e5f6"), prefix
      end

      # Named, so shrinking the list to [] cannot make the loop above pass vacuously.
      assert Enum.sort(ProvenanceTags.opaque_only_prefixes()) == ~w(corpus- email-)
    end

    test "the genuine subject tags that share those prefixes are untouched" do
      # This is WHY they are a separate list: `@prefixes` is matched bare, so putting
      # `email-` there would drop these the way a broad `p-` drops `p-value`.
      for tag <- ~w(email-marketing email-deliverability corpus-linguistics) do
        assert ProvenanceTags.admissible_suggestion?(tag), tag
        assert ProvenanceTags.topical?(tag), tag
      end

      {:ok, regex} = Regex.compile(ProvenanceTags.sql_pattern())

      for tag <- ~w(email-marketing corpus-linguistics) do
        refute Regex.match?(regex, tag), tag
      end
    end

    test "they are deliberately absent from the bare-matched list" do
      for prefix <- ProvenanceTags.opaque_only_prefixes() do
        refute prefix in ProvenanceTags.prefixes(), prefix
      end
    end

    test "the reserved counterpart is still refused by prefix alone" do
      # Once the --drop-legacy pass runs, this is the only form left, and `idem-` covers it.
      refute ProvenanceTags.admissible_suggestion?("idem-email-a1b2c3d4e5f6")
      refute ProvenanceTags.topical?("idem-email-a1b2c3d4e5f6")
    end
  end
end
