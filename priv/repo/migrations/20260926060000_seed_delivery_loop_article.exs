defmodule Loopctl.Repo.Migrations.SeedDeliveryLoopArticle do
  use Ecto.Migration

  # The public wiki article for the agent delivery loop. This migration is its only copy: the
  # body is inlined because docs/ is not in a release, and a second copy there would drift.
  # A later correction is a new migration upserting this slug.
  @slug "delivery-loop"
  @title "The Agent Delivery Loop — From a Reported Issue to a Verified Deploy"
  @body ~S"""
  # The Agent Delivery Loop

  loopctl can take a problem reported on GitHub and carry it through triage, implementation, review, CI, merge and post-deploy verification. Agent sessions do the work on **runners**, which are dev machines the tenant enrolls. loopctl is the control plane: it holds the queue, the stage of every story, the claims and the gates. It never runs these sessions itself and never pushes to the repository; its only GitHub writes are a resolution comment, labels and closing on the reporter's issue.

  ## The stages

  ```
  detected → triaged → queued → claimed → worktree → implementing → reviewing
          → pr_open → ci → merged → deployed → verified → done

  any gate refusal → escalated   (left only by a human's resolution)
  ```

  A story's stage is read with `story_stage`. `stage: null` means the loop has never touched the story.

  ## Who moves a story

  - **Intake.** A signed GitHub webhook on an enrolled repository (an *intake source*) records each issue. A job turns the record into a stub story at `detected`. The reporter's words are stored as untrusted and never reach the implementer.
  - **Triage.** A triage session on a runner returns a verdict: `story` (queued), `escalate` or `reject`. A `story` verdict that fails a delivery gate is escalated instead of queued.
  - **Placement.** An operator (`place_dispatch`) or the unattended dispatch driver claims a queued story under a fresh custody dispatch and sends it to a runner with a free slot.
  - **The session.** The runner reports each stage as it implements, reviews, opens the pull request and watches CI. It can move a story forward, or back to `implementing`, but never to `verified` or `done`.
  - **The merge gate.** An orchestrator or operator calls `merge_precondition`, which a runner session cannot. It re-checks the real diff: both delivery gates, custody and a hard size bound. Only `allow` licenses a merge, `refuse` escalates the story, and a head that moved since CI sends it back to `implementing`.
  - **After the merge.** Post-deploy verification moves a story from `deployed` to `verified`, and completion moves it to `done` once the reporter's issue is closed.

  ## The claim: lease and fence

  A claim has a lease (`claimed_until`) and an epoch (`claim_epoch`). Every report names the epoch, so a session that lost its claim cannot move a story that someone else now holds. A lease nobody renews is reclaimed. A counted release puts the story back in the queue below the retry ceiling and escalates it at the ceiling.

  ## Escalation is the safety valve

  Wherever a gate refuses, a budget runs out or a session gives up, the story goes to `escalated` and waits for a person. `resolve_escalation` moves it to `queued`, `done` or `failed`. It requires a user key that no dispatch minted, so a session can never resolve its own escalation. This is the same separation the [chain of custody](/wiki/chain-of-custody) enforces for report, review and verify.

  ## Setting it up

  1. Enroll a runner (`runner_enroll`) and start it on the machine with its token file.
  2. Enroll the repository (`intake_source_enroll`) with its target epic and base branch, and add the GitHub webhook for the Issues event.
  3. Configure the delivery gates and the dispatch budgets.
  4. Place one story by hand and watch it with `story_stage`.
  5. Turn on the unattended dispatch driver.

  The full operator reference, including every refusal and recovery path, is `docs/agent-delivery-loop.md` in the loopctl repository.
  """

  def up do
    execute("""
    INSERT INTO articles (id, tenant_id, scope, slug, title, body, category, status, metadata, tags, inserted_at, updated_at)
    VALUES (
      gen_random_uuid(),
      NULL,
      'system',
      '#{@slug}',
      '#{escape_sql(@title)}',
      '#{escape_sql(@body)}',
      'reference',
      'published',
      '{"authored_by": "delivery_loop_docs"}',
      '{}',
      NOW(),
      NOW()
    )
    ON CONFLICT (slug) WHERE scope = 'system'
    DO UPDATE SET title = EXCLUDED.title, body = EXCLUDED.body, category = EXCLUDED.category,
      status = EXCLUDED.status, metadata = EXCLUDED.metadata, updated_at = NOW()
    """)
  end

  def down do
    execute("DELETE FROM articles WHERE scope = 'system' AND slug = '#{@slug}'")
  end

  defp escape_sql(text), do: String.replace(text, "'", "''")
end
