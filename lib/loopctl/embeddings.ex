defmodule Loopctl.Embeddings do
  @moduledoc """
  US-41.1 — the per-tenant embedding DIMENSION context.

  Owns four things that used to be implicit in a `vector(1536)` column type:

    1. **The supported set** (`supported_dimensions/0`) — the FIXED set of
       dimensions this instance has pre-created ANN indexes for. Published on
       `.well-known/loopctl` as `supported_embedding_dimensions` and used by the
       index migration, so the published set and the migrated indexes cannot
       drift (AC-41.1.3).
    2. **The tenant's ACTIVE dimension** (`active_dimension/1`) — resolved ONCE
       per operation or batch and threaded into the changesets, never read from
       inside a validator (AC-41.1.11).
    3. **The write path** (`upsert_article_embedding/4`, `upsert_memory_embedding/5`)
       — dual-writing the legacy column and the side table in ONE transaction
       while `dim == 1536` (AC-41.1.8).
    4. **The cutover levers** (`side_table_reads_enabled?/0`, `backfill_articles/2`,
       `reconcile_articles/1`) — an explicit, reversible flag plus a resumable
       batched backfill and a reconciliation pass (AC-41.1.8/.9).

  ## Cutover, in order (AC-41.1.8)

      1. deploy this code           -> every node dual-writes dim 1536
      2. run the backfill           -> `backfill_articles/2` / `backfill_memories/2`
      3. run the reconciliation     -> `reconcile_articles/1` / `reconcile_memories/1`
      4. flip the read flag         -> SystemConfig "embedding_side_table_reads" = 1

  Step 4 may only happen after step 1 has reached EVERY node: during a Fly rolling
  deploy an old node writes the legacy column only, so a node reading the side
  table would miss its writes. The flag is a `SystemConfig` integer precisely so
  reverting it is a single `UPDATE system_configs` with no redeploy — reverting is
  a SUPPORTED operation for the whole dual-write window (AC-41.1.8(iii)).

  ## Dual-write is dim-1536-ONLY, and why

  The legacy columns are `vector(1536)`. pgvector HARD-ERRORS on storing a
  768/1024/3072-length value in them, so a dual-write mandate for non-default
  dimensions is physically unexecutable. Non-default dimensions are therefore
  side-table-ONLY and are not recallable until the read flag flips;
  `recall_availability/1` is the tenant-facing surface that SAYS so rather than
  failing opaquely.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Loopctl.AdminRepo
  alias Loopctl.Audit
  alias Loopctl.Embeddings.Dimensions
  alias Loopctl.Embeddings.DisclosureCache
  alias Loopctl.HeavyRead
  alias Loopctl.Knowledge.Article
  alias Loopctl.Knowledge.ArticleEmbedding
  alias Loopctl.Knowledge.VectorSearch
  alias Loopctl.Llm
  alias Loopctl.Memory.Memory
  alias Loopctl.Memory.MemoryEmbedding
  alias Loopctl.Repo
  alias Loopctl.Tenants.Tenant
  alias Loopctl.Workers.ReembedWorker
  alias Loopctl.Workers.SystemCorpusEmbeddingWorker

  @read_flag_key "embedding_side_table_reads"
  @default_batch_size 500

  # ---------------------------------------------------------------------------
  # The supported set (AC-41.1.3)
  # ---------------------------------------------------------------------------

  @doc """
  The dimensions this instance supports, ascending and deduplicated.

  Every value here has a pre-created per-dimension HNSW index on BOTH side tables
  (migration `CreatePerDimensionEmbeddingHnswIndexes`) and is published on
  `.well-known/loopctl`. Changing this config alone is NOT enough — a new
  dimension needs a migration that builds its indexes CONCURRENTLY. Index DDL is
  operator/migration plane only; nothing on the request path may issue it.
  """
  @spec supported_dimensions() :: [pos_integer()]
  def supported_dimensions do
    # SINGLE-SOURCED with the read path: `VectorSearch` can only emit a
    # per-dimension cast for a dimension in its COMPILE-TIME set, so publishing (or
    # index-building for) any other value would advertise recall the query builder
    # physically cannot produce.
    VectorSearch.supported_dimensions()
    |> Enum.filter(&(is_integer(&1) and &1 > 0))
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc "True when `dim` is in the published supported set."
  @spec supported_dimension?(term()) :: boolean()
  def supported_dimension?(dim), do: dim in supported_dimensions()

  @doc """
  The deployment default dimension (`:embedding_dimensions`, 1536) — the value a
  tenant with no explicit model gets, preserving the pre-41.1 config semantics.
  """
  @spec default_dimension() :: pos_integer()
  def default_dimension, do: Application.get_env(:loopctl, :embedding_dimensions, 1536)

  @doc "The dimension the LEGACY `articles.embedding` / `memories.embedding` columns are typed at."
  @spec legacy_dimension() :: pos_integer()
  def legacy_dimension, do: 1536

  # ---------------------------------------------------------------------------
  # The tenant's active dimension (AC-41.1.4 / AC-41.1.11)
  # ---------------------------------------------------------------------------

  @doc """
  The tenant's ACTIVE embedding dimension.

  Precedence:

    1. `tenants.tenant_embedding_dimension` — the explicitly recorded value
       (written by an operator, or by the US-41.2 endpoint probe, which is
       authoritative because it reflects what the real endpoint returned).
    2. the static model table applied to `tenant_llm_settings.embedding_model`.
    3. `default_dimension/0`.

  Call this ONCE per operation or batch and thread the result into the
  changesets — never per item (AC-41.1.11). Both lookups are served from caches
  (`Llm.get_settings/1` is ETS-backed), but the contract is the call site's:
  `upsert_article_embeddings/3` resolves once for the whole batch.

  ## SUPPORTED-ONLY (review)

  The returned value is always in `supported_dimensions/0`. The derivation can
  legitimately produce an UNSUPPORTED one — `Dimensions.for_model/1` maps
  `text-embedding-3-large` to 3072, which is above pgvector's 2000-dimension HNSW
  ceiling and therefore deliberately NOT in the published set — and every read-path
  query builder RAISES on a dimension it has no compile-time cast for. Returning it
  unchanged made a free-form `tenant_llm_settings.embedding_model` an unhandled 500
  on the hottest read while `recall_availability/1` simultaneously reported
  `semantic_available: true`. An unsupported derivation therefore resolves to the
  deployment default and is DISCLOSED by `recall_availability/1`; writes then fail
  legibly on `Dimensions.validate_vector_length/3` (naming both numbers) instead of
  landing 3072-length rows in a table with no ANN index.
  """
  @spec active_dimension(Ecto.UUID.t()) :: pos_integer()
  def active_dimension(tenant_id) when is_binary(tenant_id) do
    dimension = declared_dimension(tenant_id)

    if supported_dimension?(dimension), do: dimension, else: fallback_dimension()
  end

  @doc """
  The dimension the tenant's configuration IMPLIES, WITHOUT the supported-set gate
  — i.e. what `active_dimension/1` would have returned pre-gate.

  Only for DISCLOSURE (`recall_availability/1` compares the two to explain why a
  tenant naming a 3072-dimension model gets no semantic recall). Never use it to
  build a query or a changeset.
  """
  @spec declared_dimension(Ecto.UUID.t()) :: pos_integer()
  def declared_dimension(tenant_id) when is_binary(tenant_id) do
    tenant_pin(tenant_id).dimension || model_dimension(tenant_id) || default_dimension()
  end

  @doc """
  The MODEL that produced the tenant's ACTIVE corpus (`tenants.tenant_embedding_model`),
  or `nil` when nothing has been pinned yet.

  Pinned by `resolve_write_dimension/1` on the first write and re-pinned atomically
  with the dimension at re-embed completion (`complete_reembed/2`).
  """
  @spec active_model(Ecto.UUID.t()) :: String.t() | nil
  def active_model(tenant_id) when is_binary(tenant_id), do: tenant_pin(tenant_id).model

  @doc """
  The model an ORDINARY embedding call must use, or `nil` when the tenant's current
  configuration already agrees with the active corpus.

  This is the AC-41.1.10 "query embeddings are generated against the model that
  produced the ACTIVE corpus, never the pending one" guarantee, made resolvable: a
  re-embed requires the tenant to point `tenant_llm_settings.embedding_model` at the
  NEW model (that is the only way the worker can obtain target-dimension vectors),
  and from that moment the configured model disagrees with the whole live corpus.
  Returning the PIN here keeps query vectors — and any newly-written article/memory
  vector — at the active dimension for the entire window; the re-embed worker is the
  one caller that deliberately opts out and uses the configured (pending) model.

  `nil` in the common case, so the overwhelmingly common path calls the embedding
  client exactly as before.
  """
  @spec query_model_override(Ecto.UUID.t()) :: String.t() | nil
  def query_model_override(tenant_id) when is_binary(tenant_id) do
    case active_model(tenant_id) do
      pinned when is_binary(pinned) ->
        if pinned == Llm.embedding_model(tenant_id), do: nil, else: pinned

      _ ->
        nil
    end
  end

  defp fallback_dimension do
    default = default_dimension()

    if supported_dimension?(default), do: default, else: legacy_dimension()
  end

  # ONE read for both pins — `active_dimension/1` and `active_model/1` are resolved
  # from the same row, so a caller that needs both never pays for two round trips.
  #
  # ETS-CACHED (review): the pin is an uncached `AdminRepo.one` on `tenants` that
  # several request paths call more than once per operation (memory recall, suggest
  # links, the novelty gate), against the moduledoc's "call ONCE per operation" and
  # the 3-connection admin pool. It changes only on a pin WRITE (`maybe_pin_tenant/2`,
  # `set_tenant_dimension/2`, `pin_completed_reembed/2`), each of which invalidates the
  # entry, so caching it for the short DisclosureCache TTL keeps recall correct while
  # removing the per-request tenant lookups. (The test config sets the TTL to 0, so
  # tests observe pin writes immediately with no cache.)
  defp tenant_pin(tenant_id) do
    DisclosureCache.fetch({:pin, tenant_id}, fn -> read_tenant_pin(tenant_id) end)
  end

  defp read_tenant_pin(tenant_id) do
    AdminRepo.one(
      from(t in Tenant,
        where: t.id == ^tenant_id,
        select: %{dimension: t.tenant_embedding_dimension, model: t.tenant_embedding_model}
      )
    ) || %{dimension: nil, model: nil}
  end

  # invalidate_CLUSTER (review, findings 5/10): the pin write must bust EVERY node's
  # node-local DisclosureCache, not just this one — a re-embed completion moves the
  # dimension/model pin and sweeps the old-dimension rows, and a peer still serving the
  # stale pin would scan a swept dimension (empty recall) or re-create swept rows.
  defp invalidate_tenant_pin(tenant_id), do: DisclosureCache.invalidate_cluster({:pin, tenant_id})

  defp model_dimension(tenant_id) do
    case Llm.get_settings(tenant_id) do
      %{embedding_model: model} -> Dimensions.for_model(model)
      _ -> nil
    end
  end

  @doc """
  Resolves the dimension for a WRITE and PINS it if the tenant has none recorded.

  Call this ONCE per operation or batch, in place of `active_dimension/1`, on every
  path that is about to STORE vectors. The pin is what stops the derived leg of
  `active_dimension/1` from moving under a populated corpus (review #6): once a
  tenant has embedded anything at N, an edit to `tenant_llm_settings.embedding_model`
  can no longer silently re-point recall at an empty dimension — moving to a new
  dimension is then exactly one supported operation, the AC-41.1.10 re-embed, which
  re-writes the pin only after the whole corpus is present at the target.

  The tenant's MODEL is pinned by the same statement (AC-41.1.10): the dimension
  records the SHAPE of the active corpus, the model records what PRODUCED it, and
  `query_model_override/1` needs both to keep query vectors on the active corpus
  while a re-embed is in flight.

  ONE conditional `UPDATE ... WHERE tenant_embedding_dimension IS NULL OR
  tenant_embedding_model IS NULL` per batch — never per item, so it does not
  reintroduce the AC-41.1.11 N+1, and it is a no-op once both pins are set.
  """
  @spec resolve_write_dimension(Ecto.UUID.t()) :: pos_integer()
  def resolve_write_dimension(tenant_id) when is_binary(tenant_id) do
    declared = declared_dimension(tenant_id)
    dimension = if supported_dimension?(declared), do: declared, else: fallback_dimension()

    # ONLY pin when the tenant's DECLARED dimension is the one being pinned (review).
    #
    # `active_dimension/1` SUBSTITUTES the deployment default for an unsupported
    # derivation (e.g. `text-embedding-3-large` -> 3072 -> 1536). Pinning that
    # substitute made `declared_dimension/1` return it forever after, so
    # `recall_availability/1` stopped taking its `not supported_dimension?(declared)`
    # branch and reported `semantic_available: true` — while every write kept failing
    # the length validation and nothing could ever be stored. Leaving both pins NULL
    # keeps the real cause disclosed. (The old `if supported_dimension?(dimension)`
    # guard here was tautological: `active_dimension/1` can only return a supported
    # value.)
    if supported_dimension?(declared), do: maybe_pin_tenant(tenant_id, dimension)

    dimension
  end

  # The MODEL pin must agree with the DIMENSION pin (review). Without the agreement
  # check a pre-41.1 tenant backfilled to dim 1536 but left with a NULL model could be
  # pinned to a 768-dimension model on the next write: `query_model_override/1` then
  # returned nil, every query vector was 768 against a 1536 corpus, and
  # `recall_availability/1` still said `semantic_available: true`. A disagreeing (or
  # unknown-dimension) model is therefore NOT pinned — `model_pin_conflict/1`
  # discloses the disagreement instead.
  defp maybe_pin_tenant(tenant_id, dimension) do
    model = Llm.embedding_model(tenant_id)
    set = pin_set(dimension, model)

    {n, _} =
      AdminRepo.update_all(
        from(t in Tenant,
          where:
            t.id == ^tenant_id and
              (is_nil(t.tenant_embedding_dimension) or is_nil(t.tenant_embedding_model))
        ),
        set: set
      )

    if n > 0, do: invalidate_tenant_pin(tenant_id)
  end

  defp pin_set(dimension, model) do
    case Dimensions.for_model(model) do
      nil -> [tenant_embedding_dimension: dimension, tenant_embedding_model: model]
      ^dimension -> [tenant_embedding_dimension: dimension, tenant_embedding_model: model]
      _other -> [tenant_embedding_dimension: dimension]
    end
  end

  @doc """
  The `{pinned_dimension, configured_model, model_dimension}` triple when the tenant's
  CONFIGURED embedding model disagrees with the pinned corpus dimension, else `nil`.

  A disagreement means every query vector is generated at one length while the whole
  stored corpus is at another: writes fail the length validation and recall matches
  nothing. `recall_availability/1` discloses it (AC-41.1.4/.8) rather than reporting
  `semantic_available: true` for a tenant that can never store or match a vector.

  Only reported when the MODEL pin is absent: with a model pinned,
  `query_model_override/1` keeps every ordinary embedding on the pinned model, which
  is exactly the supported AC-41.1.10 re-embed window (configured model deliberately
  ahead of the corpus) and NOT a misconfiguration.
  """
  @spec model_pin_conflict(Ecto.UUID.t()) ::
          {pos_integer(), String.t(), pos_integer()} | nil
  def model_pin_conflict(tenant_id) when is_binary(tenant_id) do
    pin = tenant_pin(tenant_id)
    model = Llm.embedding_model(tenant_id)

    with nil <- pin.model,
         dim when is_integer(dim) <- pin.dimension,
         model_dim when is_integer(model_dim) <- Dimensions.for_model(model),
         true <- model_dim != dim do
      {dim, model, model_dim}
    else
      _ -> nil
    end
  end

  @doc """
  Records `dimension` on the tenant.

  Rejects a dimension outside the published supported set: an unsupported
  dimension has no ANN index, so accepting it would silently degrade that tenant
  to a sequential scan of the whole corpus. (The CONFIG-TIME rejection an agent
  sees when it names an unsupported model is US-41.2's probe; this is the
  data-layer backstop.)
  """
  @spec set_tenant_dimension(Ecto.UUID.t(), pos_integer()) ::
          {:ok, Tenant.t()}
          | {:error, :unsupported_dimension | :not_found | Ecto.Changeset.t()}
  def set_tenant_dimension(tenant_id, dimension)
      when is_binary(tenant_id) and is_integer(dimension) do
    if supported_dimension?(dimension) do
      do_set_tenant_dimension(tenant_id, dimension)
    else
      {:error, :unsupported_dimension}
    end
  end

  defp do_set_tenant_dimension(tenant_id, dimension) do
    case AdminRepo.get(Tenant, tenant_id) do
      nil ->
        {:error, :not_found}

      tenant ->
        result =
          tenant
          |> Ecto.Changeset.change(tenant_embedding_dimension: dimension)
          |> AdminRepo.update()

        with {:ok, _} <- result, do: invalidate_tenant_pin(tenant_id)
        result
    end
  end

  # ---------------------------------------------------------------------------
  # The cutover flag (AC-41.1.8)
  # ---------------------------------------------------------------------------

  @doc """
  Whether recall reads the SIDE TABLE (`true`) or the legacy column (`false`).

  A `SystemConfig` integer (`0` = legacy, `1` = side table) so the flip and — just
  as importantly — the REVERT are a single operator UPDATE with no redeploy.

  Resolved through `Loopctl.Embeddings.ReadPathBehaviour` (config-based DI), NOT
  read from `SystemConfig` here. Production resolves to
  `Loopctl.Embeddings.SystemConfigReadPath`, which is the exact previous
  implementation, so operator semantics are unchanged. The seam exists because
  the flag is cached in VM-GLOBAL `:persistent_term`: without it, a test can only
  select the side-table path by mutating global state for the whole node, which
  leaked across tests and produced empty-result failures that read as a vector
  recall bug. See the behaviour's moduledoc.
  """
  @spec side_table_reads_enabled?() :: boolean()
  def side_table_reads_enabled?, do: read_path().side_table_reads_enabled?()

  defp read_path do
    Application.get_env(
      :loopctl,
      :embedding_read_path,
      Loopctl.Embeddings.SystemConfigReadPath
    )
  end

  @doc "The `SystemConfig` key backing `side_table_reads_enabled?/0`."
  @spec read_flag_key() :: String.t()
  def read_flag_key, do: @read_flag_key

  @doc """
  Whether the embedding IDEMPOTENCY guards should read the content hash from the SIDE
  TABLE rather than the legacy `articles.embedding` / `memories.embedding` column.

  Gated on the resolved WRITE dimension, NOT the read flag (review): the legacy column
  is NEVER written for a non-1536 tenant, so a 768/1024 tenant's legacy hash stays NULL
  forever. Before the read flag flips, an idempotency guard keyed on the read flag
  therefore fell through to "not embedded" on every invocation and every enqueue
  re-billed the paid provider for the WHOLE corpus — exactly the tenants this epic
  exists for. The side table has the hash recorded from deploy time (dual-write), so
  read it whenever the tenant writes off-1536 OR the cutover flag is already on.
  """
  @spec use_side_table_hash?(Ecto.UUID.t()) :: boolean()
  def use_side_table_hash?(tenant_id) when is_binary(tenant_id) do
    side_table_reads_enabled?() or active_dimension(tenant_id) != legacy_dimension()
  end

  @doc """
  The dimension the READ path will scan for `tenant_id` — the tenant's active
  dimension behind the cutover flag, else the legacy 1536.
  """
  @spec read_dimension(Ecto.UUID.t()) :: pos_integer()
  def read_dimension(tenant_id) when is_binary(tenant_id) do
    if side_table_reads_enabled?(), do: active_dimension(tenant_id), else: legacy_dimension()
  end

  @doc """
  Checks a freshly-generated query vector's LENGTH against the dimension the read
  path will scan, so a mismatch degrades gracefully instead of raising pgvector's
  "different vector dimensions" 500 (AC-41.1.5, review).

  The write path validates vector length (`Dimensions.validate_vector_length/3`); the
  read side-table entry points (novelty/dedup, suggest-links, article-linking) bind a
  FRESHLY generated vector into the per-dimension `(embedding::vector(N))` cast with no
  such check, so a query/corpus dimension drift (mid-model-change, a stale cached
  setting, a model/dimension pin conflict) surfaced as a raw 500 on a request path.
  """
  @spec check_query_vector(Ecto.UUID.t(), [float()]) ::
          :ok | {:error, {:dimension_mismatch, non_neg_integer(), pos_integer()}}
  def check_query_vector(tenant_id, vector) when is_binary(tenant_id) and is_list(vector) do
    expected = read_dimension(tenant_id)
    actual = length(vector)
    if actual == expected, do: :ok, else: {:error, {:dimension_mismatch, actual, expected}}
  end

  @doc """
  What recall a tenant can currently get, as a `meta`-ready map.

  A non-default dimension is side-table-only, so before the read flag flips that
  tenant has NO semantic recall — a fact the surface must state rather than return
  an unexplained empty result (AC-41.1.8, AC-41.1.10).
  """
  @spec recall_availability(Ecto.UUID.t(), pos_integer() | nil) :: %{
          dimension: pos_integer(),
          reads_side_table: boolean(),
          semantic_available: boolean(),
          reason: String.t() | nil
        }
  def recall_availability(tenant_id, dimension \\ nil) when is_binary(tenant_id) do
    dimension = dimension || active_dimension(tenant_id)
    side_table? = side_table_reads_enabled?()
    declared = declared_dimension(tenant_id)
    conflict = model_pin_conflict(tenant_id)

    cond do
      # The tenant NAMES a model this instance cannot serve (e.g. a 3072-dimension
      # model, above pgvector's HNSW ceiling). `active_dimension/1` falls back to the
      # supported default so no read path raises, but every vector that model returns
      # then fails the length validation, so nothing is stored and recall is empty.
      # Saying so is the whole point of this surface (AC-41.1.4 / AC-41.1.8).
      not supported_dimension?(declared) ->
        %{
          dimension: dimension,
          reads_side_table: side_table?,
          semantic_available: false,
          reason:
            "this tenant's configured embedding model returns #{declared}-dimension " <>
              "vectors, which this instance does not support (supported: " <>
              "#{inspect(supported_dimensions())}). No ANN index exists for that " <>
              "dimension, so its vectors are rejected at write time and search is " <>
              "keyword-only until the tenant configures a supported model."
        }

      # The MODEL the tenant is configured with disagrees with the PINNED corpus
      # dimension and no model pin exists to override it (review): every query vector
      # is generated at one length against a corpus stored at another, so writes fail
      # validation and recall matches nothing. Only intercept when recall would
      # OTHERWISE be reported AVAILABLE (side-table reads on, or the pinned dimension is
      # the legacy 1536) — that is the AC-41.1.4/.8 false positive (`semantic_available:
      # true` for a tenant that can never match). A tenant whose pinned dimension is
      # simply side-table-only-until-flip is already disclosed by the final branch.
      is_tuple(conflict) and (side_table? or dimension == legacy_dimension()) ->
        {pinned, model, model_dim} = conflict

        %{
          dimension: pinned,
          reads_side_table: side_table?,
          semantic_available: false,
          reason:
            "this tenant's corpus is pinned at #{pinned} dimensions but its configured " <>
              "embedding model (#{model}) returns #{model_dim}-dimension vectors. Query " <>
              "vectors and the stored corpus cannot be compared, and new writes are " <>
              "rejected at the length validation. Either restore a #{pinned}-dimension " <>
              "model or run the re-embed onto #{model_dim} " <>
              "(POST /api/v1/knowledge/embeddings/reembed)."
        }

      side_table? ->
        %{
          dimension: dimension,
          reads_side_table: true,
          semantic_available: true,
          reason: nil
        }

      dimension == legacy_dimension() ->
        %{
          dimension: dimension,
          reads_side_table: false,
          semantic_available: true,
          reason: nil
        }

      true ->
        %{
          dimension: dimension,
          reads_side_table: false,
          semantic_available: false,
          reason:
            "this tenant embeds at #{dimension} dimensions, which is stored only in the " <>
              "embedding side table; semantic recall becomes available for it once the " <>
              "operator flips the #{@read_flag_key} read flag. Search is keyword-only until then."
        }
    end
  end

  # ---------------------------------------------------------------------------
  # The write path (AC-41.1.4 / AC-41.1.8)
  # ---------------------------------------------------------------------------

  @doc """
  Writes `embedding` for `article` at the tenant's active dimension.

  Resolves the dimension ONCE and delegates to `upsert_article_embedding/5`. Use
  `upsert_article_embeddings/3` for a batch — it resolves once for the WHOLE batch
  (AC-41.1.11).
  """
  @spec upsert_article_embedding(Ecto.UUID.t(), Article.t(), [float()] | nil, String.t() | nil) ::
          {:ok, ArticleEmbedding.t()} | {:error, term()}
  def upsert_article_embedding(tenant_id, %Article{} = article, embedding, content_hash \\ nil) do
    # `resolve_write_dimension/1`, NOT `active_dimension/1` (review): this is a WRITE, and
    # the module invariant is that every store path PINS the dimension so the derived leg
    # of `active_dimension/1` cannot move under a populated corpus. The public convenience
    # arity must not be the one path that silently skips the pin.
    upsert_article_embedding(
      tenant_id,
      article,
      embedding,
      content_hash,
      resolve_write_dimension(tenant_id)
    )
  end

  @doc """
  Writes `embedding` at an EXPLICIT `dimension` (resolved by the caller).

  ## One transaction, both locations (AC-41.1.8(i))

  When `dimension == 1536` the legacy `articles.embedding` column and the side-table
  row are written inside a SINGLE `Ecto.Multi`. Two separate writes would leave a
  crash window in which the legacy row exists but the side-table row does not — and
  the resumable backfill of AC-41.1.9 would SKIP that article forever, because the
  backfill's cursor only knows "does a legacy embedding exist", not "was it
  mirrored". That gap is what `reconcile_articles/1` exists to catch.
  """
  @spec upsert_article_embedding(
          Ecto.UUID.t(),
          Article.t(),
          [float()] | nil,
          String.t() | nil,
          pos_integer(),
          keyword()
        ) :: {:ok, ArticleEmbedding.t()} | {:error, term()}
  def upsert_article_embedding(
        tenant_id,
        %Article{} = article,
        embedding,
        content_hash,
        dimension,
        opts \\ []
      )
      when is_binary(tenant_id) and is_integer(dimension) do
    Multi.new()
    |> article_embedding_multi(tenant_id, article, embedding, content_hash, dimension, opts)
    |> AdminRepo.transaction()
    |> case do
      {:ok, %{side_table: row}} -> {:ok, row}
      {:error, _step, reason, _done} -> {:error, reason}
    end
  end

  @doc """
  Adds the AC-41.1.8(i) dual-write steps (`:legacy` when `dimension == 1536`, plus
  `:side_table`) to an EXISTING `Ecto.Multi`.

  This is the composition seam the real request/worker write paths use
  (`Loopctl.Knowledge.update_embedding/4`, `Loopctl.Memory.update_memory_embedding/4`)
  so the legacy column, the side-table row AND their audit entry all commit in ONE
  transaction. Two separate transactions would leave the exact crash window
  `reconcile_articles/1` has to sweep up; one transaction makes that window
  unreachable on the happy path.
  """
  @spec article_embedding_multi(
          Multi.t(),
          Ecto.UUID.t(),
          Article.t(),
          [float()] | nil,
          String.t() | nil,
          pos_integer(),
          keyword()
        ) :: Multi.t()
  def article_embedding_multi(
        multi,
        tenant_id,
        %Article{} = article,
        embedding,
        hash,
        dimension,
        opts \\ []
      ) do
    multi
    |> maybe_write_legacy_article(
      article,
      embedding,
      hash,
      dimension,
      Keyword.put(opts, :tenant_id, tenant_id)
    )
    |> Multi.run(:side_table, fn repo, _changes ->
      upsert_article_embedding_row(repo, tenant_id, article, embedding, hash, dimension)
    end)
  end

  @doc "The memories twin of `article_embedding_multi/7`."
  @spec memory_embedding_multi(
          Multi.t(),
          Ecto.UUID.t(),
          Memory.t(),
          [float()] | nil,
          String.t() | nil,
          pos_integer(),
          keyword()
        ) :: Multi.t()
  def memory_embedding_multi(
        multi,
        tenant_id,
        %Memory{} = memory,
        embedding,
        hash,
        dimension,
        opts \\ []
      ) do
    multi
    |> maybe_write_legacy_memory(memory, embedding, hash, dimension, opts)
    |> Multi.run(:side_table, fn repo, _changes ->
      upsert_memory_embedding_row(repo, tenant_id, memory, embedding, hash, dimension)
    end)
  end

  @doc """
  Deletes every side-table row for `article_id` — the side-table half of
  "clear this article's embedding".
  """
  @spec delete_article_embeddings(Ecto.UUID.t(), Ecto.UUID.t()) :: {:ok, non_neg_integer()}
  def delete_article_embeddings(tenant_id, article_id),
    do: delete_article_embeddings(AdminRepo, tenant_id, article_id)

  @doc """
  `delete_article_embeddings/2` using the CALLER's repo/transaction — so a Multi step
  uses the repo Ecto injects rather than reaching for `AdminRepo` directly (review),
  mirroring `upsert_article_embedding_row/6`.
  """
  @spec delete_article_embeddings(module(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, non_neg_integer()}
  def delete_article_embeddings(repo, tenant_id, article_id) do
    {n, _} =
      repo.delete_all(
        from(ae in ArticleEmbedding,
          where: ae.tenant_id == ^tenant_id and ae.article_id == ^article_id
        )
      )

    {:ok, n}
  end

  @doc """
  Batch form: resolves the tenant's dimension ONCE and writes every
  `{article, embedding, content_hash}` triple at that dimension.

  This is the US-37.4 ~100-article batch path. It performs NO per-item tenant or
  settings query (TC-41.1.9) — the dimension is resolved before the loop and
  threaded into every changeset.

  ## ONE transaction for the WHOLE batch (review)

  The per-item form opens its own `AdminRepo.transaction`, so a ~100-item batch was
  ~100 sequential round trips on the 3-connection admin pool AND had no atomicity: a
  failure at item 60 left 59 rows written while the caller got `{:error, _}` and Oban
  re-ran the whole batch, re-billing the provider for all 100 texts. Every row is now
  composed into ONE `Ecto.Multi` and committed once, so the batch is all-or-nothing.

  `opts`:

    * `:dimension` — the caller-resolved write dimension (skips the pin lookup).
    * `:legacy_write` — `false` skips the dim-1536 `articles.embedding` dual-write
      (the AC-41.1.10 re-embed path, whose target may legally BE 1536).
  """
  @spec upsert_article_embeddings(
          Ecto.UUID.t(),
          [{Article.t(), [float()], String.t() | nil}],
          keyword()
        ) :: {:ok, [ArticleEmbedding.t()]} | {:error, term()}
  def upsert_article_embeddings(tenant_id, entries, opts \\ []) when is_binary(tenant_id) do
    dimension = Keyword.get(opts, :dimension) || resolve_write_dimension(tenant_id)
    legacy_opts = Keyword.take(opts, [:legacy_write])

    entries
    |> Enum.with_index()
    |> Enum.reduce(Multi.new(), fn {{article, embedding, hash}, i}, multi ->
      multi
      |> maybe_batch_legacy_article(
        i,
        article,
        embedding,
        hash,
        dimension,
        Keyword.put(legacy_opts, :tenant_id, tenant_id)
      )
      |> Multi.run({:side_table, i}, fn repo, _changes ->
        upsert_article_embedding_row(repo, tenant_id, article, embedding, hash, dimension)
      end)
    end)
    |> commit_batch(length(entries))
  end

  # Per-item step names (`{:legacy, i}` / `{:side_table, i}`) — `Ecto.Multi` names must
  # be unique across the whole multi, so the single-item seam's fixed `:legacy` /
  # `:side_table` keys cannot be reused for a batch.
  defp maybe_batch_legacy_article(multi, index, article, embedding, hash, dimension, opts) do
    if legacy_write?(opts) and dimension == legacy_dimension() and
         own_tenant_article?(article, Keyword.get(opts, :tenant_id)) do
      Multi.update(
        multi,
        {:legacy, index},
        Article.embedding_changeset(article, embedding, hash, dimension)
      )
    else
      multi
    end
  end

  defp maybe_batch_legacy_memory(multi, index, memory, embedding, hash, dimension, opts) do
    if legacy_write?(opts) and dimension == legacy_dimension() do
      Multi.update(
        multi,
        {:legacy, index},
        Memory.embedding_changeset(memory, embedding, hash, dimension)
      )
    else
      multi
    end
  end

  defp commit_batch(multi, count) do
    case AdminRepo.transaction(multi) do
      {:ok, changes} ->
        {:ok, for(i <- 0..(count - 1)//1, do: Map.fetch!(changes, {:side_table, i}))}

      {:error, _step, reason, _done} ->
        {:error, reason}
    end
  end

  @doc """
  The memories twin of `upsert_article_embeddings/3` — resolves the dimension ONCE
  and writes every `{memory, embedding, content_hash}` triple at it (AC-41.1.11).
  """
  @spec upsert_memory_embeddings(
          Ecto.UUID.t(),
          [{Memory.t(), [float()], String.t() | nil}],
          keyword()
        ) :: {:ok, [MemoryEmbedding.t()]} | {:error, term()}
  def upsert_memory_embeddings(tenant_id, entries, opts \\ []) when is_binary(tenant_id) do
    dimension = Keyword.get(opts, :dimension) || resolve_write_dimension(tenant_id)
    legacy_opts = Keyword.take(opts, [:legacy_write])

    entries
    |> Enum.with_index()
    |> Enum.reduce(Multi.new(), fn {{memory, embedding, hash}, i}, multi ->
      multi
      |> maybe_batch_legacy_memory(i, memory, embedding, hash, dimension, legacy_opts)
      |> Multi.run({:side_table, i}, fn repo, _changes ->
        upsert_memory_embedding_row(repo, tenant_id, memory, embedding, hash, dimension)
      end)
    end)
    |> commit_batch(length(entries))
  end

  @doc """
  Writes `embedding` for `memory` at an explicit `dimension`.

  Mirrors `upsert_article_embedding/5`. `subject_id` is denormalized onto the row
  so recall can satisfy `HeavyRead.guard_memory!/3`'s outermost subject equality
  without joining `memories` inside the index-ordered ANN.
  """
  @spec upsert_memory_embedding(
          Ecto.UUID.t(),
          Memory.t(),
          [float()] | nil,
          String.t() | nil,
          pos_integer(),
          keyword()
        ) :: {:ok, MemoryEmbedding.t()} | {:error, term()}
  def upsert_memory_embedding(
        tenant_id,
        %Memory{} = memory,
        embedding,
        content_hash,
        dimension,
        opts \\ []
      )
      when is_binary(tenant_id) and is_integer(dimension) do
    Multi.new()
    |> memory_embedding_multi(tenant_id, memory, embedding, content_hash, dimension, opts)
    |> AdminRepo.transaction()
    |> case do
      {:ok, %{side_table: row}} -> {:ok, row}
      {:error, _step, reason, _done} -> {:error, reason}
    end
  end

  # Dual-write is dim-1536-only: pgvector hard-errors on a non-1536 value in a
  # vector(1536) column, so for any other dimension the side table is the only
  # location and this step is skipped entirely.
  #
  # THREE more exclusions, all review findings:
  #
  #   * `legacy_write?: false` — the RE-EMBED path. Its target dimension can legally
  #     BE 1536 (reverting a 768 tenant to the hosted default), and writing the legacy
  #     column mid-run would publish the PENDING corpus's vectors to the still-serving
  #     legacy read path.
  #   * `scope: :system` / `tenant_id == nil` — `articles.embedding` is ONE GLOBAL slot
  #     on a row shared by every tenant, so writing tenant A's vector there clobbers
  #     tenant B's. `materialize_system_article_embedding/5` documents this as
  #     forbidden; `pending_reembed_articles/3` deliberately enumerates system articles,
  #     so the re-embed reached it.
  #   * `article.tenant_id != tenant_id` — the same clobber, generalized.
  defp maybe_write_legacy_article(multi, article, embedding, content_hash, dimension, opts) do
    if legacy_write?(opts) and dimension == legacy_dimension() and
         own_tenant_article?(article, Keyword.get(opts, :tenant_id)) do
      Multi.update(
        multi,
        :legacy,
        Article.embedding_changeset(article, embedding, content_hash, dimension)
      )
    else
      multi
    end
  end

  defp legacy_write?(opts), do: Keyword.get(opts, :legacy_write, true)

  defp own_tenant_article?(%Article{scope: :system}, _tenant_id), do: false
  defp own_tenant_article?(%Article{tenant_id: nil}, _tenant_id), do: false
  defp own_tenant_article?(%Article{tenant_id: owner}, tenant_id), do: owner == tenant_id

  defp maybe_write_legacy_memory(multi, memory, embedding, content_hash, dimension, opts) do
    if legacy_write?(opts) and dimension == legacy_dimension() do
      Multi.update(
        multi,
        :legacy,
        Memory.embedding_changeset(memory, embedding, content_hash, dimension)
      )
    else
      multi
    end
  end

  @doc """
  Upserts ONE article side-table row using the CALLER's repo/transaction.

  Public so a caller that already owns a transaction (`Loopctl.Knowledge.update_embedding/4`,
  which also writes the legacy column and the audit entry) can write the side-table
  row INSIDE it — AC-41.1.8(i)'s "one transaction, both locations".

  ## A single atomic UPSERT, not read-then-write (review)

  The previous form SELECTed the `(tenant_id, article_id, dim)` row and then
  `insert_or_update`d it, with no lock between the two. Two concurrent writers for
  the same key (`ArticleEmbeddingWorker` racing `BatchArticleEmbeddingWorker`, or a
  live dual-write racing the AC-41.1.9 backfill's `INSERT ... ON CONFLICT DO
  NOTHING`) both saw `existing == nil` and both INSERTed; the loser hit
  `article_embeddings_tenant_article_dim_index`. Because this step runs inside the
  AC-41.1.8(i) Multi, that changeset error rolled back the LEGACY column write and
  the audit entry too, and the write was lost until Oban retried. `INSERT ... ON
  CONFLICT DO UPDATE` makes the loser's write WIN-or-UPDATE instead of failing, with
  no read at all. The BEFORE-INSERT/UPDATE trigger runs on both branches, so
  `live_denorm` stays synced either way.
  """
  @spec upsert_article_embedding_row(
          module(),
          Ecto.UUID.t(),
          Article.t(),
          [float()] | nil,
          String.t() | nil,
          pos_integer()
        ) :: {:ok, ArticleEmbedding.t()} | {:error, Ecto.Changeset.t()}
  def upsert_article_embedding_row(repo, tenant_id, article, embedding, content_hash, dimension) do
    %ArticleEmbedding{tenant_id: tenant_id}
    |> ArticleEmbedding.changeset(
      %{article_id: article.id, embedding: embedding, embedding_content_hash: content_hash},
      dimension
    )
    |> repo.insert(
      on_conflict: {:replace, [:embedding, :embedding_content_hash, :updated_at]},
      conflict_target: [:tenant_id, :article_id, :dim],
      returning: [:id, :live_denorm, :inserted_at, :updated_at]
    )
  end

  @doc """
  The stored content hash for `article_id` at `dimension`, or `nil` when there is no
  row (or the row predates hash recording).

  This is the SIDE-TABLE half of embedding idempotency (review). Every dedupe guard
  used to read `articles.embedding` + `articles.embedding_content_hash`, which
  `update_embedding/5` never writes for a non-1536 dimension — so for exactly the
  768/1024 tenants this epic exists for, the guard fell through to "not embedded" on
  every invocation and every enqueue re-billed the paid provider.
  """
  @spec article_embedded_hash(Ecto.UUID.t(), Ecto.UUID.t(), pos_integer()) :: String.t() | nil
  def article_embedded_hash(tenant_id, article_id, dimension) do
    AdminRepo.one(
      from(ae in ArticleEmbedding,
        where:
          ae.tenant_id == ^tenant_id and ae.article_id == ^article_id and ae.dim == ^dimension,
        select: ae.embedding_content_hash
      )
    )
  end

  @doc "Batch form of `article_embedded_hash/3`: `%{article_id => hash}` for the rows present."
  @spec article_embedded_hashes(Ecto.UUID.t(), [Ecto.UUID.t()], pos_integer()) :: %{
          Ecto.UUID.t() => String.t() | nil
        }
  def article_embedded_hashes(_tenant_id, [], _dimension), do: %{}

  def article_embedded_hashes(tenant_id, article_ids, dimension) do
    from(ae in ArticleEmbedding,
      where:
        ae.tenant_id == ^tenant_id and ae.article_id in ^article_ids and ae.dim == ^dimension,
      select: {ae.article_id, ae.embedding_content_hash}
    )
    |> AdminRepo.all()
    |> Map.new()
  end

  @doc """
  The subset of `article_ids` that HAS a side-table row at `dimension`, as a
  `MapSet`.
  """
  # No @spec: a `MapSet.t()` return annotation trips dialyzer's contract_with_opaque
  # check against the concrete success typing (a known false positive for opaque
  # built-ins) — same treatment as `Knowledge.visible_article_ids/3`.
  def embedded_article_ids(_tenant_id, [], _dimension), do: MapSet.new()

  def embedded_article_ids(tenant_id, article_ids, dimension) do
    from(ae in ArticleEmbedding,
      where:
        ae.tenant_id == ^tenant_id and ae.article_id in ^article_ids and ae.dim == ^dimension,
      select: ae.article_id
    )
    |> AdminRepo.all()
    |> MapSet.new()
  end

  @doc "The memories twin of `article_embedded_hash/3`."
  @spec memory_embedded_hash(Ecto.UUID.t(), Ecto.UUID.t(), pos_integer()) :: String.t() | nil
  def memory_embedded_hash(tenant_id, memory_id, dimension) do
    AdminRepo.one(
      from(me in MemoryEmbedding,
        where: me.tenant_id == ^tenant_id and me.memory_id == ^memory_id and me.dim == ^dimension,
        select: me.embedding_content_hash
      )
    )
  end

  @doc """
  A memory's STORED vector at `dimension`, as a plain `[float()]`, or `nil`.

  The graduation path reuses a memory's already-paid-for vector instead of asking the
  provider again; reading it from `memories.embedding` alone meant a non-1536 tenant
  paid for a fresh embedding on every graduation (review).
  """
  @spec memory_embedding_vector(Ecto.UUID.t(), Ecto.UUID.t(), pos_integer()) :: [float()] | nil
  def memory_embedding_vector(tenant_id, memory_id, dimension) do
    from(me in MemoryEmbedding,
      where: me.tenant_id == ^tenant_id and me.memory_id == ^memory_id and me.dim == ^dimension,
      select: me.embedding
    )
    |> AdminRepo.one()
    |> case do
      %Pgvector{} = vector -> Pgvector.to_list(vector)
      list when is_list(list) and list != [] -> list
      _ -> nil
    end
  end

  @doc """
  Upserts ONE memory side-table row using the CALLER's repo/transaction.

  Public so a caller that already owns a transaction (the promotion path) can write
  the side-table row inside it rather than opening a second one.
  """
  @spec upsert_memory_embedding_row(
          module(),
          Ecto.UUID.t(),
          Memory.t(),
          [float()] | nil,
          String.t() | nil,
          pos_integer()
        ) :: {:ok, MemoryEmbedding.t()} | {:error, Ecto.Changeset.t()}
  def upsert_memory_embedding_row(repo, tenant_id, memory, embedding, content_hash, dimension) do
    %MemoryEmbedding{tenant_id: tenant_id}
    |> MemoryEmbedding.changeset(
      %{
        memory_id: memory.id,
        subject_id: memory.subject_id,
        embedding: embedding,
        embedding_content_hash: content_hash
      },
      dimension
    )
    |> repo.insert(
      # Same atomic-upsert rationale as `upsert_article_embedding_row/6`. `subject_id`
      # is replaced too: it is a DENORMALIZED copy of `memories.subject_id` (now also
      # enforced by a composite FK), so a stale copy on the conflicting row must not
      # survive a re-write.
      on_conflict: {:replace, [:subject_id, :embedding, :embedding_content_hash, :updated_at]},
      conflict_target: [:tenant_id, :memory_id, :dim],
      returning: [:id, :live_denorm, :inserted_at, :updated_at]
    )
  end

  # ---------------------------------------------------------------------------
  # Backfill (AC-41.1.9) + reconciliation (AC-41.1.8(i))
  # ---------------------------------------------------------------------------

  @doc """
  Copies every legacy `articles.embedding` into the side table at dim 1536.

  RESUMABLE and BATCHED: the batch is an anti-join against rows already present at
  dim 1536, so an interrupted run resumes with no double work and a completed run
  re-run is a no-op (no duplicates — TC-41.1.3). There is deliberately NO cursor:
  every batch re-evaluates the anti-join, which is what makes an arbitrary
  interleaving with the concurrent dual-write safe. The legacy column is LEFT IN
  PLACE and unused; dropping it is a deliberate follow-up so rollback stays trivial.

  ## Completion is a GAP PROBE, not a zero-row batch (review #14)

  A batch is `INSERT ... SELECT ... WHERE NOT EXISTS ... LIMIT n ON CONFLICT DO
  NOTHING`. A batch whose selected rows were all swallowed by `ON CONFLICT` — the
  race with the concurrent dual-write inserting the same `(tenant, article, 1536)`
  between the SELECT and the INSERT — reports `num_rows == 0` while work REMAINS.
  Halting there would report completion prematurely, and AC-41.1.8 makes the read
  flag flip conditional on that report. So a zero-row batch only ends the run once
  the reconciliation gap probe agrees there is nothing left; otherwise the run
  continues, bounded by `@max_zero_progress_batches` consecutive no-progress
  batches so a pathological repeated conflict cannot spin forever.

  Returns `{:ok, %{copied: n, batches: b, complete: bool}}`. `complete` is FALSE
  when the batch budget or the no-progress bound stopped the run with gaps left.
  """
  @spec backfill_articles(keyword()) ::
          {:ok, %{copied: non_neg_integer(), batches: non_neg_integer(), complete: boolean()}}
  def backfill_articles(opts \\ []) do
    batch_size = Keyword.get(opts, :batch_size, @default_batch_size)
    max_batches = Keyword.get(opts, :max_batches, :infinity)

    run_backfill(
      &article_backfill_batch/1,
      fn -> article_reconciliation_gaps(limit: 1) == [] end,
      batch_size,
      max_batches
    )
  end

  @doc "The memories twin of `backfill_articles/1`."
  @spec backfill_memories(keyword()) ::
          {:ok, %{copied: non_neg_integer(), batches: non_neg_integer(), complete: boolean()}}
  def backfill_memories(opts \\ []) do
    batch_size = Keyword.get(opts, :batch_size, @default_batch_size)
    max_batches = Keyword.get(opts, :max_batches, :infinity)

    run_backfill(
      &memory_backfill_batch/1,
      fn -> memory_reconciliation_gaps(limit: 1) == [] end,
      batch_size,
      max_batches
    )
  end

  defp run_backfill(batch_fun, gaps_drained?, batch_size, max_batches) do
    Enum.reduce_while(
      Stream.iterate(0, &(&1 + 1)),
      %{copied: 0, batches: 0, complete: false, zero_batches: 0},
      fn _i, acc ->
        if batch_budget_exhausted?(acc, max_batches) do
          {:halt, acc}
        else
          run_backfill_batch(batch_fun, gaps_drained?, batch_size, acc)
        end
      end
    )
    |> then(&{:ok, Map.drop(&1, [:zero_batches])})
  end

  defp batch_budget_exhausted?(_acc, :infinity), do: false
  defp batch_budget_exhausted?(acc, max_batches), do: acc.batches >= max_batches

  # A no-progress batch is only terminal once the gap probe agrees the anti-join is
  # drained. Otherwise it is a lost ON CONFLICT race: keep going, bounded.
  @max_zero_progress_batches 3

  defp run_backfill_batch(batch_fun, gaps_drained?, batch_size, acc) do
    case batch_fun.(batch_size) do
      0 -> halt_or_retry(gaps_drained?, acc)
      n -> {:cont, %{acc | copied: acc.copied + n, batches: acc.batches + 1, zero_batches: 0}}
    end
  end

  defp halt_or_retry(gaps_drained?, acc) do
    cond do
      gaps_drained?.() -> {:halt, %{acc | complete: true}}
      acc.zero_batches + 1 >= @max_zero_progress_batches -> {:halt, acc}
      true -> {:cont, %{acc | zero_batches: acc.zero_batches + 1}}
    end
  end

  # One batch, as a single INSERT ... SELECT so the vector never round-trips
  # through the BEAM. `ON CONFLICT DO NOTHING` makes a re-run idempotent; the
  # BEFORE-INSERT trigger sets `live_denorm` from the parent's status, so the
  # backfill cannot desynchronize the marker either.
  defp article_backfill_batch(batch_size) do
    {count, _} =
      AdminRepo.query!(
        """
        INSERT INTO article_embeddings
          (id, tenant_id, article_id, dim, embedding, live_denorm, embedding_content_hash,
           inserted_at, updated_at)
        SELECT gen_random_uuid(), a.tenant_id, a.id, $1, a.embedding, true,
               a.embedding_content_hash, NOW(), NOW()
        FROM articles a
        WHERE a.embedding IS NOT NULL
          AND a.tenant_id IS NOT NULL
          AND NOT EXISTS (
            SELECT 1 FROM article_embeddings ae
            WHERE ae.article_id = a.id AND ae.tenant_id = a.tenant_id AND ae.dim = $1
          )
        LIMIT $2
        ON CONFLICT DO NOTHING
        """,
        [legacy_dimension(), batch_size]
      )
      |> then(&{&1.num_rows, &1})

    count
  end

  defp memory_backfill_batch(batch_size) do
    {count, _} =
      AdminRepo.query!(
        """
        INSERT INTO memory_embeddings
          (id, tenant_id, memory_id, subject_id, dim, embedding, live_denorm,
           embedding_content_hash, inserted_at, updated_at)
        SELECT gen_random_uuid(), m.tenant_id, m.id, m.subject_id, $1, m.embedding, true,
               m.embedding_content_hash, NOW(), NOW()
        FROM memories m
        WHERE m.embedding IS NOT NULL
          AND NOT EXISTS (
            SELECT 1 FROM memory_embeddings me
            WHERE me.memory_id = m.id AND me.tenant_id = m.tenant_id AND me.dim = $1
          )
        LIMIT $2
        ON CONFLICT DO NOTHING
        """,
        [legacy_dimension(), batch_size]
      )
      |> then(&{&1.num_rows, &1})

    count
  end

  @doc """
  Finds articles whose LEGACY embedding has no matching side-table row at dim 1536
  — the crash-between-the-two-writes gap (AC-41.1.8(i)).

  The resumable backfill of AC-41.1.9 alone does NOT catch this class once it has
  completed: the operator considers the corpus migrated and stops running it. The
  reconciliation pass is a standing, cheap anti-join that any half-write shows up
  in, and `reconcile_articles/1` repairs them by re-running the same idempotent
  copy.
  """
  @spec article_reconciliation_gaps(keyword()) :: [Ecto.UUID.t()]
  def article_reconciliation_gaps(opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_batch_size)

    AdminRepo.all(
      from(a in Article,
        as: :article,
        where: not is_nil(a.embedding) and not is_nil(a.tenant_id),
        where:
          not exists(
            from(ae in ArticleEmbedding,
              where:
                ae.article_id == parent_as(:article).id and
                  ae.tenant_id == parent_as(:article).tenant_id and
                  ae.dim == ^legacy_dimension(),
              select: 1
            )
          ),
        select: a.id,
        limit: ^limit
      )
    )
  end

  @doc "The memories twin of `article_reconciliation_gaps/1`."
  @spec memory_reconciliation_gaps(keyword()) :: [Ecto.UUID.t()]
  def memory_reconciliation_gaps(opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_batch_size)

    AdminRepo.all(
      from(m in Memory,
        as: :memory,
        where: not is_nil(m.embedding),
        where:
          not exists(
            from(me in MemoryEmbedding,
              where:
                me.memory_id == parent_as(:memory).id and
                  me.tenant_id == parent_as(:memory).tenant_id and
                  me.dim == ^legacy_dimension(),
              select: 1
            )
          ),
        select: m.id,
        limit: ^limit
      )
    )
  end

  @doc """
  Repairs every gap `article_reconciliation_gaps/1` reports AND every `live_denorm`
  marker that has drifted from its parent, returning
  `{:ok, %{repaired: n, live_denorm_repaired: n}}`.
  """
  @spec reconcile_articles(keyword()) ::
          {:ok,
           %{
             repaired: non_neg_integer(),
             live_denorm_repaired: non_neg_integer(),
             complete: boolean()
           }}
  def reconcile_articles(opts \\ []) do
    {:ok, %{copied: copied, complete: complete}} = backfill_articles(opts)
    {:ok, drift} = repair_article_live_denorm()

    {:ok, %{repaired: copied, live_denorm_repaired: drift, complete: complete}}
  end

  @doc "The memories twin of `reconcile_articles/1`."
  @spec reconcile_memories(keyword()) ::
          {:ok,
           %{
             repaired: non_neg_integer(),
             live_denorm_repaired: non_neg_integer(),
             complete: boolean()
           }}
  def reconcile_memories(opts \\ []) do
    {:ok, %{copied: copied, complete: complete}} = backfill_memories(opts)
    {:ok, drift} = repair_memory_live_denorm()

    {:ok, %{repaired: copied, live_denorm_repaired: drift, complete: complete}}
  end

  @doc """
  Side-table rows whose `live_denorm` marker DISAGREES with their parent — the
  marker-drift class the gap probe cannot see (review).

  `article_reconciliation_gaps/1` only finds MISSING rows. A row that exists with a
  STALE marker is invisible to it and strictly worse: the per-dimension HNSW indexes
  are PARTIAL on `live_denorm`, so a superseded article marked live is IN the index
  and occupies ANN pool slots on every recall (the US-28.2 regression), while a live
  article marked dead vanishes from recall entirely. The trigger pair is the primary
  mechanism and the `FOR SHARE` parent read closes the known write skew; this is the
  standing safety net for anything neither covers.
  """
  @spec article_live_denorm_drift(keyword()) :: [Ecto.UUID.t()]
  def article_live_denorm_drift(opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_batch_size)

    AdminRepo.all(
      from(ae in ArticleEmbedding,
        join: a in Article,
        on: a.id == ae.article_id,
        where: ae.live_denorm != fragment("(? <> 'superseded')", a.status),
        select: ae.id,
        limit: ^limit
      )
    )
  end

  @doc "The memories twin of `article_live_denorm_drift/1`."
  @spec memory_live_denorm_drift(keyword()) :: [Ecto.UUID.t()]
  def memory_live_denorm_drift(opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_batch_size)

    AdminRepo.all(
      from(me in MemoryEmbedding,
        join: m in Memory,
        on: m.id == me.memory_id,
        where: me.live_denorm != is_nil(m.superseded_by),
        select: me.id,
        limit: ^limit
      )
    )
  end

  @doc "Repairs every marker `article_live_denorm_drift/1` reports."
  @spec repair_article_live_denorm() :: {:ok, non_neg_integer()}
  def repair_article_live_denorm do
    %{num_rows: n} =
      AdminRepo.query!("""
      UPDATE article_embeddings ae
         SET live_denorm = (a.status <> 'superseded'), updated_at = ae.updated_at
        FROM articles a
       WHERE a.id = ae.article_id
         AND ae.live_denorm IS DISTINCT FROM (a.status <> 'superseded')
      """)

    {:ok, n}
  end

  @doc "The memories twin of `repair_article_live_denorm/0`."
  @spec repair_memory_live_denorm() :: {:ok, non_neg_integer()}
  def repair_memory_live_denorm do
    %{num_rows: n} =
      AdminRepo.query!("""
      UPDATE memory_embeddings me
         SET live_denorm = (m.superseded_by IS NULL), updated_at = me.updated_at
        FROM memories m
       WHERE m.id = me.memory_id
         AND me.live_denorm IS DISTINCT FROM (m.superseded_by IS NULL)
      """)

    {:ok, n}
  end

  # ---------------------------------------------------------------------------
  # System-scoped corpus materialization (AC-41.1.7)
  # ---------------------------------------------------------------------------

  @doc """
  System-scoped articles (`scope: :system`, `tenant_id IS NULL`) that `tenant_id`
  has NOT yet materialized an embedding row for at `dimension`.

  System articles cannot be embedded once for everyone: embeddings are BYO and
  mandatory (`EmbeddingClient` returns `{:error, :no_api_key}` with no operator
  fallback, and the global operator key was deliberately removed), and a NULL
  `tenant_id` row could never satisfy `HeavyRead.guard!/2`'s conjunctive tenant
  predicate. They are therefore embedded ON DEMAND PER TENANT with the requesting
  tenant's own credential and stored as ordinary rows carrying THAT tenant_id.

  ## PUBLISHED only (review)

  The enumeration carries `status == :published`. Without it every system-scoped
  article in ANY status (draft, archived, superseded) had its full title+body sent to
  the TENANT's embedding endpoint — which under Epic 41 is tenant-DECLARED and
  possibly tenant-OPERATED, so operator content deliberately not published left the
  instance to a tenant-controlled destination, billed to the tenant. Nothing was
  gained: `hydrate_semantic_pool/6` applies the status filter and `live_denorm`
  excludes superseded rows, so a non-published system article can never be returned.
  Second-order, it also pinned `system_corpus_meta/2` at `keyword_only` forever for
  every tenant whenever one unpublishable system article existed.
  """
  @spec unmaterialized_system_articles(Ecto.UUID.t(), pos_integer(), keyword()) :: [Article.t()]
  def unmaterialized_system_articles(tenant_id, dimension, opts \\ [])
      when is_binary(tenant_id) and is_integer(dimension) do
    limit = Keyword.get(opts, :limit, @default_batch_size)

    AdminRepo.all(
      from(a in system_articles_query(),
        as: :article,
        where:
          not exists(
            from(ae in ArticleEmbedding,
              where:
                ae.article_id == parent_as(:article).id and
                  ae.tenant_id == ^tenant_id and
                  ae.dim == ^dimension,
              select: 1
            )
          ),
        limit: ^limit
      )
    )
  end

  @doc """
  System-scoped articles this tenant must (re-)embed at `dimension`: the
  UNMATERIALIZED ones PLUS the ones whose body has changed since materialization.

  Materialization used to be existence-only, and this worker is the ONLY writer for
  system-scoped articles (the ordinary content-hash-driven workers never touch them,
  because a system article has no `tenant_id`). So once materialized, an edit to a
  system article's title or body left EVERY tenant's vector permanently stale with no
  repair path short of manual deletion — while `system_corpus_meta/2` reported
  `"semantic"` throughout (review).

  Staleness is detected in SQL by `ae.updated_at < a.updated_at` (an edit bumps the
  article's `updated_at`); the worker then compares the ACTUAL content hash before
  spending anything, so an article that was touched without a content change costs a
  `updated_at` touch rather than a provider call.

  Deliberately NOT the query `system_corpus_meta/2` probes: a stale-but-present
  corpus is still SEMANTICALLY searchable, so reporting `keyword_only` for it would
  be false, and it would flip every tenant's search meta on any system-article edit.
  """
  @spec stale_system_articles(Ecto.UUID.t(), pos_integer(), keyword()) :: [Article.t()]
  def stale_system_articles(tenant_id, dimension, opts \\ [])
      when is_binary(tenant_id) and is_integer(dimension) do
    limit = Keyword.get(opts, :limit, @default_batch_size)

    AdminRepo.all(
      from(a in system_articles_query(),
        as: :article,
        where:
          not exists(
            from(ae in ArticleEmbedding,
              where:
                ae.article_id == parent_as(:article).id and
                  ae.tenant_id == ^tenant_id and
                  ae.dim == ^dimension,
              select: 1
            )
          ) or
            exists(
              from(ae in ArticleEmbedding,
                where:
                  ae.article_id == parent_as(:article).id and
                    ae.tenant_id == ^tenant_id and
                    ae.dim == ^dimension and
                    ae.updated_at < parent_as(:article).updated_at,
                select: 1
              )
            ),
        limit: ^limit
      )
    )
  end

  @doc """
  Marks a system article's materialization as CURRENT without re-embedding it — the
  cheap branch of `stale_system_articles/3` for an article whose `updated_at` moved
  but whose content hash did not.
  """
  @spec touch_system_article_embedding(Ecto.UUID.t(), Ecto.UUID.t(), pos_integer()) ::
          {:ok, non_neg_integer()}
  def touch_system_article_embedding(tenant_id, article_id, dimension),
    do: touch_system_article_embeddings(tenant_id, [article_id], dimension)

  @doc """
  Batch form: touches EVERY `article_id` at `dimension` in ONE `update_all`.

  The materialization path de-N+1s its hash reads (AC-41.1.11) but touched each
  unchanged article with its own UPDATE — up to `embedding_batch_max/0` (~100) writes
  per run (review). One `article_id in ^ids` update replaces the per-item loop.
  """
  @spec touch_system_article_embeddings(Ecto.UUID.t(), [Ecto.UUID.t()], pos_integer()) ::
          {:ok, non_neg_integer()}
  def touch_system_article_embeddings(_tenant_id, [], _dimension), do: {:ok, 0}

  def touch_system_article_embeddings(tenant_id, article_ids, dimension)
      when is_list(article_ids) do
    {n, _} =
      AdminRepo.update_all(
        from(ae in ArticleEmbedding,
          where:
            ae.tenant_id == ^tenant_id and ae.article_id in ^article_ids and ae.dim == ^dimension
        ),
        set: [updated_at: DateTime.utc_now()]
      )

    {:ok, n}
  end

  defp system_articles_query do
    from(a in Article,
      where: a.scope == :system and is_nil(a.tenant_id) and a.status == :published
    )
  end

  @doc """
  Writes ONE system-scoped article's vector as a per-tenant `article_embeddings`
  row (AC-41.1.7).

  Deliberately NOT a dual-write: the legacy `articles.embedding` column is a single
  GLOBAL slot on a row shared by every tenant, so writing tenant A's vector there
  would overwrite tenant B's — and for a non-1536 tenant it is physically
  impossible anyway. System-article vectors are side-table-ONLY, always.
  """
  @spec materialize_system_article_embedding(
          Ecto.UUID.t(),
          Article.t(),
          [float()],
          String.t() | nil,
          pos_integer()
        ) :: {:ok, ArticleEmbedding.t()} | {:error, term()}
  def materialize_system_article_embedding(tenant_id, %Article{} = article, embedding, hash, dim)
      when is_binary(tenant_id) and is_integer(dim) do
    upsert_article_embedding_row(AdminRepo, tenant_id, article, embedding, hash, dim)
  end

  @doc """
  Enqueues the on-demand per-tenant materialization of the system corpus at the
  tenant's ACTIVE dimension (AC-41.1.7).

  Idempotent: the worker is `unique` per `(tenant_id, dim)` and its batch query is
  an anti-join, so re-enqueuing while a run is in flight is a no-op and a completed
  corpus makes the job an immediate `:ok`.

  ## Terminal-state gate (review)

  The worker's uniqueness was deliberately narrowed to
  `[:available, :scheduled, :retryable]` so it can re-enqueue ITSELF, which means
  `:discarded` and `:cancelled` jobs are NOT deduped. Since the search read path
  enqueues this whenever the corpus reports `keyword_only`, a tenant whose
  materialization terminated PERMANENTLY (`{:discard, {:no_embedding_key, _}}`, a
  permanent provider error, an egress cancel, a persistent dimension mismatch)
  re-enqueued a fresh job on every semantic search, forever, driven by user traffic.
  An existing terminal job for `(tenant_id, dim)` therefore short-circuits with
  `{:error, :materialization_terminal}`. `force: true` (the explicit operator/agent
  POST) bypasses the gate — a human asking again is a new decision, and a retry is
  exactly how the terminal state is meant to be cleared.
  """
  @spec enqueue_system_corpus_materialization(Ecto.UUID.t(), keyword()) ::
          {:ok, Oban.Job.t() | :already_materialized}
          | {:error, :materialization_terminal | term()}
  def enqueue_system_corpus_materialization(tenant_id, opts \\ []) when is_binary(tenant_id) do
    dimension = Keyword.get(opts, :dimension) || active_dimension(tenant_id)
    force? = Keyword.get(opts, :force, false)

    cond do
      # Already fully materialized ⇒ NO job (review, finding 11). The worker's Oban
      # uniqueness covers only [:available, :scheduled, :retryable] (it must re-enqueue
      # itself), so a COMPLETED corpus is not deduped: without this short-circuit every
      # repeated agent-role POST inserted and ran a fresh job that the anti-join makes a
      # no-op — an agent key could loop the endpoint to flood the embeddings queue for
      # its own tenant. A limit-1 anti-join probe is cheap and returns a 200-shaped
      # `:already_materialized` with no job created. Checked BEFORE the terminal gate so
      # a done-but-terminal corpus reports done, not a conflict.
      unmaterialized_system_articles(tenant_id, dimension, limit: 1) == [] ->
        {:ok, :already_materialized}

      not force? and system_corpus_terminal?(tenant_id, dimension) ->
        {:error, :materialization_terminal}

      true ->
        %{tenant_id: tenant_id, dim: dimension}
        |> SystemCorpusEmbeddingWorker.new()
        |> Oban.insert()
    end
  end

  @doc """
  Whether a system-corpus materialization for `(tenant_id, dimension)` has already
  terminated permanently (`discarded` / `cancelled`).
  """
  @spec system_corpus_terminal?(Ecto.UUID.t(), pos_integer()) :: boolean()
  def system_corpus_terminal?(tenant_id, dimension) do
    worker = inspect(SystemCorpusEmbeddingWorker)

    # OBAN's repo, not `AdminRepo`: `oban_jobs` is Oban's own, non-RLS table, and
    # reading it through the same repo that WRITES it keeps the two consistent.
    Repo.exists?(
      from(j in "oban_jobs",
        where:
          j.worker == ^worker and j.state in ["discarded", "cancelled"] and
            fragment("?->>'tenant_id' = ?", j.args, ^tenant_id) and
            fragment("(?->>'dim')::int = ?", j.args, ^dimension),
        limit: 1
      )
    )
  end

  @doc """
  Enqueues the agent-triggerable RE-EMBED backfill onto `target_dimension`
  (AC-41.1.10).

  The tenant's ACTIVE dimension is deliberately NOT changed here. Old and new
  dimension rows COEXIST (uniqueness is `(id, dim)`) and recall keeps serving at the
  ACTIVE dimension for the whole window — the query vector is always generated at
  the active dimension, never the pending one. Only when the backfill reports
  completion does the worker flip `tenants.tenant_embedding_dimension` and drop the
  stale-dimension rows. Without that ordering the endpoint PATCH alone would make
  every query vector disagree with the whole corpus: a total recall blackout.
  """
  @spec enqueue_reembed(Ecto.UUID.t(), pos_integer()) ::
          {:ok, Oban.Job.t()} | {:error, :unsupported_dimension | term()}
  def enqueue_reembed(tenant_id, target_dimension)
      when is_binary(tenant_id) and is_integer(target_dimension) do
    if supported_dimension?(target_dimension) do
      # Capture the model that will PRODUCE the target corpus AT ENQUEUE (review, finding
      # 12): the worker embeds every batch with it and `complete_reembed/3` pins it, so a
      # mid-run edit to `tenant_llm_settings.embedding_model` can neither split the corpus
      # across two models nor make the completion pin a model that did not produce it.
      %{
        tenant_id: tenant_id,
        target_dim: target_dimension,
        embedding_model: Llm.embedding_model(tenant_id)
      }
      |> ReembedWorker.new()
      |> Oban.insert()
    else
      {:error, :unsupported_dimension}
    end
  end

  @doc """
  Re-embed progress for `tenant_id` onto `target_dimension`: how many of the
  tenant's ACTIVE-dimension rows already have a `target_dimension` twin.

  This is the AC-41.1.10 progress surface AND the source of the "rows excluded from
  PENDING-dimension recall" number the search `meta` reports.
  """
  @spec reembed_progress(Ecto.UUID.t(), pos_integer()) :: %{
          active_dimension: pos_integer(),
          target_dimension: pos_integer(),
          total: non_neg_integer(),
          done: non_neg_integer(),
          pending: non_neg_integer(),
          complete: boolean()
        }
  def reembed_progress(tenant_id, target_dimension)
      when is_binary(tenant_id) and is_integer(target_dimension) do
    active = active_dimension(tenant_id)

    case dimension_counts_status(tenant_id) do
      # HeavyRead SHED (review, finding 9): counts are UNKNOWN, not zero. Reporting
      # `total: 0`/`done: 0` here would make `done >= total` compute `complete: true` —
      # emitting a false `complete:true`/`pending:0` telemetry + disclosure during a
      # transient overload. An empty-but-genuinely-complete corpus is INDISTINGUISHABLE
      # from a shed at the count layer, so on a shed we report NOT complete (the safe,
      # self-correcting answer — actual completion is re-verified via `reembed_complete?`
      # inside `complete_reembed/3`, never off this progress number).
      :overloaded ->
        %{
          active_dimension: active,
          target_dimension: target_dimension,
          total: 0,
          done: 0,
          pending: 0,
          complete: false
        }

      {:ok, counts} ->
        total = Map.get(counts, active, 0)
        done = Map.get(counts, target_dimension, 0)

        %{
          active_dimension: active,
          target_dimension: target_dimension,
          total: total,
          done: min(done, total),
          pending: max(total - done, 0),
          # `done >= total` and NOT `total > 0 and …` (review #15): a tenant with an
          # empty corpus at the active dimension has nothing left to re-embed, so it IS
          # complete. The old form made such a tenant permanently incomplete, which the
          # worker's completion decision reads. (The shed case above is handled
          # separately so a `%{}` from an OVERLOAD is not misread as an empty corpus.)
          complete: done >= total
        }
    end
  end

  @doc """
  The AC-41.1.10 search-`meta` disclosure for an IN-FLIGHT re-embed.

  When a tenant has rows at more than one dimension, recall is served at the ACTIVE
  dimension and every row not yet re-embedded at the pending dimension is EXCLUDED
  from pending-dimension recall rather than compared incorrectly (pgvector would
  error on a cross-dimension comparison). The exclusion is reported so an agent can
  see WHY recall shrank instead of inferring it from a short result set.

  Returns `%{}` when nothing is in flight, so the caller can `Map.merge/2` it
  unconditionally.
  """
  @spec reembed_meta(Ecto.UUID.t(), pos_integer() | nil) :: map()
  def reembed_meta(tenant_id, active \\ nil) when is_binary(tenant_id) do
    active = active || active_dimension(tenant_id)

    # HOT PATH: this runs on EVERY semantic search, so the common case (no re-embed
    # in flight) must not pay for a grouped count over the tenant's whole embedding
    # corpus. A `LIMIT 1` existence probe on the `(tenant_id, dim)` btree stops at
    # the first off-dimension row — index-only and O(1) — and only a tenant that is
    # actually mid-re-embed pays for the counts below.
    if reembed_in_flight?(tenant_id, active) do
      build_reembed_meta(tenant_id, active)
    else
      %{}
    end
  end

  # BOTH side tables (review #14): a tenant whose only off-dimension rows are
  # MEMORIES is just as mid-re-embed as one with off-dimension articles, and an
  # article-only probe gave it no disclosure at all.
  defp reembed_in_flight?(tenant_id, active) do
    # HeavyRead, not AdminRepo (review): these run on the semantic-search hot path, and
    # KB 9c766ca7 routes heavy/analytical reads to the dedicated HeavyRead pool so they
    # cannot starve AdminRepo's 3-connection pool (the US-27.11 outage class). Each probe
    # is a single tenant-scoped source with a conjunctive `tenant_id ==` equality, so
    # `guard!/2` accepts it. An overloaded shed degrades to "no re-embed disclosed"
    # rather than raising a 500 on the disclosure path.
    #
    # Row-existence based BY DESIGN (AC-41.1.10): off-active-dimension rows are excluded
    # from active-dimension recall, and that exclusion MUST be disclosed rather than
    # silently shrink the result set — the disclosure is truthful whether the rows come
    # from an in-flight run or a stranded one. The standing
    # `EmbeddingReconciliationWorker` re-embeds active-dimension gaps so stranded rows do
    # not persist.
    off_dimension_rows?(tenant_id, ArticleEmbedding, active) or
      off_dimension_rows?(tenant_id, MemoryEmbedding, active)
  end

  defp off_dimension_rows?(tenant_id, schema, active) do
    query =
      from(x in schema,
        where: x.tenant_id == ^tenant_id and x.dim != ^active,
        select: 1,
        limit: 1
      )

    case HeavyRead.one(tenant_id, query, heavy_disclosure_opts()) do
      {:error, :heavy_read_overloaded} -> false
      nil -> false
      _ -> true
    end
  end

  # Disclosure/progress reads are best-effort and memoized — `on_overload: :tag` so an
  # over-cap shed degrades gracefully instead of raising on the hot read path.
  defp heavy_disclosure_opts, do: [{:on_overload, :tag} | HeavyRead.opts(:semantic_search)]

  defp build_reembed_meta(tenant_id, active) do
    counts = dimension_counts(tenant_id)

    # SORTED, then head (review): `Map.keys/1` order is unspecified, so with more than
    # one off-dimension present the reported `pending_dim` and its row count varied
    # between identical requests. `reembed_pending_dimensions` is already sorted; the
    # scalar disclosure is now drawn from the SAME deterministic order.
    case counts |> Map.keys() |> Enum.reject(&(&1 == active)) |> Enum.sort() do
      [] ->
        %{}

      [pending_dim | _] = pending_dims ->
        progress = reembed_progress(tenant_id, pending_dim)

        %{
          reembed_in_progress: true,
          reembed_active_dimension: active,
          reembed_pending_dimensions: pending_dims,
          reembed_pending_rows: progress.pending,
          reembed_excluded_reason:
            "a re-embed onto #{pending_dim} dimensions is in flight. Recall is served at " <>
              "the ACTIVE #{active}-dimension corpus; #{progress.pending} row(s) are not yet " <>
              "re-embedded at #{pending_dim} and are excluded from pending-dimension recall " <>
              "rather than compared across dimensions."
        }
    end
  end

  # ---------------------------------------------------------------------------
  # The re-embed work queue (AC-41.1.10) — BOTH side tables, and system articles
  # ---------------------------------------------------------------------------

  @doc """
  Articles that have a side-table row at SOME dimension other than `target_dim`
  and none yet at `target_dim` — the resumable, idempotent re-embed work queue.

  Two things this does NOT do, both of which were recall-destroying bugs (review #1):

    * it does not key the source off the tenant's ACTIVE dimension. The source is
      "any other dimension", so a tenant whose derived active dimension has already
      moved to the target (a model change) still has its stale corpus enumerated
      instead of the re-embed short-circuiting into a no-op.
    * it does not require `articles.tenant_id == tenant_id`. SYSTEM-scoped articles
      (`tenant_id IS NULL`, materialized PER TENANT by AC-41.1.7) carry the
      requesting tenant's id on the EMBEDDING row, not the article row — filtering on
      the article's tenant excluded every one of them from the re-embed, and the
      completion sweep then deleted them.
  """
  @spec pending_reembed_articles(Ecto.UUID.t(), pos_integer(), pos_integer()) :: [Article.t()]
  def pending_reembed_articles(tenant_id, target_dim, limit)
      when is_binary(tenant_id) and is_integer(target_dim) and is_integer(limit) do
    ids =
      AdminRepo.all(
        from(ae in ArticleEmbedding,
          as: :src,
          where: ae.tenant_id == ^tenant_id and ae.dim != ^target_dim,
          where:
            not exists(
              from(t in ArticleEmbedding,
                where:
                  t.article_id == parent_as(:src).article_id and t.tenant_id == ^tenant_id and
                    t.dim == ^target_dim,
                select: 1
              )
            ),
          distinct: true,
          select: ae.article_id,
          limit: ^limit
        )
      )

    case ids do
      [] ->
        []

      ids ->
        AdminRepo.all(
          from(a in Article,
            where: a.id in ^ids,
            where: a.tenant_id == ^tenant_id or a.scope == :system
          )
        )
    end
  end

  @doc "The memories twin of `pending_reembed_articles/3`."
  @spec pending_reembed_memories(Ecto.UUID.t(), pos_integer(), pos_integer()) :: [Memory.t()]
  def pending_reembed_memories(tenant_id, target_dim, limit)
      when is_binary(tenant_id) and is_integer(target_dim) and is_integer(limit) do
    ids =
      AdminRepo.all(
        from(me in MemoryEmbedding,
          as: :src,
          where: me.tenant_id == ^tenant_id and me.dim != ^target_dim,
          where:
            not exists(
              from(t in MemoryEmbedding,
                where:
                  t.memory_id == parent_as(:src).memory_id and t.tenant_id == ^tenant_id and
                    t.dim == ^target_dim,
                select: 1
              )
            ),
          distinct: true,
          select: me.memory_id,
          limit: ^limit
        )
      )

    case ids do
      [] -> []
      ids -> AdminRepo.all(from(m in Memory, where: m.id in ^ids and m.tenant_id == ^tenant_id))
    end
  end

  @doc """
  True when NOTHING (article or memory) is still awaiting a `target_dim` twin — the
  precondition `drop_stale_dimensions/2` refuses to delete without.
  """
  @spec reembed_complete?(Ecto.UUID.t(), pos_integer()) :: boolean()
  def reembed_complete?(tenant_id, target_dim) do
    pending_reembed_articles(tenant_id, target_dim, 1) == [] and
      pending_reembed_memories(tenant_id, target_dim, 1) == []
  end

  @doc """
  Drops every side-table row for `tenant_id` at a dimension OTHER than `keep_dim`
  — the AC-41.1.10 stale-dimension cleanup, run only AFTER the re-embed reports
  completion.

  FAIL-CLOSED (review #1): this deletes BOTH side tables, so calling it while any
  row still lacks a `keep_dim` twin is a permanent recall blackout for exactly the
  rows that were never migrated (agent memories and per-tenant system-article
  materializations were the two classes that used to fall in that hole). The
  precondition is therefore re-checked HERE, not just at the call site, and an
  incomplete corpus returns `{:error, :reembed_incomplete}` with nothing deleted.
  """
  @spec drop_stale_dimensions(Ecto.UUID.t(), pos_integer()) ::
          {:ok, non_neg_integer()} | {:error, :reembed_incomplete}
  def drop_stale_dimensions(tenant_id, keep_dim)
      when is_binary(tenant_id) and is_integer(keep_dim) do
    if reembed_complete?(tenant_id, keep_dim) do
      do_drop_stale_dimensions(tenant_id, keep_dim)
    else
      {:error, :reembed_incomplete}
    end
  end

  defp do_drop_stale_dimensions(tenant_id, keep_dim) do
    {articles, _} =
      AdminRepo.delete_all(
        from(ae in ArticleEmbedding, where: ae.tenant_id == ^tenant_id and ae.dim != ^keep_dim)
      )

    {memories, _} =
      AdminRepo.delete_all(
        from(me in MemoryEmbedding, where: me.tenant_id == ^tenant_id and me.dim != ^keep_dim)
      )

    {:ok, articles + memories}
  end

  @doc """
  The AC-41.1.7 disclosure for the search response `meta`.

  Until a tenant has materialized the system corpus at its active dimension, those
  articles are KEYWORD-ONLY for it. That MUST be stated explicitly — a silent
  absence looks identical to "the system corpus has nothing relevant", which is
  exactly the failure mode this AC exists to prevent.
  """
  @spec system_corpus_meta(Ecto.UUID.t(), pos_integer() | nil) :: map()
  def system_corpus_meta(tenant_id, dimension \\ nil) when is_binary(tenant_id) do
    dimension = dimension || active_dimension(tenant_id)
    pending = length(unmaterialized_system_articles(tenant_id, dimension, limit: 1))

    if pending == 0 do
      %{system_corpus_recall: "semantic", system_corpus_dimension: dimension}
    else
      %{
        system_corpus_recall: "keyword_only",
        system_corpus_dimension: dimension,
        system_corpus_reason:
          "the shared system-scoped corpus has not been embedded for this tenant at " <>
            "#{dimension} dimensions yet. System articles are embedded on demand with THIS " <>
            "tenant's own embedding credential; until that materialization runs they are " <>
            "matched by keyword only."
      }
    end
  end

  @doc """
  The WHOLE search-response disclosure for `(tenant_id, dimension)` — the
  AC-41.1.7 system-corpus state merged with the AC-41.1.10 re-embed state —
  MEMOIZED for a short TTL.

  This runs on every semantic response, and in the steady state its three queries
  (a system-corpus anti-join that qualifies no rows, plus two re-embed existence
  probes) always answer the same thing: the answer changes only when the
  materialization worker runs, a system article is published, or a re-embed makes
  progress — never as a function of the request. See
  `Loopctl.Embeddings.DisclosureCache` (TTL `0` disables it).
  """
  @spec search_disclosure_meta(Ecto.UUID.t(), pos_integer()) :: map()
  def search_disclosure_meta(tenant_id, dimension)
      when is_binary(tenant_id) and is_integer(dimension) do
    DisclosureCache.fetch({:disclosure, tenant_id, dimension}, fn ->
      meta =
        Map.merge(system_corpus_meta(tenant_id, dimension), reembed_meta(tenant_id, dimension))

      # AC-41.1.7's "on demand" read-path materialization trigger lives INSIDE the
      # memoized fill (review): it was previously called on EVERY semantic response,
      # so an unmaterialized tenant paid an unindexed `oban_jobs` JSONB scan plus an
      # Oban insert on every search. Firing it only on a cache MISS bounds it to once
      # per DisclosureCache TTL, and the anti-join/uniqueness make repeat inserts no-ops.
      maybe_trigger_system_corpus(tenant_id, dimension, meta)

      meta
    end)
  end

  defp maybe_trigger_system_corpus(tenant_id, dimension, %{
         system_corpus_recall: "keyword_only"
       }) do
    enqueue_system_corpus_materialization(tenant_id, dimension: dimension)
    :ok
  end

  defp maybe_trigger_system_corpus(_tenant_id, _dimension, _meta), do: :ok

  @doc """
  Completes a re-embed onto `target_dim` ATOMICALLY: verify completeness, re-pin the
  tenant's dimension AND model, then drop the stale-dimension rows — all in ONE
  transaction.

  ## Why the order and the transaction matter (review)

  The worker used to `set_tenant_dimension/2` FIRST and then call
  `drop_stale_dimensions/2`, which re-checks `reembed_complete?/2` and can return
  `{:error, :reembed_incomplete}` — the fail-closed guard for exactly the race where
  a new off-dimension row appears after the last batch. When that guard fired the pin
  had ALREADY moved: `active_dimension/1` returned the target, recall served the
  target corpus, and the raced rows existed only at the old dimension, silently
  absent from results. If the job then exhausted its attempts, the tenant was left
  permanently pinned at the target with un-migrated rows excluded from recall.

  Verifying and pinning inside the same transaction as the sweep makes the pin move
  only on the interleaving where the sweep is also safe; anything else rolls back
  and the job retries with recall untouched.
  """
  @spec complete_reembed(Ecto.UUID.t(), pos_integer(), String.t() | nil) ::
          {:ok, non_neg_integer()} | {:error, :reembed_incomplete | :not_found | term()}
  def complete_reembed(tenant_id, target_dim, model \\ nil)
      when is_binary(tenant_id) and is_integer(target_dim) and
             (is_binary(model) or is_nil(model)) do
    if supported_dimension?(target_dim) do
      AdminRepo.transaction(fn -> do_complete_reembed(tenant_id, target_dim, model) end)
    else
      {:error, :unsupported_dimension}
    end
  end

  defp do_complete_reembed(tenant_id, target_dim, model) do
    with :ok <- assert_reembed_complete(tenant_id, target_dim),
         :ok <- pin_completed_reembed(tenant_id, target_dim, model),
         {:ok, dropped} <- do_drop_stale_dimensions(tenant_id, target_dim) do
      # AUDIT the completion (review): completion DELETES every stale-dimension row, so
      # it is the data-removing half of the operation KB 3e89e251 requires be audited to
      # stay below `:user`. Written inside the same transaction as the pin + sweep.
      Audit.create_log_entry(tenant_id, %{
        entity_type: "knowledge_embedding",
        entity_id: tenant_id,
        action: "embedding.reembed_completed",
        actor_type: "system",
        actor_id: nil,
        actor_label: "worker:reembed",
        new_state: %{"target_dimension" => target_dim, "stale_rows_dropped" => dropped}
      })

      dropped
    else
      {:error, reason} -> AdminRepo.rollback(reason)
    end
  end

  defp assert_reembed_complete(tenant_id, target_dim) do
    if reembed_complete?(tenant_id, target_dim), do: :ok, else: {:error, :reembed_incomplete}
  end

  # The model pin moves WITH the dimension: from here on, ordinary embeddings (query
  # vectors included) are generated with the model that produced the corpus now
  # serving.
  #
  # `model` is THREADED from the worker — the model captured when the re-embed was
  # ENQUEUED, i.e. the one that actually produced the target-dimension corpus (review,
  # finding 12/TOCTOU). It is NOT re-read from the tenant's CURRENT config here: a
  # tenant that edits `tenant_llm_settings.embedding_model` between the last batch and
  # completion would otherwise have the pin record a model that did not produce the now
  # active corpus, so `query_model_override/1` would generate query vectors in the wrong
  # embedding space. A `nil` model (a legacy job enqueued before this field existed)
  # falls back to the currently configured model.
  #
  # The pin uses the SAME model/dimension agreement check as `pin_set/2` (review,
  # finding 8): only pin the model when it genuinely produces `target_dim` vectors.
  # A disagreeing model is pinned as NULL so `model_pin_conflict/1` DISCLOSES the
  # conflict, rather than pinning a disagreeing model that `model_pin_conflict/1`
  # (which only fires on a nil pin) would never surface — a silent recall blackout.
  defp pin_completed_reembed(tenant_id, target_dim, model) do
    model = model || Llm.embedding_model(tenant_id)

    {n, _} =
      AdminRepo.update_all(
        from(t in Tenant, where: t.id == ^tenant_id),
        set: completion_pin_set(target_dim, model)
      )

    if n == 0 do
      {:error, :not_found}
    else
      invalidate_tenant_pin(tenant_id)
      :ok
    end
  end

  # Unlike `pin_set/2` (which leaves the model UNCHANGED on disagreement), completion
  # must EXPLICITLY move the model with the dimension — so on disagreement it pins the
  # model NULL, both flipping the dimension AND letting `model_pin_conflict/1` disclose
  # the mismatch (finding 8).
  defp completion_pin_set(target_dim, model) do
    if Dimensions.for_model(model) == target_dim do
      [tenant_embedding_dimension: target_dim, tenant_embedding_model: model]
    else
      [tenant_embedding_dimension: target_dim, tenant_embedding_model: nil]
    end
  end

  @doc """
  Counts a tenant's side-table rows per dimension — the AC-41.1.10 re-embed
  progress surface and the source of the "rows excluded from PENDING-dimension
  recall" number the search `meta` reports.
  """
  @spec dimension_counts(Ecto.UUID.t()) :: %{pos_integer() => non_neg_integer()}
  def dimension_counts(tenant_id) when is_binary(tenant_id) do
    Map.merge(
      article_dimension_counts(tenant_id),
      memory_dimension_counts(tenant_id),
      fn _dim, a, m -> a + m end
    )
  end

  @doc "Per-dimension row counts for the ARTICLE side table only."
  @spec article_dimension_counts(Ecto.UUID.t()) :: %{pos_integer() => non_neg_integer()}
  def article_dimension_counts(tenant_id) when is_binary(tenant_id) do
    dimension_counts_for(tenant_id, ArticleEmbedding)
  end

  @doc "Per-dimension row counts for the MEMORY side table only."
  @spec memory_dimension_counts(Ecto.UUID.t()) :: %{pos_integer() => non_neg_integer()}
  def memory_dimension_counts(tenant_id) when is_binary(tenant_id) do
    dimension_counts_for(tenant_id, MemoryEmbedding)
  end

  # HeavyRead, not AdminRepo (review): an unbounded per-tenant `GROUP BY dim` aggregate
  # is exactly the heavy/analytical read KB 9c766ca7 routes to the dedicated pool so it
  # cannot starve AdminRepo's 3-connection pool — and it is reachable from the agent-role
  # status endpoint. One tenant-scoped source with a conjunctive `tenant_id ==` equality,
  # so `guard!/2` accepts it. An overloaded shed degrades to no counts (`%{}`).
  defp dimension_counts_for(tenant_id, schema) do
    case dimension_counts_for_status(tenant_id, schema) do
      :overloaded -> %{}
      {:ok, counts} -> counts
    end
  end

  # `{:ok, counts}` or `:overloaded` — the OVERLOAD-DISTINGUISHING variant (review,
  # finding 9). `dimension_counts_for/2` collapses a shed to `%{}` (its best-effort
  # disclosure contract), but `reembed_progress/2` must tell "empty corpus" (genuinely
  # `%{}`, complete) apart from "HeavyRead shed" (unknown, NOT complete) — so it reads
  # this and never derives `complete:true` from a shed.
  defp dimension_counts_status(tenant_id) do
    with {:ok, articles} <- dimension_counts_for_status(tenant_id, ArticleEmbedding),
         {:ok, memories} <- dimension_counts_for_status(tenant_id, MemoryEmbedding) do
      {:ok, Map.merge(articles, memories, fn _dim, a, m -> a + m end)}
    end
  end

  defp dimension_counts_for_status(tenant_id, schema) do
    query =
      from(x in schema,
        where: x.tenant_id == ^tenant_id,
        group_by: x.dim,
        select: {x.dim, count(x.id)}
      )

    case HeavyRead.all(tenant_id, query, heavy_disclosure_opts()) do
      {:error, :heavy_read_overloaded} -> :overloaded
      rows when is_list(rows) -> {:ok, Map.new(rows)}
    end
  end
end
