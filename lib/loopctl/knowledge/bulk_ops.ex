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
  - `{:source, source_id}` — every active article from that source id

  Foreign ids / cross-tenant selectors never match: every resolution and every
  mutation re-ANDs `tenant_id` (AC-27.12.6).

  ## Operations

  - `archive/3` — `:draft`/`:published` → `:archived` (reversible; links left
    intact but inert in published-only graph traversal, AC-27.12.3).
  - `unpublish/3` — `:published` → `:draft` (reversible).
  - `delete/3` / `delete_with_token/3` — irreversible HARD delete. FK-correct:
    `article_links` (both directions, tenant-scoped) are deleted FIRST in the
    same transaction or the `:restrict` FK aborts; `article_access_events`
    cascade automatically (`on_delete: :delete_all`).

  ## Atomicity & blast-radius

  Every op runs in one `AdminRepo.transaction` (BYPASSRLS, explicit tenant
  scoping) that first issues `SET LOCAL statement_timeout = <ms>` so a single
  large statement can't hold one of the small admin-pool connections
  indefinitely. The mutation + its dependent-link handling + the single audit
  event are all-or-nothing (AC-27.12.4).

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

  @archivable_statuses [:draft, :published]
  @unpublishable_statuses [:published]

  @type selector :: {:ids, [Ecto.UUID.t()]} | {:tag, String.t()} | {:source, Ecto.UUID.t()}
  @type op :: :archive | :unpublish | :delete
  @type audit_opts :: keyword()

  # --- public API ---

  @doc """
  Set-based archive: `:draft`/`:published` → `:archived` over the selected set.

  One `update_all` + one audit event in a single transaction. Idempotent — the
  `status in archivable` predicate makes a re-run a no-op. Returns
  `{:ok, %{affected: n}}`, or `{:error, :too_many}` if the selector exceeds the
  5000-row cap, or `{:error, :bad_request, msg}` for a malformed selector.
  """
  @spec archive(Ecto.UUID.t(), selector(), audit_opts()) ::
          {:ok, %{affected: non_neg_integer()}}
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
  `{:ok, %{affected: n}}` / `{:error, :too_many}` / `{:error, :bad_request, msg}`.
  """
  @spec unpublish(Ecto.UUID.t(), selector(), audit_opts()) ::
          {:ok, %{affected: non_neg_integer()}}
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
  cascade), then write one audit event. Returns `{:ok, %{affected: n}}` where `n`
  is the number of articles deleted.
  """
  @spec delete(Ecto.UUID.t(), [Ecto.UUID.t()], audit_opts()) ::
          {:ok, %{affected: non_neg_integer()}} | {:error, term()}
  def delete(tenant_id, frozen_ids, audit_opts) do
    ids = sanitize_ids(frozen_ids)

    tenant_id
    |> delete_multi(ids, %{ids: ids}, audit_opts)
    |> run_multi()
  end

  @doc """
  Dry-run preview. Resolves the selector to a bounded id-set and returns
  `{:ok, %{would_affect: n}}` (plus a `:token`/`:oversized` for `:delete`)
  WITHOUT mutating anything.

  - For `:archive`/`:unpublish` (reversible) — no token, just `would_affect`.
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
    with {:ok, ids} <- resolve_selector(tenant_id, selector) do
      sorted = Enum.sort(ids)
      n = length(sorted)

      if n <= frozen_token_max() do
        token = mint_token!(tenant_id, sorted)
        {:ok, %{would_affect: n, token: token.id, frozen_ids: sorted}}
      else
        {:ok, %{would_affect: n, token: nil, oversized: true, frozen_ids: sorted}}
      end
    end
  end

  @doc """
  Consume a frozen-set token and run the HARD delete over its FROZEN ids.

  In one transaction: load the token by `(id AND tenant_id)`; refuse
  (`{:error, :invalid_token}`) if missing / expired / already used / cross-tenant;
  stamp `used_at` (single-use); then run the `delete/3` Multi over
  `token.article_ids`. All-or-nothing — a failure anywhere rolls back the token
  consumption too.
  """
  @spec delete_with_token(Ecto.UUID.t(), Ecto.UUID.t(), audit_opts()) ::
          {:ok, %{affected: non_neg_integer()}} | {:error, :invalid_token} | {:error, term()}
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

  def resolve_selector(tenant_id, {:source, source_id}) when is_binary(source_id) do
    Knowledge.list_archivable_ids(tenant_id, source_id: source_id)
  end

  def resolve_selector(_tenant_id, _selector) do
    {:error, :bad_request, "Unsupported selector. Use {:ids, [..]}, {:tag, _}, or {:source, _}."}
  end

  # --- transition (archive / unpublish) ---

  defp transition(tenant_id, selector, target, from_statuses, audit_action, audit_opts) do
    with {:ok, ids} <- resolve_selector(tenant_id, selector) do
      tenant_id
      |> transition_multi(ids, target, from_statuses, audit_action, selector, audit_opts)
      |> run_multi()
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

  # Token path: load + integrity-check + single-use stamp, THEN the delete steps —
  # all in ONE transaction so a delete failure un-consumes the token (atomic).
  defp delete_with_token_multi(tenant_id, token_id, audit_opts) do
    now = DateTime.utc_now()

    timeout_multi()
    |> Multi.run(:token, fn repo, _changes ->
      token =
        from(t in BulkDeleteToken, where: t.id == ^token_id and t.tenant_id == ^tenant_id)
        |> repo.one()

      cond do
        is_nil(token) -> {:error, :invalid_token}
        not is_nil(token.used_at) -> {:error, :invalid_token}
        DateTime.compare(token.expires_at, now) != :gt -> {:error, :invalid_token}
        true -> {:ok, token}
      end
    end)
    |> Multi.update_all(
      :consume_token,
      fn _changes ->
        from(t in BulkDeleteToken, where: t.id == ^token_id and t.tenant_id == ^tenant_id)
      end,
      set: [used_at: now]
    )
    |> Multi.merge(fn %{token: token} ->
      append_delete_steps(
        Multi.new(),
        tenant_id,
        token.article_ids,
        %{token: token_id},
        audit_opts
      )
    end)
  end

  # Shared delete steps: links FIRST (both directions, tenant-scoped — the
  # :restrict FK aborts otherwise, AC-27.12.2), then the articles
  # (article_access_events cascade on delete), then the single audit event.
  defp append_delete_steps(multi, tenant_id, ids, selector_summary, audit_opts) do
    links_query =
      from(l in ArticleLink,
        where:
          l.tenant_id == ^tenant_id and
            (l.source_article_id in ^ids or l.target_article_id in ^ids)
      )

    articles_query = from(a in Article, where: a.tenant_id == ^tenant_id and a.id in ^ids)

    multi
    |> Multi.delete_all(:links, links_query)
    |> Multi.delete_all(:articles, articles_query)
    |> Audit.log_in_multi(:audit, fn %{articles: {affected, _}} ->
      bulk_audit_attrs(tenant_id, "article.bulk_deleted", selector_summary, affected, audit_opts)
    end)
  end

  # --- shared helpers ---

  # First step of every op's Multi: scope a SET LOCAL statement_timeout to THIS
  # transaction (blast-radius bound, AC-27.12.5). Issued inside the tx via the
  # repo handed to the Multi so the GUC override holds for the whole transaction.
  defp timeout_multi do
    Multi.run(Multi.new(), :set_timeout, fn repo, _changes ->
      repo.query!("SET LOCAL statement_timeout = #{statement_timeout_ms()}")
      {:ok, :set}
    end)
  end

  # Run a built Multi in one AdminRepo transaction and unwrap to the public shape.
  # A `Multi.run` `{:error, reason}` (e.g. an invalid token) surfaces as
  # `{:error, reason}`. A raw FK abort from delete_all raises a Postgrex.Error;
  # the transaction is already rolled back, and we map it to `{:error, exception}`
  # so callers get the atomicity guarantee without a leaked stacktrace.
  defp run_multi(multi) do
    case AdminRepo.transaction(multi) do
      {:ok, %{articles: {affected, _}}} -> {:ok, %{affected: affected}}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  rescue
    e in [Postgrex.Error, DBConnection.ConnectionError] -> {:error, e}
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

  defp summarize_selector({:source, source_id}),
    do: %{"type" => "source", "source_id" => source_id}

  defp summarize_selector(%{ids: ids}), do: %{"type" => "ids", "count" => length(ids)}
  defp summarize_selector(%{token: token_id}), do: %{"type" => "token", "token" => token_id}

  # The :ids selector resolves to active (draft/published), tenant-scoped ids,
  # capped at 5000 — consistent with archive/unpublish and list_archivable_ids.
  # Foreign / cross-tenant ids are filtered out by the tenant_id AND id IN guard.
  defp resolve_ids_selector(tenant_id, ids) do
    queryable = sanitize_ids(ids)

    matched =
      from(a in Article,
        where:
          a.tenant_id == ^tenant_id and a.id in ^queryable and
            a.status in ^@archivable_statuses,
        select: a.id,
        limit: ^(bulk_max() + 1)
      )
      |> AdminRepo.all()

    if length(matched) > bulk_max(), do: {:error, :too_many}, else: {:ok, matched}
  end

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
    do: Application.get_env(:loopctl, :bulk_op_statement_timeout_ms, 30_000)

  defp frozen_token_max,
    do: Application.get_env(:loopctl, :bulk_delete_frozen_max, 1_000)

  defp token_ttl_seconds,
    do: Application.get_env(:loopctl, :bulk_delete_token_ttl_seconds, 300)

  # The selector cap (mirrors Knowledge.list_archivable_ids / @bulk_publish_max).
  defp bulk_max, do: 5_000

  # Per-tenant confirm secret for the re-confirm-on-drift hash. Derived from the
  # app secret_key_base + tenant_id so it's stable across nodes without storing a
  # separate per-tenant key. NEVER trusted as a delete target — only compared.
  defp confirm_secret(tenant_id) do
    base =
      Application.get_env(:loopctl, LoopctlWeb.Endpoint, [])
      |> Keyword.get(:secret_key_base, "loopctl-bulk-delete-confirm")

    base <> ":" <> to_string(tenant_id)
  end
end
