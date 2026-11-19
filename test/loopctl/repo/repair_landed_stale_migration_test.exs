defmodule Loopctl.Repo.RepairLandedStaleMigrationTest do
  @moduledoc """
  The data repair in `20261119150000_repair_landed_stale_and_credential_abandoned_findings.exs`:
  it clears `stale` only on a landed change, and revives only an `open` action a missing
  credential abandoned before it made an issue. The migration is data-only, so it runs inside
  this test's sandbox transaction (`Ecto.Migration.Runner.run/9`, the pattern of
  `Loopctl.Repo.RunnerAgentBackfillMigrationTest`) and nothing it touches outlives the test.
  """

  use Loopctl.DataCase, async: true

  import Ecto.Query

  alias Ecto.Migration.Runner
  alias Loopctl.AdminRepo
  alias Loopctl.Changes.Cursor
  alias Loopctl.Changes.Event
  alias Loopctl.Changes.Finding
  alias Loopctl.Changes.FindingAction
  alias Loopctl.Repo.Migrations.RepairLandedStaleAndCredentialAbandonedFindings, as: Repair
  alias Loopctl.Test.MigrationFile

  @version 20_261_119_150_000

  MigrationFile.require!(Repair, @version)

  setup do
    %{source: source} = fixture(:chg_source, %{})
    %{source: source, tenant_id: source.tenant_id}
  end

  defp migrate_up,
    do:
      Runner.run(AdminRepo, AdminRepo.config(), @version, Repair, :forward, :up, :up, log: false)

  defp cursor!(ctx, attention) do
    now = DateTime.utc_now()

    AdminRepo.insert!(%Cursor{
      tenant_id: ctx.tenant_id,
      source_id: ctx.source.id,
      repo: "mkreyman/infra",
      change_id: "C" <> Integer.to_string(System.unique_integer([:positive])),
      applied_seq: 4,
      last_event_at: now,
      attention: attention,
      attention_at: now
    })
  end

  defp event!(%Cursor{} = cursor, kind, applied?) do
    now = DateTime.utc_now()

    AdminRepo.insert!(%Event{
      tenant_id: cursor.tenant_id,
      source_id: cursor.source_id,
      repo: cursor.repo,
      change_id: cursor.change_id,
      event_seq: 4,
      kind: kind,
      revision: 1,
      sha: String.duplicate("a", 40),
      occurred_at: now,
      received_via: "push",
      applied_at: if(applied?, do: now),
      routed: true
    })
  end

  defp attention(%Cursor{id: id}),
    do: AdminRepo.one(from c in Cursor, where: c.id == ^id).attention

  defp action!(ctx, attrs) do
    finding =
      AdminRepo.insert!(%Finding{
        tenant_id: ctx.tenant_id,
        kind: "selection_miss",
        repo_full_name: "mkreyman/chg",
        fingerprint: "fp-" <> Integer.to_string(System.unique_integer([:positive])),
        state: :filed,
        issue_number: Map.get(attrs, :finding_issue),
        first_seen_at: DateTime.utc_now(),
        last_seen_at: DateTime.utc_now()
      })

    AdminRepo.insert!(
      struct!(
        FindingAction,
        Map.merge(
          %{
            tenant_id: ctx.tenant_id,
            finding_id: finding.id,
            source_id: ctx.source.id,
            action: :open,
            generation: 0,
            cycle: 0,
            repo_full_name: "mkreyman/chg",
            title: "t",
            body: "b",
            status: :abandoned,
            abandoned_reason: "retries_exhausted",
            attempts: 6,
            last_error: ":credential_unavailable"
          },
          Map.delete(attrs, :finding_issue)
        )
      )
    )
  end

  defp status(%FindingAction{id: id}), do: AdminRepo.get!(FindingAction, id)

  test "stale is cleared on landed changes and kept on the others", ctx do
    landed = cursor!(ctx, "stale")
    event!(landed, "landed", true)

    held = cursor!(ctx, "stale")
    event!(held, "landed", false)

    quiet = cursor!(ctx, "stale")
    event!(quiet, "submitted", true)

    gapped = cursor!(ctx, "gap")
    event!(gapped, "landed", true)

    migrate_up()

    assert attention(landed) == nil
    assert attention(held) == "stale"
    assert attention(quiet) == "stale"
    assert attention(gapped) == "gap"
  end

  test "revives only an open a missing credential abandoned before it made an issue", ctx do
    revived = action!(ctx, %{})
    other_reason = action!(ctx, %{last_error: "{:github_api_error, 422}"})
    has_issue = action!(ctx, %{issue_number: 12, finding_issue: 12})
    permanent = action!(ctx, %{abandoned_reason: "permanent_forge_failure"})

    migrate_up()

    assert %FindingAction{status: :pending, attempts: 0, abandoned_reason: nil} = status(revived)
    assert %FindingAction{status: :abandoned} = status(other_reason)
    assert %FindingAction{status: :abandoned} = status(has_issue)
    assert %FindingAction{status: :abandoned} = status(permanent)
  end
end
