defmodule Loopctl.Progress.MergeCustodyStatusTest do
  @moduledoc """
  `Loopctl.Progress.merge_custody_status/1` — the custody half of the merge precondition
  (issue #803, design §9): a merge requires `verified_status = :verified` set by a verifier
  dispatch whose lineage is separate from the implementer's.

  The separation itself is `verify_recorded_separation/2`, the SAME L4 clause `verify`
  runs. What is tested here is that this entrance to it fails closed where `verify` may
  legitimately fall through — a story with no implementer or no verifier dispatch has
  nothing to show separation WITH, and a merge has no live caller whose own lineage could
  make up for it.
  """

  use Loopctl.DataCase, async: true

  import ExUnit.CaptureLog

  alias Loopctl.AdminRepo
  alias Loopctl.Dispatches
  alias Loopctl.Progress

  setup :verify_on_exit!

  describe "merge_custody_status/1" do
    test "a verified story whose verifier is under a SEPARATE root is :ok" do
      assert :ok == Progress.merge_custody_status(story())
    end

    test "an unverified story is refused" do
      assert {:error, :not_verified} =
               Progress.merge_custody_status(story(verified_status: :unverified))
    end

    test "a REJECTED story is refused" do
      assert {:error, :not_verified} =
               Progress.merge_custody_status(story(verified_status: :rejected))
    end

    test "a verifier on the implementer's own chain is refused" do
      assert {:error, :self_verify_blocked} =
               Progress.merge_custody_status(story(verifier: :child_of_implementer))
    end

    test "a verifier that IS the implementer's dispatch is refused" do
      assert {:error, :self_verify_blocked} =
               Progress.merge_custody_status(story(verifier: :same_dispatch))
    end

    test "a verified story with NO verifier dispatch is refused, not passed vacuously" do
      # `verify` legitimately reaches this state — request-review is optional — and its
      # CALLER lineage clause is what gates it there. A merge has no caller.
      assert {:error, :missing_verifier_dispatch} =
               Progress.merge_custody_status(story(verifier: :none))
    end

    test "a verified story with NO implementer dispatch is refused" do
      assert {:error, :missing_implementer_dispatch} =
               Progress.merge_custody_status(story(implementer: :none))
    end
  end

  describe "tenant isolation" do
    # The only way a recorded dispatch is UNLOADABLE: `get_dispatch/2` reads by id AND
    # tenant, and the FKs make a dangling id unreachable. A verifier belonging to another
    # tenant therefore resolves to an empty lineage, and an empty lineage on either side
    # fails CLOSED rather than reading as "independent".
    test "a verifier dispatch of another tenant fails closed, and says so in the log" do
      other = fixture(:tenant)
      other_agent = fixture(:agent, %{tenant_id: other.id, agent_type: :orchestrator})

      {:ok, %{dispatch: foreign}} =
        Dispatches.create_dispatch(other.id, %{role: :orchestrator, agent_id: other_agent.id})

      story =
        story()
        |> Ecto.Changeset.change(verifier_dispatch_id: foreign.id)
        |> AdminRepo.update!()

      log =
        capture_log(fn ->
          assert {:error, :unresolvable_dispatch_lineage} =
                   Progress.merge_custody_status(story)
        end)

      assert log =~ "unresolvable_dispatch_lineage"
      assert log =~ story.id
    end
  end

  # -- helpers ---------------------------------------------------------------------------

  # A verified story with an implementer dispatch and, by default, a verifier dispatch
  # under a separate ROOT — the shape a merge is supposed to be allowed from.
  defp story(opts \\ []) do
    tenant = fixture(:tenant)
    epic = fixture(:epic, %{tenant_id: tenant.id})
    agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :implementer})
    verifier_agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :orchestrator})

    {:ok, %{dispatch: implementer}} =
      Dispatches.create_dispatch(tenant.id, %{role: :agent, agent_id: agent.id})

    fixture(:story, %{tenant_id: tenant.id, epic_id: epic.id})
    |> Ecto.Changeset.change(%{
      agent_status: :reported_done,
      verified_status: Keyword.get(opts, :verified_status, :verified),
      assigned_agent_id: agent.id,
      implementer_dispatch_id: implementer_id(implementer, opts),
      verifier_dispatch_id: verifier_id(tenant, verifier_agent, implementer, opts)
    })
    |> AdminRepo.update!()
  end

  defp implementer_id(implementer, opts) do
    case Keyword.get(opts, :implementer, :present) do
      :none -> nil
      :present -> implementer.id
    end
  end

  defp verifier_id(tenant, verifier_agent, implementer, opts) do
    case Keyword.get(opts, :verifier, :separate_root) do
      :none ->
        nil

      :same_dispatch ->
        implementer.id

      :child_of_implementer ->
        {:ok, %{dispatch: child}} =
          Dispatches.create_dispatch(tenant.id, %{
            role: :agent,
            agent_id: verifier_agent.id,
            parent_dispatch_id: implementer.id
          })

        child.id

      :separate_root ->
        {:ok, %{dispatch: root}} =
          Dispatches.create_dispatch(tenant.id, %{
            role: :orchestrator,
            agent_id: verifier_agent.id
          })

        root.id
    end
  end
end
