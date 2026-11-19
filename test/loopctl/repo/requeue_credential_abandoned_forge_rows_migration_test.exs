defmodule Loopctl.Repo.RequeueCredentialAbandonedForgeRowsMigrationTest do
  @moduledoc """
  The data repair in `20261119170000_requeue_credential_abandoned_forge_rows.exs` (#1058): a
  revert issue or an issue closure abandoned `retries_exhausted` while its last error was the
  missing credential goes back to `:pending`, and every other abandoned row stays. The migration
  is data-only, so it runs inside this test's sandbox transaction, as in
  `Loopctl.Repo.RepairLandedStaleMigrationTest`.
  """

  use Loopctl.DataCase, async: true

  import Ecto.Query

  alias Ecto.Migration.Runner
  alias Loopctl.AdminRepo
  alias Loopctl.Changes.RevertIssue
  alias Loopctl.Changes.RevertIssueOpener
  alias Loopctl.Changes.RevertIssues
  alias Loopctl.Delivery.ForgeRepo
  alias Loopctl.Intake.IssueClosure
  alias Loopctl.Repo
  alias Loopctl.Repo.Migrations.RequeueCredentialAbandonedForgeRows, as: Requeue
  alias Loopctl.Test.MigrationFile
  alias Loopctl.Verification.Credential

  @version 20_261_119_170_000

  MigrationFile.require!(Requeue, @version)

  setup do
    %{source: source} = fixture(:chg_source, %{})
    %{source: source, tenant_id: source.tenant_id}
  end

  defp migrate_up,
    do:
      Runner.run(AdminRepo, AdminRepo.config(), @version, Requeue, :forward, :up, :up, log: false)

  @credential ":credential_unavailable"

  defp abandon(schema, id, reason, last_error, age_days) do
    {1, _} =
      AdminRepo.update_all(from(r in schema, where: r.id == ^id),
        set: [
          status: :abandoned,
          abandoned_reason: reason,
          attempts: 6,
          last_error: last_error,
          updated_at: DateTime.add(DateTime.utc_now(), -age_days, :day)
        ]
      )
  end

  defp revert!(ctx, reason, last_error, age_days \\ 0) do
    story = fixture(:story, %{tenant_id: ctx.tenant_id})
    seq = System.unique_integer([:positive])

    {:ok, _} =
      Repo.with_tenant(ctx.tenant_id, fn ->
        RevertIssues.record_in(Repo, ctx.tenant_id, %{
          story_id: story.id,
          source_id: ctx.source.id,
          repo: "mkreyman/infra",
          change_id: "01JCHANGE",
          event_seq: seq,
          revision: 2,
          data: %{
            "landed_sha" => String.duplicate("a", 40),
            "revert_sha" => String.duplicate("b", 40),
            "revert_change_id" => "01JREVERT",
            "failures" => [],
            "verification_id" => "V7"
          }
        })
      end)

    row = AdminRepo.one!(from r in RevertIssue, where: r.story_id == ^story.id)
    abandon(RevertIssue, row.id, reason, last_error, age_days)
    row
  end

  defp closure!(ctx, reason, last_error, age_days) do
    story = fixture(:story, %{tenant_id: ctx.tenant_id})
    row = fixture(:issue_closure, %{tenant_id: ctx.tenant_id, story_id: story.id})
    abandon(IssueClosure, row.id, reason, last_error, age_days)
    row
  end

  # A revert row restarts at ONE attempt so its next claim searches for an issue an earlier
  # attempt may have opened; a closure reads its issue on every attempt and restarts at zero.
  test "requeues only recent rows the missing credential exhausted, in both outboxes", ctx do
    for {schema, make, restart} <- [{RevertIssue, &revert!/4, 1}, {IssueClosure, &closure!/4, 0}] do
      waited = make.(ctx, "retries_exhausted", @credential, 0)
      forge = make.(ctx, "retries_exhausted", "{:github_api_error, 503}", 0)
      permanent = make.(ctx, "permanent_forge_failure", @credential, 0)
      old = make.(ctx, "retries_exhausted", @credential, 15)

      migrate_up()

      assert %{status: :pending, attempts: ^restart, abandoned_reason: nil, next_attempt_at: nil} =
               AdminRepo.get!(schema, waited.id)

      assert %{status: :abandoned} = AdminRepo.get!(schema, forge.id)
      assert %{status: :abandoned} = AdminRepo.get!(schema, permanent.id)
      assert %{status: :abandoned} = AdminRepo.get!(schema, old.id)
    end
  end

  test "a requeued revert row searches before it creates, so it never opens a second issue",
       ctx do
    row = revert!(ctx, "retries_exhausted", @credential)
    migrate_up()

    stub(Loopctl.MockVerificationCredential, :for_read, fn _tenant_id, repo ->
      {:ok,
       %Credential{
         kind: :operator_token,
         repo: ForgeRepo.operator(repo)
       }}
    end)

    expect(Loopctl.MockPullRequestSource, :find_issue, fn _repo, _search -> {:ok, 77} end)
    expect(Loopctl.MockPullRequestSource, :create_issue, 0, fn _r, _t, _b -> {:ok, 1} end)

    assert {:opened, nil} =
             RevertIssueOpener.open(AdminRepo.get!(RevertIssue, row.id))
  end
end
