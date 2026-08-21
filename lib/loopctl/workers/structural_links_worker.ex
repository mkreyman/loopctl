defmodule Loopctl.Workers.StructuralLinksWorker do
  @moduledoc """
  Weekly, per-tenant harvest of `derived_from` star edges from source provenance
  (`Loopctl.Knowledge.StructuralLinks`, US-42.1).

  ## Why this is a separate change from the harvester

  US-42.1 shipped `harvest/2` callable and idempotent, and deliberately scheduled
  nothing. The recorded reason (story note, and the KB finding "self-signup permanently
  joins every all-tenants cron fan-out") is that the fan-out shape wanted deciding on its
  own rather than being inherited from whichever worker the harvest was folded into. This
  worker is that decision, and it makes three of them:

  * **Fan-out is per tenant, gated, and bounded by who has a corpus.** One dispatcher job
    enqueues one job per ACTIVE tenant THAT HAS A PUBLISHED ARTICLE, and each per-tenant
    job passes `FairShare.gate/3` before it touches the corpus — so a tenant with a large
    corpus cannot monopolise the shared `:knowledge` lane, which is the concern the story
    raised and `FairShare` already answers. The corpus predicate answers the other half,
    the one the recorded fan-out finding poses: see `harvestable_tenants/0`.
  * **A shed heavy read SNOOZES the tenant, it does not fail it.** `harvest/2` returns
    `{:error, :heavy_read_overloaded}` when the scan is shed, and binding that as a list
    would crash under exactly the load the shedder exists to relieve. A partial harvest is
    also not a usable answer: a source whose members straddle the shed boundary would be
    counted short and could fall under the floor, producing no hub for a source that
    qualifies. So the whole tenant retries later — but a BOUNDED number of times, because
    a snooze can never exhaust into `discarded` on its own. (Same reading as
    `DraftDuplicateSweepWorker`.)
  * **The unattended floor is higher than the library default.** See below.

  ## The floor: 25 here, 3 in the library

  `StructuralLinks.harvest/2` defaults to `:structural_hub_min_siblings` (3) — the floor
  US-42.1 specifies for a deliberate, explicit call. This worker reads its OWN key,
  `:structural_links_min_siblings`, defaulting to 25, exactly as `KnowledgeMocWorker`
  holds its own `:knowledge_moc_min_tag_count`.

  The difference is not an oversight, it is the measurement from the first production
  backfill (#725, hosted corpus, 2026-08-20):

  | floor | sources | edges | adopted | minted (new articles) |
  |---|---|---|---|---|
  | 25 | 313 | 39,040 | 72 | 241 |
  | 10 | 1,360 | 51,931 | 826 | 534 |
  | 3 | 3,713 | 66,567 | 1,568 | 2,145 |

  25 -> 3 buys 27,527 more edges and mints ~1,900 more hubs from the SMALLEST sources —
  where a universally-shared identifying tag is least likely, so the digest-named rate
  rises exactly where the volume does (`Source: doc a8d8cf71c5df` tells a reader nothing).
  An unattended weekly writer is the wrong place to take that trade unmeasured. Somewhere
  between 10 and 25 looks better than either end; re-measure per-floor on the live corpus
  before moving this, because the corpus grows.

  ## Cadence

  `0 6 * * 0` — Sunday, after the 05:00 `KnowledgeMocWorker` fan-out and the 05:50
  `DraftDuplicateSweepWorker`, so the three weekly `:knowledge` passes queue behind each
  other instead of contending for the same lane. Hub creation landing after the MOC run
  also means a hub minted this week is indexed by next week's MOC rather than half-way
  through one.

  ## Safety

  Additive only. The harvest creates hubs and edges and never mutates a member article,
  and it is idempotent — a second run over an unchanged corpus writes nothing (hubs
  resolve by `idempotency_key`, edges by the composite unique index). A weekly cadence is
  therefore a refresh, not an accumulation.
  """

  use Oban.Worker,
    queue: :knowledge,
    max_attempts: 3,
    unique: [fields: [:worker, :args], period: 300]

  import Ecto.Query

  require Logger

  alias Loopctl.AdminRepo
  alias Loopctl.Audit
  alias Loopctl.Knowledge.Article
  alias Loopctl.Oban.FairShare
  alias Loopctl.Tenants.Tenant

  @actor_label "worker:structural_links"

  # Compile-time DI (the convention for Oban workers here). The seam exists for the shed
  # branch below, which a sandboxed test database cannot produce on its own.
  @harvester Application.compile_env(
               :loopctl,
               :structural_links_harvester,
               Loopctl.Knowledge.StructuralLinks
             )

  # See the moduledoc — this is the UNATTENDED floor and it is deliberately not the
  # library default of 3.
  @default_min_siblings 25

  # A shed scan is a load signal, not a failure. Long enough that the retry lands after
  # the burst that shed it, short enough that a weekly pass still completes today.
  @shed_snooze_seconds 300

  # ...but BOUNDED. A snooze raises `max_attempts` in lockstep, so it can never exhaust
  # into `discarded` — the trap `.claude/skills/oban-health/SKILL.md` names outright: a
  # job gated on a permanently-wrong condition re-scans forever while nothing fails and
  # nothing alerts, and next Sunday's cron adds another (the 300s unique window does not
  # reach a week back). An hour of trying; past that the job is CANCELLED, which is
  # visible in Oban, and the weekly cron re-enqueues it.
  #
  # The bound is ELAPSED TIME, not `attempt`. `attempt` is the job-wide counter and the
  # FairShare branch in `perform/1` consumes it too, at a 5-10 second cadence against this
  # branch's 300s — so a cap of twelve ATTEMPTS cancelled the harvest after ~90 seconds of
  # ordinary queue contention, having never once been shed. The hour is what the bound was
  # always about, so it is measured directly off the job's own `inserted_at`.
  @max_shed_seconds 3600

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"mode" => "all_tenants"}}) do
    Enum.each(harvestable_tenants(), &enqueue_tenant/1)

    :ok
  end

  def perform(%Oban.Job{id: id, inserted_at: inserted_at, args: %{"tenant_id" => tenant_id}}) do
    # The dispatcher clause above is deliberately NOT gated — it carries no tenant_id.
    # `id` excludes THIS already-executing job from its own count (US-36.2).
    case FairShare.gate(tenant_id, :knowledge, id) do
      {:snooze, _n} = snooze -> snooze
      :ok -> harvest(tenant_id, inserted_at)
    end
  end

  # A dropped insert is a tenant that silently gets no harvest this week — the dispatcher
  # would still complete green, with no failed job row to find it by.
  defp enqueue_tenant(tenant_id) do
    case %{"tenant_id" => tenant_id} |> __MODULE__.new() |> Oban.insert() do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "structural_links_worker enqueue failed: tenant=#{tenant_id} " <>
            "reason=#{inspect(reason)} — no harvest for this tenant this week"
        )
    end
  end

  defp harvest(tenant_id, inserted_at) do
    case @harvester.harvest(tenant_id, min_siblings: min_siblings()) do
      {:error, :heavy_read_overloaded} ->
        shed(tenant_id, inserted_at)

      {:ok, report} ->
        log_audit(tenant_id, report)
        :ok
    end
  end

  defp shed(tenant_id, inserted_at) do
    if shed_budget_spent?(inserted_at) do
      Logger.error(
        "structural_links_worker still shedding after #{@max_shed_seconds}s: " <>
          "tenant=#{tenant_id} — cancelling rather than snoozing forever; the weekly cron " <>
          "re-enqueues"
      )

      {:cancel, :heavy_read_overloaded}
    else
      Logger.info(
        "structural_links_worker shed: tenant=#{tenant_id} reason=heavy_read_overloaded"
      )

      {:snooze, @shed_snooze_seconds}
    end
  end

  # A job with no `inserted_at` (a hand-built struct) has spent nothing — snooze.
  defp shed_budget_spent?(%DateTime{} = inserted_at),
    do: DateTime.diff(DateTime.utc_now(), inserted_at, :second) >= @max_shed_seconds

  defp shed_budget_spent?(_inserted_at), do: false

  # ACTIVE **and carrying a published article**. The recorded finding "self-signup
  # permanently joins every all-tenants cron fan-out — per-IP caps don't bound the growth"
  # closes with the test to apply to any NEW all-tenants worker: what set does it
  # enumerate, and what SHRINKS that set? Enumerating `status == :active` alone answers
  # "every tenant that ever signed up" and "nothing" — a scripted junk signup then costs a
  # job insert plus a scan every week, forever, for a corpus that does not exist.
  #
  # An empty tenant is exactly the one this worker has nothing to do for, so the EXISTS
  # probe is both the cheap answer and the correct one: no corpus, no hub, no job. It is a
  # per-tenant index probe on `articles`, not an enumeration of the corpus. It is the ONLY
  # AdminRepo query this worker itself issues; the harvest it schedules reads through
  # HeavyRead and touches AdminRepo only for its bounded, chunked edge writes.
  defp harvestable_tenants do
    published =
      from(a in Article,
        where: a.tenant_id == parent_as(:tenant).id,
        where: a.status == :published,
        select: 1
      )

    from(t in Tenant,
      as: :tenant,
      where: t.status == :active,
      where: exists(published),
      select: t.id
    )
    |> AdminRepo.all()
  end

  defp min_siblings do
    Application.get_env(:loopctl, :structural_links_min_siblings, @default_min_siblings)
  end

  # The report carries its own reconciliation verdict (`reconciled`), so recording it
  # verbatim is what makes a contaminated run auditable after the fact rather than only
  # visible in a log line that has since rotated. `StructuralLinks` already logs the
  # mismatch at :error; this is the durable copy.
  defp log_audit(tenant_id, report) do
    Audit.create_log_entry(tenant_id, %{
      entity_type: "knowledge_structural_links",
      entity_id: tenant_id,
      action: "knowledge.structural_links_harvested",
      actor_type: "system",
      actor_id: nil,
      actor_label: @actor_label,
      new_state: Map.new(report, fn {key, value} -> {to_string(key), value} end)
    })
  end
end
