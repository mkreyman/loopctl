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
          required(:verdict) => :duplicate | :low_novelty | :novel | :unknown,
          required(:score) => float() | nil,
          required(:neighbors) => [neighbor()],
          # US-41.7: did the assessment itself make a provider call? The gate embeds
          # the proposal's title+body SYNCHRONOUSLY in the create path, BEFORE the
          # article row exists — so the create's custody entry is the only place that
          # egress can be recorded, and it must not be recorded when a caller-supplied
          # vector was reused instead. Optional so an implementation that never embeds
          # need not assert anything; absent is read as `false`.
          optional(:gate_embedded) => boolean(),
          # Did the nearest-neighbour COMPARISON actually happen? `:complete` means the
          # corpus was searched and the verdict rests on what came back; `:unavailable`
          # means it was not, so the verdict rests on nothing.
          #
          # This is NOT the same question as `verdict`, and that is the whole point.
          # A search that cannot run returns an empty neighbour list, an empty list is
          # maximally novel, and `:novel` is therefore the verdict a TOTAL FAILURE
          # produces — indistinguishable from a genuinely novel proposal. The create
          # path is content with that (it must never block a write, and a caller that
          # is not passes `on_gate_unavailable: :skip`); an UNATTENDED consumer that
          # publishes on `:novel` is not, because it would publish having compared
          # nothing.
          #
          # The verdict is deliberately left ALONE when a search is unavailable, so
          # every existing caller's branch is byte-for-byte what it was. Read this key
          # instead. Optional so an implementation that never searches need assert
          # nothing; absent is read as `:complete`.
          optional(:comparison) => :complete | :unavailable
        }

  @doc """
  Assess a proposal. `attrs` carries at least `"title"`/`"body"` (string or atom
  keys). Returns the verdict, the top nearest-neighbor similarity `score` (or `nil`
  when nothing crosses the overlap floor), and the `neighbors` list.

  Implementations MUST fall open — on any embedding/search failure, return
  `%{verdict: :unknown, score: nil, neighbors: []}` so the gate never blocks a write.

  An implementation that can tell an UNSEARCHABLE corpus from an EMPTY one must say
  so with `comparison: :unavailable`, on whatever verdict it returns. Falling open is
  what keeps a write unblocked; the flag is what keeps an unattended consumer from
  reading "nothing came back" as "nothing is similar".

  `gate_embedded` (optional) reports whether the assessment made an outbound
  embedding call; `Loopctl.Knowledge.propose_article/3` threads it into the created
  article's US-41.7 custody entry so a gated (draft) proposal — which never enqueues
  an embedding worker — cannot read as a zero-egress row.
  """
  @callback assess(tenant_id :: Ecto.UUID.t() | nil, attrs :: map(), opts :: keyword()) ::
              assessment()
end
