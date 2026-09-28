defmodule LoopctlRunner.ReviewDispatchTest do
  use ExUnit.Case, async: true

  alias LoopctlRunner.{ByteRule, Contract, ReviewDispatch, Session}

  @sha String.duplicate("a", 40)
  @tree String.duplicate("b", 40)

  defp review(overrides \\ %{}) do
    Map.merge(
      %{
        "review_id" => Session.uuid4(),
        "round" => 1,
        "checkpoint_id" => Session.uuid4(),
        "checkpoint_seq" => 2,
        "commit_sha" => @sha,
        "tree_sha" => @tree
      },
      overrides
    )
  end

  @checkpoint Session.uuid4()

  defp bound(round \\ 1),
    do: %{
      "dispatch_id" => Session.uuid4(),
      "claim_epoch" => 4,
      "round" => round,
      "checkpoint_id" => @checkpoint
    }

  defp finding(overrides \\ %{}),
    do: Map.merge(%{"kind" => "finding", "body" => "it breaks", "severity" => "high"}, overrides)

  defp verdict(body \\ "one defect, fix it"), do: %{"kind" => "verdict", "body" => body}

  describe "the review object" do
    test "a dispatch with none carries none, and a well-formed one is read with its keys only" do
      assert ReviewDispatch.review_object(%{}) == :none
      assert ReviewDispatch.review_object(%{"review" => nil}) == :none

      assert {:error, "the dispatch review is not an object"} =
               ReviewDispatch.review_object(%{"review" => "r"})

      object = review(%{"extra" => "dropped"})
      assert {:ok, read} = ReviewDispatch.review_object(%{"review" => object})
      assert read == Map.delete(object, "extra")
    end

    test "a commit or tree that is not lowercase hex, or a missing field, is refused" do
      for {key, value} <- [{"commit_sha", String.upcase(@sha)}, {"tree_sha", "../x"}] do
        assert {:error, detail} =
                 ReviewDispatch.review_object(%{"review" => review(%{key => value})})

        assert detail =~ "the dispatch review"
      end

      assert {:error, detail} =
               ReviewDispatch.review_object(%{"review" => Map.delete(review(), "commit_sha")})

      assert detail =~ "commit_sha"
    end
  end

  describe "composing the messages" do
    test "numbered from 0 in the order stated, the verdict last, and nothing after it" do
      b = bound()

      %{messages: messages, skipped: [], after_verdict: 1} =
        ReviewDispatch.messages(b, [
          finding(%{"body" => "first", "location" => "lib/a.ex:1"}),
          finding(%{"body" => "second", "severity" => "low"}),
          verdict(),
          finding(%{"body" => "after the verdict"})
        ])

      assert [
               {"review_finding", first},
               {"review_finding", second},
               {"review_verdict", last}
             ] = messages

      assert first == %{
               "dispatch_id" => b["dispatch_id"],
               "claim_epoch" => 4,
               "client_seq" => 0,
               "body" => "first",
               "severity" => "high",
               "location" => "lib/a.ex:1"
             }

      assert second["client_seq"] == 1 and not Map.has_key?(second, "location")

      assert last ==
               Map.take(first, ~w(dispatch_id claim_epoch))
               |> Map.merge(%{"client_seq" => 2, "body" => "one defect, fix it"})

      for {event, payload} <- messages do
        definition =
          if event == "review_finding", do: "RunnerReviewFinding", else: "RunnerReviewVerdict"

        assert Contract.validate(definition, payload) == :ok
      end
    end

    test "a judgement no message can be made from is skipped, and the numbers stay contiguous" do
      %{messages: messages, skipped: skipped} =
        ReviewDispatch.messages(bound(), [
          finding(%{"severity" => "blocker"}),
          finding(%{"introduced_by" => "none"}),
          finding(),
          verdict()
        ])

      assert [{0, why_severity}, {1, why_round}] = skipped
      assert why_severity =~ "RunnerReviewFinding"
      assert why_round == "introduced_by is not allowed in round 1"
      assert Enum.map(messages, fn {_e, p} -> p["client_seq"] end) == [0, 1]
    end

    test "after round 1 every finding carries introduced_by" do
      assert {:error, "introduced_by is required after round 1"} =
               ReviewDispatch.message(bound(2), finding(), 0)

      assert {:ok, {"review_finding", %{"introduced_by" => "none"}}} =
               ReviewDispatch.message(bound(2), finding(%{"introduced_by" => "none"}), 0)
    end

    test "introduced_by is the checkpoint under review or none, checked before it is sent" do
      id = @checkpoint

      assert {:ok, {"review_finding", %{"introduced_by" => ^id}}} =
               ReviewDispatch.message(bound(2), finding(%{"introduced_by" => id}), 0)

      # Each of these fits the schema's string of at most 36, and names no checkpoint this runner
      # knows — another well-formed checkpoint id included.
      for bad <- [Session.uuid4(), String.upcase(id), "NONE", "checkpoint-3"] do
        assert {:error, why} =
                 ReviewDispatch.message(bound(2), finding(%{"introduced_by" => bad}), 0)

        assert why =~ "neither this review's checkpoint nor none", bad
      end
    end

    test "the UTF-8 byte caps and the byte rule are what bind, not the schema's characters" do
      # 16384 characters is inside `maxLength`, and far over the byte rule's 60000.
      long = String.duplicate("a", 16_384)
      assert {:error, why} = ReviewDispatch.message(bound(), finding(%{"body" => long}), 0)
      assert why =~ "byte rule"

      # Under the character cap and over the UTF-8 byte cap the description states.
      wide = String.duplicate("é", 9_000)
      assert {:error, why} = ReviewDispatch.message(bound(), finding(%{"body" => wide}), 0)
      assert why =~ "UTF-8 bytes"

      assert {:error, why} = ReviewDispatch.message(bound(), verdict(long), 0)
      assert why =~ "byte rule"
    end

    test "a stored message is re-checked, never rebuilt" do
      {:ok, message} = ReviewDispatch.message(bound(), finding(), 3)
      assert ReviewDispatch.sendable(message) == :ok

      {event, payload} = message
      assert {:error, _} = ReviewDispatch.sendable({event, Map.put(payload, "severity", "x")})
      assert {:error, _} = ReviewDispatch.sendable({"stage", payload})
    end
  end

  describe "the form the commands check against" do
    test "carries the contract's numbers, and its budgets are exactly what the byte rule leaves" do
      form = ReviewDispatch.form(%{"round" => 2, "checkpoint_id" => @checkpoint})
      limits = Contract.connection()["limits"]

      assert form["round"] == 2
      assert form["checkpoint_id"] == @checkpoint
      assert form["severities"] == ~w(critical high medium low)
      assert form["body_max_bytes"] == limits["review_finding"]["fields"]["body"]["max_length"]

      assert form["location_max_bytes"] ==
               limits["review_finding"]["fields"]["location"]["max_length"]

      assert form["per_char"] == limits["json_byte_rule"]["per_string_char"]

      # A body that spends the whole budget fits the widest message, and one more character does
      # not: the scripts' arithmetic and the runner's agree at the boundary.
      chars = div(form["finding_budget"], form["per_char"])

      widest =
        &finding(%{
          "body" => &1,
          "severity" => "critical",
          "location" => "",
          "introduced_by" => ""
        })

      b = %{"dispatch_id" => String.duplicate("f", 36), "claim_epoch" => 0}
      at = Map.merge(b, %{"client_seq" => 0})

      fits = ByteRule.bytes(payload(at, widest.(String.duplicate("a", chars))))
      over = ByteRule.bytes(payload(at, widest.(String.duplicate("a", chars + 1))))
      max = limits["review_finding"]["max_bytes"]
      assert fits <= max
      assert over > max

      vchars = div(form["verdict_budget"], form["per_char"])
      vbody = %{"dispatch_id" => b["dispatch_id"], "claim_epoch" => 0, "client_seq" => 0}

      assert ByteRule.bytes(Map.put(vbody, "body", String.duplicate("a", vchars))) <=
               limits["review_verdict"]["max_bytes"]

      assert ByteRule.bytes(Map.put(vbody, "body", String.duplicate("a", vchars + 1))) >
               limits["review_verdict"]["max_bytes"]
    end
  end

  defp payload(at, judgement),
    do: Map.merge(at, Map.take(judgement, ~w(body severity location introduced_by)))

  describe "a refusal" do
    test "every refusal the contract publishes for either message is classified by name" do
      for event <- ReviewDispatch.events(), reason <- ReviewDispatch.errors(event) do
        refute ReviewDispatch.classify(event, reason) == :unknown,
               "#{event} #{reason} has no handling"
      end
    end

    test "a claim-ending one ends the claim, a run-ending one the stream, the rest the message" do
      for event <- ReviewDispatch.events() do
        for reason <- ~w(review_closed review_claim_ended review_round_superseded
                         reviewer_not_separate unknown_dispatch stale_claim_epoch) do
          assert ReviewDispatch.classify(event, reason) == :claim_ended, "#{event} #{reason}"
        end

        assert ReviewDispatch.classify(event, "dispatch_not_accepted") == :stop

        # 1.22.0's two per-message codes drop only the message that drew them.
        for reason <- ~w(secret_blocked idempotency_key_reused invalid_payload
                         audit_chain_append_failed claim_epoch_mismatch wrong_dispatch_kind) do
          assert ReviewDispatch.classify(event, reason) == :drop, "#{event} #{reason}"
        end

        assert ReviewDispatch.classify(event, "tenant_halted") == :halted
        assert ReviewDispatch.classify(event, "rate_limited") == :rate_limited
        assert ReviewDispatch.classify(event, "internal_error") == :internal_error
        assert ReviewDispatch.classify(event, "no_such_reason") == :unknown
        assert ReviewDispatch.classify(event, nil) == :unknown
      end
    end

    test "a halt is not permanent in the contract, and every stop and drop is" do
      for event <- ReviewDispatch.events() do
        permanent = Contract.permanent_errors(event)
        refute "tenant_halted" in permanent

        for reason <- ReviewDispatch.errors(event),
            ReviewDispatch.classify(event, reason) in [:claim_ended, :stop, :drop] do
          assert reason in permanent, "#{event} #{reason}"
        end
      end
    end

    test "the claim-ending set is the contract's, key for key" do
      # Read, never re-typed: the refusals a review stream ends its claim on are exactly what the
      # vendored contract publishes for the event.
      for event <- ReviewDispatch.events() do
        claim_ending =
          for reason <- ReviewDispatch.errors(event),
              ReviewDispatch.classify(event, reason) == :claim_ended,
              do: reason

        assert Enum.sort(claim_ending) == Enum.sort(Contract.claim_ending_errors(event))
      end
    end

    test "a rate-limited message waits its own burst's refill" do
      limits = Contract.connection()["limits"]

      assert ReviewDispatch.retry_ms("review_finding") ==
               limits["review_finding_burst"]["refill_interval_ms"]

      assert ReviewDispatch.retry_ms("review_verdict") ==
               limits["review_verdict_burst"]["refill_interval_ms"]
    end
  end
end
