defmodule Loopctl.Repo.Migrations.AddChannelPostsQuarantineRelease do
  use Ecto.Migration

  @moduledoc """
  Operator RELEASE marker for a quarantined channel post (issue #499 review follow-up).

  The quarantine introduced in `20260722140000` is deliberately NOT a delete, because the
  denylist is a prefix HEURISTIC and a false positive must be recoverable. That rationale
  only holds if an operator can actually EXONERATE a post — otherwise quarantine is a
  delayed delete with extra steps (the row lives on, invisible to every reader, until the
  TTL sweep reclaims it).

    * `quarantine_released_at` — set by `Loopctl.Coordination.release_post/5` (role
      `:user`, audited). Clearing `quarantined_at` alone would not be durable: the next
      rescan under the SAME pattern set would immediately re-flag the row. A non-NULL
      stamp removes the row from the rescan candidate set
      (`ChannelPostRescanWorker.due_posts/2`) for the denylist revision the operator
      judged it against, so their judgement sticks — but NOT forever: the worker
      compares it to `SecretDenylist.revision/0`, so a later pattern set (a wholly
      different credential shape) re-examines the row rather than leaving it
      scan-exempt for life.
      It is CLEARED again when a keyed working-state slot is overwritten with new
      content, so an exonerated slot can never become a permanent scan-exempt channel.

  No index: released rows are rare, and the existing partial `channel_posts_rescan_idx`
  (`WHERE quarantined_at IS NULL`) still serves the candidate scan — the extra predicate
  is a cheap filter on top.

  RLS: `channel_posts` already has ROW LEVEL SECURITY ENABLED; an added column inherits
  the existing policies.
  """

  def up do
    alter table(:channel_posts) do
      add :quarantine_released_at, :utc_datetime_usec
    end
  end

  def down do
    alter table(:channel_posts) do
      remove :quarantine_released_at
    end
  end
end
