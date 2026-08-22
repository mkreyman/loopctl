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

  This task is the DEVELOPMENT entry point: it parses argv and delegates to
  `Loopctl.DataMigrations.ReserveIdempotencyTags.backfill/1`, which holds the logic
  and references no `Mix` at all.

  ## Against production, use the release entry point instead

      bin/loopctl eval "Loopctl.Release.reserve_idempotency_tags()"
      bin/loopctl eval "Loopctl.Release.reserve_idempotency_tags(apply: true)"

  `mix` does not exist in a compiled release, so this task cannot run there — and it
  should not, for a second reason: the sweep issues one compare-and-set UPDATE per
  changed row, so its cost is a network round trip per row. Measured 2026-08-22,
  ~6.4 rows/s over a `fly proxy` from a laptop — about three hours for 68,544 rows
  — against seconds from inside the datacenter. `Loopctl.Release` starts only
  `AdminRepo`, so it adds no second Oban node to a running deployment.

  Runs on `Loopctl.AdminRepo` — a cross-tenant maintenance write has no
  request-scoped tenant to set RLS from, and every page is still explicitly
  tenant-ordered and tenant-filterable.
  """

  use Mix.Task

  alias Loopctl.DataMigrations.ReserveIdempotencyTags
  alias Loopctl.Knowledge.Article

  @shortdoc "Promote legacy idempotency tags into the reserved idem- namespace"

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

    report = ReserveIdempotencyTags.backfill(opts)

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
end
