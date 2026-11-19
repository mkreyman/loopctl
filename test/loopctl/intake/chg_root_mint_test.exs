defmodule Loopctl.Intake.ChgRootMintTest do
  @moduledoc """
  A chg root is a lineage anchor, never a held key. `mint_chg_root: true` has loopctl insert
  it keyless and agentless in the source write, and `RevokeExpiredDispatchesWorker` never
  revokes a root a live source names. Before this, a root minted through `POST /dispatches`
  took its agent's one-orchestrator-key slot (so the fleet's agent could not have one), and the
  expiry sweep revoked it after 4h, which made every post from its source 401.
  """

  use Loopctl.DataCase, async: true

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.AuditChain.Entry
  alias Loopctl.Auth.ApiKey
  alias Loopctl.Changes.Ledger
  alias Loopctl.Changes.Signature
  alias Loopctl.Dispatches
  alias Loopctl.Dispatches.Dispatch
  alias Loopctl.Intake
  alias Loopctl.Intake.Source
  alias Loopctl.Workers.RevokeExpiredDispatchesWorker

  setup :verify_on_exit!

  @secret String.duplicate("s", 32)

  defp signed(raw) do
    ts = Integer.to_string(System.os_time(:second))

    %{
      raw_body: raw,
      timestamp: ts,
      signature: Signature.header(@secret, Signature.delivery_string(ts, raw))
    }
  end

  defp batch(repo) do
    Jason.encode!(%{
      rows: [
        %{
          "v" => 1,
          "kind" => "gate",
          "repo" => repo,
          "host" => "minis",
          "sha" => "0123456789abcdef0123456789abcdef01234567",
          "at_ms" => 1_763_400_000_000,
          "verdict" => "pass",
          "ms" => 12
        }
      ]
    })
  end

  defp pr_source(tenant_id, repo \\ "mkreyman/infra") do
    project = fixture(:project, %{tenant_id: tenant_id})

    {_webhook_secret, source} =
      fixture(:intake_source, %{
        tenant_id: tenant_id,
        project_id: project.id,
        repo_full_name: repo
      })

    source
  end

  defp expire!(dispatch_id) do
    {1, _} =
      AdminRepo.update_all(from(d in Dispatch, where: d.id == ^dispatch_id),
        set: [expires_at: DateTime.add(DateTime.utc_now(), -60)]
      )
  end

  defp sweep, do: RevokeExpiredDispatchesWorker.perform(%Oban.Job{})

  defp candidate?(dispatch_id),
    do:
      DateTime.utc_now()
      |> RevokeExpiredDispatchesWorker.expired_candidates()
      |> Enum.any?(&(&1.id == dispatch_id))

  defp roots(tenant_id),
    do:
      AdminRepo.all(
        from d in Dispatch, where: d.tenant_id == ^tenant_id and is_nil(d.parent_dispatch_id)
      )

  describe "mint_chg_root on update" do
    test "gives a pr source a keyless, agentless root, and the source sends its ledger" do
      tenant = fixture(:tenant)
      source = pr_source(tenant.id)

      assert {:ok, %Source{chg_root_dispatch_id: root_id, mode: :pr}} =
               Intake.update_source(tenant.id, source.id, %{
                 change_events_secret: @secret,
                 mint_chg_root: true
               })

      assert %Dispatch{
               parent_dispatch_id: nil,
               api_key_id: nil,
               agent_id: nil,
               role: :orchestrator,
               lineage_path: [^root_id],
               revoked_at: nil
             } = AdminRepo.get!(Dispatch, root_id)

      assert AdminRepo.exists?(
               from e in Entry,
                 where:
                   e.tenant_id == ^tenant.id and e.entity_id == ^root_id and
                     e.action == "dispatch_created"
             )

      assert {:ok, %{inserted: 1}} =
               Ledger.receive_batch(source.id, signed(batch(source.repo_full_name)))
    end

    test "is not blocked by an agent already holding a live orchestrator key" do
      tenant = fixture(:tenant)
      agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :orchestrator})

      assert {:ok, _} =
               Dispatches.create_dispatch(tenant.id, %{role: :orchestrator, agent_id: agent.id})

      source = pr_source(tenant.id)

      assert {:ok, %Source{chg_root_dispatch_id: root_id}} =
               Intake.update_source(tenant.id, source.id, %{
                 change_events_secret: @secret,
                 mint_chg_root: true
               })

      assert is_binary(root_id)
    end

    test "naming a root and asking for one is refused, and nothing is minted" do
      tenant = fixture(:tenant)
      source = pr_source(tenant.id)
      root = fixture(:chg_root_dispatch, %{tenant_id: tenant.id})

      assert {:error, %Ecto.Changeset{} = changeset} =
               Intake.update_source(tenant.id, source.id, %{
                 change_events_secret: @secret,
                 chg_root_dispatch_id: root.id,
                 mint_chg_root: true
               })

      assert %{chg_root_dispatch_id: [_]} = errors_on(changeset)
      assert [%Dispatch{id: only}] = roots(tenant.id)
      assert only == root.id
      assert AdminRepo.get!(Source, source.id).chg_root_dispatch_id == nil
    end

    test "a write refused inside its transaction leaves no root behind" do
      tenant = fixture(:tenant)
      source = pr_source(tenant.id)

      # `mode: chg` with a story holding a merge allow is refused inside the write.
      story = fixture(:story, %{tenant_id: tenant.id, project_id: source.project_id})

      fixture(:story_stage, %{
        tenant_id: tenant.id,
        story_id: story.id,
        repo: AdminRepo,
        stage: :ci,
        merge_gate_allowed_sha: String.duplicate("a", 40)
      })

      assert {:error, {:pr_route_in_flight, _}} =
               Intake.update_source(tenant.id, source.id, %{
                 mode: "chg",
                 change_events_secret: @secret,
                 mint_chg_root: true
               })

      assert roots(tenant.id) == []
    end

    test "only a literal true mints" do
      tenant = fixture(:tenant)
      source = pr_source(tenant.id)

      assert {:ok, %Source{chg_root_dispatch_id: nil}} =
               Intake.update_source(tenant.id, source.id, %{
                 base_branch: "main",
                 mint_chg_root: false
               })

      assert roots(tenant.id) == []
    end
  end

  describe "mint_chg_root on create" do
    test "enrolls a ledger source on a kb scope with no root id from the caller" do
      tenant = fixture(:tenant)
      kb = fixture(:project, %{tenant_id: tenant.id, kind: :kb})

      assert {:ok, %{source: %Source{mode: :ledger, chg_root_dispatch_id: root_id}}} =
               Intake.create_source(tenant.id, %{
                 repo_full_name: "mkreyman/kb_only",
                 project_id: kb.id,
                 mode: "ledger",
                 change_events_secret: @secret,
                 mint_chg_root: true
               })

      assert %Dispatch{api_key_id: nil, agent_id: nil} = AdminRepo.get!(Dispatch, root_id)
    end
  end

  describe "naming an existing root" do
    test "is refused when the root expires within the naming margin" do
      tenant = fixture(:tenant)
      source = pr_source(tenant.id)
      root = fixture(:chg_root_dispatch, %{tenant_id: tenant.id})

      AdminRepo.update_all(from(d in Dispatch, where: d.id == ^root.id),
        set: [expires_at: DateTime.add(DateTime.utc_now(), 100)]
      )

      assert {:error, :chg_root_invalid} =
               Intake.update_source(tenant.id, source.id, %{
                 change_events_secret: @secret,
                 chg_root_dispatch_id: root.id
               })
    end

    test "with time to spare is accepted, as before" do
      tenant = fixture(:tenant)
      source = pr_source(tenant.id)
      root = fixture(:chg_root_dispatch, %{tenant_id: tenant.id})

      assert {:ok, %Source{}} =
               Intake.update_source(tenant.id, source.id, %{
                 change_events_secret: @secret,
                 chg_root_dispatch_id: root.id
               })
    end
  end

  describe "verifier selection" do
    test "never draws a chg root, minted or named, live source or revoked" do
      tenant = fixture(:tenant)
      source = pr_source(tenant.id)

      {:ok, %Source{}} =
        Intake.update_source(tenant.id, source.id, %{
          change_events_secret: @secret,
          mint_chg_root: true
        })

      # The minted root is the tenant's only live dispatch, so the pool is empty.
      assert {:error, :no_eligible_verifier} =
               Dispatches.select_verifier(tenant.id, Ecto.UUID.generate(), [])

      AdminRepo.update_all(from(s in Source, where: s.id == ^source.id),
        set: [revoked_at: DateTime.utc_now()]
      )

      assert {:error, :no_eligible_verifier} =
               Dispatches.select_verifier(tenant.id, Ecto.UUID.generate(), [])
    end

    test "another tenant's source naming the id does not hide it from this tenant's pool" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      root = fixture(:chg_root_dispatch, %{tenant_id: tenant_a.id})
      other = pr_source(tenant_b.id)

      AdminRepo.update_all(from(s in Source, where: s.id == ^other.id),
        set: [chg_root_dispatch_id: root.id, change_events_secret: @secret]
      )

      # Still a candidate (the pool is non-empty), so the answer is the seed's, not the pool's.
      refute Dispatches.select_verifier(tenant_a.id, Ecto.UUID.generate(), []) ==
               {:error, :no_eligible_verifier}
    end
  end

  describe "the expiry sweep" do
    test "keeps a root a live source names; the source still authenticates after it" do
      tenant = fixture(:tenant)
      source = pr_source(tenant.id)

      {:ok, %Source{chg_root_dispatch_id: root_id}} =
        Intake.update_source(tenant.id, source.id, %{
          change_events_secret: @secret,
          mint_chg_root: true
        })

      expire!(root_id)
      sweep()

      assert %Dispatch{revoked_at: nil} = AdminRepo.get!(Dispatch, root_id)

      assert {:ok, %{inserted: 1}} =
               Ledger.receive_batch(source.id, signed(batch(source.repo_full_name)))
    end

    test "still revokes a named root's KEY" do
      tenant = fixture(:tenant)
      agent = fixture(:agent, %{tenant_id: tenant.id, agent_type: :orchestrator})

      {:ok, %{dispatch: root}} =
        Dispatches.create_dispatch(tenant.id, %{role: :orchestrator, agent_id: agent.id})

      source = pr_source(tenant.id)

      {:ok, _} =
        Intake.update_source(tenant.id, source.id, %{
          change_events_secret: @secret,
          chg_root_dispatch_id: root.id
        })

      expire!(root.id)
      sweep()

      assert %Dispatch{revoked_at: nil} = AdminRepo.get!(Dispatch, root.id)
      key = AdminRepo.get!(ApiKey, root.api_key_id)
      refute is_nil(key.revoked_at)

      # Once its key is revoked, the root is no longer a candidate on any later run.
      refute candidate?(root.id)
      assert key.revoked_at
    end

    test "a minted (keyless) named root is never a candidate, an unnamed one is" do
      tenant = fixture(:tenant)
      source = pr_source(tenant.id)

      {:ok, %Source{chg_root_dispatch_id: root_id}} =
        Intake.update_source(tenant.id, source.id, %{
          change_events_secret: @secret,
          mint_chg_root: true
        })

      unnamed = fixture(:chg_root_dispatch, %{tenant_id: tenant.id})
      expire!(root_id)
      expire!(unnamed.id)

      refute candidate?(root_id)
      assert candidate?(unnamed.id)
    end

    test "revokes a root once its source is revoked" do
      tenant = fixture(:tenant)
      source = pr_source(tenant.id)

      {:ok, %Source{chg_root_dispatch_id: root_id}} =
        Intake.update_source(tenant.id, source.id, %{
          change_events_secret: @secret,
          mint_chg_root: true
        })

      AdminRepo.update_all(from(s in Source, where: s.id == ^source.id),
        set: [revoked_at: DateTime.utc_now()]
      )

      expire!(root_id)
      sweep()

      refute is_nil(AdminRepo.get!(Dispatch, root_id).revoked_at)
    end

    test "another tenant's source naming the id does not exempt it" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      root = fixture(:chg_root_dispatch, %{tenant_id: tenant_a.id})
      other = pr_source(tenant_b.id)

      # Only a raw write can make a source point across tenants; the sweep must still hold.
      AdminRepo.update_all(from(s in Source, where: s.id == ^other.id),
        set: [chg_root_dispatch_id: root.id, change_events_secret: @secret]
      )

      expire!(root.id)
      sweep()

      refute is_nil(AdminRepo.get!(Dispatch, root.id).revoked_at)
    end
  end
end
