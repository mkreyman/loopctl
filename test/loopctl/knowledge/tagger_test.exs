defmodule Loopctl.Knowledge.TaggerTest do
  use Loopctl.DataCase, async: true

  alias Loopctl.Knowledge.Article
  alias Loopctl.Knowledge.IdempotencyTag
  alias Loopctl.Knowledge.Tagger
  alias Loopctl.Knowledge.Tagger.Llm

  defmodule Suggesting do
    @moduledoc false
    @behaviour Tagger
    @impl true
    def suggest(_scope, _article, _vocabulary, opts),
      do: {:ok, Keyword.get(opts, :suggestions, ["zettelkasten", "note-taking"])}
  end

  defmodule Erroring do
    @moduledoc false
    @behaviour Tagger
    @impl true
    def suggest(_scope, _article, _vocabulary, _opts), do: {:error, :no_api_key}
  end

  defmodule Raising do
    @moduledoc false
    @behaviour Tagger
    @impl true
    def suggest(_scope, _article, _vocabulary, _opts), do: raise("boom")
  end

  defp article(tags),
    do: %{id: "a", title: "Atomic notes", body: "One idea per note.", tags: tags}

  describe "merge/2 — existing tags are never dropped" do
    test "an idempotency key survives a re-tag" do
      # The reserved key is how a sourcer knows an article was already captured. Dropping it
      # causes a RE-CAPTURE, not a cosmetic regression, which is why merge is append-only.
      idem = IdempotencyTag.reserved_prefix() <> "url-42516bb95051"

      assert {[^idem, "rls", "zettelkasten"], ["zettelkasten"]} =
               Tagger.merge([idem, "rls"], ["zettelkasten", "rls"])
    end

    test "a duplicate suggestion adds nothing" do
      assert {["rls"], []} = Tagger.merge(["rls"], ["rls", "RLS", "  rls  "])
    end

    test "a suggestion may never mint a provenance-shaped tag" do
      # Those identify WHERE an article came from; a generated one is a false claim about
      # its source, and it would also be excluded from the keyword index as noise.
      {tags, added} = Tagger.merge([], ["url-deadbeefcafe", "book-0be008289fe8", "chunking"])

      assert added == ["chunking"]
      assert tags == ["chunking"]
    end

    test "malformed suggestions are dropped, not fatal to the whole article" do
      {_tags, added} =
        Tagger.merge([], [
          "Good-Tag",
          "has spaces",
          "-leading-hyphen",
          "",
          String.duplicate("x", 80)
        ])

      assert added == ["good-tag"]
    end

    test "the cap truncates the SUGGESTION, never the record" do
      existing = Enum.map(1..Article.max_tags(), &"existing#{&1}")

      assert {^existing, []} = Tagger.merge(existing, ["brand-new"])
    end

    test "nil existing tags are treated as empty" do
      assert {["chunking"], ["chunking"]} = Tagger.merge(nil, ["chunking"])
    end
  end

  describe "retag/4" do
    test "returns the merged list and what the suggestion contributed" do
      assert {:ok, ["rls", "zettelkasten", "note-taking"], ["zettelkasten", "note-taking"]} =
               Tagger.retag("t", article(["rls"]), ["rls"], tagger_impl: Suggesting)
    end

    for {label, impl} <- [{"a provider error", Erroring}, {"a raise", Raising}] do
      test "leaves the article alone on #{label}" do
        assert {:error, _} = Tagger.retag("t", article(["rls"]), [], tagger_impl: unquote(impl))
      end
    end
  end

  describe "Llm" do
    test "the prompt SHOWS the established vocabulary, which is the whole mechanism" do
      content = Llm.user_content(article([]), ["chunking", "retrieval", "embeddings"])

      assert content =~ "VOCABULARY (prefer these): chunking, retrieval, embeddings"
      assert content =~ "Atomic notes"
    end

    test "the vocabulary shown is capped" do
      vocabulary = Enum.map(1..500, &"tag#{&1}")
      content = Llm.user_content(article([]), vocabulary)

      shown = content |> String.split("\n") |> hd() |> String.split(", ") |> length()
      assert shown == Llm.vocabulary_shown()
    end

    test "the system prompt makes reuse the default rather than a suggestion" do
      assert Llm.system_prompt() =~ "Prefer the vocabulary"
      assert Llm.system_prompt() =~ "Propose a NEW tag only when"
    end

    test "parse_tags/1 accepts a list and rejects everything else" do
      assert {:ok, ["a", "b"]} = Llm.parse_tags(~s({"tags":["a","b"]}))
      assert {:ok, ["a"]} = Llm.parse_tags(~s|Here:\n```json\n{"tags": ["a"]}\n```|)

      assert {:error, :unparseable_tags} = Llm.parse_tags(~s({"tags":"a,b"}))
      assert {:error, :unparseable_tags} = Llm.parse_tags(~s({"tags":[1,2]}))
      assert {:error, :unparseable_tags} = Llm.parse_tags(~s({"labels":["a"]}))
      assert {:error, :unparseable_tags} = Llm.parse_tags("no json")
      assert {:error, :unparseable_tags} = Llm.parse_tags(nil)
    end
  end
end
