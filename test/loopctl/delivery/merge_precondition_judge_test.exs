defmodule Loopctl.Delivery.MergePreconditionJudgeTest do
  @moduledoc """
  `Loopctl.Delivery.MergePrecondition.judge/1` — the merge precondition's whole decision, as
  a pure function of its facts (issue #803, design §5 "Both gates run twice" and §9).

  Pure, so every fail-closed path is tested with no database and no forge: the facts a
  live run would have gathered arrive here as `{:ok, value}` or `{:error, reason}`, which
  is exactly how an unreachable GitHub, a project with no repository and a diff that did
  not parse present themselves.

  The trigger configuration under test is `config/test.exs`'s synthetic document for
  `acme/widgets` — `priv/rates/**` as the effect path, `lib/widgets_web/router.ex` as the
  human path, 12 files / 1000 lines. It is loaded through
  `Loopctl.DeliveryGates.load_triggers/0`, so the config key, the document and the checksum
  are all exercised rather than hand-built.
  """

  use ExUnit.Case, async: true

  alias Loopctl.Delivery.MergePrecondition
  alias Loopctl.Delivery.MergePrecondition.Verdict
  alias Loopctl.DeliveryGates
  alias Loopctl.DeliveryGates.Triggers

  @repo "acme/widgets"
  @head String.duplicate("a", 40)
  @base String.duplicate("b", 40)

  # A repository whose files satisfy every configured pattern, so the stale-trigger guard
  # is silent and a test that is not about staleness measures what it says it does.
  @repo_files ["priv/rates/2026.csv", "lib/widgets_web/router.ex", "lib/widgets/thing.ex"]

  describe "a clean pull request" do
    test "allows a change under the bound that touches no trigger" do
      verdict = judge(files: ["lib/widgets/thing.ex"], diffstat: %{files: 1, changed_lines: 10})

      assert %Verdict{decision: :allow, reasons: []} = verdict
      assert verdict.repo == @repo
      assert verdict.pr_number == 4242
      assert verdict.head_sha == @head
      assert verdict.merge_base_sha == @base
      assert verdict.custody == :ok
      assert verdict.gate_a_inputs == :caller_asserted
    end

    test "judges the same facts the same way twice" do
      facts = facts(files: ["lib/widgets/thing.ex"], diffstat: %{files: 1, changed_lines: 10})

      assert MergePrecondition.judge(facts) == MergePrecondition.judge(facts)
      assert MergePrecondition.judge(facts).decision == :allow
    end

    test "a DIFFERENT diff at the same pull request is judged on the new diff" do
      allowed = judge(files: ["lib/widgets/thing.ex"], diffstat: %{files: 1, changed_lines: 10})

      refused =
        judge(files: ["lib/widgets_web/router.ex"], diffstat: %{files: 1, changed_lines: 10})

      assert allowed.decision == :allow
      assert refused.decision == :refuse
    end
  end

  describe "each trigger class escalates" do
    test "a human path refuses and names the pattern" do
      verdict =
        judge(files: ["lib/widgets_web/router.ex"], diffstat: %{files: 1, changed_lines: 3})

      assert verdict.decision == :refuse

      assert {:gate_b, {:human_path, "lib/widgets_web/router.ex", "lib/widgets_web/router.ex"}} in verdict.reasons
    end

    test "an effect path with NO proof refuses rather than merging" do
      verdict = judge(files: ["priv/rates/2026.csv"], diffstat: %{files: 1, changed_lines: 2})

      assert verdict.decision == :refuse
      assert verdict.gate_b.outcome == :prove_effect
      assert :effect_proof_required in verdict.reasons
    end

    test "an effect path with a PASSING but CALLER-ASSERTED proof still refuses" do
      verdict =
        judge(
          files: ["priv/rates/2026.csv"],
          diffstat: %{files: 1, changed_lines: 2},
          effect_proof: %{
            intent: {:changes, ["fixture-a"]},
            fixture_set: ["fixture-a", "fixture-b"],
            fixture_results: %{"fixture-a" => :changed, "fixture-b" => :unchanged},
            coverage: %{required: ["T1019"], covered: ["T1019"]}
          }
        )

      # The proof is an assertion by the principal that drives the merge, so it is judged
      # and recorded and it does NOT clear the gate. The server-side harness is what would.
      assert verdict.decision == :refuse
      assert verdict.proof.verdict == :pass
      assert {:effect_proof_caller_asserted, :pass} in verdict.reasons
    end

    test "an effect path with a FAILING proof refuses and routes to Gate A" do
      verdict =
        judge(
          files: ["priv/rates/2026.csv"],
          diffstat: %{files: 1, changed_lines: 2},
          effect_proof: %{
            intent: {:changes, ["fixture-a"]},
            fixture_set: ["fixture-a", "fixture-b"],
            # The intended fixture did not change AND an unintended one did: both halves.
            fixture_results: %{"fixture-a" => :unchanged, "fixture-b" => :changed},
            coverage: %{required: ["T1019"], covered: []}
          }
        )

      assert verdict.decision == :refuse
      assert verdict.proof.verdict == :fail
      assert verdict.proof.route == :gate_a
      assert Enum.any?(verdict.reasons, &match?({:effect_proof, _}, &1))
    end

    test "a proof of the wrong shape is a FAILED proof, never an absent one" do
      verdict =
        judge(
          files: ["priv/rates/2026.csv"],
          diffstat: %{files: 1, changed_lines: 2},
          effect_proof: %{"intent" => "whatever"}
        )

      assert verdict.decision == :refuse
      assert verdict.proof.verdict == :fail
      assert Enum.any?(verdict.reasons, &match?({:effect_proof, {:invalid_effect_proof, _}}, &1))
    end

    test "a rename OUT of a guarded path is still a touch of it" do
      verdict =
        judge(
          files: ["docs/rates.csv"],
          renames: [{"priv/rates/2026.csv", "docs/rates.csv"}],
          diffstat: %{files: 1, changed_lines: 4}
        )

      assert verdict.decision == :refuse
      assert verdict.gate_b.outcome == :prove_effect
      assert {"priv/rates/2026.csv", "priv/rates/**"} in verdict.gate_b.effect_matches
    end

    test "a DELETION under a guarded path is a change to it" do
      verdict = judge(files: ["priv/rates/2026.csv"], diffstat: %{files: 1, changed_lines: 40})

      assert verdict.gate_b.outcome == :prove_effect
      assert verdict.decision == :refuse
    end
  end

  describe "the hard bound" do
    test "12 files and 1000 lines pass" do
      verdict = judge(files: files(12), diffstat: %{files: 12, changed_lines: 1000})
      assert verdict.decision == :allow
    end

    test "13 files escalates" do
      verdict = judge(files: files(13), diffstat: %{files: 13, changed_lines: 10})

      assert verdict.decision == :refuse
      assert {:hard_bound_files_exceeded, 13, 12} in verdict.reasons
    end

    test "1001 changed lines escalates" do
      verdict = judge(files: ["lib/widgets/thing.ex"], diffstat: %{files: 1, changed_lines: 1001})

      assert verdict.decision == :refuse
      assert {:hard_bound_changed_lines_exceeded, 1001, 1000} in verdict.reasons
    end

    test "a CONFIGURATION that raises the limit cannot raise the hard bound" do
      # 500/100000 in the trigger document, so Gate B itself is satisfied by 13 files —
      # and the change is still refused, by the design's ceiling rather than by Gate B.
      verdict =
        judge(
          files: files(13),
          diffstat: %{files: 13, changed_lines: 5_000},
          triggers: loose_triggers()
        )

      assert verdict.gate_b.outcome == :clear
      assert verdict.decision == :refuse
      assert {:hard_bound_files_exceeded, 13, 12} in verdict.reasons
      assert {:hard_bound_changed_lines_exceeded, 5_000, 1_000} in verdict.reasons
    end

    test "the bound reads the FORGE's diffstat, not the length of the file list" do
      # One name in the list, 13 files in the authoritative diffstat: a forge that returned
      # a short list must not shrink the bound that judges the change.
      verdict = judge(files: ["lib/widgets/thing.ex"], diffstat: %{files: 13, changed_lines: 10})

      assert verdict.decision == :refuse
      assert {:hard_bound_files_exceeded, 13, 12} in verdict.reasons
    end

    test "a diffstat that is not a diffstat escalates" do
      verdict = judge(files: ["lib/widgets/thing.ex"], diffstat: nil)

      assert verdict.decision == :refuse
      assert Enum.any?(verdict.reasons, &match?({:invalid_diffstat, _}, &1))
    end
  end

  describe "Gate A runs again at merge" do
    test "a trio that disagrees escalates" do
      verdict =
        judge(
          files: ["lib/widgets/thing.ex"],
          diffstat: %{files: 1, changed_lines: 1},
          trio_outputs: [trio("story"), trio("story"), trio("escalate")]
        )

      assert verdict.decision == :refuse
      assert verdict.gate_a.decision == :escalate
      assert Enum.any?(verdict.reasons, &match?({:gate_a, {:verdict_disagreement, _}}, &1))
    end

    test "a MISSING trio escalates — Gate A judges it, and it fails closed" do
      verdict =
        judge(
          files: ["lib/widgets/thing.ex"],
          diffstat: %{files: 1, changed_lines: 1},
          trio_outputs: nil
        )

      assert verdict.decision == :refuse
      assert {:gate_a, {:trio_size, :not_a_list}} in verdict.reasons
    end

    test "a unanimous REJECT verdict does not merge" do
      verdict =
        judge(
          files: ["lib/widgets/thing.ex"],
          diffstat: %{files: 1, changed_lines: 1},
          trio_outputs: List.duplicate(trio("reject"), 3)
        )

      assert verdict.decision == :refuse
      assert {:trio_verdict, :reject} in verdict.reasons
    end

    test "an agent escalation is ADDED and nothing removes a computed trigger" do
      verdict =
        judge(
          files: ["lib/widgets/thing.ex"],
          diffstat: %{files: 1, changed_lines: 1},
          trio_outputs: [
            trio("story"),
            trio("story"),
            Map.put(trio("story"), "escalation_reasons", ["workflow_change_not_defect_fix"])
          ]
        )

      assert verdict.decision == :refuse
      assert {:gate_a, {:workflow_change, 2}} in verdict.reasons
    end
  end

  describe "the trigger configuration fails closed" do
    test "a MISSING configuration escalates unconditionally" do
      verdict =
        judge(
          files: ["lib/widgets/thing.ex"],
          diffstat: %{files: 1, changed_lines: 1},
          triggers: Triggers.parse(nil, nil)
        )

      assert verdict.decision == :refuse
      assert {:gate_b, {:config_error, :missing_config}} in verdict.reasons
    end

    test "an EMPTY configuration escalates unconditionally" do
      verdict =
        judge(
          files: ["lib/widgets/thing.ex"],
          diffstat: %{files: 1, changed_lines: 1},
          triggers: Triggers.parse("", sha256(""))
        )

      assert verdict.decision == :refuse
      assert {:gate_b, {:config_error, :missing_config}} in verdict.reasons
    end

    test "a GARBAGE configuration escalates unconditionally" do
      document = "{not json at all"

      verdict =
        judge(
          files: ["lib/widgets/thing.ex"],
          diffstat: %{files: 1, changed_lines: 1},
          triggers: Triggers.parse(document, sha256(document))
        )

      assert verdict.decision == :refuse
      assert {:gate_b, {:config_error, :invalid_json}} in verdict.reasons
    end

    test "a configuration whose CHECKSUM does not match is never interpreted" do
      document = valid_document(12, 1000)

      verdict =
        judge(
          files: ["lib/widgets/thing.ex"],
          diffstat: %{files: 1, changed_lines: 1},
          triggers: Triggers.parse(document, sha256("something else"))
        )

      assert verdict.decision == :refuse
      assert {:gate_b, {:config_error, :checksum_mismatch}} in verdict.reasons
    end

    test "an unknown repository escalates" do
      verdict =
        judge(
          repo: {:ok, "acme/not-configured"},
          files: ["lib/widgets/thing.ex"],
          diffstat: %{files: 1, changed_lines: 1}
        )

      assert verdict.decision == :refuse
      assert {:gate_b, {:unknown_repo, "acme/not-configured"}} in verdict.reasons
    end

    test "a project with no intake source escalates rather than guessing a repository" do
      verdict = judge(repo: {:error, {:no_intake_source, "p-1"}})

      assert verdict.decision == :refuse
      assert {:repository_unresolved, {:no_intake_source, "p-1"}} in verdict.reasons
    end
  end

  describe "a TRANSIENT forge fault is not a verdict" do
    # Escalating is expensive: `escalated` is human-only, so one blip would park a story
    # until Mark acts. These decide nothing and transition nothing.
    test "an unreachable forge is :unevaluated, not a refusal" do
      verdict = judge(pull_request: {:error, {:github_unreachable, :timeout}})

      assert verdict.decision == :unevaluated
      assert {:pull_request_unavailable, {:github_unreachable, :timeout}} in verdict.reasons
    end

    test "a rate-limited forge is :unevaluated, and carries the delay it asked for" do
      verdict = judge(pull_request: {:error, {:github_rate_limited, 403, 90}})

      assert verdict.decision == :unevaluated
      assert {:pull_request_unavailable, {:github_rate_limited, 403, 90}} in verdict.reasons
      assert verdict.retry_after == 90
    end

    test "a rate limit with no stated delay is still :unevaluated, with no retry_after" do
      verdict = judge(pull_request: {:error, {:github_rate_limited, 429, nil}})

      assert verdict.decision == :unevaluated
      assert is_nil(verdict.retry_after)
    end

    test "a 5xx is :unevaluated" do
      verdict = judge(pull_request: {:error, {:github_api_error, 502}})
      assert verdict.decision == :unevaluated
    end

    test "a merge-base file tree that 500s is :unevaluated" do
      verdict =
        judge(
          files: ["lib/widgets/thing.ex"],
          diffstat: %{files: 1, changed_lines: 1},
          base_files: {:error, {:github_api_error, 500}}
        )

      assert verdict.decision == :unevaluated
      assert {:base_files_unavailable, {:github_api_error, 500}} in verdict.reasons
    end

    test "an unevaluated verdict still reports everything else that is wrong" do
      verdict =
        judge(
          pull_request: {:error, {:github_unreachable, :timeout}},
          custody: {:error, :not_verified},
          trio_outputs: nil
        )

      assert verdict.decision == :unevaluated
      assert {:custody, :not_verified} in verdict.reasons
      assert {:gate_a, {:trio_size, :not_a_list}} in verdict.reasons
    end

    test "transient?/1 is narrow: a 404, a 401 and an unreadable body are NOT transient" do
      assert MergePrecondition.transient?({:github_unreachable, :closed})
      assert MergePrecondition.transient?({:github_api_error, 429})
      assert MergePrecondition.transient?({:github_api_error, 503})
      assert MergePrecondition.transient?({:github_rate_limited, 403, 60})
      refute MergePrecondition.transient?({:github_api_error, 404})
      refute MergePrecondition.transient?({:github_api_error, 401})
      refute MergePrecondition.transient?({:unreadable_pull_request, :invalid_field_types})
      refute MergePrecondition.transient?({:tree_truncated, "abc"})
    end

    test "a BARE 403 is a permission denial and escalates — it is not a rate limit" do
      # GitHub answers both with 403. A fine-grained token that cannot read a repository's
      # contents 403s for ever, so treating every 403 as transient is a story retried for
      # ever with nobody told.
      refute MergePrecondition.transient?({:github_api_error, 403})

      verdict = judge(pull_request: {:error, {:github_api_error, 403}})

      assert verdict.decision == :refuse
      assert {:pull_request_unavailable, {:github_api_error, 403}} in verdict.reasons
    end
  end

  describe "a NON-transient forge failure is a refusal" do
    test "a 404 escalates — the repository or the token is wrong, and a human fixes that" do
      verdict = judge(pull_request: {:error, {:github_api_error, 404}})

      assert verdict.decision == :refuse
      assert {:pull_request_unavailable, {:github_api_error, 404}} in verdict.reasons
    end

    test "a head file tree GitHub truncated escalates" do
      verdict =
        judge(
          files: ["lib/widgets/thing.ex"],
          diffstat: %{files: 1, changed_lines: 1},
          head_files: {:error, {:tree_truncated, @head}}
        )

      assert verdict.decision == :refuse
      assert {:head_files_unavailable, {:tree_truncated, @head}} in verdict.reasons
    end

    test "BOTH unreadable refs are reported, not just the first" do
      verdict =
        judge(
          files: ["lib/widgets/thing.ex"],
          diffstat: %{files: 1, changed_lines: 1},
          head_files: {:error, {:tree_truncated, @head}},
          base_files: {:error, {:tree_truncated, @base}}
        )

      assert verdict.decision == :refuse
      assert {:head_files_unavailable, {:tree_truncated, @head}} in verdict.reasons
      assert {:base_files_unavailable, {:tree_truncated, @base}} in verdict.reasons
    end

    test "a diff that did not parse escalates, and no file list survives it" do
      verdict =
        judge(
          diff: {:error, {:unmerged, "lib/widgets/thing.ex"}},
          diffstat: %{files: 1, changed_lines: 1}
        )

      assert verdict.decision == :refuse
      assert {:gate_b, {:unreadable_diff, {:unmerged, "lib/widgets/thing.ex"}}} in verdict.reasons
    end

    test "an EMPTY diff escalates rather than reading as touching nothing" do
      verdict = judge(files: [], diffstat: %{files: 0, changed_lines: 0})

      assert verdict.decision == :refuse
      assert {:gate_b, :no_files} in verdict.reasons
    end
  end

  describe "the stale-trigger guard runs at BOTH refs" do
    test "a pattern matching at the merge base and NOT at the head escalates" do
      # The head no longer has anything under `priv/rates/**`: a rename moved the guarded
      # path away and the configuration has not caught up.
      verdict =
        judge(
          files: ["lib/widgets/thing.ex"],
          diffstat: %{files: 1, changed_lines: 1},
          head_files: {:ok, ["lib/widgets_web/router.ex", "lib/widgets/thing.ex"]}
        )

      assert verdict.decision == :refuse
      assert {:gate_b, {:stale_trigger, "priv/rates/**"}} in verdict.reasons
    end

    test "a pattern matching at the head and NOT at the merge base escalates" do
      verdict =
        judge(
          files: ["lib/widgets/thing.ex"],
          diffstat: %{files: 1, changed_lines: 1},
          base_files: {:ok, ["lib/widgets_web/router.ex", "lib/widgets/thing.ex"]}
        )

      assert verdict.decision == :refuse
      assert {:gate_b, {:stale_trigger, "priv/rates/**"}} in verdict.reasons
    end

    test "a pattern matching at NEITHER ref escalates once" do
      files = {:ok, ["lib/widgets_web/router.ex"]}

      verdict =
        judge(
          files: ["lib/widgets/thing.ex"],
          diffstat: %{files: 1, changed_lines: 1},
          head_files: files,
          base_files: files
        )

      assert verdict.decision == :refuse

      assert Enum.count(verdict.reasons, &(&1 == {:gate_b, {:stale_trigger, "priv/rates/**"}})) ==
               1
    end
  end

  describe "the judged head must be the head CI ran on" do
    test "a head that does not match the recorded one goes back to implementing" do
      # A push after CI and verification. New commits are ordinary, so this is NOT an
      # escalation — but it does not merge either, because no CI run and no verifier saw it.
      recorded = String.duplicate("e", 40)

      verdict =
        judge(
          files: ["lib/widgets/thing.ex"],
          diffstat: %{files: 1, changed_lines: 1},
          recorded_head_sha: recorded
        )

      assert verdict.decision == :head_moved
      assert {:head_moved, @head, recorded} in verdict.reasons
    end

    test "a stage row with NO recorded head does not merge" do
      verdict =
        judge(
          files: ["lib/widgets/thing.ex"],
          diffstat: %{files: 1, changed_lines: 1},
          recorded_head_sha: nil
        )

      assert verdict.decision == :head_moved
      assert :head_sha_not_recorded in verdict.reasons
    end

    test "a moved head is NOT masked by a transient fault in a list it never reads" do
      # `gather/3` does not fetch the file lists once the head has moved, so this state is
      # unreachable through `evaluate/3` today — but `judge/1` is public and its contract
      # has to hold for any facts, and this is the clause that keeps an ordinary push from
      # becoming an escalation if the fetch ever runs again.
      verdict =
        judge(
          files: ["lib/widgets/thing.ex"],
          diffstat: %{files: 1, changed_lines: 1},
          recorded_head_sha: String.duplicate("e", 40),
          head_files: {:error, {:github_rate_limited, 429, 60}},
          base_files: {:error, {:github_rate_limited, 429, 60}}
        )

      assert verdict.decision == :head_moved
    end

    test "a moved head still reports the custody and Gate A problems it found" do
      verdict =
        judge(
          files: ["lib/widgets/thing.ex"],
          diffstat: %{files: 1, changed_lines: 1},
          recorded_head_sha: String.duplicate("e", 40),
          custody: {:error, :not_verified}
        )

      assert verdict.decision == :head_moved
      assert {:custody, :not_verified} in verdict.reasons
    end
  end

  describe "the custody precondition" do
    test "an unverified story is refused" do
      verdict =
        judge(
          files: ["lib/widgets/thing.ex"],
          diffstat: %{files: 1, changed_lines: 1},
          custody: {:error, :not_verified}
        )

      assert verdict.decision == :refuse
      assert verdict.custody == :not_verified
      assert {:custody, :not_verified} in verdict.reasons
    end

    test "a verifier sharing the implementer's lineage is refused" do
      verdict =
        judge(
          files: ["lib/widgets/thing.ex"],
          diffstat: %{files: 1, changed_lines: 1},
          custody: {:error, :self_verify_blocked}
        )

      assert verdict.decision == :refuse
      assert {:custody, :self_verify_blocked} in verdict.reasons
    end

    test "a custody fact that was never supplied refuses rather than defaulting to ok" do
      facts =
        [files: ["lib/widgets/thing.ex"], diffstat: %{files: 1, changed_lines: 1}]
        |> facts()
        |> Map.delete(:custody)

      verdict = MergePrecondition.judge(facts)

      assert verdict.decision == :refuse
      assert {:custody, :custody_unknown} in verdict.reasons
    end
  end

  describe "the pull request's own state" do
    test "an already-merged head the gate ALLOWED is :already_merged" do
      merge_sha = String.duplicate("c", 40)

      verdict =
        judge(
          merged?: true,
          state: "closed",
          merge_sha: merge_sha,
          recorded_allow_sha: @head,
          diffstat: %{files: 1, changed_lines: 1}
        )

      assert verdict.decision == :already_merged
      assert verdict.merge_sha == merge_sha
      assert verdict.reasons == []
    end

    test "an already-merged head with NO recorded allow is a refusal naming the sha" do
      # A merge performed around the gate, or after it refused. The last gate before an
      # outward effect must never report clean for an effect it did not authorise.
      merge_sha = String.duplicate("c", 40)

      verdict =
        judge(
          merged?: true,
          state: "closed",
          merge_sha: merge_sha,
          recorded_allow_sha: nil,
          diffstat: %{files: 1, changed_lines: 1}
        )

      assert verdict.decision == :refuse
      assert {:ungated_merge, merge_sha, :no_recorded_allow} in verdict.reasons
      # The sha is still reported, so the fact is not lost.
      assert verdict.merge_sha == merge_sha
    end

    test "an already-merged head with an allow for a DIFFERENT head is a refusal" do
      merge_sha = String.duplicate("c", 40)
      other = String.duplicate("d", 40)

      verdict =
        judge(
          merged?: true,
          state: "closed",
          merge_sha: merge_sha,
          recorded_allow_sha: other,
          diffstat: %{files: 1, changed_lines: 1}
        )

      assert verdict.decision == :refuse
      assert {:ungated_merge, merge_sha, {:allow_for_other_head, other}} in verdict.reasons
    end

    test "an already-merged pull request with NO merge sha is a refusal, not a strand" do
      # `advance/4` refuses a `merged` transition that names nothing, so reporting
      # already_merged here would leave the caller unable to record anything at all.
      verdict =
        judge(merged?: true, state: "closed", merge_sha: nil, recorded_allow_sha: @head)

      assert verdict.decision == :refuse
      assert :merged_without_sha in verdict.reasons
    end

    test "a TRANSIENT tree fault cannot suppress the ungated-merge escalation" do
      # The already-merged branch reads neither file list, so a rate-limited tree call is a
      # fault the decision never consumes — and suppressing the loudest signal this module
      # produces on one is exactly the failure the scoping prevents.
      merge_sha = String.duplicate("c", 40)

      verdict =
        judge(
          merged?: true,
          state: "closed",
          merge_sha: merge_sha,
          recorded_allow_sha: nil,
          head_files: {:error, {:github_rate_limited, 429, 60}},
          base_files: {:error, {:github_rate_limited, 429, 60}},
          diffstat: %{files: 1, changed_lines: 1}
        )

      assert verdict.decision == :refuse
      assert {:ungated_merge, merge_sha, :no_recorded_allow} in verdict.reasons
    end

    test "an authorised already-merged pull request still reports a custody problem" do
      verdict =
        judge(
          merged?: true,
          state: "closed",
          merge_sha: String.duplicate("c", 40),
          recorded_allow_sha: @head,
          custody: {:error, :not_verified}
        )

      # The effect is already out and the allow covers it, so this is not a refusal — but
      # the custody fact is on the verdict either way.
      assert verdict.decision == :already_merged
      assert verdict.custody == :not_verified
    end

    test "a pull request closed WITHOUT merging escalates" do
      verdict =
        judge(
          state: "closed",
          files: ["lib/widgets/thing.ex"],
          diffstat: %{files: 1, changed_lines: 1}
        )

      assert verdict.decision == :refuse
      assert {:pr_not_open, "closed"} in verdict.reasons
    end

    test "a stage row with no recorded pull request escalates" do
      verdict = judge(pr_number: {:error, {:not_recorded, nil}})

      assert verdict.decision == :refuse
      assert {:no_pull_request_recorded, {:not_recorded, nil}} in verdict.reasons
    end
  end

  describe "a refusal carries the whole inventory" do
    test "the forge failing does not hide Gate A or custody" do
      verdict =
        judge(
          pull_request: {:error, {:github_api_error, 404}},
          trio_outputs: [trio("story"), trio("story"), trio("escalate")],
          custody: {:error, :not_verified}
        )

      assert verdict.decision == :refuse
      assert {:pull_request_unavailable, {:github_api_error, 404}} in verdict.reasons
      assert {:custody, :not_verified} in verdict.reasons
      assert Enum.any?(verdict.reasons, &match?({:gate_a, _}, &1))
    end

    test "an unresolved repository AND an unrecorded pull request are BOTH reported" do
      verdict =
        judge(
          repo: {:error, {:no_intake_source, "p-1"}},
          pr_number: {:error, {:not_recorded, nil}},
          pull_request: {:error, :not_attempted}
        )

      assert verdict.decision == :refuse
      assert {:repository_unresolved, {:no_intake_source, "p-1"}} in verdict.reasons
      assert {:no_pull_request_recorded, {:not_recorded, nil}} in verdict.reasons
      # `:not_attempted` is the CONSEQUENCE of the two above, never a third fault.
      refute Enum.any?(verdict.reasons, &match?({_kind, :not_attempted}, &1))
    end

    test "a human path does not hide the hard bound or custody" do
      verdict =
        judge(
          files: ["lib/widgets_web/router.ex"],
          diffstat: %{files: 13, changed_lines: 1},
          custody: {:error, :missing_verifier_dispatch}
        )

      assert {:hard_bound_files_exceeded, 13, 12} in verdict.reasons
      assert {:custody, :missing_verifier_dispatch} in verdict.reasons
      assert Enum.any?(verdict.reasons, &match?({:gate_b, {:human_path, _, _}}, &1))
    end
  end

  # -- helpers ---------------------------------------------------------------------------

  defp judge(opts), do: opts |> facts() |> MergePrecondition.judge()

  defp facts(opts) do
    %{
      repo: Keyword.get(opts, :repo, {:ok, @repo}),
      pr_number: Keyword.get(opts, :pr_number, {:ok, 4242}),
      pull_request: Keyword.get_lazy(opts, :pull_request, fn -> {:ok, pull_request(opts)} end),
      head_files: Keyword.get(opts, :head_files, {:ok, @repo_files}),
      base_files: Keyword.get(opts, :base_files, {:ok, @repo_files}),
      triggers: Keyword.get_lazy(opts, :triggers, &DeliveryGates.load_triggers/0),
      custody: Keyword.get(opts, :custody, :ok),
      recorded_head_sha: Keyword.get(opts, :recorded_head_sha, @head),
      recorded_allow_sha: Keyword.get(opts, :recorded_allow_sha),
      trio_outputs: Keyword.get(opts, :trio_outputs, List.duplicate(trio("story"), 3)),
      effect_proof: Keyword.get(opts, :effect_proof)
    }
  end

  defp pull_request(opts) do
    diff =
      Keyword.get_lazy(opts, :diff, fn ->
        {:ok, %{files: Keyword.get(opts, :files, []), renames: Keyword.get(opts, :renames, [])}}
      end)

    %{
      state: Keyword.get(opts, :state, "open"),
      merged?: Keyword.get(opts, :merged?, false),
      merge_sha: Keyword.get(opts, :merge_sha),
      head_sha: @head,
      merge_base_sha: @base,
      diffstat: Keyword.get(opts, :diffstat, %{files: 0, changed_lines: 0}),
      diff: diff
    }
  end

  defp trio(verdict) do
    %{
      "verdict" => verdict,
      "escalation_reasons" => [],
      "contradicts" => [],
      "confidence" => 0.9
    }
  end

  defp files(n), do: for(i <- 1..n, do: "lib/widgets/f#{i}.ex")

  defp sha256(binary), do: :sha256 |> :crypto.hash(binary) |> Base.encode16(case: :lower)

  # The same repository, with limits far above the design's ceiling: the document an
  # operator could write, and the one the hard bound exists to be independent of.
  defp loose_triggers do
    document = valid_document(500, 100_000)
    Triggers.parse(document, sha256(document))
  end

  defp valid_document(max_files, max_changed_lines) do
    Jason.encode!(%{
      "version" => 1,
      "repos" => %{
        @repo => %{
          "effect_paths" => ["priv/rates/**"],
          "human_paths" => ["lib/widgets_web/router.ex"],
          "limits" => %{"max_files" => max_files, "max_changed_lines" => max_changed_lines}
        }
      }
    })
  end
end
