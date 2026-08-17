defmodule Loopctl.Knowledge.RerankerTest do
  use Loopctl.DataCase, async: true

  alias Loopctl.Knowledge.Reranker
  alias Loopctl.Knowledge.Reranker.Fixture
  alias Loopctl.Knowledge.Reranker.Llm

  defmodule Reversing do
    @moduledoc false
    @behaviour Reranker
    @impl true
    def rerank(_scope, _query, candidates, _opts),
      do: {:ok, candidates |> Enum.map(& &1.id) |> Enum.reverse()}
  end

  defmodule Erroring do
    @moduledoc false
    @behaviour Reranker
    @impl true
    def rerank(_scope, _query, _candidates, _opts), do: {:error, :provider_down}
  end

  defmodule Raising do
    @moduledoc false
    @behaviour Reranker
    @impl true
    def rerank(_scope, _query, _candidates, _opts), do: raise("boom")
  end

  defmodule Dropping do
    @moduledoc false
    @behaviour Reranker
    @impl true
    def rerank(_scope, _query, candidates, _opts),
      do: {:ok, candidates |> Enum.map(& &1.id) |> Enum.drop(1)}
  end

  defmodule Inventing do
    @moduledoc false
    @behaviour Reranker
    @impl true
    def rerank(_scope, _query, candidates, _opts) do
      [_first | rest] = Enum.map(candidates, & &1.id)
      {:ok, ["an-id-that-was-never-retrieved" | rest]}
    end
  end

  defmodule Duplicating do
    @moduledoc false
    @behaviour Reranker
    @impl true
    def rerank(_scope, _query, candidates, _opts) do
      [first | _] = Enum.map(candidates, & &1.id)
      {:ok, List.duplicate(first, length(candidates))}
    end
  end

  defp page do
    [
      %{id: "a", title: "Advisory locks", snippet: "take a lock"},
      %{id: "b", title: "Cache expiry", snippet: "entries expire"},
      %{id: "c", title: "Presence tracking", snippet: "who is connected"}
    ]
  end

  defp order(results), do: Enum.map(results, & &1.id)

  describe "maybe_rerank/4 — the feature gate" do
    test "is off by default, so no implementation is consulted" do
      assert order(Reranker.maybe_rerank("t", "q", page(), reranker: Reversing)) == ~w(a b c)
      refute Reranker.enabled?()
    end

    test "a per-call :rerank opt turns it on without touching application config" do
      assert order(Reranker.maybe_rerank("t", "q", page(), rerank: true, reranker: Reversing)) ==
               ~w(c b a)
    end

    test "a single-result page is never sent to a reranker" do
      single = Enum.take(page(), 1)

      assert Reranker.maybe_rerank("t", "q", single, rerank: true, reranker: Raising) == single
    end
  end

  describe "maybe_rerank/4 — failing open is the contract" do
    # Search degrading to "unreranked" is invisible to a caller and correct; search FAILING
    # because a reranker was unavailable is not. Each of these is a distinct way the
    # provider half can go wrong, and every one of them must return the fused order.
    for {label, impl} <- [
          {"an error tuple", Erroring},
          {"a raise inside the implementation", Raising},
          {"a reply that drops a candidate", Dropping},
          {"a reply that invents an id", Inventing},
          {"a reply that repeats one id", Duplicating}
        ] do
      test "keeps the fused order on #{label}" do
        results = page()

        assert Reranker.maybe_rerank("t", "q", results, rerank: true, reranker: unquote(impl)) ==
                 results
      end
    end

    test "a partial ordering is discarded WHOLE, never applied as a shorter page" do
      # `Dropping` returns a valid ordering of 2 of the 3 candidates. Applying it would
      # silently truncate the page — a reranker must be able to permute results, never to
      # remove one.
      assert length(Reranker.maybe_rerank("t", "q", page(), rerank: true, reranker: Dropping)) ==
               3
    end
  end

  describe "Llm.parse_order/2" do
    test "accepts a clean permutation and maps positions back to ids" do
      assert {:ok, ~w(c a b)} = Llm.parse_order(~s({"order":[3,1,2]}), page())
    end

    test "tolerates the usual model wrapping — a fence and a preamble" do
      assert {:ok, ~w(b a c)} =
               Llm.parse_order("Here you go:\n```json\n{\"order\": [2, 1, 3]}\n```", page())
    end

    for {label, text} <- [
          {"a dropped position", ~s({"order":[1,2]})},
          {"a repeated position", ~s({"order":[1,1,2]})},
          {"an out-of-range position", ~s({"order":[1,2,4]})},
          {"a zero-based list", ~s({"order":[0,1,2]})},
          {"positions as strings", ~s({"order":["1","2","3"]})},
          {"no order key at all", ~s({"ranking":[1,2,3]})},
          {"prose with no JSON", "I think the first one is best."}
        ] do
      test "rejects #{label}" do
        assert {:error, :unparseable_order} = Llm.parse_order(unquote(text), page())
      end
    end

    test "rejects a nil reply rather than crashing" do
      assert {:error, :unparseable_order} = Llm.parse_order(nil, page())
    end
  end

  describe "Fixture" do
    setup do
      dir = Path.join(System.tmp_dir!(), "rerank-fixture-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      {:ok, path: Path.join(dir, "fixture.json")}
    end

    defp write!(path, entries) do
      File.write!(path, JSON.encode!(%{"golden_version" => "test", "entries" => entries}))
    end

    test "replays a recorded ordering", %{path: path} do
      candidates = page()

      write!(path, %{
        Fixture.key("q", candidates) => ["Presence tracking", "Advisory locks", "Cache expiry"]
      })

      assert {:ok, ~w(c a b)} = Fixture.rerank("t", "q", candidates, rerank_fixture_path: path)
    end

    test "an unrecorded key is :not_recorded, so the page keeps its fused order", %{path: path} do
      write!(path, %{"some other question >> ..." => ["Advisory locks"]})

      assert {:error, :not_recorded} =
               Fixture.rerank("t", "q", page(), rerank_fixture_path: path)

      # ...and end to end that is a no-op rather than a failure, which is what lets a new
      # golden question be added before the recording is refreshed.
      assert Reranker.maybe_rerank("t", "q", page(),
               rerank: true,
               reranker: Fixture,
               rerank_fixture_path: path
             ) == page()
    end

    test "a recording naming a title this page does not contain is stale, not partial",
         %{path: path} do
      candidates = page()

      write!(path, %{
        Fixture.key("q", candidates) => ["Advisory locks", "A renamed article", "Cache expiry"]
      })

      assert {:error, :stale_recording} =
               Fixture.rerank("t", "q", candidates, rerank_fixture_path: path)
    end

    test "a missing file is a miss, not a crash", %{path: path} do
      assert {:error, :not_recorded} =
               Fixture.rerank("t", "q", page(), rerank_fixture_path: Path.join(path, "nope.json"))
    end

    test "the key changes when the candidate ORDER changes", %{path: path} do
      candidates = page()

      write!(path, %{
        Fixture.key("q", candidates) => ["Advisory locks", "Cache expiry", "Presence tracking"]
      })

      # Reordering the input is a different question for a reranker, so it must MISS rather
      # than replay an ordering that was chosen for a different starting point.
      assert {:error, :not_recorded} =
               Fixture.rerank("t", "q", Enum.reverse(candidates), rerank_fixture_path: path)
    end
  end
end
