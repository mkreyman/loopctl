defmodule Loopctl.Delivery.StagesTest do
  @moduledoc """
  Issue #803: the per-story delivery stage machine — compare-and-set transitions fenced by
  the claim epoch, idempotent side-effect identities, the audit-chain subset, and the
  runner-lost requeue the claim reclaimer performs.

  Everything `Stages` touches lives on the RLS `Loopctl.Repo` sandbox connection
  (`fixture(:stage_story)` makes the tenant there too), so this module is async. The
  reclaimer runs on `AdminRepo`, a separate sandbox connection, so its tests build their
  story and stage row on AdminRepo. Real concurrency — which one sandbox connection cannot
  produce — is in `Loopctl.Delivery.StagesLockTest`.
  """

  use Loopctl.DataCase, async: true

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.AuditChain
  alias Loopctl.AuditChain.Entry
  alias Loopctl.Delivery.StageEvent
  alias Loopctl.Delivery.StageMachine
  alias Loopctl.Delivery.Stages
  alias Loopctl.Delivery.StoryStage
  alias Loopctl.Delivery.Untrusted
  alias Loopctl.Progress
  alias Loopctl.Repo
  alias Loopctl.WorkBreakdown.Story
  alias Loopctl.Workers.ReclaimExpiredClaimsWorker

  setup :verify_on_exit!

  @sha_a String.duplicate("a", 40)
  @sha_b String.duplicate("b", 40)

  defp as_tenant(tenant_id, fun) do
    {:ok, result} = Repo.with_tenant(tenant_id, fun)
    result
  end

  defp chain_actions(tenant_id) do
    as_tenant(tenant_id, fn ->
      Repo.all(
        from e in Entry,
          where: e.tenant_id == ^tenant_id,
          order_by: [asc: e.chain_position],
          select: e.action
      )
    end)
  end

  # The transition's own event rows, whose jsonb `data` carries the reason.
  defp transition_events(tenant_id, story_id) do
    as_tenant(tenant_id, fn ->
      Repo.all(
        from e in StageEvent,
          where: e.tenant_id == ^tenant_id and e.story_id == ^story_id,
          order_by: [asc: e.inserted_at, asc: e.lock_version]
      )
    end)
  end

  # The chain entries' payloads — the half of the record nobody can edit afterwards.
  defp chain_payloads(tenant_id) do
    as_tenant(tenant_id, fn ->
      Repo.all(
        from e in Entry,
          where: e.tenant_id == ^tenant_id,
          order_by: [asc: e.chain_position],
          select: e.payload
      )
    end)
  end

  # A story in `status` at `epoch` with its stage row at `stage`.
  defp at_stage(stage, attrs \\ %{}) do
    attrs = Map.new(attrs)

    story =
      fixture(:stage_story, %{
        claim_epoch: Map.get(attrs, :claim_epoch, 1),
        agent_status: Map.get(attrs, :agent_status, :assigned)
      })

    row_attrs =
      attrs
      |> Map.drop([:agent_status])
      |> Map.merge(%{tenant_id: story.tenant_id, story_id: story.id, stage: stage})
      |> Map.put_new(:claim_epoch, story.claim_epoch)
      |> then(fn a ->
        if stage == :escalated, do: Map.put_new(a, :escalation_reason, "why"), else: a
      end)

    {story, fixture(:story_stage, row_attrs)}
  end

  defp note_post_deploy(story, merge_sha, kind, opts),
    do: Stages.note_post_deploy_unresolved(story.tenant_id, story.id, merge_sha, kind, opts)

  defp release_claim(story) do
    as_tenant(story.tenant_id, fn ->
      story = Repo.get!(Story, story.id)
      story |> Ecto.Changeset.change(Progress.claim_release_change(story)) |> Repo.update!()
    end)
  end

  describe "open/3" do
    test "creates the row at detected under the story's epoch, once" do
      story = fixture(:stage_story, %{claim_epoch: 3})

      assert {:ok, %StoryStage{stage: :detected, claim_epoch: 3} = row} =
               Stages.open(story.tenant_id, story.id)

      assert {:ok, again} = Stages.open(story.tenant_id, story.id)
      assert again.id == row.id

      assert [%StageEvent{event: "opened"}] = Stages.list_events(story.tenant_id, story.id)
    end

    test "refuses a story that is not in the tenant" do
      story = fixture(:stage_story, %{})
      other = fixture(:stage_story, %{})

      assert {:error, :not_found} = Stages.open(other.tenant_id, story.id)
    end
  end

  describe "the transition table" do
    test "every triple in StageMachine.transitions/0 advances, counts and chains as declared" do
      for {from, to, edge} <- StageMachine.transitions() do
        {story, row} = at_stage(from)

        opts =
          [
            claim_epoch: story.claim_epoch,
            reason: "because",
            actor_role: :user,
            actor_lineage: [],
            effects: required_effects(to)
          ]

        result = Stages.advance(story.tenant_id, story.id, {from, to, edge}, opts)

        if edge in ([:runner_lost, :claim_released] ++ StageMachine.release_escalation_edges()) do
          # Only a releasing transaction takes these (follow_release/5): the release edges,
          # and the two escalations a release decides (US-44.4).
          assert {:error, :invalid_transition} = result, inspect({from, to, edge})
        else
          assert {:ok, %StoryStage{stage: ^to} = moved} = result, inspect({from, to, edge})

          # The transition writes once, and once more per identity it carries.
          assert moved.lock_version == row.lock_version + 1 + length(required_effects(to)),
                 inspect({from, to, edge})

          expected_attempts =
            if StageMachine.counted?(edge), do: %{Atom.to_string(edge) => 1}, else: %{}

          assert moved.attempts == expected_attempts, inspect({from, to, edge})

          chained = chain_actions(story.tenant_id) != []
          assert chained == StageMachine.chained?(from, to, edge), inspect({from, to, edge})
        end
      end
    end

    test "every triple NOT in the table is refused before the database is consulted" do
      edges = StageMachine.transitions() |> Enum.map(&elem(&1, 2)) |> Enum.uniq()
      stages = StageMachine.stages()
      missing = Ecto.UUID.generate()
      tenant = fixture(:stage_story, %{}).tenant_id

      refused =
        for from <- stages,
            to <- stages,
            edge <- edges,
            not StageMachine.allowed?(from, to, edge) do
          # A story that does not exist: :invalid_transition, not :not_found, proves the
          # refusal came first.
          assert {:error, :invalid_transition} =
                   Stages.advance(tenant, missing, {from, to, edge},
                     claim_epoch: 0,
                     reason: "r",
                     actor_role: :user
                   ),
                 inspect({from, to, edge})
        end

      assert refused != []
    end

    test "a repeated attempt counts again" do
      {story, _row} = at_stage(:ci)
      opts = [claim_epoch: story.claim_epoch]

      {:ok, _} = Stages.advance(story.tenant_id, story.id, {:ci, :implementing, :ci_red}, opts)

      [:implementing, :reviewing, :pr_open, :ci]
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.each(fn [from, to] ->
        {:ok, _} = Stages.advance(story.tenant_id, story.id, {from, to}, opts)
      end)

      {:ok, row} = Stages.advance(story.tenant_id, story.id, {:ci, :implementing, :ci_red}, opts)
      assert row.attempts == %{"ci_red" => 2}
    end
  end

  describe "advance/4 refusals" do
    test "a replay of a committed transition is stale_stage and does not happen twice" do
      {story, _row} = at_stage(:implementing)
      opts = [claim_epoch: story.claim_epoch]

      assert {:ok, first} =
               Stages.advance(story.tenant_id, story.id, {:implementing, :reviewing}, opts)

      assert {:error, :stale_stage} =
               Stages.advance(story.tenant_id, story.id, {:implementing, :reviewing}, opts)

      assert Stages.get(story.tenant_id, story.id).lock_version == first.lock_version
      assert length(Stages.list_events(story.tenant_id, story.id)) == 1
    end

    test "an epoch that is not the story's current one is stale_claim_epoch" do
      {story, _row} = at_stage(:implementing, claim_epoch: 2)

      assert {:error, :stale_claim_epoch} =
               Stages.advance(story.tenant_id, story.id, {:implementing, :reviewing},
                 claim_epoch: 1
               )
    end

    test "a row behind the story's epoch is refused even to a caller presenting the current one" do
      {story, _row} = at_stage(:implementing, claim_epoch: 1)
      released = release_claim(story)

      assert {:error, :stale_claim_epoch} =
               Stages.advance(story.tenant_id, story.id, {:implementing, :reviewing},
                 claim_epoch: released.claim_epoch
               )

      assert {:error, :stale_claim_epoch} =
               Stages.record_effect(story.tenant_id, story.id, :head_sha, @sha_a,
                 claim_epoch: released.claim_epoch
               )

      assert Stages.get(story.tenant_id, story.id).stage == :implementing
    end

    test "entering claimed needs a claim, and rebinds the row to the claim's epoch" do
      {pending, _} = at_stage(:queued, agent_status: :pending, claim_epoch: 4)

      assert {:error, :not_claimed} =
               Stages.advance(pending.tenant_id, pending.id, {:queued, :claimed},
                 claim_epoch: 4,
                 actor_lineage: []
               )

      {story, _} = at_stage(:queued, claim_epoch: 5)

      as_tenant(story.tenant_id, fn ->
        Repo.update_all(from(s in StoryStage), set: [claim_epoch: 2])
      end)

      assert {:ok, %StoryStage{stage: :claimed, claim_epoch: 5}} =
               Stages.advance(story.tenant_id, story.id, {:queued, :claimed},
                 claim_epoch: 5,
                 actor_lineage: []
               )
    end

    test "human_resolution needs a human: a user role on a key no dispatch minted" do
      {story, _} = at_stage(:escalated)
      transition = {:escalated, :queued, :human_resolution}
      base = [claim_epoch: story.claim_epoch, actor_lineage: []]

      assert {:error, :human_required} =
               Stages.advance(story.tenant_id, story.id, transition, base)

      assert {:error, :human_required} =
               Stages.advance(
                 story.tenant_id,
                 story.id,
                 transition,
                 base ++ [actor_role: :orchestrator]
               )

      assert {:error, :human_required} =
               Stages.advance(
                 story.tenant_id,
                 story.id,
                 transition,
                 Keyword.merge(base, actor_role: :user, actor_lineage: [Ecto.UUID.generate()])
               )

      assert {:ok, %StoryStage{stage: :queued}} =
               Stages.advance(
                 story.tenant_id,
                 story.id,
                 transition,
                 base ++ [actor_role: :user]
               )

      assert chain_actions(story.tenant_id) == ["story_stage_escalation_resolved"]
    end

    test "escalating needs a reason, and records it" do
      {story, _} = at_stage(:deployed)
      transition = {:deployed, :escalated, :verification_failed}
      base = [claim_epoch: story.claim_epoch, actor_lineage: []]

      assert {:error, :reason_required} =
               Stages.advance(story.tenant_id, story.id, transition, base ++ [reason: "  "])

      # A pasted CI log would be refused by the CHECK after the transition was decided.
      assert {:error, :invalid_reason} =
               Stages.advance(
                 story.tenant_id,
                 story.id,
                 transition,
                 base ++ [reason: String.duplicate("x", 4001)]
               )

      # The NUL case moved to its own test below: it now SUCCEEDS, and a success here would
      # advance the row out from under the refusals that follow.

      # The CHECK counts CODEPOINTS (char_length); a grapheme count does not. This family
      # emoji is ONE grapheme and several codepoints, so at the boundary a grapheme-counting
      # guard passed a value Postgres then refused as 23514 — losing the escalation.
      #
      # It is ALSO the case that shows what escaping costs, which is why it is still measured
      # here rather than simplified away: the sequence is joined by ZERO-WIDTH JOINERS, and
      # `sanitise/1` cannot tell a legitimate joiner from a hidden one, so each becomes eight
      # visible characters. The bound is therefore measured on the SANITISED text — the thing
      # the column actually holds — and a caller near the cap has less room than the raw
      # length suggests. That is the accepted price of a permanent record whose invisible
      # characters are visible; it is measured rather than asserted.
      family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
      assert String.length(family) == 1

      stored = Untrusted.sanitise(family)
      assert stored =~ "<U+200D>"
      stored_codepoints = stored |> String.to_charlist() |> length()
      assert stored_codepoints > family |> String.to_charlist() |> length()

      assert {:error, :invalid_reason} =
               Stages.advance(
                 story.tenant_id,
                 story.id,
                 transition,
                 base ++ [reason: String.duplicate("x", 4000 - 1) <> family]
               )

      # THE DISCRIMINATING CASE, which round 1 of #859's review found missing: raw INSIDE the
      # bound and escaped OUTSIDE it. Both of the assertions above are decided identically
      # with or without the escape — 4004 raw codepoints is over 4000 either way — so neither
      # pinned the new behaviour, while the comment claimed the cost was measured here.
      #
      # This one is the whole design in a single assertion: the caller is bounded on what it
      # SENT, so a reason that is 4,000 raw codepoints is ACCEPTED even though what lands in
      # the column is longer. Bounding the escaped form instead is what split one published
      # number into two and lost the escalation.
      at_bound = String.duplicate("x", 4000 - 5) <> family
      assert at_bound |> String.to_charlist() |> length() == 4000
      assert Untrusted.sanitise(at_bound) |> String.to_charlist() |> length() > 4000

      assert {:ok, %StoryStage{stage: :escalated}} =
               Stages.advance(story.tenant_id, story.id, transition, base ++ [reason: at_bound])

      # The accepted one left the row at `escalated`, so the reason is read back — and it ends
      # with the SANITISED sequence, not the raw one. That is what says the column holds the
      # escaped form while the caller was judged on the raw one.
      assert String.ends_with?(
               Stages.get(story.tenant_id, story.id).escalation_reason,
               stored
             )

      assert {:error, :stale_stage} =
               Stages.advance(
                 story.tenant_id,
                 story.id,
                 transition,
                 base ++ [reason: "smoke test failed"]
               )

      assert chain_actions(story.tenant_id) == ["story_stage_escalated"]
    end

    test "a NUL in the reason is ESCAPED and the escalation survives" do
      # It used to be refused — Postgres will not take a NUL in text, so the guard caught it
      # before the transition — and the cost was that a session escalating with one byte of
      # rubbish in its reason got NO ESCALATION AT ALL and the story was stranded at whatever
      # stage it was in. The reason is escaped before it is bounded now, so the NUL is
      # recorded visibly and the escalation lands.
      {story, _} = at_stage(:deployed)
      transition = {:deployed, :escalated, :verification_failed}
      base = [claim_epoch: story.claim_epoch, actor_lineage: []]

      assert {:ok, row} =
               Stages.advance(
                 story.tenant_id,
                 story.id,
                 transition,
                 base ++ [reason: "log tail" <> <<0>>]
               )

      assert row.escalation_reason == "log tail<U+0000>"
      assert row.stage == :escalated

      # THE COLUMN IS HALF THE CLAIM. The reason also reaches the stage EVENT's jsonb and, on
      # a chained transition, the tenant's append-only chain entry — and the chain is half of
      # why this escape exists at all. Asserted here because a regression that escaped only
      # the value handed to the compare-and-set would pass on the column alone while a NUL
      # reached both of the places nobody can edit afterwards. Postgres refuses a NUL in
      # jsonb, so such a regression would not merely record badly, it would raise.
      events = transition_events(story.tenant_id, story.id)
      assert Enum.any?(events, &(&1.data["reason"] == "log tail<U+0000>"))

      assert Enum.any?(
               chain_payloads(story.tenant_id),
               &(&1["reason"] == "log tail<U+0000>")
             )
    end

    test "no stage row is not_found" do
      story = fixture(:stage_story, %{})

      assert {:error, :not_found} =
               Stages.advance(story.tenant_id, story.id, {:detected, :triaged}, claim_epoch: 0)
    end
  end

  describe "note_unevaluated/4" do
    test "counts consecutive results at ONE head, and resets when the head moves" do
      {story, _row} = at_stage(:ci)
      opts = [claim_epoch: story.claim_epoch]
      head = String.duplicate("a", 40)
      moved = String.duplicate("b", 40)

      assert {:ok, 1} = Stages.note_unevaluated(story.tenant_id, story.id, head, opts)
      assert {:ok, 2} = Stages.note_unevaluated(story.tenant_id, story.id, head, opts)
      assert {:ok, 3} = Stages.note_unevaluated(story.tenant_id, story.id, head, opts)

      # A new head is new material: a story's blips at an older one must not escalate it.
      assert {:ok, 1} = Stages.note_unevaluated(story.tenant_id, story.id, moved, opts)

      row = Stages.get(story.tenant_id, story.id)
      assert row.merge_gate_unevaluated == %{"head_sha" => moved, "count" => 1}
    end

    test "leaves an event, so a story going quiet is on the record" do
      {story, _row} = at_stage(:ci)
      head = String.duplicate("a", 40)

      assert {:ok, 1} =
               Stages.note_unevaluated(story.tenant_id, story.id, head,
                 claim_epoch: story.claim_epoch,
                 actor_label: "test"
               )

      assert [%StageEvent{event: "merge_gate_unevaluated", data: data, actor_label: "test"}] =
               story.tenant_id
               |> Stages.list_events(story.id)
               |> Enum.filter(&(&1.event == "merge_gate_unevaluated"))

      assert data == %{"head_sha" => head, "count" => 1}
    end

    test "clear_unevaluated/3 removes the count, and is a no-op with nothing to clear" do
      {story, _row} = at_stage(:ci)
      opts = [claim_epoch: story.claim_epoch]

      assert {:ok, :nothing_to_clear} = Stages.clear_unevaluated(story.tenant_id, story.id, opts)

      assert {:ok, 1} =
               Stages.note_unevaluated(story.tenant_id, story.id, String.duplicate("a", 40), opts)

      assert {:ok, :cleared} = Stages.clear_unevaluated(story.tenant_id, story.id, opts)
      assert is_nil(Stages.get(story.tenant_id, story.id).merge_gate_unevaluated)

      # And the next run starts over rather than resuming the cleared arithmetic.
      assert {:ok, 1} =
               Stages.note_unevaluated(story.tenant_id, story.id, String.duplicate("a", 40), opts)
    end

    test "an edge that clears head_sha clears the count with it" do
      {story, _row} = at_stage(:ci)
      opts = [claim_epoch: story.claim_epoch]

      assert {:ok, 1} =
               Stages.note_unevaluated(story.tenant_id, story.id, String.duplicate("a", 40), opts)

      assert {:ok, row} =
               Stages.advance(story.tenant_id, story.id, {:ci, :implementing, :ci_red},
                 claim_epoch: story.claim_epoch
               )

      assert is_nil(row.merge_gate_unevaluated)
    end

    test "is refused off the ci stage — no other stage runs this gate" do
      {story, _row} = at_stage(:implementing)

      assert {:error, :wrong_stage} =
               Stages.note_unevaluated(story.tenant_id, story.id, String.duplicate("a", 40),
                 claim_epoch: story.claim_epoch
               )
    end

    test "is fenced by the claim epoch like every other write here" do
      {story, _row} = at_stage(:ci)

      assert {:error, :stale_claim_epoch} =
               Stages.note_unevaluated(story.tenant_id, story.id, String.duplicate("a", 40),
                 claim_epoch: story.claim_epoch + 7
               )
    end

    test "refuses a story with no stage row" do
      story = fixture(:stage_story, %{})

      assert {:error, :not_found} =
               Stages.note_unevaluated(story.tenant_id, story.id, String.duplicate("a", 40),
                 claim_epoch: story.claim_epoch
               )
    end
  end

  describe "note_post_deploy_unresolved/4" do
    test "counts consecutive sweeps at ONE merge, and resets when the merge differs" do
      {story, _row} = at_stage(:deployed)
      opts = [claim_epoch: story.claim_epoch]

      assert {:ok, %{count: 1}} =
               note_post_deploy(story, @sha_a, :forge_fault, opts)

      assert {:ok, %{count: 2}} =
               note_post_deploy(story, @sha_a, :forge_fault, opts)

      assert {:ok, %{count: 1}} =
               note_post_deploy(story, @sha_b, :forge_fault, opts)

      row = Stages.get(story.tenant_id, story.id)

      assert row.post_deploy_unresolved ==
               %{"merge_sha" => @sha_b, "kind" => "forge_fault", "count" => 1, "total" => 1}

      # And it does NOT share a column with the merge gate's count.
      assert is_nil(row.merge_gate_unevaluated)
    end

    test "the KIND is part of the identity, so a different one restarts the count" do
      # Two conditions reach `:unresolved` and they have different bounds. Counting them on
      # one number made a slow-but-healthy deploy inherit the forge's much shorter ceiling
      # and escalate the normal path.
      {story, _row} = at_stage(:deployed)
      opts = [claim_epoch: story.claim_epoch]

      assert {:ok, %{count: 1}} = note_post_deploy(story, @sha_a, :forge_fault, opts)
      assert {:ok, %{count: 2}} = note_post_deploy(story, @sha_a, :forge_fault, opts)
      assert {:ok, %{count: 1}} = note_post_deploy(story, @sha_a, :deploy_pending, opts)
      assert {:ok, %{count: 2}} = note_post_deploy(story, @sha_a, :deploy_pending, opts)
      assert {:ok, %{count: 1}} = note_post_deploy(story, @sha_a, :forge_fault, opts)

      row = Stages.get(story.tenant_id, story.id).post_deploy_unresolved
      assert row["count"] == 1
      assert row["kind"] == "forge_fault"

      # And the TOTAL kept accumulating across the alternation — without it neither count
      # ever reaches its bound and the story waits for ever with nobody told.
      assert row["total"] == 5
    end

    test "leaves an event under its own name" do
      {story, _row} = at_stage(:deployed)

      assert {:ok, %{count: 1}} =
               note_post_deploy(story, @sha_a, :deploy_pending,
                 claim_epoch: story.claim_epoch,
                 actor_label: "test"
               )

      assert [%StageEvent{event: "post_deploy_unresolved", data: data, actor_label: "test"}] =
               story.tenant_id
               |> Stages.list_events(story.id)
               |> Enum.filter(&(&1.event == "post_deploy_unresolved"))

      assert data ==
               %{"merge_sha" => @sha_a, "kind" => "deploy_pending", "count" => 1, "total" => 1}
    end

    test "clear_post_deploy_unresolved/3 removes the count, no-op with nothing to clear" do
      {story, _row} = at_stage(:deployed)
      opts = [claim_epoch: story.claim_epoch]

      assert {:ok, :nothing_to_clear} =
               Stages.clear_post_deploy_unresolved(story.tenant_id, story.id, opts)

      assert {:ok, %{count: 1}} =
               note_post_deploy(story, @sha_a, :forge_fault, opts)

      assert {:ok, :cleared} =
               Stages.clear_post_deploy_unresolved(story.tenant_id, story.id, opts)

      assert is_nil(Stages.get(story.tenant_id, story.id).post_deploy_unresolved)
    end

    test "the two counters are independent — clearing one leaves the other" do
      # They are separate COLUMNS precisely so a verdict at one gate cannot reset the
      # other's backstop. Walked through `ci` and on to `deployed` so both are set at once.
      {story, _row} = at_stage(:ci)
      opts = [claim_epoch: story.claim_epoch]

      assert {:ok, 1} = Stages.note_unevaluated(story.tenant_id, story.id, @sha_a, opts)

      {:ok, _} =
        Stages.advance(story.tenant_id, story.id, {:ci, :merged},
          claim_epoch: story.claim_epoch,
          actor_lineage: [],
          effects: [merge_sha: @sha_b]
        )

      {:ok, _} = Stages.advance(story.tenant_id, story.id, {:merged, :deployed}, opts)

      assert {:ok, %{count: 1}} =
               note_post_deploy(story, @sha_b, :forge_fault, opts)

      assert {:ok, :cleared} =
               Stages.clear_post_deploy_unresolved(story.tenant_id, story.id, opts)

      row = Stages.get(story.tenant_id, story.id)
      assert is_nil(row.post_deploy_unresolved)
      # The merge gate has ONE kind, so it carries no total and its stored shape is unchanged.
      assert row.merge_gate_unevaluated == %{"head_sha" => @sha_a, "count" => 1}
    end

    test "is refused off the deployed stage — no other stage runs this gate" do
      {story, _row} = at_stage(:ci)

      assert {:error, :wrong_stage} =
               note_post_deploy(story, @sha_a, :forge_fault, claim_epoch: story.claim_epoch)
    end

    test "is fenced by the claim epoch like every other write here" do
      {story, _row} = at_stage(:deployed)

      assert {:error, :stale_claim_epoch} =
               note_post_deploy(story, @sha_a, :forge_fault, claim_epoch: story.claim_epoch + 7)
    end
  end

  describe "record_effect/5" do
    @values %{
      triage_dispatch_id: "0b6e3a52-7d0e-4b8e-9c55-6a9a1e1f0c01",
      worktree_path: "/home/runner/workspace/app/.claude/worktrees/us-1",
      branch: "feature/us-1",
      head_sha: String.duplicate("c", 40),
      pr_number: 821,
      merge_sha: String.duplicate("d", 64),
      release_id: "v421",
      merge_gate_allowed_sha: String.duplicate("1", 40)
    }

    @others %{
      triage_dispatch_id: "0b6e3a52-7d0e-4b8e-9c55-6a9a1e1f0c02",
      worktree_path: "/elsewhere",
      branch: "feature/other",
      head_sha: String.duplicate("e", 40),
      pr_number: 822,
      merge_sha: String.duplicate("f", 40),
      release_id: "v422",
      merge_gate_allowed_sha: String.duplicate("2", 40)
    }

    test "a replay of every outward stage finds and reuses its recorded identity" do
      # `merge_sha` is not here: only the transition into `merged` writes it, so that its
      # chained entry names the merge. Its own tests are in "the merge identity".
      for effect <- StageMachine.effects(), not StageMachine.transition_only?(effect) do
        [stage | _] = StageMachine.effect_stages(effect)
        {story, _} = at_stage(stage)
        value = effect_value(effect, story.tenant_id)
        opts = [claim_epoch: story.claim_epoch]

        assert {:ok, first} = Stages.record_effect(story.tenant_id, story.id, effect, value, opts)
        assert Map.fetch!(first, effect) == value

        assert {:ok, replay} =
                 Stages.record_effect(story.tenant_id, story.id, effect, value, opts)

        assert Map.fetch!(replay, effect) == value
        assert replay.lock_version == first.lock_version, inspect(effect)

        assert [%StageEvent{event: "effect_recorded"}] =
                 Stages.list_events(story.tenant_id, story.id)

        other = other_value(effect, story.tenant_id)

        assert {:error, :effect_conflict} =
                 Stages.record_effect(story.tenant_id, story.id, effect, other, opts),
               inspect(effect)

        assert Map.fetch!(Stages.get(story.tenant_id, story.id), effect) == value
      end
    end

    test "a stage that does not produce the effect cannot record it" do
      {story, _} = at_stage(:implementing)

      assert {:error, :wrong_stage} =
               Stages.record_effect(story.tenant_id, story.id, :pr_number, 5,
                 claim_epoch: story.claim_epoch
               )
    end

    test "a replay still succeeds after the stage moved on" do
      {story, _} = at_stage(:worktree)
      opts = [claim_epoch: story.claim_epoch]
      {:ok, _} = Stages.record_effect(story.tenant_id, story.id, :branch, "feature/x", opts)
      {:ok, _} = Stages.advance(story.tenant_id, story.id, {:worktree, :implementing}, opts)

      assert {:ok, %StoryStage{branch: "feature/x"}} =
               Stages.record_effect(story.tenant_id, story.id, :branch, "feature/x", opts)
    end

    test "a stale epoch cannot record" do
      {story, _} = at_stage(:implementing, claim_epoch: 2)

      assert {:error, :stale_claim_epoch} =
               Stages.record_effect(story.tenant_id, story.id, :head_sha, @sha_a, claim_epoch: 1)
    end

    test "a text identity is bounded in codepoints, like the CHECK, not in graphemes" do
      {story, _} = at_stage(:worktree)
      opts = [claim_epoch: story.claim_epoch]
      family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
      assert String.length(family) == 1
      codepoints = family |> String.to_charlist() |> length()

      assert {:error, :invalid_effect} =
               Stages.record_effect(
                 story.tenant_id,
                 story.id,
                 :branch,
                 String.duplicate("b", 255 - 1) <> family,
                 opts
               )

      assert {:ok, %StoryStage{}} =
               Stages.record_effect(
                 story.tenant_id,
                 story.id,
                 :branch,
                 String.duplicate("b", 255 - codepoints) <> family,
                 opts
               )
    end

    test "malformed values are refused before the database" do
      story = fixture(:stage_story, %{})
      missing = Ecto.UUID.generate()

      for {effect, value} <- [
            {:head_sha, "ABC"},
            {:head_sha, String.duplicate("a", 41)},
            {:pr_number, 0},
            {:pr_number, "7"},
            {:runner_id, "not-a-uuid"},
            {:branch, ""},
            {:branch, String.duplicate("b", 256)},
            {:worktree_path, "a" <> <<0>>},
            {:release_id, 5},
            {:stage, "done"}
          ] do
        assert {:error, :invalid_effect} =
                 Stages.record_effect(story.tenant_id, missing, effect, value, claim_epoch: 0),
               inspect({effect, value})
      end
    end

    test "going back to implementing clears the head, so the next head can be recorded" do
      {story, _} = at_stage(:ci, head_sha: @sha_a, branch: "feature/y", pr_number: 9)
      opts = [claim_epoch: story.claim_epoch]

      assert {:ok, %StoryStage{head_sha: nil, branch: "feature/y", pr_number: 9}} =
               Stages.advance(story.tenant_id, story.id, {:ci, :implementing, :ci_red}, opts)

      assert {:ok, %StoryStage{head_sha: @sha_b}} =
               Stages.record_effect(story.tenant_id, story.id, :head_sha, @sha_b, opts)
    end
  end

  describe "the audit chain" do
    test "a walk down the main line chains claimed and merged, and nothing else" do
      {story, _} = at_stage(:queued)
      opts = [claim_epoch: story.claim_epoch]

      [:queued, :claimed, :worktree, :implementing, :reviewing, :pr_open, :ci, :merged, :deployed]
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.each(fn [from, to] ->
        assert {:ok, _} =
                 Stages.advance(
                   story.tenant_id,
                   story.id,
                   {from, to},
                   opts ++ [actor_lineage: [], effects: required_effects(to)]
                 )
      end)

      assert chain_actions(story.tenant_id) == ["story_stage_claimed", "story_stage_merged"]

      # Eight transitions, plus the `effect_recorded` for the sha `ci -> merged` carried.
      assert story.tenant_id
             |> Stages.list_events(story.id)
             |> Enum.frequencies_by(& &1.event) == %{
               "transitioned" => 8,
               "effect_recorded" => 1
             }
    end

    test "a refused transition writes neither an event nor a chain entry" do
      {story, _} = at_stage(:ci)

      assert {:error, :stale_claim_epoch} =
               Stages.advance(story.tenant_id, story.id, {:ci, :merged},
                 claim_epoch: 99,
                 actor_lineage: [],
                 effects: required_effects(:merged)
               )

      assert chain_actions(story.tenant_id) == []
      assert Stages.list_events(story.tenant_id, story.id) == []
    end
  end

  describe "tenant isolation" do
    test "tenant B sees none of tenant A's stage rows or events, and cannot write them" do
      {story_a, _} = at_stage(:implementing)

      {:ok, _} =
        Stages.advance(story_a.tenant_id, story_a.id, {:implementing, :reviewing}, claim_epoch: 1)

      story_b = fixture(:stage_story, %{})

      # No explicit predicate: RLS alone must hide A's rows from B.
      assert as_tenant(story_b.tenant_id, fn -> Repo.all(StoryStage) end) == []
      assert as_tenant(story_b.tenant_id, fn -> Repo.all(StageEvent) end) == []
      assert as_tenant(story_a.tenant_id, fn -> Repo.all(StoryStage) end) != []

      assert Stages.get(story_b.tenant_id, story_a.id) == nil
      assert Stages.list_events(story_b.tenant_id, story_a.id) == []

      assert {:error, :not_found} =
               Stages.advance(story_b.tenant_id, story_a.id, {:reviewing, :pr_open},
                 claim_epoch: 1
               )

      assert {:error, :not_found} =
               Stages.record_effect(story_b.tenant_id, story_a.id, :head_sha, @sha_a,
                 claim_epoch: 1
               )

      assert Stages.get(story_a.tenant_id, story_a.id).stage == :reviewing
    end
  end

  describe "claim releases (follow_release/5)" do
    # On AdminRepo: every release path's connection.
    defp claimed_with_stage(stage, row_attrs \\ %{}, story_attrs \\ %{}) do
      tenant = fixture(:tenant)
      agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})

      story =
        fixture(
          :story,
          Map.merge(%{tenant_id: tenant.id, agent_status: :contracted}, story_attrs)
        )

      {:ok, claimed} = Progress.claim_story(tenant.id, story.id, agent_id: agent.id)

      row =
        fixture(
          :story_stage,
          %{
            repo: AdminRepo,
            tenant_id: tenant.id,
            story_id: story.id,
            stage: stage,
            claim_epoch: claimed.claim_epoch
          }
          |> Map.merge(escalation(stage))
          |> Map.merge(row_attrs)
        )

      %{tenant_id: tenant.id, agent: agent, story: claimed, row: row}
    end

    defp expire_lease(story) do
      {1, _} =
        from(s in Story, where: s.id == ^story.id)
        |> AdminRepo.update_all(set: [claimed_until: DateTime.add(DateTime.utc_now(), -60)])
    end

    defp report_done(story) do
      {1, _} =
        from(s in Story, where: s.id == ^story.id)
        |> AdminRepo.update_all(
          set: [agent_status: :reported_done, reported_done_at: DateTime.utc_now()]
        )
    end

    defp orchestrator(tenant_id),
      do: fixture(:agent, %{tenant_id: tenant_id, agent_type: :orchestrator})

    # Every path that releases a claim, as its production caller runs it. Each returns the
    # edge it is recorded under.
    defp release(:reclaim, %{story: story}) do
      expire_lease(story)
      assert :ok = ReclaimExpiredClaimsWorker.perform(%Oban.Job{args: %{}})
      :runner_lost
    end

    defp release(:unclaim, %{tenant_id: t, story: story, agent: agent}) do
      {:ok, _} = Progress.unclaim_story(t, story.id, agent_id: agent.id)
      :claim_released
    end

    defp release(:reject, %{tenant_id: t, story: story}) do
      report_done(story)

      # The story RETURNED is the story as the reject left it — re-contracted, for a delivery
      # story below the ceiling (US-44.4), which the caller then asserts from the database.
      {:ok, %Story{}} =
        Progress.reject_story(t, story.id, %{"reason" => "Missing tests"},
          orchestrator_agent_id: orchestrator(t).id
        )

      :claim_released
    end

    defp release(:bulk_reject, %{tenant_id: t, story: story}) do
      report_done(story)

      {:ok, [%{status: "success"}]} =
        Loopctl.BulkOperations.bulk_reject(
          t,
          [%{"story_id" => story.id, "reason" => "Missing tests"}],
          orchestrator(t).id,
          verifier_lineage: []
        )

      :claim_released
    end

    # The releases that SPENT an attempt (US-44.4): each counts, and below the ceiling
    # (`config/test.exs` sets 2) re-contracts the story so the driver can place it again.
    # Force-unclaim is an operator's release and is asserted on its own below.
    @release_paths [:reclaim, :unclaim, :reject, :bulk_reject]

    for path <- @release_paths do
      test "#{path}: the in-flight stage row goes back to queued in the same transaction" do
        ctx =
          claimed_with_stage(:implementing, %{
            worktree_path: "/w",
            head_sha: @sha_a,
            branch: "feature/z",
            pr_number: 12,
            attempts: %{"ci_red" => 1}
          })

        edge = release(unquote(path), ctx)

        story = AdminRepo.get!(Story, ctx.story.id)
        assert story.claim_epoch > ctx.story.claim_epoch

        requeued = AdminRepo.get!(StoryStage, ctx.row.id)
        assert requeued.stage == :queued
        assert requeued.claim_epoch == story.claim_epoch
        assert requeued.attempts == %{"ci_red" => 1, Atom.to_string(edge) => 1}
        assert requeued.lock_version == ctx.row.lock_version + 1
        assert {requeued.worktree_path, requeued.head_sha} == {nil, nil}
        assert {requeued.branch, requeued.pr_number} == {"feature/z", 12}

        edge_name = Atom.to_string(edge)

        assert [%StageEvent{from_stage: "implementing", to_stage: "queued", edge: ^edge_name}] =
                 AdminRepo.all(from e in StageEvent, where: e.story_stage_id == ^ctx.row.id)

        # REACHABLE AGAIN (#877): queued with nothing contracted is a story the driver never
        # selects. Below the ceiling the release re-contracts it in the same transaction.
        assert story.agent_status == :contracted
      end
    end

    # TC-44.4.6 (AC-44.4.7). An operator taking a delivery story back is a human decision, so a
    # human decides what it does next — never a re-queue under them, never `queued` +
    # `:pending`. It spends no attempt: the requeue is not counted, and the ceiling never sees
    # it.
    test "force_unclaim with no release_cause escalates over operator_released" do
      ctx =
        claimed_with_stage(:implementing, %{
          worktree_path: "/w",
          head_sha: @sha_a,
          attempts: %{"ci_red" => 1}
        })

      {:ok, released} = Progress.force_unclaim_story(ctx.tenant_id, ctx.story.id)
      assert released.agent_status == :pending

      row = AdminRepo.get!(StoryStage, ctx.row.id)
      assert row.stage == :escalated
      assert row.claim_epoch == released.claim_epoch
      assert row.escalation_reason =~ "operator_released"
      assert row.attempts == %{"ci_red" => 1, "operator_released" => 1}

      assert [
               %StageEvent{
                 from_stage: "implementing",
                 to_stage: "queued",
                 edge: "claim_released"
               },
               %StageEvent{from_stage: "queued", to_stage: "escalated", edge: "operator_released"}
             ] =
               AdminRepo.all(
                 from e in StageEvent,
                   where: e.story_stage_id == ^ctx.row.id,
                   order_by: [asc: e.lock_version]
               )

      # Entering `escalated` is custody-critical, so the escalation is on the chain — written
      # inside the release's AdminRepo transaction, so read on that repo.
      assert [%Entry{payload: %{"edge" => "operator_released", "to" => "escalated"}}] =
               AdminRepo.all(
                 from e in Entry,
                   where:
                     e.tenant_id == ^ctx.tenant_id and e.entity_id == ^ctx.story.id and
                       e.action == "story_stage_escalated"
               )
    end

    # TC-44.4.1 (AC-44.4.1, AC-44.4.2), at the mechanism: a placement's own undo spends
    # nothing and puts the story back in front of the driver.
    test "force_unclaim with release_cause :placement_refused re-contracts, uncounted" do
      ctx = claimed_with_stage(:claimed, %{attempts: %{"ci_red" => 1}})

      {:ok, released} =
        Progress.force_unclaim_story(ctx.tenant_id, ctx.story.id,
          release_cause: :placement_refused
        )

      assert released.agent_status == :contracted
      assert AdminRepo.get!(Story, ctx.story.id).agent_status == :contracted

      row = AdminRepo.get!(StoryStage, ctx.row.id)
      assert {row.stage, row.attempts} == {:queued, %{"ci_red" => 1}}
    end

    test "force_unclaim refuses a release_cause it does not know" do
      ctx = claimed_with_stage(:claimed)

      assert_raise ArgumentError, fn ->
        Progress.force_unclaim_story(ctx.tenant_id, ctx.story.id, release_cause: :attempt)
      end
    end

    # TC-44.4.2 / TC-44.4.3 (AC-44.4.3, AC-44.4.4), through the worker the lease runs through.
    test "a lost lease under the ceiling retries; the one that reaches it escalates" do
      ctx = claimed_with_stage(:implementing, %{attempts: %{"runner_lost" => 1}})
      expire_lease(ctx.story)

      assert :ok = ReclaimExpiredClaimsWorker.perform(%Oban.Job{args: %{}})

      row = AdminRepo.get!(StoryStage, ctx.row.id)
      assert row.stage == :escalated
      assert row.attempts["runner_lost"] == 2
      assert row.attempts["attempts_exhausted"] == 1
      assert row.escalation_reason =~ "attempts_exhausted: 2 counted releases"
      assert row.escalation_reason =~ "retry ceiling of 2"

      # Escalated, the story is NOT re-contracted: a human decides.
      assert AdminRepo.get!(Story, ctx.story.id).agent_status == :pending

      assert [_requeue, %StageEvent{from_stage: "queued", edge: "attempts_exhausted"}] =
               AdminRepo.all(
                 from e in StageEvent,
                   where: e.story_stage_id == ^ctx.row.id,
                   order_by: [asc: e.lock_version]
               )
    end

    test "a lost lease under the ceiling re-contracts and counts one runner_lost" do
      ctx = claimed_with_stage(:implementing)
      expire_lease(ctx.story)

      assert :ok = ReclaimExpiredClaimsWorker.perform(%Oban.Job{args: %{}})

      row = AdminRepo.get!(StoryStage, ctx.row.id)
      assert {row.stage, row.attempts} == {:queued, %{"runner_lost" => 1}}
      assert AdminRepo.get!(Story, ctx.story.id).agent_status == :contracted
    end

    # The ceiling counts BOTH spent-attempt edges: one crash plus one reject is two.
    test "a reject that reaches the ceiling after an earlier lost lease escalates" do
      ctx = claimed_with_stage(:ci, %{attempts: %{"runner_lost" => 1}})
      release(:reject, ctx)

      row = AdminRepo.get!(StoryStage, ctx.row.id)
      assert row.stage == :escalated
      assert row.attempts["claim_released"] == 1
      assert row.escalation_reason =~ "attempts_exhausted: 2 counted releases"
      assert AdminRepo.get!(Story, ctx.story.id).agent_status == :pending
    end

    # TC-44.4.5 (AC-44.4.6): a verifier reject of work reported under a dispatch whose row is
    # at `ci` — in flight — is a counted release, re-contracted below the ceiling.
    test "an in-flight reject counts, and re-contracts under the ceiling" do
      ctx = claimed_with_stage(:ci)
      release(:reject, ctx)

      row = AdminRepo.get!(StoryStage, ctx.row.id)
      assert {row.stage, row.attempts} == {:queued, %{"claim_released" => 1}}
      assert AdminRepo.get!(Story, ctx.story.id).agent_status == :contracted
    end

    test "follow_release/5 requires a known :cause and a stated :actor_lineage" do
      ctx = claimed_with_stage(:implementing)

      for opts <- [[actor_lineage: []], [cause: :whatever, actor_lineage: []], [cause: :attempt]] do
        assert_raise ArgumentError, fn ->
          AdminRepo.transaction(fn ->
            Stages.follow_release(ctx.tenant_id, ctx.story.id, 99, :runner_lost, opts)
          end)
        end
      end

      assert AdminRepo.get!(StoryStage, ctx.row.id).stage == :implementing
    end

    # TC-44.4.7 (AC-44.4.8): no stage row, nothing about the release changes.
    test "a story with no stage row is released exactly as before" do
      tenant = fixture(:tenant)
      agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})
      story = fixture(:story, %{tenant_id: tenant.id, agent_status: :contracted})
      {:ok, claimed} = Progress.claim_story(tenant.id, story.id, agent_id: agent.id)

      {:ok, released} = Progress.force_unclaim_story(tenant.id, claimed.id)

      assert released.agent_status == :pending
      assert AdminRepo.get!(Story, story.id).agent_status == :pending
      assert Stages.get(tenant.id, story.id) == nil
    end

    # A row the release only REBINDS spent nothing, so a counted cause decides nothing there:
    # a `queued` row is re-contracted even at a ceiling of 0 worth of counts, and nothing else
    # is touched.
    test "a release that only rebinds a queued row re-contracts without counting" do
      ctx = claimed_with_stage(:queued, %{attempts: %{"runner_lost" => 5}})
      expire_lease(ctx.story)

      {:ok, released} =
        Progress.reclaim_expired_claim(ctx.tenant_id, ctx.story.id, ctx.story.claim_epoch)

      assert released.agent_status == :contracted
      row = AdminRepo.get!(StoryStage, ctx.row.id)
      assert {row.stage, row.attempts} == {:queued, %{"runner_lost" => 5}}
    end

    test "every stage: in flight is requeued, done and failed untouched, the rest rebound" do
      for stage <- StageMachine.stages() do
        ctx = claimed_with_stage(stage)
        expire_lease(ctx.story)

        {:ok, released} =
          Progress.reclaim_expired_claim(ctx.tenant_id, ctx.story.id, ctx.story.claim_epoch)

        after_release = AdminRepo.get!(StoryStage, ctx.row.id)

        cond do
          stage in StageMachine.in_flight_stages() ->
            assert {after_release.stage, after_release.claim_epoch} ==
                     {:queued, released.claim_epoch},
                   inspect(stage)

          stage in [:done, :failed] ->
            assert after_release == ctx.row, inspect(stage)

          true ->
            assert {after_release.stage, after_release.claim_epoch, after_release.attempts} ==
                     {stage, released.claim_epoch, %{}},
                   inspect(stage)

            assert [%StageEvent{event: "rebound"}] =
                     AdminRepo.all(from e in StageEvent, where: e.story_stage_id == ^ctx.row.id)
        end
      end
    end

    test "force-unclaim of an already-pending story rebinds a row a release left behind" do
      tenant = fixture(:tenant)
      story = fixture(:story, %{tenant_id: tenant.id})

      {1, _} =
        from(s in Story, where: s.id == ^story.id) |> AdminRepo.update_all(set: [claim_epoch: 3])

      row =
        fixture(:story_stage, %{
          repo: AdminRepo,
          tenant_id: tenant.id,
          story_id: story.id,
          stage: :merged,
          claim_epoch: 2
        })

      {:ok, %Story{claim_epoch: 3}} = Progress.force_unclaim_story(tenant.id, story.id)
      assert %StoryStage{stage: :merged, claim_epoch: 3} = AdminRepo.get!(StoryStage, row.id)

      # Again: already at the story's epoch, nothing to write.
      {:ok, _} = Progress.force_unclaim_story(tenant.id, story.id)
      assert AdminRepo.get!(StoryStage, row.id).lock_version == row.lock_version + 1
    end

    test "a reclaim that refuses (lease renewed) leaves the stage row in flight" do
      ctx = claimed_with_stage(:ci)

      assert {:error, :claim_not_expired} =
               Progress.reclaim_expired_claim(ctx.tenant_id, ctx.story.id, ctx.story.claim_epoch)

      assert AdminRepo.get!(StoryStage, ctx.row.id).stage == :ci
    end

    test "follow_release/5 refuses to run outside a releasing transaction" do
      assert_raise ArgumentError, fn ->
        Stages.follow_release(Ecto.UUID.generate(), Ecto.UUID.generate(), 1, :claim_released)
      end
    end
  end

  describe "claims (follow_claim/4)" do
    # A claim bumps the epoch as a release does, so the row has to follow it or a story
    # claimed before triage finished can never be advanced again.
    defp contracted_story_with_stage(stage) do
      tenant = fixture(:tenant)
      agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})
      story = fixture(:story, %{tenant_id: tenant.id, agent_status: :contracted})

      row =
        fixture(:story_stage, %{
          repo: AdminRepo,
          tenant_id: tenant.id,
          story_id: story.id,
          stage: stage,
          claim_epoch: story.claim_epoch
        })

      %{tenant_id: tenant.id, agent: agent, story: story, row: row}
    end

    for stage <- [:detected, :triaged, :queued] do
      test "a hand-claimed story at #{stage} keeps its stage and takes the claim's epoch" do
        %{tenant_id: t, agent: agent, story: story, row: row} =
          contracted_story_with_stage(unquote(stage))

        {:ok, claimed} = Progress.claim_story(t, story.id, agent_id: agent.id)
        assert claimed.claim_epoch == story.claim_epoch + 1

        rebound = AdminRepo.get!(StoryStage, row.id)
        assert rebound.stage == unquote(stage)
        assert rebound.claim_epoch == claimed.claim_epoch
        assert rebound.attempts == %{}

        assert [%StageEvent{event: "rebound"}] =
                 AdminRepo.all(from e in StageEvent, where: e.story_stage_id == ^row.id)
      end
    end

    test "a bulk claim rebinds the row the same way" do
      %{tenant_id: t, agent: agent, story: story, row: row} = contracted_story_with_stage(:queued)

      {:ok, [%{status: "success"}]} =
        Loopctl.BulkOperations.bulk_claim(t, [story.id], agent.id)

      claimed = AdminRepo.get!(Story, story.id)
      assert AdminRepo.get!(StoryStage, row.id).claim_epoch == claimed.claim_epoch
    end

    test "follow_claim/4 refuses to run outside the claiming transaction" do
      assert_raise ArgumentError, fn ->
        Stages.follow_claim(Ecto.UUID.generate(), Ecto.UUID.generate(), 1)
      end
    end
  end

  describe "database contention is retryable, everything else is not" do
    test "the retryable classes" do
      for code <- ["55P03", "57014", "40P01", "40001"] do
        assert Stages.retryable_error?(%Postgrex.Error{postgres: %{pg_code: code}}), code
      end

      assert Stages.retryable_error?(%DBConnection.ConnectionError{reason: :queue_timeout})
    end

    test "of the chain's own P0001 raises, only the position violation is transient" do
      # Both errors come from the REAL triggers in `20260411231547_create_audit_chain`, so
      # renaming a RAISE there fails this test rather than silently reclassifying a
      # transient contention error as a 500. A hand-built Postgrex.Error would not.
      tenant = fixture(:tenant)
      {:ok, first} = AuditChain.append(tenant.id, chain_attrs())

      position_violation =
        assert_raise Postgrex.Error, fn ->
          insert_chain_entry(tenant.id, 7, first.entry_hash)
        end

      assert position_violation.postgres.pg_code == "P0001"
      assert Stages.retryable_error?(position_violation)

      hash_violation =
        assert_raise Postgrex.Error, fn ->
          insert_chain_entry(tenant.id, 1, :binary.copy(<<1>>, 32))
        end

      assert hash_violation.postgres.pg_code == "P0001"
      # An L6 integrity signal: reported as :busy it would spin retries against a chain
      # that is broken and will stay broken.
      refute Stages.retryable_error?(hash_violation)
    end
  end

  describe "custody attribution on a chained transition" do
    test "a chained transition refuses a caller that did not state its lineage" do
      {story, _} = at_stage(:queued)

      assert {:error, :actor_lineage_required} =
               Stages.advance(story.tenant_id, story.id, {:queued, :claimed},
                 claim_epoch: story.claim_epoch
               )

      assert chain_actions(story.tenant_id) == []
      assert Stages.get(story.tenant_id, story.id).stage == :queued
    end

    test "an unchained transition does not need one" do
      {story, _} = at_stage(:implementing)

      assert {:ok, %StoryStage{stage: :reviewing}} =
               Stages.advance(story.tenant_id, story.id, {:implementing, :reviewing},
                 claim_epoch: story.claim_epoch
               )
    end

    test "a dispatch-minted user key is not the human, even omitting nothing else" do
      {story, _} = at_stage(:escalated)
      transition = {:escalated, :queued, :human_resolution}

      # Absent lineage is refused BEFORE the human test — a dispatch-minted :user key that
      # simply omits it must never pass as the operator.
      assert {:error, :actor_lineage_required} =
               Stages.advance(story.tenant_id, story.id, transition,
                 claim_epoch: story.claim_epoch,
                 actor_role: :user
               )
    end

    test "a chain append the database refuses rolls the transition back" do
      {story, _} = at_stage(:queued)

      # A lineage `Entry.changeset/2` cannot cast. In production the lineage is resolved
      # server-side and is always well formed; this is the one caller-reachable way to make
      # the append return `{:error, changeset}`, and the point is that the TRANSITION does
      # not commit when its custody entry cannot.
      assert {:error, :audit_chain_append_failed} =
               Stages.advance(story.tenant_id, story.id, {:queued, :claimed},
                 claim_epoch: story.claim_epoch,
                 actor_lineage: [%{"not" => "a string"}]
               )

      assert Stages.get(story.tenant_id, story.id).stage == :queued
      assert Stages.list_events(story.tenant_id, story.id) == []
      assert chain_actions(story.tenant_id) == []
    end

    test "the chain entry records the lineage the caller stated" do
      {story, _} = at_stage(:queued)
      lineage = [Ecto.UUID.generate(), Ecto.UUID.generate()]

      {:ok, _} =
        Stages.advance(story.tenant_id, story.id, {:queued, :claimed},
          claim_epoch: story.claim_epoch,
          actor_lineage: lineage
        )

      assert [%Entry{actor_lineage: ^lineage}] =
               as_tenant(story.tenant_id, fn -> Repo.all(Entry) end)
    end
  end

  describe "the merge identity" do
    test "is carried on the transition, so the merged chain entry names the merge" do
      {story, _} = at_stage(:ci)
      opts = [claim_epoch: story.claim_epoch, actor_lineage: []]
      merge_sha = String.duplicate("9", 40)

      # `record_effect/5` never writes this identity, at any stage: only the transition
      # does, so the chained entry can name it.
      assert {:error, :transition_only_effect} =
               Stages.record_effect(story.tenant_id, story.id, :merge_sha, merge_sha, opts)

      # Perform the merge, take the sha GitHub returns, transition carrying it.
      assert {:ok, %StoryStage{stage: :merged, merge_sha: ^merge_sha}} =
               Stages.advance(
                 story.tenant_id,
                 story.id,
                 {:ci, :merged},
                 opts ++ [effects: [merge_sha: merge_sha]]
               )

      # The custody record NAMES the merge. A nil here is an entry that asserts a merge and
      # identifies nothing.
      assert [%Entry{action: "story_stage_merged", payload: payload}] =
               as_tenant(story.tenant_id, fn -> Repo.all(Entry) end)

      assert payload["merge_sha"] == merge_sha

      # One `effect_recorded` event alongside the transition's own.
      assert ["transitioned", "effect_recorded"] =
               story.tenant_id |> Stages.list_events(story.id) |> Enum.map(& &1.event)
    end

    test "a replayed transition reuses the recorded sha, and a different one conflicts" do
      merge_sha = String.duplicate("9", 40)
      {story, _} = at_stage(:ci)
      opts = [claim_epoch: story.claim_epoch, actor_lineage: []]

      {:ok, _} =
        Stages.advance(
          story.tenant_id,
          story.id,
          {:ci, :merged},
          opts ++ [effects: [merge_sha: merge_sha]]
        )

      # The runner comes back, asks GitHub, gets the same sha, and repeats the call: the
      # row has moved on, so the transition is refused and nothing is merged twice.
      assert {:error, :stale_stage} =
               Stages.advance(
                 story.tenant_id,
                 story.id,
                 {:ci, :merged},
                 opts ++ [effects: [merge_sha: merge_sha]]
               )

      # And the retraction still names the sha it withdraws.
      {:ok, _} =
        Stages.advance(
          story.tenant_id,
          story.id,
          {:merged, :implementing, :merge_refused},
          opts ++ [reason: "branch protection"]
        )

      assert ["story_stage_merged", "story_stage_merge_retracted"] =
               chain_actions(story.tenant_id)

      assert [_merged, %Entry{payload: payload}] =
               as_tenant(story.tenant_id, fn ->
                 Repo.all(from e in Entry, order_by: [asc: e.chain_position])
               end)

      assert payload["retracted"]["merge_sha"] == merge_sha
    end

    test "entering merged without the sha is refused, and nothing is chained" do
      {story, _} = at_stage(:ci)
      opts = [claim_epoch: story.claim_epoch, actor_lineage: []]

      assert {:error, :missing_required_effect} =
               Stages.advance(story.tenant_id, story.id, {:ci, :merged}, opts)

      assert {:error, :missing_required_effect} =
               Stages.advance(story.tenant_id, story.id, {:ci, :merged}, opts ++ [effects: []])

      assert Stages.get(story.tenant_id, story.id).stage == :ci
      assert chain_actions(story.tenant_id) == []
    end

    test "a malformed :effects option is refused, not raised" do
      {story, _} = at_stage(:implementing)
      opts = [claim_epoch: story.claim_epoch]

      malformed = [
        nil,
        :merge_sha,
        ["head_sha"],
        [{"head_sha", @sha_a}],
        %{"head_sha" => @sha_a},
        42
      ]

      for effects <- malformed do
        assert {:error, :invalid_effect} =
                 Stages.advance(
                   story.tenant_id,
                   story.id,
                   {:implementing, :reviewing},
                   opts ++ [effects: effects]
                 ),
               inspect(effects)
      end

      assert Stages.get(story.tenant_id, story.id).stage == :implementing
    end

    test "an effect the destination stage does not produce, or a malformed one, is refused" do
      {story, _} = at_stage(:ci)
      opts = [claim_epoch: story.claim_epoch, actor_lineage: []]

      assert {:error, :invalid_effect} =
               Stages.advance(
                 story.tenant_id,
                 story.id,
                 {:ci, :merged},
                 opts ++ [effects: [merge_sha: "not-a-sha"]]
               )

      assert {:error, :wrong_stage} =
               Stages.advance(
                 story.tenant_id,
                 story.id,
                 {:ci, :merged},
                 opts ++ [effects: [merge_sha: sample_effect(:merge_sha), worktree_path: "/w"]]
               )

      # Neither attempt moved the row or wrote an entry.
      assert Stages.get(story.tenant_id, story.id).stage == :ci
      assert chain_actions(story.tenant_id) == []
    end

    test "a refused merge is chained as a retraction, with its reason" do
      merge_sha = String.duplicate("7", 40)
      {story, row} = at_stage(:merged, merge_sha: merge_sha, head_sha: @sha_a, pr_number: 4)
      retraction = {:merged, :implementing, :merge_refused}
      base = [claim_epoch: story.claim_epoch, actor_lineage: []]

      assert {:error, :reason_required} =
               Stages.advance(story.tenant_id, story.id, retraction, base)

      assert {:ok, %StoryStage{stage: :implementing} = back} =
               Stages.advance(
                 story.tenant_id,
                 story.id,
                 retraction,
                 base ++ [reason: "required check missing"]
               )

      assert {back.merge_sha, back.head_sha} == {nil, nil}
      assert back.pr_number == 4
      assert back.attempts == %{"merge_refused" => 1}
      assert back.lock_version == row.lock_version + 1

      # The chain carried the merge as a fact; the retraction says it did not hold, and
      # why. Unchained, the chain would say the story merged at that sha forever.
      assert chain_actions(story.tenant_id) == ["story_stage_merge_retracted"]

      assert [%Entry{payload: payload}] = as_tenant(story.tenant_id, fn -> Repo.all(Entry) end)
      assert payload["reason"] == "required check missing"
      # Which merge it retracts — the row's own merge_sha is nil by now, cleared by the edge.
      # `merge_gate_allowed_sha` is retracted alongside the head it was granted for (#803
      # review round 1): an allow that outlived its head would authorise an unjudged one.
      assert payload["retracted"] == %{
               "merge_sha" => merge_sha,
               "head_sha" => @sha_a,
               "merge_gate_allowed_sha" => nil,
               "merge_gate_unevaluated" => nil,
               # Merge-keyed alongside `merge_sha` (#803 §9): post-deploy verification's
               # unresolved count is kept per MERGE, so a retracted merge takes it too.
               "post_deploy_unresolved" => nil
             }

      # And the next attempt can record its own head again.
      {:ok, _} =
        Stages.record_effect(story.tenant_id, story.id, :head_sha, @sha_b,
          claim_epoch: story.claim_epoch
        )
    end
  end

  describe "runner_id is resolved in this tenant" do
    test "another tenant's runner is refused, though the foreign key would accept it" do
      {story, _} = at_stage(:claimed)
      other = fixture(:stage_story, %{})
      foreign_runner = fixture(:stage_runner, %{tenant_id: other.tenant_id})

      assert {:error, :invalid_effect} =
               Stages.record_effect(story.tenant_id, story.id, :runner_id, foreign_runner.id,
                 claim_epoch: story.claim_epoch
               )

      assert Stages.get(story.tenant_id, story.id).runner_id == nil
    end

    test "a runner id that resolves to nothing is refused, not raised" do
      {story, _} = at_stage(:claimed)

      assert {:error, :invalid_effect} =
               Stages.record_effect(story.tenant_id, story.id, :runner_id, Ecto.UUID.generate(),
                 claim_epoch: story.claim_epoch
               )
    end
  end

  defp chain_attrs do
    %{
      action: "test_chain_entry",
      actor_lineage: [],
      entity_type: "story",
      entity_id: nil,
      payload: %{}
    }
  end

  # Straight at the table, bypassing `AuditChain`, so the TRIGGERS decide.
  defp insert_chain_entry(tenant_id, chain_position, prev_entry_hash) do
    AdminRepo.insert!(%Entry{
      tenant_id: tenant_id,
      chain_position: chain_position,
      prev_entry_hash: prev_entry_hash,
      action: "test_chain_entry",
      actor_lineage: [],
      entity_type: "story",
      payload: %{},
      entry_hash: :binary.copy(<<2>>, 32),
      inserted_at: DateTime.utc_now()
    })
  end

  # What a transition into `to` must carry (today: the merge sha, entering `merged`).
  defp required_effects(to) do
    for effect <- StageMachine.required_effects(to), do: {effect, sample_effect(effect)}
  end

  defp sample_effect(:merge_sha), do: String.duplicate("a", 40)

  defp escalation(:escalated), do: %{escalation_reason: "why"}
  defp escalation(_stage), do: %{}

  describe "the triage binding fences every transition out of triaged (US-44.1)" do
    test "a session dispatch that is not the bound one is refused triage_not_bound" do
      {story, _row} = at_stage(:detected)
      bound = Ecto.UUID.generate()

      {:ok, _} =
        Stages.advance(story.tenant_id, story.id, {:detected, :triaged, :forward},
          claim_epoch: story.claim_epoch,
          actor_label: "test",
          effects: [triage_dispatch_id: bound]
        )

      opts = [
        claim_epoch: story.claim_epoch,
        actor_label: "runner:test",
        actor_role: :agent,
        actor_lineage: []
      ]

      assert {:error, :triage_not_bound} =
               Stages.advance(
                 story.tenant_id,
                 story.id,
                 {:triaged, :queued, :forward},
                 Keyword.put(opts, :session_dispatch, {Ecto.UUID.generate(), 0})
               )

      assert {:ok, %{stage: :queued}} =
               Stages.advance(
                 story.tenant_id,
                 story.id,
                 {:triaged, :queued, :forward},
                 Keyword.put(opts, :session_dispatch, {bound, 0})
               )
    end

    test "a row bound to NOBODY is no session's to move out of triaged" do
      {story, _row} = at_stage(:detected)

      {:ok, _} =
        Stages.advance(story.tenant_id, story.id, {:detected, :triaged, :forward},
          claim_epoch: story.claim_epoch,
          actor_label: "test"
        )

      assert {:error, :triage_not_bound} =
               Stages.advance(story.tenant_id, story.id, {:triaged, :queued, :forward},
                 claim_epoch: story.claim_epoch,
                 actor_label: "runner:test",
                 actor_role: :agent,
                 actor_lineage: [],
                 session_dispatch: {Ecto.UUID.generate(), 0}
               )
    end
  end

  defp effect_value(:runner_id, tenant_id), do: fixture(:stage_runner, %{tenant_id: tenant_id}).id
  defp effect_value(effect, _tenant_id), do: Map.fetch!(@values, effect)

  defp other_value(:runner_id, tenant_id), do: fixture(:stage_runner, %{tenant_id: tenant_id}).id
  defp other_value(effect, _tenant_id), do: Map.fetch!(@others, effect)
end
