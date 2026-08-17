defmodule Loopctl.Knowledge.Reranker.Recorder do
  @moduledoc """
  A reranker that calls the REAL provider-backed one and writes down what it said.

  This is how the Phase 4 fixture is produced: `mix loopctl.retrieval.eval --record-rerank`
  starts the collector, runs the golden set with this module wired in, and dumps the result
  to `priv/retrieval_eval/rerank_fixture.json`. Every later run replays that file through
  `Loopctl.Knowledge.Reranker.Fixture`, so CI scores a real model's judgement without a key,
  without a bill, and without two runs of the same commit disagreeing.

  Only SUCCESSES are recorded. A provider error or an unparseable reply is a run that failed
  to observe anything, not an observation that the model declined to reorder — recording it
  as an empty entry would bake a provider outage into the committed evidence.

  The recorded VALUE is the ordered candidate titles rather than ids, for the reason in
  `Reranker.Fixture`: ids are per-run, titles are stable and readable in a diff.
  """

  @behaviour Loopctl.Knowledge.Reranker

  alias Loopctl.Knowledge.Reranker.Fixture
  alias Loopctl.Knowledge.Reranker.Llm

  @doc "Start the collector for one recording run."
  @spec start_link() :: {:ok, pid()} | {:error, term()}
  def start_link, do: Agent.start_link(fn -> %{} end, name: __MODULE__)

  @doc "Everything recorded so far, as the fixture file's `entries` map."
  @spec entries() :: %{String.t() => [String.t()]}
  def entries, do: Agent.get(__MODULE__, & &1)

  @impl true
  def rerank(scope_or_tenant_id, query, candidates, opts) do
    case Llm.rerank(scope_or_tenant_id, query, candidates, opts) do
      {:ok, ids} ->
        record(query, candidates, ids)
        {:ok, ids}

      {:error, _} = error ->
        error
    end
  end

  defp record(query, candidates, ids) do
    by_id = Map.new(candidates, &{&1.id, &1.title})
    titles = Enum.map(ids, &Map.fetch!(by_id, &1))

    Agent.update(__MODULE__, &Map.put(&1, Fixture.key(query, candidates), titles))
  end
end
