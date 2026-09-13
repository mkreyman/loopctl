defmodule Loopctl.Delivery.PostDeployVerificationJudgeTest do
  @moduledoc """
  `Loopctl.Delivery.PostDeployVerification.judge/1` — the whole decision, as a pure function
  of its facts (issue #803 §9, issue #805 item 2).

  Pure, so every fail-closed path is tested with no database and no forge: the facts a live
  sweep would have gathered arrive here as `{:ok, value}` or `{:error, reason}`, which is
  exactly how an unreachable GitHub, a deploy that has not started and a deploy still in
  flight present themselves.

  The deployments arrive ALREADY ANNOTATED with containment, because that is what `gather/3`
  produces: it walks them newest-first and asks the forge only until one answers `true`.
  """

  use ExUnit.Case, async: true

  alias Loopctl.Delivery.PostDeployVerification
  alias Loopctl.Delivery.PostDeployVerification.Result
  alias Loopctl.Delivery.Resolution

  @repo "acme/widgets"
  @merge String.duplicate("a", 40)
  @deployed String.duplicate("b", 40)
  @other String.duplicate("c", 40)

  @merged_at ~U[2026-09-13 12:00:00.000000Z]

  describe "the merge is running" do
    test "a deployment that carries it and succeeded verifies" do
      result = judge(deployments: [deployment(sha: @merge, contains: true)])

      assert %Result{decision: :verified, reasons: []} = result
      assert result.repo == @repo
      assert result.merge_sha == @merge
      assert result.deployed_sha == @merge
      assert result.deployment_state == :success
      assert result.deployment_id == 77
      assert is_nil(result.unresolved_kind)
    end

    test "a merge BEHIND the deployed commit still verifies" do
      # Merges queue. A story merged at 10:00 and shipped inside the 10:04 deploy of a later
      # merge HAS shipped, and sha equality would escalate it.
      result = judge(deployments: [deployment(contains: true)])

      assert %Result{decision: :verified} = result
      assert result.deployed_sha == @deployed
    end

    test "an older carrying SUCCESS beats a newer carrying FAILURE" do
      # THE case, with the containment answers GitHub would actually give. A merges and
      # deploy 1 carries it; B merges and deploy 2 fails. B is a DESCENDANT of A, so deploy
      # 2 carries A's merge too — `contains: false` there is an answer the forge cannot
      # give, and stubbing it that way made the guard vacuous. With both carrying, halting
      # at the first (newest) carrier escalates A although A's code is running.
      result =
        judge(
          deployments: [
            deployment(id: 2, sha: @other, state: :failure, contains: true),
            deployment(id: 1, sha: @deployed, state: :success, contains: true)
          ]
        )

      assert %Result{decision: :verified} = result
      assert result.deployment_id == 1
      assert result.deployed_sha == @deployed
    end

    test "a deployment that reported success and THEN failed has NOT shipped" do
      # `succeeded?` read before the settled-failure set verified this: statuses of
      # `[error, success]` give a latest state of `:error` with the flag true. That is a
      # two-phase deploy whose smoke test failed, and it is also what a rollback job writes
      # onto the original record. The flag is scoped to the case it was introduced for.
      for state <- [:failure, :error] do
        result =
          judge(deployments: [deployment(state: state, succeeded?: true, contains: true)])

        assert %Result{decision: :failed, reasons: reasons} = result
        assert {:deploy_not_successful, state, @deployed, @merge} in reasons
      end
    end

    test "an INACTIVE deployment that once succeeded still shipped" do
      # GitHub writes `inactive` onto an earlier deployment the moment a newer one succeeds
      # (`auto_inactive`, on any environment not flagged `production_environment` — and the
      # name is configurable). Reading the latest state alone escalated a story whose
      # deployment had shipped perfectly well.
      result =
        judge(deployments: [deployment(state: :inactive, succeeded?: true, contains: true)])

      assert %Result{decision: :verified} = result
    end

    test "and ONLY a verification produces a `shipped` resolution" do
      # #805 item 1: the merge is not the ship. Every other decision says nothing.
      verified = judge(deployments: [deployment(contains: true)])
      assert verified.resolution == Resolution.for_verdict(:shipped)
      assert verified.resolution.close?
      assert verified.resolution.label == "loopctl:resolution-shipped"
    end
  end

  describe "the deploy that WOULD have carried it failed" do
    for state <- [:failure, :error, :inactive] do
      test "a #{state} deployment that carries the merge and NEVER succeeded escalates" do
        state = unquote(state)

        result =
          judge(deployments: [deployment(state: state, succeeded?: false, contains: true)])

        assert %Result{decision: :failed, reasons: reasons} = result
        assert {:deploy_not_successful, state, @deployed, @merge} in reasons
        assert result.resolution == Resolution.for_verdict(:escalated)
        refute result.resolution.close?
      end
    end

    test "every carrying deployment must have failed — one success anywhere is enough" do
      result =
        judge(
          deployments: [
            deployment(id: 3, sha: @other, state: :failure, contains: true),
            deployment(id: 2, sha: @deployed, state: :inactive, succeeded?: true, contains: true),
            deployment(id: 1, sha: @deployed, state: :error, contains: true)
          ]
        )

      assert %Result{decision: :verified, deployment_id: 2} = result
    end

    test "a failed deployment that does NOT carry the merge is passed over" do
      # Somebody else's deploy failing says nothing about this story.
      result = judge(deployments: [deployment(state: :failure, contains: false)])

      assert %Result{decision: :unresolved, unresolved_kind: :deploy_pending} = result
      refute Enum.any?(result.reasons, &match?({:deploy_not_successful, _, _, _}, &1))
    end
  end

  describe "no verdict yet" do
    test "NO deployment since the merge is waiting, not failure — the happy path" do
      # Between the runner reporting `deployed` and the deploy job creating its record
      # (queued workflow, cold runner: 30-120s) there is nothing that could carry the merge.
      # This used to escalate every healthy delivery.
      result = judge(deployments: [])

      assert %Result{decision: :unresolved, unresolved_kind: :deploy_pending} = result
      assert {:deploy_not_started, @merge, "production"} in result.reasons
      assert is_nil(result.retry_after)
      assert result.resolution == Resolution.for_verdict(:escalated)
    end

    test "a deployment carrying the merge that is still running waits" do
      result = judge(deployments: [deployment(state: :pending, contains: true)])

      assert %Result{decision: :unresolved, unresolved_kind: :deploy_pending} = result
      assert {:deploy_in_flight, @deployed, @merge} in result.reasons
    end

    test "a failed carrier does not escalate while another carrier is still running" do
      result =
        judge(
          deployments: [
            deployment(id: 2, sha: @other, state: :pending, contains: true),
            deployment(id: 1, sha: @deployed, state: :failure, contains: true)
          ]
        )

      assert %Result{decision: :unresolved, unresolved_kind: :deploy_pending} = result
    end

    test "a deployment that has not settled waits even when it is not ours yet" do
      result = judge(deployments: [deployment(state: :pending, contains: false)])

      assert %Result{decision: :unresolved, unresolved_kind: :deploy_pending} = result
      assert {:deploy_in_flight, @deployed, @merge} in result.reasons
    end

    test "settled deployments that none carry the merge WAIT rather than escalating" do
      # A rollback, or a deploy from another branch. Both are bounded by the in-flight
      # count, which escalates naming both shas; concluding failure here read a concurrent
      # deploy as a broken one.
      result = judge(deployments: [deployment(state: :success, contains: false)])

      assert %Result{decision: :unresolved, unresolved_kind: :deploy_pending} = result
      assert {:merge_not_deployed, @merge, @deployed} in result.reasons
    end

    for reason <- [
          {:github_unreachable, :timeout},
          {:github_api_error, 500},
          {:github_api_error, 429}
        ] do
      test "a TRANSIENT forge fault (#{inspect(reason)}) decides nothing" do
        reason = unquote(Macro.escape(reason))
        result = judge(deployments: {:error, reason})

        assert %Result{decision: :unresolved, unresolved_kind: :forge_fault} = result
        assert {:deployments_unavailable, reason} in result.reasons
      end
    end

    test "the two kinds of waiting are DISTINCT, because their bounds differ" do
      # One number for both is how a slow-but-healthy deploy inherited the forge's ten
      # minutes and escalated the normal path.
      fault = judge(deployments: {:error, {:github_unreachable, :timeout}})
      pending = judge(deployments: [])

      assert fault.unresolved_kind == :forge_fault
      assert pending.unresolved_kind == :deploy_pending

      assert PostDeployVerification.max_consecutive_unresolved(:deploy_pending) >
               PostDeployVerification.max_consecutive_unresolved(:forge_fault)
    end

    test "the classification is the merge gate's, not a second opinion about GitHub's 403" do
      bare = judge(deployments: {:error, {:github_api_error, 403}})
      limited = judge(deployments: {:error, {:github_rate_limited, 403, 60}})

      assert bare.decision == :failed
      assert limited.decision == :unresolved
    end

    test "the retry_after the forge asked for is carried, and the LONGEST of them wins" do
      result =
        judge(
          repo: {:error, {:github_rate_limited, 403, 30}},
          merged_at: {:error, {:github_rate_limited, 403, 90}},
          deployments: :not_attempted
        )

      assert %Result{decision: :unresolved, retry_after: 90} = result
    end

    test "a transient fault decides even when something else is also broken" do
      result =
        judge(
          repo: {:error, {:no_intake_source, "p"}},
          deployments: {:error, {:github_unreachable, :timeout}}
        )

      assert %Result{decision: :unresolved, reasons: reasons} = result
      assert {:deployments_unavailable, {:github_unreachable, :timeout}} in reasons
      assert {:repository_unresolved, {:no_intake_source, "p"}} in reasons
    end
  end

  describe "an INCOMPLETE page" do
    test "does NOT stop a carrying success from verifying" do
      # Refusing on incompleteness before judging containment discarded a definitive answer:
      # a shipped story escalated on its first sweep naming the cap, and permanently, since
      # `since` is pinned to the merge and deployments only accumulate.
      result =
        judge(
          deployments:
            page([deployment(contains: true)], {:too_many_deployments_since_merge, 9, 5})
        )

      assert %Result{decision: :verified, reasons: []} = result
    end

    test "escalates only in the ABSENCE of one, naming what was incomplete" do
      reason = {:deployment_page_exhausted, 30, @merged_at}

      result = judge(deployments: page([deployment(state: :success, contains: false)], reason))

      assert %Result{decision: :failed, reasons: reasons} = result
      assert {:deployments_incomplete, reason} in reasons
    end

    test "turns an in-flight WAIT into an escalation, because the wait may never end" do
      reason = {:too_many_deployments_since_merge, 9, 5}

      result = judge(deployments: page([deployment(state: :pending, contains: false)], reason))

      assert %Result{decision: :failed, reasons: reasons} = result
      assert {:deployments_incomplete, reason} in reasons
    end
  end

  describe "fails closed" do
    test "a story with no recorded merge_sha" do
      result = judge(merge_sha: nil, deployments: [])

      assert %Result{decision: :failed, reasons: [:merge_sha_not_recorded]} = result
    end

    test "a story whose merge TIME cannot be established" do
      # Without it every deployment is back in the candidate set, which is the failure the
      # timestamp exists to remove. It is a custody-integrity gap, like a missing merge sha.
      result = judge(merged_at: {:error, :no_merge_event}, deployments: :not_attempted)

      assert %Result{decision: :failed, reasons: reasons} = result
      assert {:merge_time_unknown, :no_merge_event} in reasons
    end

    test "a repository that cannot be resolved" do
      result =
        judge(repo: {:error, {:no_intake_source, "p"}}, deployments: :not_attempted)

      assert %Result{decision: :failed, reasons: reasons} = result
      assert {:repository_unresolved, {:no_intake_source, "p"}} in reasons
    end

    for reason <- [{:github_api_error, 404}, {:github_api_error, 403}, :unreadable] do
      test "a NON-transient forge fault (#{inspect(reason)}) escalates rather than waiting" do
        reason = unquote(Macro.escape(reason))
        result = judge(deployments: {:error, reason})

        assert %Result{decision: :failed, reasons: reasons} = result
        assert {:deployments_unavailable, reason} in reasons
      end
    end

    test "a state this module does not know NEVER falls through to a verification" do
      # The dispatch used to fail OPEN: anything not pending and not in the failure list
      # reached the containment check and could verify.
      result =
        judge(deployments: [deployment(state: :something_new, succeeded?: false, contains: true)])

      assert %Result{decision: :failed, reasons: reasons} = result
      assert {:unrecognised_deployment_state, :something_new} in reasons
    end

    test "a fact of an unexpected SHAPE is a failure, never a pass" do
      result = judge(deployments: :yes)

      assert %Result{decision: :failed, reasons: reasons} = result
      assert {:deployments_unavailable, {:missing_fact, :yes}} in reasons
    end

    test "a PAGE of an unexpected shape is a failure too" do
      result = judge(deployments: {:ok, [%{id: 1}]})

      assert %Result{decision: :failed, reasons: reasons} = result
      assert {:deployments_unavailable, {:missing_fact, {:list, 1}}} in reasons
    end
  end

  test "the transitions and the bounds are named by the module, not restated by callers" do
    assert PostDeployVerification.success_transition() == {:deployed, :verified, :forward}

    assert PostDeployVerification.failure_transition() ==
             {:deployed, :escalated, :verification_failed}

    for kind <- [:forge_fault, :deploy_pending] do
      assert PostDeployVerification.max_consecutive_unresolved(kind) > 0
    end

    # The total sits ABOVE the longest single-kind bound, or it would fire on a run that
    # never alternated and the two per-kind numbers would be decoration.
    assert PostDeployVerification.max_consecutive_total() >
             PostDeployVerification.max_consecutive_unresolved(:deploy_pending)

    assert PostDeployVerification.clock_tolerance_seconds() > 0
  end

  # -- helpers -----------------------------------------------------------------------------

  defp judge(opts) do
    PostDeployVerification.judge(%{
      repo: Keyword.get(opts, :repo, {:ok, @repo}),
      environment: "production",
      merge_sha: Keyword.get(opts, :merge_sha, @merge),
      merged_at: Keyword.get(opts, :merged_at, {:ok, @merged_at}),
      deployments: wrap(Keyword.get(opts, :deployments, []))
    })
  end

  defp wrap(deployments) when is_list(deployments),
    do: {:ok, %{deployments: deployments, incomplete: nil}}

  defp wrap(other), do: other

  # `succeeded?` defaults from the state the way the adapter derives it — `success` now, or
  # anything that once was — and is set explicitly for the case that matters: an `:inactive`
  # deployment that DID ship, which is what GitHub leaves behind whenever a newer deploy
  # succeeds.
  defp page(deployments, incomplete),
    do: {:ok, %{deployments: deployments, incomplete: incomplete}}

  defp deployment(opts) do
    state = Keyword.get(opts, :state, :success)

    %{
      id: Keyword.get(opts, :id, 77),
      sha: Keyword.get(opts, :sha, @deployed),
      state: state,
      succeeded?: Keyword.get(opts, :succeeded?, state == :success),
      created_at: Keyword.get(opts, :created_at, DateTime.add(@merged_at, 60)),
      contains: Keyword.fetch!(opts, :contains)
    }
  end
end
