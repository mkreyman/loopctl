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
  alias LoopctlWeb.RunnerChannel.Refusal

  describe "the catch-all" do
    test "answers internal_error and logs the reason, which is never sent" do
      log = capture_log(fn -> assert Refusal.catch_all(:a_reason_no_clause_names) end)

      refusal = Refusal.catch_all(:a_reason_no_clause_names)
      assert refusal == %{reason: "internal_error"}

      assert log =~ "a_reason_no_clause_names"
      assert log =~ "[error]"
      refute refusal.reason =~ "a_reason_no_clause_names"
    end

    test "EVERY reason the stage machine can return is answered, none raises" do
      # This is the assertion the private clause could not carry. `Stages.advance_error/0` is
      # the set `stage` widened the channel to, and every member of it must come back as a
      # map rather than a `FunctionClauseError`.
      advance_errors = [
        :invalid_transition,
        :human_required,
        :reason_required,
        :not_found,
        :not_claimed,
        :stale_claim_epoch,
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

      for reason <- advance_errors do
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

    test "a lock this write could not get says retry, with an interval longer than the wait" do
      assert %{reason: "rate_limited", min_interval_ms: ms} = Refusal.for_message(:busy)
      assert ms > 0
      assert Refusal.for_message(:capacity_busy) == Refusal.for_message(:busy)
    end
  end

  # `Stages.advance_error/0` is a type, so it cannot be enumerated at runtime; the list above
  # is written from it by hand. This keeps the two from drifting: the type's own source is the
  # thing to re-read when it changes.
  test "the advance_error list above is written from the type's own source" do
    source = File.read!("lib/loopctl/delivery/stages.ex")
    [_, block] = String.split(source, "@type advance_error ::", parts: 2)
    [block, _] = String.split(block, "\n\n", parts: 2)

    declared =
      ~r/:([a-z_]+)/
      |> Regex.scan(block, capture: :all_but_first)
      |> List.flatten()
      |> Enum.sort()

    covered =
      ~w(invalid_transition human_required reason_required not_found not_claimed
                 stale_claim_epoch stale_stage actor_lineage_required invalid_reason
                 missing_required_effect invalid_effect wrong_stage effect_conflict
                 audit_chain_append_failed invalid_event_data busy)
      |> Enum.sort()

    assert declared == covered,
           "Stages.advance_error/0 changed; update the list in this file's catch-all test"
  end

  defp receive_it do
    receive do
      value -> value
    after
      0 -> flunk("no refusal was produced")
    end
  end
end
