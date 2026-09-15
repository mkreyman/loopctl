defmodule LoopctlRunner.TriageDispatchTest do
  use ExUnit.Case, async: true

  alias LoopctlRunner.{ByteRule, Contract, TriageDispatch}

  @record_id "7d0c1f6e-3b1a-4f7e-9c2d-5a6b7c8d9e0f"

  @triage %{
    "record_id" => @record_id,
    "issue_number" => 846,
    "html_url" => nil,
    "truncated" => false,
    "untrusted" => "<<<UNTRUSTED reported_issue n0nce>>>\n| it crashes\n<<<END n0nce>>>"
  }

  @verdict %{"outcome" => "escalate", "confidence" => "high", "missing_information" => ["what?"]}

  @binding %{"dispatch_id" => "1f0b6b8e-2c3d-4e5f-8a9b-0c1d2e3f4a5b", "claim_epoch" => 3}

  defp dispatch(overrides), do: Map.merge(%{"triage" => @triage}, overrides)

  describe "the triage object" do
    test "survives with only the keys the contract names" do
      assert {:ok, triage} =
               TriageDispatch.triage_object(
                 dispatch(%{"triage" => Map.put(@triage, "sneaked", "later contract")})
               )

      assert triage == @triage
    end

    test "a dispatch carrying none is :none, not an error" do
      assert TriageDispatch.triage_object(%{"kind" => "triage"}) == :none
      assert TriageDispatch.triage_object(dispatch(%{"triage" => nil})) == :none
    end

    test "an object of the wrong shape is refused, naming what is wrong" do
      assert {:error, detail} = TriageDispatch.triage_object(dispatch(%{"triage" => "a report"}))
      assert detail == "the dispatch triage is not an object"
    end

    # record_id becomes a PATH: TriageRun builds the run directory from it, and its own refusal
    # of one is {:error, _}, which has no wire form.
    test "a record_id that is not a uuid is refused here, before it is a path" do
      assert {:error, detail} =
               TriageDispatch.triage_object(
                 dispatch(%{"triage" => Map.put(@triage, "record_id", "../../etc")})
               )

      assert detail == "the dispatch triage record_id is not a uuid"

      assert {:error, detail} =
               TriageDispatch.triage_object(
                 dispatch(%{"triage" => Map.delete(@triage, "record_id")})
               )

      assert detail == "the dispatch triage names no record_id"
    end

    test "a report over the contract's byte cap is refused, cap read from the contract" do
      max = TriageDispatch.max_bytes()
      assert max == get_in(Contract.connection(), ["limits", "triage", "max_bytes"])

      # The per-field maxima do not bound the object, and the gap is not academic: `untrusted` at
      # its full 5000 characters is 30012 bytes of ordinary text and 60012 of astral ones, because
      # the rule charges double for a character outside the Basic Multilingual Plane. Every field
      # here is inside its own maximum; the object is over the cap.
      big = Map.put(@triage, "untrusted", String.duplicate("x", 5_000))
      assert ByteRule.bytes(big) < max

      over = Map.put(@triage, "untrusted", String.duplicate("😀", 5_000))
      assert String.length(over["untrusted"]) == 5_000
      assert ByteRule.bytes(over) > max
      assert {:error, detail} = TriageDispatch.triage_object(dispatch(%{"triage" => over}))
      assert detail =~ "over #{max}"
    end
  end

  describe "the verdict message" do
    test "a verdict is stated alone, with no incomplete beside it" do
      assert {:ok, payload} = TriageDispatch.verdict_message(@binding, {:verdict, @verdict})

      assert payload == %{
               "dispatch_id" => @binding["dispatch_id"],
               "claim_epoch" => 3,
               "verdict" => @verdict
             }

      refute Map.has_key?(payload, "incomplete")
      assert Contract.validate("RunnerTriageVerdictMessage", payload) == :ok
    end

    test "an incomplete carries its reason and detail, and no verdict" do
      assert {:ok, payload} =
               TriageDispatch.verdict_message(
                 @binding,
                 {:incomplete, "no_verdict_written", "the session escalated: no repo"}
               )

      assert payload["incomplete"] == "no_verdict_written"
      assert payload["detail"] == "the session escalated: no repo"
      refute Map.has_key?(payload, "verdict")
      assert Contract.validate("RunnerTriageVerdictMessage", payload) == :ok
    end

    # Capped in the shared constructor, not only by the producers that remember to: a detail one
    # codepoint over is refused invalid_payload, which is permanent, so an oversize note about an
    # incomplete run discards the whole report and strands the dispatch.
    test "a detail longer than the cap is cut, so the message is still sendable" do
      long = String.duplicate("the run's process died: claude exited: ", 30)
      assert String.length(long) > 300

      assert {:ok, payload} =
               TriageDispatch.verdict_message(@binding, {:incomplete, "no_verdict_written", long})

      assert String.length(payload["detail"]) == 300
      assert String.starts_with?(long, payload["detail"])
      assert Contract.validate("RunnerTriageVerdictMessage", payload) == :ok
    end

    test "an empty detail is omitted rather than sent as an empty string" do
      assert {:ok, payload} =
               TriageDispatch.verdict_message(@binding, {:incomplete, "session_crashed", ""})

      refute Map.has_key?(payload, "detail")
    end

    # The outcome with no wire form. Left as an error it would leave the dispatch in flight for
    # ever, so it is reported as the one thing the runner can say about a run it failed itself.
    test "a runner failure is reported as no_verdict_written, its reason cut to the cap" do
      reason = String.duplicate("e", 900)

      assert {:ok, payload} = TriageDispatch.verdict_message(@binding, {:error, reason})
      assert payload["incomplete"] == "no_verdict_written"
      assert String.length(payload["detail"]) == 300
      assert Contract.validate("RunnerTriageVerdictMessage", payload) == :ok
    end

    test "a payload that fails the contract is an error, never a message to send" do
      assert {:error, errors} =
               TriageDispatch.verdict_message(@binding, {:incomplete, "ran_out_of_ideas", "no"})

      assert Enum.any?(errors, &(&1 =~ "incomplete"))
    end

    # The rule loopctl enforces and the schema cannot: both fields are optional and nullable, so
    # a message with both or with neither validates locally and is refused invalid_payload on the
    # wire — which is permanent, taking the run's only output with it.
    test "exactly one of verdict and incomplete is the sender's rule, counted over non-nulls" do
      refute TriageDispatch.states_exactly_one?(%{})

      refute TriageDispatch.states_exactly_one?(%{
               "verdict" => @verdict,
               "incomplete" => "verdict_invalid"
             })

      assert TriageDispatch.states_exactly_one?(%{"verdict" => @verdict})
      assert TriageDispatch.states_exactly_one?(%{"incomplete" => "verdict_invalid"})
      # An explicit null is how the contract's own emitters say a field is not stated.
      assert TriageDispatch.states_exactly_one?(%{"verdict" => @verdict, "incomplete" => nil})
      refute TriageDispatch.states_exactly_one?(%{"verdict" => nil, "incomplete" => nil})
    end
  end

  describe "refusals" do
    test "each reason is classified as the contract describes it" do
      assert TriageDispatch.classify("rate_limited") == :rate_limited
      assert TriageDispatch.classify("internal_error") == :internal_error
      assert TriageDispatch.classify("dispatch_not_accepted") == :conditional
      assert TriageDispatch.classify("invalid_payload") == :permanent
      assert TriageDispatch.classify("already_recorded") == :permanent
      # Permanent for THIS event only; the contract lists it under `triage_verdict`.
      assert TriageDispatch.classify("stale_stage") == :permanent
      assert TriageDispatch.classify("not_a_reason") == :unknown
      assert TriageDispatch.classify(nil) == :unknown
    end

    # The compile-time guard's claim, asserted where a reader can see it: a refusal this build
    # does not know is given up on, so one the contract publishes must never be unknown.
    test "every refusal the contract publishes for a triage_verdict is handled" do
      published = get_in(Contract.connection(), ["errors", "triage_verdict"])
      assert TriageDispatch.errors() == published
      assert published != []

      for reason <- published do
        assert TriageDispatch.classify(reason) != :unknown,
               "#{reason} is published for a triage_verdict and this build gives up on it"
      end
    end
  end
end
