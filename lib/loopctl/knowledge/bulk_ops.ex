defmodule Loopctl.Knowledge.BulkOps do
  @moduledoc """
  SET-BASED bulk archive/unpublish/delete for the Knowledge Wiki (US-27.12).

  This is the **set-based** complement to the per-row partial-success bulk ops in
  `Loopctl.Knowledge` (`bulk_publish/3`, `bulk_unpublish/3`, `bulk_archive/3`).
  Those iterate row-by-row (one changeset + one audit per row) for actionable
  per-id outcomes. The ops here instead mutate the whole selected set in ONE
  `update_all`/`delete_all` statement plus ONE audit event, inside a single
  transaction — the right shape for cleaning up a whole tag/source without
  thousands of round-trips.

  ## Selectors

  A selector resolves to a bounded id-set (capped at 5000 by
  `Loopctl.Knowledge.list_archivable_ids/2`):

  - `{:ids, [uuid]}` — explicit ids (active rows only, tenant-scoped)
  - `{:tag, tag}` — every active article carrying `tag` (array overlap)
  - `{:source, %{source_id: id, source_type: type}}` — every active article from
    that source id AND matching source_type (a source_id whose source_type
    differs does NOT match). `{:source, source_id}` (bare id) is still accepted
    for source_id-only filtering.

  Foreign ids / cross-tenant selectors never match: every resolution and every
  mutation re-ANDs `tenant_id` (AC-27.12.6).

  ## Operations

  - `archive/3` — `:draft`/`:published` → `:archived`. **NOT reversible in code.** The row
    is retained and links are left intact but inert in published-only graph traversal
    (AC-27.12.3), so nothing is destroyed — but `Article`'s `@valid_transitions` has no
    `{:archived, _}` entry and there is no unarchive function, so the ONLY way back is a
    `user+` PATCH carrying an explicit status. An earlier version of this line called it
    "reversible"; that was wrong for articles and is exactly the sentence an unattended
    caller would rely on before archiving something it cannot restore.
  - `unpublish/3` — `:published` → `:draft`. Genuinely reversible: `{:draft, :published}`
    is a valid transition, so `publish/3` restores it. This is the primitive to reach for
    when something automated needs to retract an article.
  - `delete/3` / `delete_with_token/3` — irreversible HARD delete. FK-correct:
    `article_links` (both directions, tenant-scoped) are deleted FIRST in the
    same transaction or the `:restrict` FK aborts; `article_access_events`
    cascade automatically (`on_delete: :delete_all`).

  ## Atomicity & blast-radius

  Every op runs in one `AdminRepo.transaction` (BYPASSRLS, explicit tenant
  scoping) that first issues `SET LOCAL statement_timeout = <ms>` (default
  10_000, `:bulk_op_statement_timeout_ms`) so a single large statement can't hold
  one of the small admin-pool connections indefinitely, AND is itself bounded by
  a transaction-level timeout (default 15_000, `:bulk_op_transaction_timeout_ms`,
  set above the statement timeout) so the connection is reclaimed even when
  several statements chain. The mutation + its dependent-link handling + the
  single audit event are all-or-nothing (AC-27.12.4).

  ### Worst-case connection-hold (AC-27.12.5)

  The whole op is ONE transaction holding ONE AdminRepo connection (the pool is
  small — 3 conns per US-27.11), so the worst case is the cost of the largest
  realistic selector. We KEEP the single-transaction/one-audit shape rather than
  batching, because one audit event per bulk op is the AC-27.12.8 contract;
  batching would emit one per batch. Three things bound it instead:

  1. **5000-row cap** — `resolve_selector` refuses (`{:error, :too_many}`) over
     5000 active matches, so no statement touches more than 5000 articles.
  2. **Index-friendly link cleanup** — the two FK link deletes are SPLIT into
     single-column `delete_all`s (`source_article_id`, then
     `target_article_id`), each hitting its own btree index, instead of one
     OR-across-columns statement that the planner degrades to a seq scan at
     scale (see `append_delete_steps/5`).
  3. **`statement_timeout` + transaction timeout** — bound any single statement
     and the whole transaction, so even a pathological plan can't pin a
     connection past the configured ceilings; the op aborts (and rolls back)
     cleanly instead.

  For a HARD delete the accounting also includes the cascaded
  `article_access_events` (FK `on_delete: :delete_all`) — a hot article can have
  far more access-event rows than the article count, and they are deleted in the
  same `articles` statement. The 10s statement timeout on the 3-conn pool is the
  backstop; the integration test (`delete/3` over ~100 articles, each with links
  and several access events) exercises this end-to-end below the :scale tier.

  ### Pool-saturation caveat (honest framing)

  The bound above is per-transaction (ONE connection held for ≤15s). It is NOT a
  whole-pool bound. The AdminRepo pool is small (3 connections, US-27.11), so a
  handful of concurrent bulk deletes can transiently occupy ALL of it: while they
  run, other admin callers (other bulk ops, BYPASSRLS reads) queue for a
  connection and see degraded latency until one frees up. This is bounded — each
  holder is capped at the ≤15s transaction timeout, so the worst-case wait is also
  ≤~15s, and there is NO data corruption (every op is still all-or-nothing) — but
  it IS a real, observable latency hit on the shared admin pool under concurrency,
  not merely a single-connection hold. Operators sizing the admin pool or running
  many bulk deletes in parallel should account for this.

  ## Idempotency

  Archive/unpublish gate on `status in <archivable>`, so re-running on
  already-handled rows is a no-op (`affected: 0`, AC-27.12.8).

  ## Safe preview (TOCTOU)

  `preview/4` returns `{would_affect: n}` and mutates nothing. For the
  irreversible `:delete`, when `n` is within the frozen-token bound it also mints
  a single-use, TTL-bounded `Loopctl.Knowledge.BulkDeleteToken` whose `id` is the
  server-minted secret; the real run (`delete_with_token/3`) operates on that
  FROZEN id-set, not whatever the selector matches later. Over the bound, no
  token is minted and the caller must use the re-confirm-on-drift path
  (AC-27.12.9).
  """

  import Ecto.Query

  require Logger

  alias Ecto.Multi
  alias Loopctl.AdminRepo
  alias Loopctl.Audit
  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.Article
  alias Loopctl.Knowledge.ArticleLink
  alias Loopctl.Knowledge.BulkDeleteToken
  alias Loopctl.LocalGuc

  @archivable_statuses [:draft, :published]
  @unpublishable_statuses [:published]

  @type source_sel :: %{source_id: Ecto.UUID.t(), source_type: String.t() | nil}
  @type selector ::
          {:ids, [Ecto.UUID.t()]}
          | {:tag, String.t()}
          | {:source, Ecto.UUID.t()}
          | {:source, source_sel()}
  @type op :: :archive | :unpublish | :delete
  @type audit_opts :: keyword()

  # --- public API ---

  @doc """
  Set-based archive: `:draft`/`:published` → `:archived` over the selected set.

  One `update_all` + one audit event in a single transaction. Idempotent — the
  `status in archivable` predicate makes a re-run a no-op. Returns
  `{:ok, %{affected: n, resolved_count: r}}` (`r` = ids the selector resolved to,
  so `r - n` is the skipped/already-handled count), or `{:error, :too_many}` if
  the selector exceeds the 5000-row cap, or `{:error, :bad_request, msg}` for a
  malformed selector.
  """
  @spec archive(Ecto.UUID.t(), selector(), audit_opts()) ::
          {:ok, %{affected: non_neg_integer(), resolved_count: non_neg_integer()}}
          | {:error, :too_many}
          | {:error, :bad_request, String.t()}
  def archive(tenant_id, selector, audit_opts) do
    transition(
      tenant_id,
      selector,
      :archived,
      @archivable_statuses,
      "article.bulk_archived",
      audit_opts
    )
  end

  @doc """
  Set-based unpublish: `:published` → `:draft` over the selected set.

  One `update_all` + one audit event in a single transaction. Idempotent. Returns
  `{:ok, %{affected: n, resolved_count: r}}` / `{:error, :too_many}` /
  `{:error, :bad_request, msg}`.
  """
  @spec unpublish(Ecto.UUID.t(), selector(), audit_opts()) ::
          {:ok, %{affected: non_neg_integer(), resolved_count: non_neg_integer()}}
          | {:error, :too_many}
          | {:error, :bad_request, String.t()}
  def unpublish(tenant_id, selector, audit_opts) do
    transition(
      tenant_id,
      selector,
      :draft,
      @unpublishable_statuses,
      "article.bulk_unpublished",
      audit_opts
    )
  end

  @doc """
  FK-correct set-based HARD delete over a FROZEN id-set.

  `frozen_ids` MUST already be resolved + integrity-checked by the caller (the
  controller derives them from a dry-run token or a re-confirmed selector). In
  one transaction: delete `article_links` referencing any id in EITHER direction
  (tenant-scoped) FIRST, then delete the articles (`article_access_events`
  cascade), then write one audit event. Returns
  `{:ok, %{affected: n, resolved_count: r}}` where `n` is the number of articles
  actually deleted, and `r` is `length(frozen_ids)` after sanitization (dedup +
  drop of non-UUID junk). `r` is NOT guaranteed to equal `n` (`would_affect`): it
  can EXCEED `affected` when some frozen ids are cross-tenant or already gone —
  those resolve to "no row deleted" but still count toward the frozen set the
  caller asked us to operate on. Treat `r` as the size of the requested set, not a
  delete count.
  """
  @spec delete(Ecto.UUID.t(), [Ecto.UUID.t()], audit_opts()) ::
          {:ok, %{affected: non_neg_integer(), resolved_count: non_neg_integer()}}
          | {:error, term()}
  def delete(tenant_id, frozen_ids, audit_opts) do
    ids = sanitize_ids(frozen_ids)

    tenant_id
    |> delete_multi(ids, %{ids: ids}, audit_opts)
    |> run_multi(length(ids))
  end

  @doc """
  Dry-run preview. Resolves the selector to a bounded id-set and returns
  `{:ok, %{would_affect: n}}` (plus a `:token`/`:oversized` for `:delete`)
  WITHOUT mutating anything.

  - For `:archive`/`:unpublish` (non-destructive — `:unpublish` is reversible,
    `:archive` is NOT; see the moduledoc) — no token, just `would_affect`.
  - For `:delete` — if `n <= frozen-token max`, mints a single-use, TTL-bounded
    `BulkDeleteToken` over the frozen sorted ids and returns
    `%{would_affect: n, token: token_id, frozen_ids: ids}`. Over the bound,
    returns `%{would_affect: n, token: nil, oversized: true, frozen_ids: ids}`
    (the caller must use re-confirm-on-drift).

  The count is bounded (the id list is ≤ 5000 by construction), never an
  O(corpus) `COUNT`.
  """
  @spec preview(Ecto.UUID.t(), op(), selector(), audit_opts()) ::
          {:ok, map()} | {:error, :too_many} | {:error, :bad_request, String.t()}
  def preview(tenant_id, op, selector, _audit_opts) when op in [:archive, :unpublish] do
    with {:ok, ids} <- resolve_selector(tenant_id, selector) do
      {:ok, %{would_affect: length(ids)}}
    end
  end

  def preview(tenant_id, :delete, selector, _audit_opts) do
    with {:ok, ids} <- resolve_delete_selector(tenant_id, selector) do
      sorted = Enum.sort(ids)
      preview_delete_result(tenant_id, sorted)
    end
  end

  defp preview_delete_result(_tenant_id, []) do
    # A zero-match selector mints NO token: a single-use frozen-set token over an
    # empty id-set could only ever delete nothing, so it is pure table noise (and
    # one more row for the TTL sweeper to reap). The caller can re-run the dry-run
    # if the selector later matches rows.
    {:ok, %{would_affect: 0, token: nil}}
  end

  defp preview_delete_result(tenant_id, sorted) do
    n = length(sorted)

    if n <= frozen_token_max() do
      token = mint_token!(tenant_id, sorted)
      {:ok, %{would_affect: n, token: token.id, frozen_ids: sorted}}
    else
      preview_delete_oversized(tenant_id, n, sorted)
    end
  end

  defp preview_delete_oversized(tenant_id, n, sorted) do
    with {:ok, nonce_id} <- mint_nonce_for_oversized(tenant_id) do
      {:ok,
       %{
         would_affect: n,
         token: nil,
         oversized: true,
         nonce: nonce_id,
         frozen_ids: sorted,
         confirm_hash: confirm_hash(tenant_id, sorted)
       }}
    end
  end

  @doc """
  Consume a frozen-set token and run the HARD delete over its FROZEN ids.

  In one transaction: ATOMICALLY consume the token with a single guarded
  `update_all` that stamps `used_at` ONLY when the row is unused, unexpired, and
  in-tenant, returning the frozen `article_ids` from the SAME statement (no
  separate unlocked read of `used_at`); refuse (`{:error, :invalid_token}`)
  unless exactly one row was stamped — so two concurrent consumers cannot both
  proceed (the loser sees 0 rows). Then run the `delete/3` steps over those
  frozen ids. All-or-nothing — a failure anywhere rolls back the token
  consumption too.
  """
  @spec delete_with_token(Ecto.UUID.t(), Ecto.UUID.t(), audit_opts()) ::
          {:ok, %{affected: non_neg_integer(), resolved_count: non_neg_integer()}}
          | {:error, :invalid_token}
          | {:error, term()}
  def delete_with_token(tenant_id, token_id, audit_opts) when is_binary(token_id) do
    if valid_uuid?(token_id) do
      tenant_id
      |> delete_with_token_multi(token_id, audit_opts)
      |> run_multi()
    else
      {:error, :invalid_token}
    end
  end

  def delete_with_token(_tenant_id, _token_id, _audit_opts), do: {:error, :invalid_token}

  @doc """
  Mint a single-use nonce for the oversized reconfirm path.

  When a delete selector exceeds the frozen-token bound, the dry-run returns
  `oversized: true` and mints a placeholder nonce row instead of a frozen-token.
  The nonce is consumed once on the reconfirm-on-drift path to prevent replays of
  the same set. Returns `{:ok, nonce_id}` or `{:error, reason}`.
  """
  @spec mint_reconfirm_nonce(Ecto.UUID.t()) :: {:ok, Ecto.UUID.t()} | {:error, term()}
  def mint_reconfirm_nonce(tenant_id) do
    expires_at = DateTime.add(DateTime.utc_now(), token_ttl_seconds(), :second)

    %BulkDeleteToken{tenant_id: tenant_id}
    |> BulkDeleteToken.create_changeset(%{
      type: "reconfirm_nonce",
      article_ids: [],
      expires_at: expires_at
    })
    |> AdminRepo.insert()
    |> case do
      {:ok, token} -> {:ok, token.id}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Consume a reconfirm nonce and delete over a re-resolved selector.

  For oversized selectors, the dry-run returns `oversized: true` and a nonce id.
  The real run re-resolves the selector, recomputes the hash, and compares it to
  the dry-run hash. If they match (no drift), the nonce is consumed (single-use)
  and the delete proceeds over the re-resolved ids. If the nonce is already used,
  expired, or missing, returns `{:error, :invalid_nonce}`. If hashes don't match
  (drift detected), returns `{:error, :hash_mismatch}`.
  """
  @spec delete_with_reconfirm(Ecto.UUID.t(), Ecto.UUID.t(), selector(), String.t(), audit_opts()) ::
          {:ok, %{affected: non_neg_integer(), resolved_count: non_neg_integer()}}
          | {:error, :invalid_nonce}
          | {:error, :hash_mismatch}
          | {:error, term()}
  def delete_with_reconfirm(tenant_id, nonce_id, selector, confirm_hash_value, audit_opts)
      when is_binary(nonce_id) do
    if valid_uuid?(nonce_id) do
      delete_with_reconfirm_valid(tenant_id, nonce_id, selector, confirm_hash_value, audit_opts)
    else
      {:error, :invalid_nonce}
    end
  end

  def delete_with_reconfirm(_tenant_id, _nonce_id, _selector, _confirm_hash, _audit_opts),
    do: {:error, :invalid_nonce}

  defp delete_with_reconfirm_valid(tenant_id, nonce_id, selector, confirm_hash_value, audit_opts) do
    with {:ok, ids} <- resolve_delete_selector(tenant_id, selector) do
      sorted = Enum.sort(ids)

      if confirm_hash(tenant_id, sorted) != confirm_hash_value do
        {:error, :hash_mismatch}
      else
        tenant_id
        |> delete_with_reconfirm_multi(nonce_id, sorted, audit_opts)
        |> run_multi(length(sorted))
      end
    end
  end

  @doc """
  Mint a reconfirm nonce for an oversized selector.

  Called by the preview path when the selector exceeds frozen_token_max.
  Returns the nonce id to be passed back to delete_with_reconfirm.
  """
  @spec mint_nonce_for_oversized(Ecto.UUID.t()) :: {:ok, Ecto.UUID.t()} | {:error, term()}
  def mint_nonce_for_oversized(tenant_id) do
    mint_reconfirm_nonce(tenant_id)
  end

  # Consume a reconfirm nonce and run the delete over re-resolved ids.
  # Similar to delete_with_token but uses a different nonce type and doesn't
  # freeze the article_ids (they are re-resolved on each call for drift detection).
  defp delete_with_reconfirm_multi(tenant_id, nonce_id, article_ids, audit_opts) do
    now = DateTime.utc_now()

    consume_query =
      from(t in BulkDeleteToken,
        where:
          t.id == ^nonce_id and t.tenant_id == ^tenant_id and t.type == "reconfirm_nonce" and
            is_nil(t.used_at) and t.expires_at > ^now
      )

    timeout_multi()
    |> Multi.update_all(:consume_nonce, consume_query, set: [used_at: now])
    |> Multi.run(:assert_consumed, fn _repo, %{consume_nonce: {count, _returned}} ->
      if count == 1, do: {:ok, :consumed}, else: {:error, :invalid_nonce}
    end)
    |> Multi.merge(fn _changes ->
      append_delete_steps(
        Multi.new(),
        tenant_id,
        article_ids,
        %{nonce: nonce_id, resolved_count: length(article_ids)},
        audit_opts
      )
    end)
  end

  @doc """
  Hash of a sorted id-set, for the re-confirm-on-drift path used when a delete
  selector exceeds the frozen-token bound.

  The dry-run echoes this hash to the client; the real run re-resolves the
  selector and recomputes it, refusing (drift) if they differ. HMAC-SHA256 over
  the canonical (sorted, comma-joined) id list, keyed by the per-tenant confirm
  secret — same server-minted trust model as the frozen token (never trusted as
  a target, only compared for equality).
  """
  @spec confirm_hash(Ecto.UUID.t(), [Ecto.UUID.t()]) :: String.t()
  def confirm_hash(tenant_id, ids) do
    canonical = ids |> Enum.sort() |> Enum.join(",")

    :hmac
    |> :crypto.mac(:sha256, confirm_secret(tenant_id), canonical)
    |> Base.encode16(case: :lower)
  end

  @doc """
  Resolve a selector to a bounded, tenant-scoped, active-only id-set.

  Exposed so the controller can re-resolve a selector for the re-confirm-on-drift
  path. Returns `{:ok, ids}` / `{:error, :too_many}` / `{:error, :bad_request, _}`.
  """
  @spec resolve_selector(Ecto.UUID.t(), selector()) ::
          {:ok, [Ecto.UUID.t()]} | {:error, :too_many} | {:error, :bad_request, String.t()}
  def resolve_selector(tenant_id, {:ids, ids}) when is_list(ids) do
    resolve_ids_selector(tenant_id, ids)
  end

  def resolve_selector(tenant_id, {:tag, tag}) when is_binary(tag) do
    Knowledge.list_archivable_ids(tenant_id, tags: [tag])
  end

  def resolve_selector(tenant_id, {:source, %{source_id: source_id} = sel})
      when is_binary(source_id) do
    # Thread BOTH source_id and source_type so the combined filter matches the
    # shipped contract (a source_id whose source_type differs must NOT match).
    # list_archivable_ids already supports :source_type (knowledge.ex).
    opts =
      case Map.get(sel, :source_type) do
        st when is_binary(st) -> [source_id: source_id, source_type: st]
        _ -> [source_id: source_id]
      end

    Knowledge.list_archivable_ids(tenant_id, opts)
  end

  def resolve_selector(tenant_id, {:source, source_id}) when is_binary(source_id) do
    Knowledge.list_archivable_ids(tenant_id, source_id: source_id)
  end

  def resolve_selector(_tenant_id, _selector) do
    {:error, :bad_request, "Unsupported selector. Use {:ids, [..]}, {:tag, _}, or {:source, _}."}
  end

  @doc """
  Resolve a selector for a HARD delete (#266).

  A hard delete PURGES tombstones, so for an EXPLICIT `{:ids, [..]}` selector it
  must reach `:archived`/`:superseded` rows too — otherwise the natural two-phase
  "archive → then hard-purge" flow is impossible (archiving first makes the row
  unreachable by `resolve_selector/2`, whose id-list path is active-only). The
  id-list is explicit user intent, so widening it to all lifecycle statuses is
  safe and expected.

  The tag/source selectors deliberately DELEGATE to `resolve_selector/2` (still
  active-only): a broad tag/query purge that silently swept archived rows would
  be a surprise-purge. Only the explicit id-list is widened.

  Same bounds/tenant-scoping/return shape as `resolve_selector/2`.
  """
  @spec resolve_delete_selector(Ecto.UUID.t(), selector()) ::
          {:ok, [Ecto.UUID.t()]} | {:error, :too_many} | {:error, :bad_request, String.t()}
  def resolve_delete_selector(tenant_id, {:ids, ids}) when is_list(ids) do
    resolve_ids_selector(tenant_id, ids, :all)
  end

  def resolve_delete_selector(tenant_id, selector) do
    resolve_selector(tenant_id, selector)
  end

  # --- transition (archive / unpublish) ---

  defp transition(tenant_id, selector, target, from_statuses, audit_action, audit_opts) do
    with {:ok, ids} <- resolve_selector(tenant_id, selector) do
      tenant_id
      |> transition_multi(ids, target, from_statuses, audit_action, selector, audit_opts)
      |> run_multi(length(ids))
    end
  end

  defp transition_multi(tenant_id, ids, target, from_statuses, audit_action, selector, audit_opts) do
    now = DateTime.utc_now()

    update_query =
      from(a in Article,
        where: a.tenant_id == ^tenant_id and a.id in ^ids and a.status in ^from_statuses
      )

    timeout_multi()
    |> Multi.update_all(:articles, update_query, set: [status: target, updated_at: now])
    |> Audit.log_in_multi(:audit, fn %{articles: {affected, _}} ->
      bulk_audit_attrs(tenant_id, audit_action, selector, affected, audit_opts)
    end)
  end

  # --- delete ---

  defp delete_multi(tenant_id, ids, selector_summary, audit_opts) do
    timeout_multi()
    |> append_delete_steps(tenant_id, ids, selector_summary, audit_opts)
  end

  # Token path: the consume is the ATOMIC GATE. A single guarded `update_all`
  # stamps `used_at` ONLY when the token is unused, unexpired, and in-tenant —
  # and the query's `select: t.article_ids` hands back the FROZEN id-set from the
  # SAME statement's RETURNING, so there is NO separate unlocked read of
  # `used_at` for a racing caller to slip past. `:assert_consumed` then refuses
  # unless exactly one row was stamped (the loser of a double-spend race sees 0
  # rows → invalid). All in ONE transaction so a later delete failure
  # un-consumes the token.
  defp delete_with_token_multi(tenant_id, token_id, audit_opts) do
    now = DateTime.utc_now()

    consume_query =
      from(t in BulkDeleteToken,
        where:
          t.id == ^token_id and t.tenant_id == ^tenant_id and is_nil(t.used_at) and
            t.expires_at > ^now,
        select: t.article_ids
      )

    timeout_multi()
    |> Multi.update_all(:consume_token, consume_query, set: [used_at: now])
    |> Multi.run(:assert_consumed, fn _repo, %{consume_token: {count, returned}} ->
      case {count, returned} do
        {1, [article_ids]} -> {:ok, article_ids}
        _ -> {:error, :invalid_token}
      end
    end)
    |> Multi.merge(fn %{assert_consumed: article_ids} ->
      append_delete_steps(
        Multi.new(),
        tenant_id,
        article_ids,
        %{token: token_id, ids: article_ids},
        audit_opts
      )
    end)
  end

  # Shared delete steps: links FIRST (both directions, tenant-scoped — the
  # :restrict FK aborts otherwise, AC-27.12.2), then the articles
  # (article_access_events cascade on delete), then the single audit event.
  #
  # The link cleanup is SPLIT into two single-column `delete_all`s
  # (`:links_src` on source_article_id, `:links_tgt` on target_article_id). A
  # single `delete_all` with `source_article_id IN ^ids OR target_article_id IN
  # ^ids` is an OR across two columns, which the planner cannot satisfy with the
  # per-column btree indexes — it degrades to a sequential scan at scale. Two
  # single-column statements each use their own index. Both run in the SAME
  # transaction so atomicity holds (AC-27.12.4); a link matching both directions
  # is simply already gone by the second statement (DELETE is idempotent on the
  # missing row). Links still precede the article delete (load-bearing order).
  defp append_delete_steps(multi, tenant_id, ids, selector_summary, audit_opts) do
    links_src_query =
      from(l in ArticleLink,
        where: l.tenant_id == ^tenant_id and l.source_article_id in ^ids
      )

    links_tgt_query =
      from(l in ArticleLink,
        where: l.tenant_id == ^tenant_id and l.target_article_id in ^ids
      )

    articles_query = from(a in Article, where: a.tenant_id == ^tenant_id and a.id in ^ids)

    multi
    |> Multi.delete_all(:links_src, links_src_query)
    |> Multi.delete_all(:links_tgt, links_tgt_query)
    |> Multi.delete_all(:articles, articles_query)
    |> Audit.log_in_multi(:audit, fn %{articles: {affected, _}} ->
      bulk_audit_attrs(tenant_id, "article.bulk_deleted", selector_summary, affected, audit_opts)
    end)
  end

  # --- shared helpers ---

  # First step of every op's Multi: scope a SET LOCAL statement_timeout to THIS
  # transaction (blast-radius bound, AC-27.12.5). Issued inside the tx via the
  # repo handed to the Multi so the GUC override holds for the whole transaction.
  # The prior value is captured and put back by `run_multi/2`'s last step, because
  # `SET LOCAL` outlives a COMMITTED savepoint (see `Loopctl.LocalGuc`).
  # `LocalGuc`'s own docs name the hand-paired capture/restore form as the open leak, and
  # this was the last call site still using it: `capture/2` degrades a backend failure to
  # `[]`, the `SET LOCAL` below was issued regardless, and `restore/2` on `[]` is a silent
  # no-op — so the override outlived the COMMITTED savepoint and leaked onto the pooled
  # connection for whatever ran next.
  #
  # We ask for exactly one GUC, and `statement_timeout` always exists, so a successful
  # capture ALWAYS yields one pair. An empty list is therefore unambiguously a failed
  # capture, and the Multi aborts BEFORE the override is set rather than setting one it
  # cannot take back. Failing the bulk op is the right side to err on: a capture that could
  # not complete means the connection is already in trouble, and the alternative — running
  # unbounded — silently drops the blast-radius bound of AC-27.12.5.
  #
  # The abort reason is a `DBConnection.ConnectionError`, NOT a bespoke atom: `run_multi/2`
  # surfaces a `Multi.run` error verbatim and the bulk controllers pass an unrecognised one
  # straight to `LoopctlWeb.FallbackController`, which has no catch-all — a new atom there is
  # a `FunctionClauseError` (an unstructured 500) instead of a mapped response. This IS a
  # connection failure, so the US-27.3 mapping already renders it as 503 + Retry-After.
  #
  # Named once, so the capture here and the pop in `run_multi/2` cannot drift.
  @timeout_guc ["statement_timeout"]

  # How many ownership entries bulk ops have pushed on THIS process and not yet popped.
  # Incremented here (where `capture/2` pushes, and ONLY on success) and decremented by
  # `:restore_timeout` (whose `restore/2` pops), so `run_multi/2` decides from OBSERVED state
  # rather than from the outcome shape — a raise can land BEFORE the push (pool checkout,
  # BEGIN) or AFTER the pop (COMMIT), and popping in either case takes an ENCLOSING scope's
  # entry. A DEPTH, not a boolean: a boolean cannot represent nesting, so a bulk op running
  # inside another's Multi on the same process would have its inner cleanup consume the flag
  # and leave the outer's entry alive forever. `run_multi/2` compares against the depth it
  # observed on entry, so each call pops exactly its own.
  @timeout_pushed_key {__MODULE__, :timeout_guc_depth}

  defp pushed_depth, do: Process.get(@timeout_pushed_key, 0)

  defp put_pushed_depth(depth) when depth <= 0, do: Process.delete(@timeout_pushed_key)
  defp put_pushed_depth(depth), do: Process.put(@timeout_pushed_key, depth)

  defp timeout_multi do
    Multi.run(Multi.new(), :set_timeout, fn repo, _changes ->
      case LocalGuc.capture(repo, @timeout_guc) do
        [_ | _] = prior ->
          put_pushed_depth(pushed_depth() + 1)
          repo.query!("SET LOCAL statement_timeout = #{statement_timeout_ms()}")
          {:ok, prior}

        [] ->
          {:error,
           %DBConnection.ConnectionError{
             message: "could not capture statement_timeout for this bulk operation"
           }}
      end
    end)
  end

  # Run a built Multi in one AdminRepo transaction and unwrap to the public shape.
  # A `Multi.run` `{:error, reason}` (e.g. an invalid token) surfaces as
  # `{:error, reason}`. A raw FK abort from delete_all raises a Postgrex.Error;
  # the transaction is already rolled back, and we map it to `{:error, exception}`
  # so callers get the atomicity guarantee without a leaked stacktrace.
  defp run_multi(multi, resolved_count \\ nil) do
    multi =
      Multi.run(multi, :restore_timeout, fn repo, %{set_timeout: prior} ->
        restored = LocalGuc.restore(repo, prior)
        put_pushed_depth(pushed_depth() - 1)
        {:ok, restored}
      end)

    depth_before = pushed_depth()

    try do
      case AdminRepo.transaction(multi, timeout: transaction_timeout_ms()) do
        {:ok, %{articles: {affected, _}}} ->
          {:ok, %{affected: affected, resolved_count: resolved_count || affected}}

        {:error, _step, reason, _changes} ->
          {:error, reason}
      end
    rescue
      e in [Postgrex.Error, DBConnection.ConnectionError] -> {:error, e}
    after
      # `:restore_timeout` is the LAST step, so `Ecto.Multi` SKIPS it the moment an earlier one
      # errors (an invalid token, an FK abort), and a raising `delete_all` bypasses it entirely.
      # The rollback discards the `SET LOCAL` itself, so nothing needs putting back — but the
      # ownership entry `capture/2` pushed would OUTLIVE the transaction on this process, which
      # Bandit reuses across keep-alive requests, and make a later `LocalGuc.scoped/3` abort a
      # read over an enclosing scope that no longer exists.
      #
      # In an `after`, so EVERY exit path passes: the two rescued structs, an exception outside
      # them (a changeset raise in the audit step, a `MatchError` in a `Multi.run` body), a
      # Postgrex EXIT from a wedged pool, a throw.
      #
      # The depth is compared against `depth_before` (read on entry), so the pop happens
      # exactly once and only when THIS call's push is still outstanding — correct whether or
      # not another bulk op encloses this one. Both "pushed nothing" (a `[]` capture; a raise
      # at checkout or BEGIN, before `:set_timeout` ran) and "already popped"
      # (`:restore_timeout` ran — including when the COMMIT itself then failed) leave the depth
      # back at `depth_before`. Popping in either case would take an ENCLOSING scope's entry,
      # since `restore/2` and `forget/1` both pop via `list -- names`, one occurrence. That
      # scope would then look unowned, and a later nested capture failure would take
      # `capture_fallback!/2`'s RESET branch rather than its ABORT branch — clobbering the
      # outer read's deliberate `statement_timeout` instead of refusing, the exact leak
      # `LocalGuc` exists to prevent.
      if pushed_depth() > depth_before do
        LocalGuc.forget(@timeout_guc)
        put_pushed_depth(depth_before)
      end
    end
  end

  defp bulk_audit_attrs(tenant_id, action, selector_summary, affected, audit_opts) do
    %{
      tenant_id: tenant_id,
      entity_type: "article_bulk",
      # A set op has no single entity; use the tenant id as the entity anchor so
      # the immutable-audit NOT NULL entity_id holds, and carry the real detail in
      # metadata (selector summary + affected count + actor).
      entity_id: tenant_id,
      action: action,
      actor_type: Keyword.get(audit_opts, :actor_type, "api_key"),
      actor_id: Keyword.get(audit_opts, :actor_id),
      actor_label: Keyword.get(audit_opts, :actor_label),
      metadata: %{
        "selector" => summarize_selector(selector_summary),
        "affected_count" => affected
      }
    }
  end

  defp summarize_selector({:ids, ids}), do: %{"type" => "ids", "count" => length(ids)}
  defp summarize_selector({:tag, tag}), do: %{"type" => "tag", "tag" => tag}

  defp summarize_selector({:source, %{source_id: source_id} = sel}),
    do:
      %{"type" => "source", "source_id" => source_id}
      |> maybe_put_source_type(Map.get(sel, :source_type))

  defp summarize_selector({:source, source_id}),
    do: %{"type" => "source", "source_id" => source_id}

  # Token-path delete: record the FROZEN id COUNT alongside the token id. The
  # token id alone is a weak forensic record of an IRREVERSIBLE delete; the
  # frozen count is the load-bearing "how many rows did this token authorize"
  # detail. We record the count (not the full id list) to keep audit metadata
  # bounded — the frozen set can be up to bulk_delete_frozen_max ids.
  defp summarize_selector(%{token: token_id, ids: ids}),
    do: %{"type" => "token", "token" => token_id, "count" => length(ids)}

  defp summarize_selector(%{ids: ids}), do: %{"type" => "ids", "count" => length(ids)}

  defp summarize_selector(%{nonce: nonce_id, resolved_count: resolved_count}),
    do: %{"type" => "nonce", "nonce" => nonce_id, "resolved_count" => resolved_count}

  defp maybe_put_source_type(map, st) when is_binary(st), do: Map.put(map, "source_type", st)
  defp maybe_put_source_type(map, _), do: map

  # The :ids selector resolves tenant-scoped ids, capped at 5000. Foreign /
  # cross-tenant ids are filtered out by the tenant_id AND id IN guard.
  #
  # `status_scope`:
  #   * `:active` (default) — draft/published only, for archive/unpublish and the
  #     active-only `resolve_selector/2`. Matches list_archivable_ids.
  #   * `:all` — every lifecycle status, for a HARD delete by explicit id-list
  #     (#266): a purge targets archived/superseded tombstones too.
  defp resolve_ids_selector(tenant_id, ids, status_scope \\ :active) do
    queryable = sanitize_ids(ids)

    matched =
      from(a in Article,
        where: a.tenant_id == ^tenant_id and a.id in ^queryable,
        select: a.id,
        limit: ^(bulk_max() + 1)
      )
      |> scope_ids_statuses(status_scope)
      |> AdminRepo.all()

    if length(matched) > bulk_max(), do: {:error, :too_many}, else: {:ok, matched}
  end

  defp scope_ids_statuses(query, :all), do: query

  defp scope_ids_statuses(query, :active),
    do: from(a in query, where: a.status in ^@archivable_statuses)

  defp mint_token!(tenant_id, ids) do
    expires_at = DateTime.add(DateTime.utc_now(), token_ttl_seconds(), :second)

    %BulkDeleteToken{tenant_id: tenant_id}
    |> BulkDeleteToken.create_changeset(%{article_ids: ids, expires_at: expires_at})
    |> AdminRepo.insert!()
  end

  # Drop non-binary junk and non-UUID strings up front so `id in ^ids` never
  # raises on cast (foreign/malformed ids resolve to "no match").
  defp sanitize_ids(ids) do
    ids
    |> List.wrap()
    |> Enum.filter(&valid_uuid?/1)
    |> Enum.uniq()
  end

  defp valid_uuid?(id) when is_binary(id), do: match?({:ok, _}, Ecto.UUID.cast(id))
  defp valid_uuid?(_), do: false

  # --- config ---

  defp statement_timeout_ms,
    do: Application.get_env(:loopctl, :bulk_op_statement_timeout_ms, 10_000)

  defp transaction_timeout_ms,
    do: Application.get_env(:loopctl, :bulk_op_transaction_timeout_ms, 15_000)

  defp frozen_token_max,
    do: Application.get_env(:loopctl, :bulk_delete_frozen_max, 1_000)

  defp token_ttl_seconds,
    do: Application.get_env(:loopctl, :bulk_delete_token_ttl_seconds, 300)

  # The selector cap (mirrors Knowledge.list_archivable_ids / @bulk_publish_max).
  defp bulk_max, do: 5_000

  # Per-tenant confirm secret for the re-confirm-on-drift hash. Derived from the
  # app secret_key_base + tenant_id so it's stable across nodes without storing a
  # separate per-tenant key. NEVER trusted as a delete target — only compared.
  #
  # FAIL CLOSED: `secret_key_base` is fetched, not defaulted — signing a confirm
  # hash with a guessable constant would let a caller forge a drift-confirm. The
  # raise is unreachable in every real env (runtime.exs requires SECRET_KEY_BASE;
  # test/dev configs set it). Mirrors `Loopctl.Knowledge.ArticleCursor.secret/1`.
  defp confirm_secret(tenant_id) do
    base =
      :loopctl
      |> Application.fetch_env!(LoopctlWeb.Endpoint)
      |> Keyword.fetch!(:secret_key_base)

    base <> ":" <> to_string(tenant_id)
  end
end
