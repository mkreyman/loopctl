defmodule Loopctl.Repo.Migrations.AddVerifiedHeadShaAndVerifyKind do
  @moduledoc """
  `verify@1` (Epic 48, US-48.18): control verifies a pr-route story at `ci` through an
  independently rooted verifier dispatch.

  ## `story_stages.verified_head_sha`

  The head a verification was made AT. `stories.verified_status` says a story was verified;
  it does not say which commit, so a story verified at head X that went back to work and
  returned to `ci` at Y read as verified at Y. Control records the head here, at `ci`, through
  `Loopctl.Delivery.Stages.record_effect/5` once the verdict's report, review and verify have
  committed. It is HEAD-KEYED (`StageMachine.head_keyed/0`): every edge that clears `head_sha`
  clears it, and `Loopctl.Delivery.MergePrecondition` refuses a story whose verified head is not
  its recorded head (`:verified_for_other_head`). The same sha CHECK as the other heads.

  ## `runner_dispatches_kind` gains `verify`

  The ledger's kind CHECK is held equal to the registry and `RunnerContract.Kinds.all/0` by
  `Loopctl.Agents.RegistryTest`, so it widens in the release that adds the spec. Widening a
  CHECK refuses nothing an older release writes.

  No backfill and no manual step: the column starts NULL, which reads as "verified at no head",
  so a story verified before this release is verified again at its head before it can merge.
  """

  use Ecto.Migration

  @sha "'^[0-9a-f]{40}([0-9a-f]{24})?$'"

  def up do
    alter table(:story_stages) do
      add :verified_head_sha, :text, null: true
    end

    create constraint(:story_stages, :story_stages_verified_head_sha,
             check: "verified_head_sha ~ #{@sha}"
           )

    drop constraint(:runner_dispatches, :runner_dispatches_kind)

    create constraint(:runner_dispatches, :runner_dispatches_kind,
             check: "kind IN ('triage', 'implement', 'reply_draft', 'verify')"
           )
  end

  def down do
    execute("DELETE FROM runner_dispatches WHERE kind = 'verify'")
    drop constraint(:runner_dispatches, :runner_dispatches_kind)

    create constraint(:runner_dispatches, :runner_dispatches_kind,
             check: "kind IN ('triage', 'implement', 'reply_draft')"
           )

    drop constraint(:story_stages, :story_stages_verified_head_sha)

    alter table(:story_stages) do
      remove :verified_head_sha
    end
  end
end
