defmodule Loopctl.Intake.KbPromotionTest do
  @moduledoc """
  US-52.3: a `pr`/`chg` source enrolled on a repo's kb scope promotes it to a work project, in
  the enrolment's own transaction, so a repo never needs a second project to take delivery.
  """
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Audit.AuditLog
  alias Loopctl.Coordination
  alias Loopctl.Intake
  alias Loopctl.Projects
  alias Loopctl.Projects.Project

  setup do
    tenant = fixture(:tenant)

    kb =
      fixture(:project, %{
        tenant_id: tenant.id,
        kind: :kb,
        slug: "chg",
        repo_url: "git@github.com:mkreyman/chg.git"
      })

    %{tenant: tenant, kb: kb}
  end

  defp chg_credentials(tenant_id) do
    root = fixture(:chg_root_dispatch, %{tenant_id: tenant_id})
    %{change_events_secret: String.duplicate("s", 32), chg_root_dispatch_id: root.id}
  end

  defp kind(id), do: AdminRepo.get!(Project, id).kind

  defp promotions(tenant_id, project_id) do
    AdminRepo.all(
      from a in AuditLog,
        where:
          a.tenant_id == ^tenant_id and a.entity_id == ^project_id and
            a.action == "kind_promoted"
    )
  end

  test "a pr source on a kb scope promotes it and binds to it (TC-52.3.1)", %{tenant: t, kb: kb} do
    assert {:ok, %{source: source}} =
             Intake.create_source(t.id, %{repo_full_name: "mkreyman/chg", project_id: kb.id},
               actor_label: "user:test"
             )

    assert source.project_id == kb.id
    assert kind(kb.id) == :work

    assert [entry] = promotions(t.id, kb.id)
    assert entry.metadata["from"] == "kb"
    assert entry.metadata["to"] == "work"
    assert entry.metadata["intake_source_id"] == source.id
  end

  test "a chg source promotes too", %{tenant: t, kb: kb} do
    attrs =
      Map.merge(
        %{repo_full_name: "mkreyman/chg", project_id: kb.id, mode: "chg"},
        chg_credentials(t.id)
      )

    assert {:ok, _} = Intake.create_source(t.id, attrs)
    assert kind(kb.id) == :work
  end

  test "a ledger source leaves the kb scope as kb (TC-52.3.2)", %{tenant: t, kb: kb} do
    attrs =
      Map.merge(
        %{repo_full_name: "mkreyman/chg", project_id: kb.id, mode: "ledger"},
        chg_credentials(t.id)
      )

    assert {:ok, _} = Intake.create_source(t.id, attrs)
    assert kind(kb.id) == :kb
    assert promotions(t.id, kb.id) == []
  end

  test "a refused enrolment does not promote (TC-52.3.3)", %{tenant: t, kb: kb} do
    attrs = %{
      repo_full_name: "mkreyman/chg",
      project_id: kb.id,
      mode: "chg",
      change_events_secret: String.duplicate("s", 32),
      chg_root_dispatch_id: Ecto.UUID.generate()
    }

    assert {:error, :chg_root_invalid} = Intake.create_source(t.id, attrs)
    assert kind(kb.id) == :kb
    assert promotions(t.id, kb.id) == []
  end

  test "a repo another project holds is refused and promotes nothing", %{tenant: t, kb: kb} do
    other = fixture(:project, %{tenant_id: t.id, kind: :kb, slug: "other"})

    assert {:error, {:repo_has_project, holder}} =
             Intake.create_source(t.id, %{repo_full_name: "mkreyman/chg", project_id: other.id})

    assert holder == kb.id
    assert kind(other.id) == :kb
  end

  test "an archived kb scope is refused", %{tenant: t, kb: kb} do
    {:ok, _} = AdminRepo.update(Project.archive_changeset(kb))

    assert {:error, changeset} =
             Intake.create_source(t.id, %{repo_full_name: "mkreyman/chg", project_id: kb.id})

    assert %{project_id: ["must be an active work project"]} = errors_on(changeset)
  end

  test "tenant isolation: another tenant's kb scope is not found and not promoted (TC-52.3.4)",
       %{kb: kb} do
    other = fixture(:tenant)

    assert {:error, changeset} =
             Intake.create_source(other.id, %{repo_full_name: "mkreyman/chg", project_id: kb.id})

    assert %{project_id: [_]} = errors_on(changeset)
    assert kind(kb.id) == :kb
  end

  test "a promotion rolls back when the insert after it fails", %{tenant: t, kb: kb} do
    # A ledger source holds the repo without promoting; the pr source after it is promoted
    # first and then refused by the one-active-source-per-repo index.
    ledger =
      Map.merge(
        %{repo_full_name: "mkreyman/chg", project_id: kb.id, mode: "ledger"},
        chg_credentials(t.id)
      )

    assert {:ok, _} = Intake.create_source(t.id, ledger)

    assert {:error, %Ecto.Changeset{}} =
             Intake.create_source(t.id, %{repo_full_name: "mkreyman/chg", project_id: kb.id})

    assert %{kind: :kb, open_channel: false} = AdminRepo.get!(Project, kb.id)
    assert promotions(t.id, kb.id) == []
  end

  test "a promoted kb scope keeps an open channel", %{tenant: t, kb: kb} do
    {:ok, _} = Intake.create_source(t.id, %{repo_full_name: "mkreyman/chg", project_id: kb.id})
    assert %{kind: :work, open_channel: true} = AdminRepo.get!(Project, kb.id)

    outsider = fixture(:agent, %{tenant_id: t.id})
    assert :ok = Coordination.project_writable_by_agent(t.id, outsider.id, kb.id, :agent)
  end

  test "a project with no repo takes the source's repo", %{tenant: t} do
    bare = fixture(:project, %{tenant_id: t.id, repo_url: nil})

    {:ok, _} =
      Intake.create_source(t.id, %{repo_full_name: "mkreyman/other", project_id: bare.id})

    assert {:ok, %{id: id}} = Projects.repo_holder(t.id, "github.com/mkreyman/other")
    assert id == bare.id
    assert %{open_channel: false} = AdminRepo.get!(Project, bare.id)

    assert [entry] =
             AdminRepo.all(
               from a in AuditLog, where: a.entity_id == ^bare.id and a.action == "repo_claimed"
             )

    assert entry.old_state["repo_url"] == nil
    assert entry.new_state["repo_url"] == "https://github.com/mkreyman/other"
  end

  test "the promotion audit records every field it wrote", %{tenant: t, kb: kb} do
    {:ok, _} = Intake.create_source(t.id, %{repo_full_name: "mkreyman/chg", project_id: kb.id})
    assert [entry] = promotions(t.id, kb.id)
    assert entry.old_state == %{"kind" => "kb", "open_channel" => false}
    assert entry.new_state == %{"kind" => "work", "open_channel" => true}
  end

  test "a work project that was never a kb scope keeps the membership gate", %{tenant: t} do
    work = fixture(:project, %{tenant_id: t.id})
    outsider = fixture(:agent, %{tenant_id: t.id})

    assert {:error, :not_found} =
             Coordination.project_writable_by_agent(t.id, outsider.id, work.id, :agent)
  end
end
