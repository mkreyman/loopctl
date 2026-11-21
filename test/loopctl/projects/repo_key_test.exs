defmodule Loopctl.Projects.RepoKeyTest do
  @moduledoc "US-52.1: a repo has one project, decided by `projects.repo_key`."
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.AdminRepo
  alias Loopctl.Intake
  alias Loopctl.Projects
  alias Loopctl.Projects.Project
  alias Loopctl.Projects.RepoUrl

  @ssh "git@github.com:mkreyman/chg.git"
  @https "https://github.com/mkreyman/chg"

  describe "RepoUrl.key/1 (TC-52.1.1)" do
    test "every spelling of one repo gives one key" do
      for url <- [
            @https,
            @ssh,
            "https://github.com/MKreyman/chg/",
            "mkreyman/chg",
            "ssh://git@github.com:22/mkreyman/chg.git"
          ] do
        assert RepoUrl.key(url) == "github.com/mkreyman/chg", url
      end
    end

    test "no owner/repo path gives nil" do
      assert RepoUrl.key(nil) == nil
      assert RepoUrl.key("") == nil
      assert RepoUrl.key("chg") == nil
    end

    test "the changeset sets repo_key from repo_url and never casts it" do
      tenant = fixture(:tenant)

      {:ok, project} =
        Projects.create_project(tenant.id, %{
          name: "chg",
          slug: "chg",
          repo_url: @ssh,
          repo_key: "github.com/other/repo"
        })

      assert project.repo_key == "github.com/mkreyman/chg"

      {:ok, cleared} = Projects.update_project(tenant.id, project, %{repo_url: nil})
      assert cleared.repo_key == nil
    end
  end

  describe "create_project/3 (TC-52.1.2, TC-52.1.3)" do
    setup do
      tenant = fixture(:tenant)
      kb = fixture(:project, %{tenant_id: tenant.id, kind: :kb, slug: "chg", repo_url: @ssh})
      %{tenant: tenant, kb: kb}
    end

    test "a second work project on the repo is refused, naming the holder", %{tenant: t, kb: kb} do
      assert {:error, {:repo_has_project, id}} =
               Projects.create_project(t.id, %{name: "chg2", slug: "chg2", repo_url: @https})

      assert id == kb.id
    end

    test "a second kb scope on the repo is refused too", %{tenant: t, kb: kb} do
      assert {:error, {:repo_has_project, id}} =
               Projects.create_project(t.id, %{name: "chg3", slug: "chg3", repo_url: @https},
                 kind: :kb
               )

      assert id == kb.id
    end

    test "the index decides a race the pre-check lost", %{tenant: t, kb: kb} do
      changeset =
        Project.create_changeset(%Project{tenant_id: t.id}, %{
          name: "racer",
          slug: "racer",
          repo_url: @https
        })

      assert {:error, failed} = AdminRepo.insert(changeset)
      assert Keyword.has_key?(failed.errors, :repo_key)
      assert {:ok, ^kb} = Projects.repo_holder(t.id, "github.com/mkreyman/chg")

      # The loser of the race gets the same 409 the pre-check gives, not a changeset.
      kb_id = kb.id
      assert {:error, {:repo_has_project, ^kb_id}} = Projects.changeset_or_refusal(t.id, failed)
    end
  end

  describe "update and restore (TC-52.1.4)" do
    test "moving onto a held repo is refused; an archived holder does not block" do
      tenant = fixture(:tenant)
      a = fixture(:project, %{tenant_id: tenant.id, repo_url: @ssh})
      b = fixture(:project, %{tenant_id: tenant.id, repo_url: nil})

      {:ok, c} =
        Projects.create_project(tenant.id, %{name: "cc", slug: "cc", repo_url: "mkreyman/other"})

      {:ok, c} = Projects.archive_project(tenant.id, c)
      {:ok, c} = Projects.update_project(tenant.id, c, %{repo_url: @https})

      assert {:error, {:repo_has_project, holder}} =
               Projects.update_project(tenant.id, b, %{repo_url: @https})

      assert holder == a.id

      assert {:error, {:repo_has_project, ^holder}} = Projects.unarchive_project(tenant.id, c)

      {:ok, _} = Projects.archive_project(tenant.id, a)
      assert {:ok, %{status: :active}} = Projects.unarchive_project(tenant.id, c)
    end

    test "editing the holder itself is not a collision" do
      tenant = fixture(:tenant)
      a = fixture(:project, %{tenant_id: tenant.id, repo_url: @ssh})

      assert {:ok, updated} = Projects.update_project(tenant.id, a, %{repo_url: @https})
      assert updated.repo_key == "github.com/mkreyman/chg"
    end
  end

  describe "Intake.create_source/3 (TC-52.1.6)" do
    test "a source binds its repo only to the project that holds it" do
      tenant = fixture(:tenant)
      kb = fixture(:project, %{tenant_id: tenant.id, kind: :kb, slug: "chg", repo_url: @ssh})
      work = fixture(:project, %{tenant_id: tenant.id, repo_url: nil})

      assert {:error, {:repo_has_project, id}} =
               Intake.create_source(tenant.id, %{
                 repo_full_name: "mkreyman/chg",
                 project_id: work.id
               })

      assert id == kb.id
    end

    test "a repo no project holds binds to any project the mode allows" do
      tenant = fixture(:tenant)
      work = fixture(:project, %{tenant_id: tenant.id, repo_url: nil})

      assert {:ok, _} =
               Intake.create_source(tenant.id, %{
                 repo_full_name: "mkreyman/chg",
                 project_id: work.id
               })
    end

    test "the holder itself takes the source" do
      tenant = fixture(:tenant)
      work = fixture(:project, %{tenant_id: tenant.id, repo_url: @ssh})

      assert {:ok, _} =
               Intake.create_source(tenant.id, %{
                 repo_full_name: "mkreyman/chg",
                 project_id: work.id
               })
    end
  end

  describe "update_project/4 under a live intake source (#1082)" do
    setup do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id, repo_url: nil})

      {_secret, source} =
        fixture(:intake_source, %{
          tenant_id: tenant.id,
          project_id: project.id,
          repo_full_name: "acme/widgets"
        })

      %{tenant: tenant, project: AdminRepo.get!(Project, project.id), source: source}
    end

    test "re-pointing repo_url to another repo is refused", %{tenant: t, project: p, source: s} do
      assert p.repo_key == "github.com/acme/widgets"

      assert {:error, {:repo_held_by_source, s.id, "acme/widgets"}} ==
               Projects.update_project(t.id, p, %{repo_url: "acme/infra"})

      assert AdminRepo.get!(Project, p.id).repo_key == "github.com/acme/widgets"
    end

    test "clearing repo_url is refused", %{tenant: t, project: p, source: s} do
      for cleared <- [nil, ""] do
        assert {:error, {:repo_held_by_source, source_id, _}} =
                 Projects.update_project(t.id, p, %{repo_url: cleared})

        assert source_id == s.id
      end

      assert AdminRepo.get!(Project, p.id).repo_key == "github.com/acme/widgets"
    end

    test "the same repo in another spelling, or no repo change, is allowed",
         %{tenant: t, project: p} do
      assert {:ok, same} =
               Projects.update_project(t.id, p, %{repo_url: "git@github.com:acme/widgets.git"})

      assert same.repo_key == "github.com/acme/widgets"
      assert {:ok, renamed} = Projects.update_project(t.id, same, %{name: "widgets-renamed"})
      assert renamed.name == "widgets-renamed"
    end

    test "a revoked source no longer holds the repo", %{tenant: t, project: p, source: s} do
      {:ok, _} = Intake.revoke_source(t.id, s.id)

      assert {:ok, moved} = Projects.update_project(t.id, p, %{repo_url: "acme/infra"})
      assert moved.repo_key == "github.com/acme/infra"
    end

    test "a ledger source binds no repo and never blocks" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id, repo_url: "acme/widgets"})

      %{source: source} =
        fixture(:ledger_source, %{
          tenant_id: tenant.id,
          project_id: project.id,
          repo_full_name: "acme/other"
        })

      assert source.mode == :ledger and is_nil(source.revoked_at)
      project = AdminRepo.get!(Project, project.id)
      assert {:ok, moved} = Projects.update_project(tenant.id, project, %{repo_url: "acme/infra"})
      assert moved.repo_key == "github.com/acme/infra"
    end

    test "another tenant's live source never blocks an update", %{source: s} do
      tenant_b = fixture(:tenant)
      project_b = fixture(:project, %{tenant_id: tenant_b.id, repo_url: "acme/widgets"})

      assert s.tenant_id != tenant_b.id

      assert {:ok, moved} =
               Projects.update_project(tenant_b.id, project_b, %{repo_url: "acme/infra"})

      assert moved.repo_key == "github.com/acme/infra"
    end
  end

  describe "tenant isolation (TC-52.1.7)" do
    test "another tenant's project on the repo never blocks a create" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)
      _held = fixture(:project, %{tenant_id: tenant_a.id, repo_url: @ssh})

      assert {:ok, project} =
               Projects.create_project(tenant_b.id, %{name: "chg", slug: "chg", repo_url: @https})

      assert project.tenant_id == tenant_b.id
      assert Projects.repo_holder(tenant_b.id, "github.com/mkreyman/chg", project.id) == :error
    end
  end
end
