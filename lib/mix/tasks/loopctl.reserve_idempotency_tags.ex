defmodule Mix.Tasks.Loopctl.ReserveIdempotencyTags do
  @moduledoc """
  #583 — moves pre-reservation idempotency tags into the reserved namespace.

  Articles captured before the namespace was reserved carry the bare
  `<family>-<digest>` form (`url-7ebe1ca33431`). This task adds each one's
  reserved counterpart (`idem-url-7ebe1ca33431`), leaving every other tag
  untouched — the bare form has no prefix to recognise, so it is recognised by
  shape: a known source family plus a 12- or 40-char lowercase hex digest.
  Both halves must match, so `url-design` is left alone (not a digest) and so is
  `commit-<sha>` or `release-202604150930` (not a source family) — see
  `Loopctl.Knowledge.IdempotencyTag.legacy?/1`.

  ## Usage

      mix loopctl.reserve_idempotency_tags                # dry run, whole corpus
      mix loopctl.reserve_idempotency_tags --apply        # write
      mix loopctl.reserve_idempotency_tags --apply --tenant <uuid>
      mix loopctl.reserve_idempotency_tags --apply --drop-legacy

  Options:

    * `--apply` — write. WITHOUT it the task only reports, which is the default
      because a tag rewrite is visible to every reader.
    * `--tenant <uuid>` — restrict to one tenant. Omitted, it sweeps all of them.
    * `--drop-legacy` — remove the bare tag once its reserved counterpart is
      present. This is the SECOND pass. Run it only after the client half
      (mkreyman/claude-config#222) has stopped querying the bare form; the
      first pass deliberately keeps both so existing dedup reads keep working
      through the changeover.
    * `--batch-size <n>` — rows per keyset page (default 500).
    * `--throttle <ms>` — sleep between pages (default 50).

  Re-running is a no-op: a reserved tag is not legacy-shaped, so it is never
  promoted a second time and never double-prefixed.

  Runs on `Loopctl.AdminRepo` — this is a cross-tenant maintenance write that
  has no request-scoped tenant to set RLS from, and every page is still
  explicitly tenant-ordered and tenant-filterable.
  """

  use Mix.Task

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Knowledge.Article
  alias Loopctl.Knowledge.IdempotencyTag

  @shortdoc "Promote legacy idempotency tags into the reserved idem- namespace"

  @default_batch_size 500
  @default_throttle_ms 50

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")

    {opts, rest, invalid} =
      OptionParser.parse(argv,
        strict: [
          apply: :boolean,
          tenant: :string,
          drop_legacy: :boolean,
          batch_size: :integer,
          throttle: :integer
        ]
      )

    abort_on_bad_argv!(rest, invalid)

    report = backfill(opts)

    Mix.shell().info(
      "#{if report.applied?, do: "applied", else: "dry run"}: " <>
        "#{report.scanned} article(s) scanned, #{report.changed} with legacy " <>
        "idempotency tags, #{report.skipped_tag_cap} skipped (would exceed the " <>
        "#{Article.max_tags()}-tag cap)"
    )

    report
  end

  # A discarded switch silently WIDENS this task: `--tenat <uuid>` leaves
  # `tenant_id` nil, page/2 omits the tenant predicate, and because the sweep
  # runs on AdminRepo (BYPASSRLS) that predicate is the only scoping there is —
  # so a typo turns a one-tenant promotion into a whole-install rewrite, and
  # with --drop-legacy a destructive one. Same for a mistyped --batch-size or
  # --throttle, which would silently fall back to the default.
  defp abort_on_bad_argv!(rest, invalid) do
    bad = Enum.map(invalid, fn {switch, _value} -> switch end) ++ rest

    if bad == [] do
      :ok
    else
      Mix.raise(
        "unrecognised argument(s): #{Enum.join(bad, ", ")}. Refusing to run — an " <>
          "ignored --tenant would sweep every tenant. Valid switches: --apply, " <>
          "--tenant <uuid>, --drop-legacy, --batch-size <n>, --throttle <ms>."
      )
    end
  end

  @doc """
  The task body, callable without `Mix.Task.run/2` so it can be tested directly.

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

        Mix.shell().info(
          "skip #{row.id}: promoting would need #{length(promoted)} tags " <>
            "(cap #{Article.max_tags()})"
        )

        state

      true ->
        if state.applied?, do: write_tags(row.id, promoted)
        %{state | changed: state.changed + 1}
    end
  end

  # update_all, not a changeset: the promotion is computed above and every other
  # article field is untouched, so there is nothing left for a changeset to
  # validate — and `updated_at` deliberately stays put, because promoting a tag
  # is not a content edit and must not re-trigger embedding/linking.
  defp write_tags(id, tags) do
    Article
    |> where([a], a.id == ^id)
    |> AdminRepo.update_all(set: [tags: tags])
  end
end
