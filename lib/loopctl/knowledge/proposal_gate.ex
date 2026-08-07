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

  The SAME fall-open covers the novelty NEAREST-NEIGHBOUR read: `assess/3` runs
  SYNCHRONOUSLY in the `knowledge_create` write path, and that vector read goes
  through the per-tenant HeavyRead gate (US-37.5). It passes `on_overload: :tag`, so
  an over-cap shed returns `{:error, :heavy_read_overloaded}` and the gate falls open
  — a per-tenant READ limiter must NEVER 429 a WRITE (`knowledge_create`), and the
  gate's "never block write-back" invariant holds during exactly the high-load
  incident it exists to survive. (Contrast a plain API kNN read, which defaults to
  `:raise` → a legitimate 429.)
  """

  @behaviour Loopctl.Knowledge.ProposalAssessorBehaviour

  require Logger

  alias Loopctl.Embeddings.ShrinkLadder
  alias Loopctl.Embeddings.TextBudget
  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.VectorSearch
  alias Loopctl.Llm
  alias Loopctl.Llm.ProviderError

  @default_duplicate_threshold 0.97
  @default_overlap_threshold 0.88
  @neighbors_k 5

  @impl true
  def assess(tenant_id, attrs, opts \\ [])

  # System-scoped (no tenant) proposals are superadmin-only and rare — skip the gate.
  def assess(nil, _attrs, _opts), do: open_verdict()

  def assess(tenant_id, attrs, opts) when is_binary(tenant_id) do
    {embedding, gate_embedded?} = reuse_or_generate_embedding(tenant_id, attrs, opts)

    tenant_id
    |> do_assess(opts, embedding)
    # US-41.7: the create path's OWN egress fact, threaded to the custody entry.
    # This gate embeds the proposal's title+body SYNCHRONOUSLY inside
    # `Knowledge.propose_article/3`, BEFORE the article row exists — so there is no
    # earlier row to hang an entry on, and a `:low_novelty` proposal is created as a
    # DRAFT, which never enqueues an embedding worker. Without this flag the create
    # entry (whose `endpoint_kinds` are `[]`) would be the row's ONLY entry and would
    # read `all_network_local` VACUOUSLY for a body already POSTed to the resolved
    # embedding host. `true` means the guarded embedding path was INVOKED — which
    # deliberately includes an invocation that then failed, because a call that
    # egressed and then errored still egressed, and under-recording is the failure
    # mode that produces a false zero-egress claim.
    |> Map.put(:gate_embedded, gate_embedded?)
  end

  defp do_assess(tenant_id, opts, embedding) do
    dup = config(:knowledge_proposal_duplicate_threshold, @default_duplicate_threshold)
    overlap = config(:knowledge_proposal_overlap_threshold, @default_overlap_threshold)

    # Route through the GUARDED embedding path (review #4): tenant-scoped circuit
    # breaker + timeout, so a provider outage fast-fails here (this runs SYNCHRONOUSLY
    # in the HTTP write path) instead of hammering a dead provider and risking an LB
    # timeout. A caller (e.g. memory graduation) that already holds a computed embedding
    # of the assessed text may pass it via `:embedding` to skip this round-trip.
    case embedding do
      {:ok, vector} when is_list(vector) and vector != [] ->
        # `on_overload: :tag` (US-37.5): assess/3 runs SYNCHRONOUSLY in the
        # knowledge_create write path, so an over-cap HeavyRead shed must NOT raise a
        # 429 on a WRITE — it returns `{:error, :heavy_read_overloaded}` and the gate
        # falls OPEN, consistent with its treatment of every other novelty-check failure.
        case VectorSearch.nearest(tenant_id, vector, @neighbors_k,
               threshold: overlap,
               on_overload: :tag,
               visibility_agent_id: Keyword.get(opts, :visibility_agent_id)
             ) do
          {:error, :heavy_read_overloaded} ->
            Logger.warning(
              "ProposalGate: novelty read shed (heavy_read_overloaded), falling open"
            )

            open_verdict()

          neighbors when is_list(neighbors) ->
            score = neighbors |> List.first() |> neighbor_score()
            %{verdict: classify(score, dup, overlap), score: score, neighbors: neighbors}
        end

      {:error, :no_api_key} ->
        # Mandatory BYO: keyless tenant — fall open (never block write-back) and audit
        # the block for a consistent trail with the worker/Anthropic paths (review #9).
        Llm.record_blocked(tenant_id, :embedding)
        open_verdict()

      other ->
        # NEVER inspect the raw tuple (review #2): a provider error body can echo a
        # masked key fragment. Log only a value-free tag.
        Logger.warning(
          "ProposalGate: embedding failed, falling open (#{ProviderError.log_tag(other)})"
        )

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

  # Reuse a caller-supplied embedding when present (avoids a second embedding round-trip
  # for text already embedded upstream — e.g. a memory's stored vector on graduation);
  # otherwise embed the proposal text through the guarded path. A non-list / empty
  # `:embedding` is ignored and we fall back to generating.
  #
  # Returns `{result, gate_embedded?}` — the second element is the US-41.7 egress
  # fact: `false` when a caller-supplied vector was reused (NO provider call was
  # made, so recording an embedding endpoint would be a falsehood in the other
  # direction), `true` when the guarded embedding path was invoked.
  defp reuse_or_generate_embedding(tenant_id, attrs, opts) do
    case Keyword.get(opts, :embedding) do
      vector when is_list(vector) and vector != [] ->
        {{:ok, vector}, false}

      _ ->
        # US-41.4 (AC-41.4.2): the text being embedded is the PROPOSAL's own title
        # and body, so the egress scope is the proposal's project. Without it a
        # project-only `local_only` marking would not be enforced on a path that
        # runs SYNCHRONOUSLY in the `knowledge_create` write path — and because the
        # gate deliberately falls OPEN, the refusal would be silent.
        # Through `ShrinkLadder.embed_one/3` (#617). This gate falls OPEN on an
        # embedding failure, so an input-too-long rejection did not surface as an
        # error — it silently skipped novelty checking entirely, and the over-long
        # article landed as exactly the duplicate the nightly consolidation pass then
        # has to catch. The ladder is paid only by an input the provider rejected, on
        # a request that was already going to make an extra round trip and fall open.
        project_id = attrs["project_id"] || attrs[:project_id]

        {ShrinkLadder.embed_one(
           build_text(attrs),
           &Knowledge.generate_embedding(tenant_id, &1, project_id: project_id),
           label: "ProposalGate tenant=#{tenant_id}"
         ), true}
    end
  end

  defp build_text(attrs) do
    title = attrs["title"] || attrs[:title] || ""
    body = attrs["body"] || attrs[:body] || ""
    TextBudget.initial("#{title}\n\n#{body}")
  end

  defp open_verdict, do: %{verdict: :unknown, score: nil, neighbors: [], gate_embedded: false}

  defp config(key, default), do: Application.get_env(:loopctl, key, default)
end
