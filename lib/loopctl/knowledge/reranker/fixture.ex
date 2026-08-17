defmodule Loopctl.Knowledge.Reranker.Fixture do
  @moduledoc """
  Replays a committed recording of a real model's reranking, so the retrieval eval can score
  Phase 4 offline and deterministically.

  ## Why a recording rather than a hand-written expectation

  A fixture whose contents someone chose is not an experiment — it measures the author's
  taste and reports it as a model's judgement. This file is produced by
  `mix loopctl.retrieval.eval --record-rerank`, which runs
  `Loopctl.Knowledge.Reranker.Llm` against the golden set once with a real key and writes
  down what came back. The eval then replays it. The recording is the evidence; the replay
  is what keeps CI a gate rather than a billed, nondeterministic API call.

  ## The key is titles, not ids

  Every eval run mints a fresh throwaway tenant, and `deterministic_article_id/2` folds the
  tenant id into an article's id, so ids differ run to run and cannot key a committed file.
  Golden TITLES are stable, file-wide unique (the loader enforces it) and readable in a diff,
  which also makes a stale entry obvious. The key is the query plus the candidate titles in
  their pre-rerank order — reorder the input and it is a different question, so it must miss.

  ## A miss is not an error

  An unrecorded key returns `{:error, :not_recorded}`, which the dispatcher turns into "keep
  the fused order". So adding a golden question without re-recording degrades that question
  to unreranked rather than failing the run — visible in the delta, not as a crash. The
  recording file names the golden version it was taken against for exactly that reason.
  """

  @behaviour Loopctl.Knowledge.Reranker

  @relative_path "retrieval_eval/rerank_fixture.json"

  @doc "Absolute path of the committed recording."
  @spec default_path() :: String.t()
  def default_path, do: Application.app_dir(:loopctl, ["priv", @relative_path])

  @impl true
  def rerank(_scope_or_tenant_id, query, candidates, opts) do
    path = Keyword.get(opts, :rerank_fixture_path, default_path())

    with {:ok, recording} <- load(path),
         {:ok, order} <- Map.fetch(recording["entries"] || %{}, key(query, candidates)) do
      resolve(order, candidates)
    else
      _ -> {:error, :not_recorded}
    end
  end

  @doc """
  The lookup key for a query and its pre-rerank candidates.

  Public because the recorder must compute the identical key; a private copy on each side is
  how a recording silently stops matching.
  """
  @spec key(String.t(), [Loopctl.Knowledge.Reranker.candidate()]) :: String.t()
  def key(query, candidates) do
    titles = Enum.map_join(candidates, " | ", & &1.title)
    query <> " >> " <> titles
  end

  @doc "Read and decode the recording, or `:error`."
  @spec load(String.t()) :: {:ok, map()} | :error
  def load(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, %{} = decoded} <- JSON.decode(contents) do
      {:ok, decoded}
    else
      _ -> :error
    end
  end

  # The recorded value is a list of TITLES, so it stays readable and stays valid across
  # runs. Map it back through this call's candidates; a title the page does not contain
  # means the recording is stale for this key, and a stale recording must not reorder
  # anything.
  defp resolve(titles, candidates) when is_list(titles) do
    by_title = Map.new(candidates, &{&1.title, &1.id})
    ids = Enum.map(titles, &Map.get(by_title, &1))

    if length(ids) == length(candidates) and Enum.all?(ids, &is_binary/1) do
      {:ok, ids}
    else
      {:error, :stale_recording}
    end
  end

  defp resolve(_titles, _candidates), do: {:error, :stale_recording}
end
