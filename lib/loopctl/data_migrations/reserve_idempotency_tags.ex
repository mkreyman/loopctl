defmodule Loopctl.DataMigrations.ReserveIdempotencyTags do
  @moduledoc """
  #583 — moves pre-reservation idempotency tags into the reserved namespace.

  Articles captured before the namespace was reserved carry the bare
  `<family>-<digest>` form (`url-7ebe1ca33431`). This adds each one's reserved
  counterpart (`idem-url-7ebe1ca33431`), leaving every other tag untouched — the
  bare form has no prefix to recognise, so it is recognised by shape: a known
  source family plus a 12- or 40-char lowercase hex digest. Both halves must
  match, so `url-design` is left alone (not a digest) and so is `commit-<sha>` or
  `release-202604150930` (not a source family) — see
  `Loopctl.Knowledge.IdempotencyTag.legacy?/1`.

  Re-running is a no-op: a reserved tag is not legacy-shaped, so it is never
  promoted a second time and never double-prefixed.

  ## Where this runs, and why it is not a Mix task

  This module carries the logic and **never references `Mix`**, because `:mix` does
  not exist in a compiled release and this is exactly the work you want to run in
  production. `Loopctl.Release.reserve_idempotency_tags/1` is the production entry
  point and `mix loopctl.reserve_idempotency_tags` is the development one; both
  delegate here. The rule and its failure mode are the same ones home_care_billing
  wrote up after `mix hcb.plans.unmerge_per_service` could not be run against prod
  data — `Code.ensure_loaded?(Mix) == false` there, and the task reported through
  `Mix.shell/0`. `test/loopctl/data_migrations/reserve_idempotency_tags_test.exs`
  reads this module's compiled `:imports` chunk and fails if `Mix` reappears.

  Running it anywhere else is a performance decision, not a style one: the sweep
  issues one compare-and-set UPDATE per changed row, so its cost is a network round
  trip per row. Measured 2026-08-22 against the hosted corpus: ~6.4 rows/s over a
  `fly proxy` from a laptop — about three hours for 68,544 rows — against seconds
  from inside the datacenter.

  Runs on `Loopctl.AdminRepo` — a cross-tenant maintenance write has no
  request-scoped tenant to set RLS from, and every page is still explicitly
  tenant-ordered and tenant-filterable.
  """

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Knowledge.Article
  alias Loopctl.Knowledge.IdempotencyTag

  @default_batch_size 500
  @default_throttle_ms 50

  @doc """
  Promote every legacy idempotency tag in scope. Dry run unless `apply: true`.

  Returns `%{scanned:, changed:, skipped_tag_cap:, applied?:}`.
  """
  @spec backfill(keyword()) :: %{
          scanned: non_neg_integer(),
          changed: non_neg_integer(),
          skipped_tag_cap: non_neg_integer(),
          applied?: boolean()
        }
  def backfill(opts \\ []) do
    state = %{
      applied?: Keyword.get(opts, :apply, false),
      drop_legacy?: Keyword.get(opts, :drop_legacy, false),
      batch_size: Keyword.get(opts, :batch_size, @default_batch_size),
      throttle_ms: Keyword.get(opts, :throttle, @default_throttle_ms),
      tenant_id: Keyword.get(opts, :tenant),
      scanned: 0,
      changed: 0,
      skipped_tag_cap: 0
    }

    sweep(state, nil)
  end

  # Keyset pagination on the primary key: a whole-corpus tag rewrite must not
  # hold one transaction (or one OFFSET scan) across ~10^5 rows.
  defp sweep(state, after_id) do
    rows = page(state, after_id)

    case rows do
      [] ->
        Map.take(state, [:scanned, :changed, :skipped_tag_cap, :applied?])

      rows ->
        state = Enum.reduce(rows, state, &process_row/2)
        if state.throttle_ms > 0, do: Process.sleep(state.throttle_ms)
        sweep(state, List.last(rows).id)
    end
  end

  defp page(state, after_id) do
    Article
    |> select([a], %{id: a.id, tenant_id: a.tenant_id, tags: a.tags})
    |> order_by([a], asc: a.id)
    |> limit(^state.batch_size)
    |> then(fn q -> if after_id, do: where(q, [a], a.id > ^after_id), else: q end)
    |> then(fn q ->
      if state.tenant_id, do: where(q, [a], a.tenant_id == ^state.tenant_id), else: q
    end)
    |> AdminRepo.all()
  end

  defp process_row(row, state) do
    state = %{state | scanned: state.scanned + 1}
    tags = row.tags || []
    promoted = IdempotencyTag.promote_tags(tags, drop_legacy: state.drop_legacy?)

    cond do
      # Compared against the DEDUPED list, not the raw one: promote_tags/2 ends
      # in Enum.uniq/1 and nothing dedupes tags on write, so an article legally
      # holding ["elixir", "elixir"] and NO idempotency tag at all differs from
      # its promotion — which had this task rewrite a row it was never asked to
      # touch and count it under "with legacy idempotency tags".
      promoted == Enum.uniq(tags) ->
        state

      length(promoted) > Article.max_tags() ->
        state = %{state | skipped_tag_cap: state.skipped_tag_cap + 1}

        IO.puts(
          "skip #{row.id}: promoting would need #{length(promoted)} tags " <>
            "(cap #{Article.max_tags()})"
        )

        state

      true ->
        if state.applied?, do: write_tags(row, promoted)
        %{state | changed: state.changed + 1}
    end
  end

  # update_all, not a changeset: the promotion is computed above and every other
  # article field is untouched, so there is nothing left for a changeset to
  # validate — and `updated_at` deliberately stays put, because promoting a tag
  # is not a content edit and must not re-trigger embedding/linking.
  #
  # `a.tags == ^row.tags` makes this a compare-and-set against the value the page
  # read. This is a read-modify-write of a whole array over a live corpus, and a
  # `knowledge_update` (which REPLACES the tags array) landing between the page
  # read and this row's write would otherwise be silently clobbered by the stale
  # set. Losing the race is now a no-op the sweep reports and a re-run fixes,
  # rather than an agent's retag disappearing.
  #
  # Public (like `backfill/1`) only so the compare-and-set is testable with a stale
  # snapshot: the sweep's own read/write window cannot be hit from a test without
  # adding an injection seam to the sweep itself.
  @doc false
  @spec write_tags(%{id: Ecto.UUID.t(), tags: [String.t()] | nil}, [String.t()]) ::
          non_neg_integer()
  def write_tags(row, tags) do
    {count, _} =
      Article
      |> where([a], a.id == ^row.id and a.tags == ^(row.tags || []))
      |> AdminRepo.update_all(set: [tags: tags])

    if count == 0 do
      IO.puts("skip #{row.id}: tags changed concurrently, not promoted (re-run to fix)")
    end

    count
  end
end
