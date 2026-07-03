defmodule Loopctl.Knowledge.ProposalGate do
  @moduledoc """
  Default `ProposalAssessorBehaviour` — scores a proposed article's novelty against
  the tenant's published corpus by embedding the proposal text and finding its
  nearest neighbors via pgvector cosine similarity.

  Mechanical only: it embeds, searches, and classifies by threshold. It does NOT
  decide merges or edit anything — that judgment belongs to the consuming agent,
  which is a step smarter than the KB. The gate just answers "is this novel?" and
  surfaces the near-neighbors.

  ## Bands (config-tunable)

    * `score >= :knowledge_proposal_duplicate_threshold` (default `0.97`) → `:duplicate`
    * `score >= :knowledge_proposal_overlap_threshold` (default `0.88`) → `:low_novelty`
    * otherwise (incl. nothing above the overlap floor) → `:novel`

  ## Resilience

  Embedding requires a network call. On ANY failure — API down, power/internet
  outage, system-scoped proposal with no tenant — `assess/3` falls **open**:
  `%{verdict: :unknown, ...}`, so write-back is never blocked by the gate.
  """

  @behaviour Loopctl.Knowledge.ProposalAssessorBehaviour

  require Logger

  alias Loopctl.Knowledge.VectorSearch

  @embedding_client Application.compile_env(
                      :loopctl,
                      :embedding_client,
                      Loopctl.Knowledge.EmbeddingClient
                    )

  @default_duplicate_threshold 0.97
  @default_overlap_threshold 0.88
  @neighbors_k 5
  @max_text_length 32_000

  @impl true
  def assess(tenant_id, attrs, opts \\ [])

  # System-scoped (no tenant) proposals are superadmin-only and rare — skip the gate.
  def assess(nil, _attrs, _opts), do: open_verdict()

  def assess(tenant_id, attrs, opts) when is_binary(tenant_id) do
    dup = config(:knowledge_proposal_duplicate_threshold, @default_duplicate_threshold)
    overlap = config(:knowledge_proposal_overlap_threshold, @default_overlap_threshold)

    case @embedding_client.generate_embedding(tenant_id, build_text(attrs)) do
      {:ok, vector} when is_list(vector) and vector != [] ->
        neighbors =
          VectorSearch.nearest(tenant_id, vector, @neighbors_k,
            threshold: overlap,
            visibility_agent_id: Keyword.get(opts, :visibility_agent_id)
          )

        score = neighbors |> List.first() |> neighbor_score()
        %{verdict: classify(score, dup, overlap), score: score, neighbors: neighbors}

      other ->
        Logger.warning("ProposalGate: embedding failed, falling open: #{inspect(other)}")
        open_verdict()
    end
  end

  @doc """
  Pure threshold classification — the heart of the gate, unit-tested in isolation.
  `score` is the top neighbor's `similarity_score` (or `nil` when none cleared the
  overlap floor).
  """
  @spec classify(float() | nil, float(), float()) :: :duplicate | :low_novelty | :novel
  def classify(nil, _dup, _overlap), do: :novel
  def classify(score, dup, _overlap) when score >= dup, do: :duplicate
  def classify(score, _dup, overlap) when score >= overlap, do: :low_novelty
  def classify(_score, _dup, _overlap), do: :novel

  defp neighbor_score(nil), do: nil
  defp neighbor_score(%{similarity_score: s}), do: s

  defp build_text(attrs) do
    title = attrs["title"] || attrs[:title] || ""
    body = attrs["body"] || attrs[:body] || ""
    String.slice("#{title}\n\n#{body}", 0, @max_text_length)
  end

  defp open_verdict, do: %{verdict: :unknown, score: nil, neighbors: []}

  defp config(key, default), do: Application.get_env(:loopctl, key, default)
end
