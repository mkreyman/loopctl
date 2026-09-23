defmodule LoopctlWeb.RunnerChannel.RefusalTest do
  @moduledoc """
  The reason -> refusal mapping of the runner channel (#824 round 2, finding 3).

  Its CATCH-ALL is why this module exists at all. As a private clause in the channel it could
  only be reached by crashing a socket: `message_error/1` delegated its last clause to
  `join_error/1`, which has five clauses and no catch-all, so a reason no clause named RAISED
  inside `handle_in/3` — and a raise there does not refuse one message, it takes the channel
  down and every in-flight session on that socket with it. `stage` widened the reachable set
  to the whole of `Loopctl.Delivery.Stages.advance_error/0` and made it reachable in
  principle; `:actor_lineage_required` is the one, latent only because
  `Loopctl.Delivery.RunnerStages` hardcodes an empty lineage, which is a property of one
  caller and not of the mapping.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Loopctl.ApiSpec.RunnerContract
  alias Loopctl.Delivery.RunnerStages
  alias Loopctl.Delivery.StoryStage
  alias LoopctlWeb.RunnerChannel.Refusal

  # Written by hand from `Loopctl.Delivery.Stages.advance_error/0`, which is a type and cannot
  # be enumerated at runtime. ONE list: the walk below iterates it and the drift guard at the
  # bottom compares it against the type's own source.
  @advance_errors [
    :invalid_transition,
    :human_required,
    :reason_required,
    :not_found,
    :not_claimed,
    :stale_claim_epoch,
    :triage_not_bound,
    :stale_stage,
    :actor_lineage_required,
    :invalid_reason,
    :missing_required_effect,
    :invalid_effect,
    :wrong_stage,
    :effect_conflict,
    :audit_chain_append_failed,
    :invalid_event_data,
    :busy
  ]

  describe "the catch-all" do
    test "answers internal_error and logs the reason, which is never sent" do
      log =
        capture_log(fn ->
          send(self(), Refusal.catch_all(:a_reason_no_clause_names))
        end)

      refusal = receive_it()
      assert refusal == %{reason: "internal_error"}

      assert log =~ "a_reason_no_clause_names"
      assert log =~ "[error]"
      refute refusal.reason =~ "a_reason_no_clause_names"
    end

    test "EVERY reason the stage machine can return is answered, none raises" do
      # This is the assertion the private clause could not carry. `@advance_errors` is the set
      # `stage` widened the channel to, and every member of it must come back as a map rather
      # than a `FunctionClauseError`.
      for reason <- @advance_errors do
        refusal = capture_log(fn -> send(self(), Refusal.for_message(reason)) end) && receive_it()
        assert is_map(refusal), "#{reason} did not produce a refusal map"
        assert is_binary(refusal.reason), "#{reason} produced no reason string"
      end
    end

    test "a shape that is not an atom at all is answered too" do
      for reason <- [{:some, :tuple}, "a string", 42, nil, %{}] do
        capture_log(fn ->
          assert %{reason: reason_string} = Refusal.for_message(reason)
          assert is_binary(reason_string)
        end)
      end
    end

    test "join falls through to the message catch-all rather than raising" do
      capture_log(fn ->
        assert %{reason: "internal_error"} =
                 Refusal.for_join(:a_join_reason_no_clause_names, max_joins: 30, window_ms: 1)
      end)
    end
  end

  describe "the published vocabulary" do
    test "every reason this module produces is one the contract publishes" do
      published = Refusal.published_reasons()

      for reason <- Refusal.reasons() do
        assert reason in published,
               "#{reason} is not in RunnerContract.error_reasons/0 — a runner cannot switch " <>
                 "on a code the contract does not declare"
      end
    end

    test "error_fields publishes what each refusal ACTUALLY carries, and is complete" do
      # THE HALF A CODE LIST CANNOT SAY. `error_reasons/0` tells a runner which codes it may
      # see; nothing told it which of them carry anything to act on, so the extra fields were
      # learnable only by reading loopctl's source or by watching a refusal in production.
      # 1.10.0 is the release that makes that expensive — its whole point is that a
      # `stale_stage` runner reads the row off the refusal — so the shape is published too.
      assert RunnerContract.error_fields_complete?(),
             "a code in error_reasons/0 has no error_fields/0 entry; a runner looking one up " <>
               "cannot tell 'carries nothing' from 'nobody wrote this entry'"

      fields = RunnerContract.error_fields()

      # Asserted against the REFUSALS THEMSELVES, not against a second copy of the list. A
      # published shape nobody produces is as bad as a produced shape nobody published.
      produced = [
        {"stage", {:stale_stage, %StoryStage{stage: :queued, claim_epoch: 1, lock_version: 2}}},
        {"stage", {:effect_conflict, %{head_sha: String.duplicate("a", 40)}}},
        {"trace", {:batch_too_large, 100, 200}},
        {"trace", {:event_data_too_large, 3, 400, 500}},
        {"stage", {:invalid, ["something"]}},
        {"stage", :busy},
        # `session_ended` (1.16.0): the two codes that carry anything, and the permanent one
        # that carries nothing.
        {"session_ended", {:invalid, ["something"]}},
        {"session_ended", :capacity_busy},
        {"session_ended", :already_recorded}
      ]

      for {event, reason} <- produced do
        refusal = Refusal.for_message(reason)
        code = refusal.reason
        actual = refusal |> Map.delete(:reason) |> Map.keys() |> Enum.map(&Atom.to_string/1)

        assert Enum.sort(actual) == Enum.sort(fields[event][code]),
               "#{event}/#{code} carries #{inspect(Enum.sort(actual))} and publishes " <>
                 "#{inspect(fields[event][code])}"
      end

      # The asymmetry the per-event keying exists for: the SAME code, two shapes.
      assert fields["stage"]["stale_stage"] != []
      assert fields["triage_verdict"]["stale_stage"] == []
      assert Refusal.for_message(:stale_stage) == %{reason: "stale_stage"}
    end

    test "internal_error is published for every inbound event" do
      # It is reachable on all of them: the catch-all is on the shared mapping, not on `stage`.
      for event <- RunnerContract.inbound_events() do
        assert "internal_error" in RunnerContract.error_reasons()[event],
               "#{event} can be refused with internal_error but does not publish it"
      end
    end
  end

  describe "the reasons that are NOT invalid_payload, and why" do
    test "a control-plane state is its own code, never invalid_payload" do
      # `invalid_payload` means "your message is wrong, fix it". None of these is about the
      # message: `stale_stage` asks for a re-read, `unknown_story_stage` is a condition the
      # runner cannot clear at all, and `effect_conflict` asks it to reconcile with the
      # recorded identity and specifically NOT to re-send.
      for reason <- [:stale_stage, :unknown_story_stage, :effect_conflict] do
        assert Refusal.for_message(reason) == %{reason: Atom.to_string(reason)}
      end
    end

    test "stale_stage CARRIES the row, in the shape the ok ack sends (#849)" do
      row = %StoryStage{
        stage: :queued,
        claim_epoch: 7,
        lock_version: 3,
        attempts: %{"worktree" => 1},
        branch: "feature/story-11-abcdef01"
      }

      refusal = Refusal.for_message({:stale_stage, row})

      assert refusal.reason == "stale_stage"

      # ONE SHAPE, asserted against the renderer the ack itself uses rather than by listing
      # the keys again here. A test that restated the field list would stay green while the
      # two drifted, which is the whole thing this refusal exists to prevent: the contract's
      # remedy is "send the transition that applies", and the runner reads it off this map.
      assert Map.delete(refusal, :reason) == RunnerStages.row_state(row)
      assert refusal.stage == "queued"
      assert refusal.claim_epoch == 7
      assert refusal.attempts == %{"worktree" => 1}

      # THE ONE NAME `row_state/1` MAY NEVER USE. The refusal is built by putting `:reason`
      # ON TOP of the row, so a `:reason` key added to the row — the schema already carries
      # `escalation_reason`, so it is not far-fetched — would reach the ack and be silently
      # clobbered here, and the equality above passes either way. This is the assertion that
      # makes that collision loud.
      refute Map.has_key?(RunnerStages.row_state(row), :reason)
      assert refusal.effects == %{branch: "feature/story-11-abcdef01"}
    end

    test "a refused chain append is PERMANENT, never a retry instruction" do
      # #824 round 3, finding 5. It was `rate_limited`, which tells the runner to send it
      # again — against a deterministic failure that will refuse the next one identically,
      # while every custody transition in the tenant is failing until an operator acts. It
      # also disagreed with the HTTP surface, which answers 500 for the same condition and
      # says plainly that retrying will not help.
      refusal = Refusal.for_message(:audit_chain_append_failed)

      assert refusal == %{reason: "audit_chain_append_failed"}
      refute Map.has_key?(refusal, :min_interval_ms)
      refute refusal.reason == "rate_limited"
    end

    test "a lock this write could not get says retry, with an interval longer than the wait" do
      assert %{reason: "rate_limited", min_interval_ms: ms} = Refusal.for_message(:busy)
      assert ms > 0
      assert Refusal.for_message(:capacity_busy) == Refusal.for_message(:busy)
    end
  end

  # `Stages.advance_error/0` is a type, so it cannot be enumerated at runtime; `@advance_errors`
  # is written from it by hand. This binds the two.
  #
  # It compares against the SAME attribute the walk above iterates (#824 round 3, finding 7).
  # It used to compare against a second hardcoded copy, so adding a member to the type and
  # updating only that copy left this guard green while the walk stayed short — a drift guard
  # that could not see the drift it existed for.
  test "@advance_errors is exactly what the type declares" do
    source = File.read!("lib/loopctl/delivery/stages.ex")
    [_, block] = String.split(source, "@type advance_error ::", parts: 2)
    [block, _] = String.split(block, "\n\n", parts: 2)

    declared =
      ~r/:([a-z_]+)/
      |> Regex.scan(block, capture: :all_but_first)
      |> List.flatten()
      |> Enum.map(&String.to_existing_atom/1)
      |> Enum.sort()

    assert declared == Enum.sort(@advance_errors),
           "Stages.advance_error/0 changed; update @advance_errors in this file"
  end

  defp receive_it do
    receive do
      value -> value
    after
      0 -> flunk("no refusal was produced")
    end
  end
end
