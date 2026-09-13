defmodule Loopctl.Delivery.PostDeployVerificationJudgeTest do
  @moduledoc """
  `Loopctl.Delivery.PostDeployVerification.judge/1` — the whole decision, as a pure function
  of its facts (issue #803 §9, issue #805 item 2).

  Pure, so every fail-closed path is tested with no database and no forge: the facts a live
  sweep would have gathered arrive here as `{:ok, value}` or `{:error, reason}`, which is
  exactly how an unreachable GitHub, an environment with no deployment and a deploy still
  in flight present themselves.
  """

  use ExUnit.Case, async: true

  alias Loopctl.Delivery.PostDeployVerification
  alias Loopctl.Delivery.PostDeployVerification.Result
  alias Loopctl.Delivery.Resolution

  @repo "acme/widgets"
  @merge String.duplicate("a", 40)
  @deployed String.duplicate("b", 40)

  describe "the merge is running" do
    test "the deployed commit IS the merge" do
      result = judge(deployment: deployment(sha: @merge), contains: {:ok, true})

      assert %Result{decision: :verified, reasons: []} = result
      assert result.repo == @repo
      assert result.merge_sha == @merge
      assert result.deployed_sha == @merge
      assert result.deployment_state == :success
      assert result.deployment_id == 77
    end

    test "the merge is an ANCESTOR of the deployed commit" do
      # Merges queue. A story merged at 10:00 and shipped inside the 10:04 deploy of a later
      # merge HAS shipped, and sha equality would escalate it.
      result = judge(deployment: deployment(), contains: {:ok, true})

      assert %Result{decision: :verified, reasons: []} = result
      assert result.deployed_sha == @deployed
    end

    test "and ONLY that produces a `shipped` resolution" do
      # #805 item 1: the merge is not the ship. Every other decision this module can reach
      # says nothing to the reporter.
      verified = judge(deployment: deployment(), contains: {:ok, true})
      assert verified.resolution == Resolution.for_verdict(:shipped)
      assert verified.resolution.close?
      assert verified.resolution.label == "loopctl:resolution-shipped"
    end
  end

  describe "the merge is NOT running" do
    test "a commit the deployment does not contain escalates, naming BOTH shas" do
      result = judge(deployment: deployment(), contains: {:ok, false})

      assert %Result{decision: :failed, reasons: reasons} = result
      assert {:merge_not_deployed, @merge, @deployed} in reasons
      # An operator reading the escalation must not have to look either one up.
      assert result.merge_sha == @merge
      assert result.deployed_sha == @deployed
      assert result.resolution == Resolution.for_verdict(:escalated)
      refute result.resolution.close?
    end

    for state <- [:failure, :error, :inactive] do
      test "a #{state} deployment escalates rather than being read as shipped" do
        state = unquote(state)
        result = judge(deployment: deployment(state: state), contains: :not_attempted)

        assert %Result{decision: :failed, reasons: reasons} = result
        assert {:deploy_not_successful, state, @deployed, @merge} in reasons
      end
    end

    test "an environment with NO deployment escalates: we cannot tell what is running" do
      result = judge(deployment: {:ok, nil}, contains: :not_attempted)

      assert %Result{decision: :failed, reasons: [{:no_deployment, "production"}]} = result
    end

    test "a story with no recorded merge_sha fails CLOSED" do
      # There is nothing to verify against, so there is no verdict a sweep could reach on
      # its own — and a story that reached `deployed` without one is custody-broken.
      result = judge(merge_sha: nil, deployment: deployment(), contains: :not_attempted)

      assert %Result{decision: :failed, reasons: [:merge_sha_not_recorded]} = result
    end

    test "a repository that cannot be resolved escalates" do
      result =
        judge(
          repo: {:error, {:no_intake_source, "p"}},
          deployment: {:error, :not_attempted},
          contains: :not_attempted
        )

      assert %Result{decision: :failed, reasons: reasons} = result
      assert {:repository_unresolved, {:no_intake_source, "p"}} in reasons
    end

    for reason <- [{:github_api_error, 404}, {:github_api_error, 403}, :unreadable] do
      test "a NON-transient forge fault (#{inspect(reason)}) escalates rather than waiting" do
        reason = unquote(Macro.escape(reason))
        result = judge(deployment: {:error, reason}, contains: :not_attempted)

        assert %Result{decision: :failed, reasons: reasons} = result
        assert {:deployment_unavailable, reason} in reasons
      end
    end

    test "an unrecognised deployment state is NOT approximated to success" do
      result = judge(deployment: {:error, {:unrecognised_deployment_state, "abandoned"}})

      assert %Result{decision: :failed, reasons: reasons} = result
      assert {:deployment_unavailable, {:unrecognised_deployment_state, "abandoned"}} in reasons
    end
  end

  describe "no verdict yet" do
    test "a deploy that has not settled leaves the story where it is" do
      # The ordinary case for a story that reached `deployed` seconds ago. Escalating on it
      # would make the common path the escalating one.
      result = judge(deployment: deployment(state: :pending), contains: :not_attempted)

      assert %Result{decision: :unresolved, reasons: reasons} = result
      assert {:deploy_in_flight, @deployed, @merge} in reasons
      assert is_nil(result.retry_after)
      # It says nothing to the reporter, exactly as an escalation does.
      assert result.resolution == Resolution.for_verdict(:escalated)
    end

    for reason <- [
          {:github_unreachable, :timeout},
          {:github_api_error, 500},
          {:github_api_error, 429}
        ] do
      test "a TRANSIENT forge fault (#{inspect(reason)}) decides nothing" do
        reason = unquote(Macro.escape(reason))
        result = judge(deployment: {:error, reason}, contains: :not_attempted)

        assert %Result{decision: :unresolved, reasons: reasons} = result
        assert {:deployment_unavailable, reason} in reasons
      end
    end

    test "the classification is the merge gate's, not a second opinion about GitHub's 403" do
      # A BARE 403 is a permanent permission denial and escalates; a rate-limit 403 waits.
      # The whole point of sharing `MergePrecondition.transient?/1` is that the two gates
      # cannot disagree about which is which.
      bare = judge(deployment: {:error, {:github_api_error, 403}}, contains: :not_attempted)
      limited = judge(deployment: {:error, {:github_rate_limited, 403, 60}})

      assert bare.decision == :failed
      assert limited.decision == :unresolved
    end

    test "the retry_after the forge asked for is carried, and the LONGEST of them wins" do
      result =
        judge(
          deployment: {:error, {:github_rate_limited, 403, 30}},
          contains: {:error, {:github_rate_limited, 403, 90}}
        )

      assert %Result{decision: :unresolved, retry_after: 90} = result
    end

    test "a transient fault decides even when something else is also broken" do
      # Nothing was established, so nothing transitions — but the permanent problem is still
      # reported, so a caller fixing it need not wait for the forge to hear about it.
      result =
        judge(
          repo: {:error, {:no_intake_source, "p"}},
          deployment: {:error, {:github_unreachable, :timeout}},
          contains: :not_attempted
        )

      assert %Result{decision: :unresolved, reasons: reasons} = result
      assert {:deployment_unavailable, {:github_unreachable, :timeout}} in reasons
      assert {:repository_unresolved, {:no_intake_source, "p"}} in reasons
    end
  end

  test "a containment answer the forge could not give is never read as containment" do
    result = judge(deployment: deployment(), contains: {:error, {:unreadable_compare, :map}})

    assert %Result{decision: :failed, reasons: reasons} = result
    assert {:containment_unavailable, {:unreadable_compare, :map}} in reasons
  end

  test "a fact of an unexpected SHAPE is a failure, never a pass" do
    result = judge(deployment: :yes, contains: :not_attempted)

    assert %Result{decision: :failed, reasons: reasons} = result
    assert {:deployment_unavailable, {:missing_fact, :yes}} in reasons
  end

  test "the transitions and the bound are named by the module, not restated by callers" do
    assert PostDeployVerification.success_transition() == {:deployed, :verified, :forward}

    assert PostDeployVerification.failure_transition() ==
             {:deployed, :escalated, :verification_failed}

    assert PostDeployVerification.max_consecutive_unresolved() > 0
  end

  # -- helpers -----------------------------------------------------------------------------

  defp judge(opts) do
    PostDeployVerification.judge(%{
      repo: Keyword.get(opts, :repo, {:ok, @repo}),
      environment: "production",
      merge_sha: Keyword.get(opts, :merge_sha, @merge),
      deployment: Keyword.get(opts, :deployment, deployment()),
      contains: Keyword.get(opts, :contains, :not_attempted)
    })
  end

  defp deployment(opts \\ []) do
    {:ok,
     %{
       id: 77,
       sha: Keyword.get(opts, :sha, @deployed),
       state: Keyword.get(opts, :state, :success)
     }}
  end
end
