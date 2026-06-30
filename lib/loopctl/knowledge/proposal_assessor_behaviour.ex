defmodule Loopctl.Knowledge.ProposalAssessorBehaviour do
  @moduledoc """
  Behaviour for assessing the NOVELTY of a *proposed* (not-yet-persisted) knowledge
  article against the existing published corpus, so agent write-back can be gated:
  a near-identical proposal is rejected in favour of the canonical article, a
  high-overlap proposal is routed to a draft for the (smarter) consuming agent to
  resolve, and a genuinely novel proposal flows through normally.

  This is **distinct** from the creativity "novelty" endpoint
  (`KnowledgeCreativityController`), which measures idea-distance for generation.
  Here, novelty == "does this add anything the corpus doesn't already hold?".

  ## Config-based DI

  `Loopctl.Knowledge.propose_article/3` resolves the implementation at runtime via
  `Application.get_env(:loopctl, :proposal_assessor, Loopctl.Knowledge.ProposalGate)`.
  `config/test.exs` swaps in `Loopctl.MockProposalAssessor`.
  """

  @type neighbor :: %{
          id: Ecto.UUID.t(),
          title: String.t() | nil,
          similarity_score: float()
        }

  @type assessment :: %{
          verdict: :duplicate | :low_novelty | :novel | :unknown,
          score: float() | nil,
          neighbors: [neighbor()]
        }

  @doc """
  Assess a proposal. `attrs` carries at least `"title"`/`"body"` (string or atom
  keys). Returns the verdict, the top nearest-neighbor similarity `score` (or `nil`
  when nothing crosses the overlap floor), and the `neighbors` list.

  Implementations MUST fall open — on any embedding/search failure, return
  `%{verdict: :unknown, score: nil, neighbors: []}` so the gate never blocks a write.
  """
  @callback assess(tenant_id :: Ecto.UUID.t() | nil, attrs :: map(), opts :: keyword()) ::
              assessment()
end
