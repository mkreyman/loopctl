defmodule Loopctl.Delivery.TriagePayloadLoopFindingTest do
  @moduledoc """
  US-51.7: a loop issue's triage object carries loopctl's own record of its finding
  (`loop_finding`, contract 1.33.0), read by the record's `loop_finding_id` in the record's
  tenant and never from the issue text.
  """
  use Loopctl.DataCase, async: true

  alias Loopctl.AdminRepo
  alias Loopctl.ApiSpec.RunnerContract
  alias Loopctl.ApiSpec.RunnerContract.ByteRule
  alias Loopctl.ApiSpec.RunnerContract.RunnerTriage
  alias Loopctl.Changes.Finding
  alias Loopctl.Delivery.TriagePayload
  alias Loopctl.Intake.Record

  setup do
    %{tenant: fixture(:tenant, %{}), other: fixture(:tenant, %{})}
  end

  defp finding!(tenant_id, attrs \\ %{}) do
    now = DateTime.utc_now()

    AdminRepo.insert!(
      struct!(
        %Finding{
          tenant_id: tenant_id,
          kind: "flaky_test",
          repo_full_name: "mkreyman/home_care_billing",
          fingerprint: "mkreyman/home_care_billing:test/a_test.exs:12",
          state: :filed,
          occurrences: 3,
          fix_attempts: 1,
          # The shape `Findings.flaky_tests` records: the finding's own facts at the top level
          # and the ledger row's scalars nested under `row`.
          evidence: %{
            "repo" => "mkreyman/home_care_billing",
            "host" => "minis",
            "test" => "test/a_test.exs:12",
            "row" => %{"runs" => 7, "flaky" => true, "nested" => %{"too" => "deep"}},
            "failures" => ["not", "a", "scalar"]
          },
          first_seen_at: now,
          last_seen_at: now
        },
        attrs
      )
    )
  end

  defp record(tenant_id, finding_id, attrs \\ %{}) do
    struct!(
      %Record{
        id: Ecto.UUID.generate(),
        tenant_id: tenant_id,
        issue_number: 77,
        html_url: nil,
        untrusted_title: "chg loop: flaky_test",
        untrusted_body: "The evidence, as the issue says it.",
        untrusted_labels: [],
        untrusted_truncated: false,
        escalation_reasons: [],
        loop_finding_id: finding_id
      },
      attrs
    )
  end

  defp wire(triage) do
    payload = %{
      "dispatch_id" => Ecto.UUID.generate(),
      "story_id" => Ecto.UUID.generate(),
      "kind" => "triage",
      "repo" => "mkreyman/home_care_billing",
      "branch" => "triage/77",
      "base_branch" => "master",
      "claim_epoch" => 1,
      "wall_clock_seconds" => 600,
      "max_turns" => 40,
      "triage" => Jason.decode!(Jason.encode!(triage))
    }

    RunnerContract.cast_dispatch(payload)
  end

  test "a loop record carries its finding, from loopctl's row", %{tenant: tenant} do
    finding = finding!(tenant.id)

    assert {:ok, triage} = TriagePayload.build(record(tenant.id, finding.id))

    assert triage.loop_finding == %{
             finding_id: finding.id,
             kind: "flaky_test",
             fingerprint: finding.fingerprint,
             occurrences: 3,
             fix_attempts: 1,
             evidence: [
               %{key: "host", value: "minis"},
               %{key: "repo", value: "mkreyman/home_care_billing"},
               %{key: "test", value: "test/a_test.exs:12"},
               %{key: "row.flaky", value: "true"},
               %{key: "row.runs", value: "7"}
             ]
           }

    assert ByteRule.bytes(triage) <= RunnerTriage.max_bytes()
    assert {:ok, %{triage: %{loop_finding: %{kind: "flaky_test"}}}} = wire(triage)
  end

  test "a selection_miss's two full rows never crowd out its own facts", %{tenant: tenant} do
    row = fn prefix -> Map.new(1..16, &{"#{prefix}#{&1}", &1}) end

    finding =
      finding!(tenant.id, %{
        kind: "selection_miss",
        evidence: %{
          "repo" => "mkreyman/chg",
          "host" => "minis",
          "sha" => String.duplicate("a", 40),
          "chg_row" => row.("c"),
          "gate_row" => row.("g"),
          "failures" => ["test/a_test.exs:12"]
        }
      })

    assert {:ok, triage} = TriagePayload.build(record(tenant.id, finding.id))
    keys = Enum.map(triage.loop_finding.evidence, & &1.key)

    assert length(keys) == RunnerTriage.max_evidence()
    assert Enum.take(keys, 3) == ["host", "repo", "sha"]
    assert Enum.all?(Enum.drop(keys, 3), &String.starts_with?(&1, "chg_row."))
    assert {:ok, _} = wire(triage)
  end

  test "another tenant's finding id carries nothing", %{tenant: tenant, other: other} do
    finding = finding!(other.id)

    assert {:ok, triage} = TriagePayload.build(record(tenant.id, finding.id))
    refute Map.has_key?(triage, :loop_finding)
  end

  test "a record with no loop_finding_id carries none", %{tenant: tenant} do
    assert {:ok, triage} = TriagePayload.build(record(tenant.id, nil))
    refute Map.has_key?(triage, :loop_finding)
  end

  test "a record that fits only without the finding is sent without it, never escalated",
       %{tenant: tenant} do
    evidence =
      Map.new(1..16, fn i ->
        {String.pad_leading("k#{i}", 64, "k"), String.duplicate("v", 200)}
      end)

    finding = finding!(tenant.id, %{evidence: evidence})
    body = String.duplicate("x", RunnerTriage.max_untrusted_length() - 400)

    assert {:ok, triage} =
             TriagePayload.build(record(tenant.id, finding.id, %{untrusted_body: body}))

    refute Map.has_key?(triage, :loop_finding)
    assert {:ok, without} = TriagePayload.build(record(tenant.id, nil, %{untrusted_body: body}))
    assert Enum.sort(Map.keys(triage)) == Enum.sort(Map.keys(without))
  end
end
