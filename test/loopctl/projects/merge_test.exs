defmodule Loopctl.Projects.MergeTest do
  @moduledoc "US-52.2: one project merges into another, every row moving with it."
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Audit.AuditLog
  alias Loopctl.Coordination
  alias Loopctl.Coordination.ChannelClaim
  alias Loopctl.Coordination.ChannelPost
  alias Loopctl.Intake.Source
  alias Loopctl.Projects
  alias Loopctl.Projects.Merge
  alias Loopctl.Projects.Project
  alias Loopctl.WorkBreakdown.Epic
  alias Loopctl.WorkBreakdown.Story

  # A kb scope holding the repo, and a work project carrying delivery: the shape four
  # production repos grew before US-52.1.
  defp pair do
    tenant = fixture(:tenant)
    work = fixture(:project, %{tenant_id: tenant.id, slug: "chg-delivery", repo_url: nil})
    agent = fixture(:agent, %{tenant_id: tenant.id})
    story = fixture(:story, %{tenant_id: tenant.id, project_id: work.id})

    source =
      fixture(:intake_source, %{
        tenant_id: tenant.id,
        project_id: work.id,
        repo_full_name: "mkreyman/chg"
      })

    {_secret, source} = source

    # Enrolment now gives a repo-less project the source's repo (US-52.3); the production
    # pairs predate that, so the work project is put back to holding no repo.
    AdminRepo.update_all(from(p in Project, where: p.id == ^work.id),
      set: [repo_url: nil, repo_key: nil]
    )

    {:ok, post} =
      Coordination.create_post(tenant.id, work.id, agent.id, %{"body" => "on the work channel"})

    claim =
      fixture(:channel_claim, %{
        tenant_id: tenant.id,
        project_id: work.id,
        claimant_agent_id: agent.id
      })

    kb =
      fixture(:project, %{
        tenant_id: tenant.id,
        kind: :kb,
        slug: "chg",
        repo_url: "git@github.com:mkreyman/chg.git"
      })

    article = fixture(:article, %{tenant_id: tenant.id, project_id: kb.id})

    %{
      tenant: tenant,
      work: work,
      kb: kb,
      rows: %{
        story: story,
        source: source,
        post: post,
        claim: claim,
        article: article
      }
    }
  end

  defp project_of(schema, id),
    do: AdminRepo.one!(from r in schema, where: r.id == ^id, select: r.project_id)

  describe "merge_into/4 (TC-52.2.1)" do
    test "a work project merges into its kb scope: rows move, kind becomes work, source archived" do
      %{tenant: t, work: work, kb: kb, rows: rows} = pair()

      assert {:ok, result} = Merge.merge_into(t.id, work.id, kb.id)
      assert result.promoted
      assert result.counts["stories"] == 1
      assert result.counts["epics"] == 1

      assert project_of(Story, rows.story.id) == kb.id
      assert project_of(Epic, rows.story.epic_id) == kb.id
      assert project_of(Source, rows.source.id) == kb.id
      assert project_of(ChannelPost, rows.post.id) == kb.id
      assert project_of(ChannelClaim, rows.claim.id) == kb.id
      assert project_of(Loopctl.Knowledge.Article, rows.article.id) == kb.id

      assert %{kind: :work, status: :active} = AdminRepo.get!(Project, kb.id)
      merged = AdminRepo.get!(Project, work.id)
      assert merged.status == :archived
      assert merged.metadata["merged_into"] == kb.id
    end

    test "a kb source never changes a work target's kind" do
      tenant = fixture(:tenant)
      kb = fixture(:project, %{tenant_id: tenant.id, kind: :kb})
      work = fixture(:project, %{tenant_id: tenant.id})

      assert {:ok, %{promoted: false}} = Merge.merge_into(tenant.id, kb.id, work.id)
      assert %{kind: :work} = AdminRepo.get!(Project, work.id)
    end
  end

  describe "the schema binding (TC-52.2.2)" do
    test "project_tables/0 is exactly the set of tables with a project_id foreign key" do
      %{rows: rows} =
        AdminRepo.query!("""
        SELECT DISTINCT k.table_name
        FROM information_schema.key_column_usage k
        JOIN information_schema.table_constraints tc
          ON tc.constraint_name = k.constraint_name AND tc.constraint_type = 'FOREIGN KEY'
        JOIN information_schema.constraint_column_usage cu
          ON cu.constraint_name = tc.constraint_name
        WHERE k.table_schema = 'public' AND k.column_name = 'project_id'
          AND cu.table_name = 'projects'
        """)

      assert Enum.sort(List.flatten(rows)) == Enum.sort(Merge.project_tables())
    end

    test "unique_keys/0 names every per-project unique index" do
      %{rows: rows} =
        AdminRepo.query!("""
        SELECT indexname FROM pg_indexes
        WHERE schemaname = 'public' AND indexdef ILIKE '%UNIQUE%'
          AND indexdef ~* '\\(.*project_id.*\\)'
          AND tablename NOT LIKE 'audit_log%'
          AND indexname <> 'egress_scope_markings_tenant_scope_idx'
        """)

      assert Enum.sort(List.flatten(rows)) == Enum.sort(Enum.map(Merge.unique_keys(), & &1.index))
    end
  end

  describe "conflicts (TC-52.2.3)" do
    test "a story number both projects hold refuses the merge and moves nothing" do
      tenant = fixture(:tenant)
      a = fixture(:project, %{tenant_id: tenant.id})
      b = fixture(:project, %{tenant_id: tenant.id})
      sa = fixture(:story, %{tenant_id: tenant.id, project_id: a.id, number: "1.1"})
      sb = fixture(:story, %{tenant_id: tenant.id, project_id: b.id, number: "1.1"})

      assert {:error, {:merge_conflicts, conflicts}} = Merge.merge_into(tenant.id, a.id, b.id)

      assert %{source_row_id: sa_id, target_row_id: sb_id} =
               Enum.find(conflicts, &(&1.table == "stories"))

      assert {sa_id, sb_id} == {sa.id, sb.id}
      assert project_of(Story, sa.id) == a.id
      assert %{status: :active} = AdminRepo.get!(Project, a.id)
    end
  end

  describe "dry run (TC-52.2.4)" do
    test "reports counts and conflicts and writes nothing" do
      %{tenant: t, work: work, kb: kb, rows: rows} = pair()

      assert {:ok, %{dry_run: true, counts: counts, conflicts: []}} =
               Merge.merge_into(t.id, work.id, kb.id, dry_run: true)

      assert counts["stories"] == 1
      assert counts["channel_posts"] == 1
      assert project_of(Story, rows.story.id) == work.id
      assert %{status: :active, kind: :work} = AdminRepo.get!(Project, work.id)
      assert %{kind: :kb} = AdminRepo.get!(Project, kb.id)
    end
  end

  describe "repeat and invalid merges (TC-52.2.5)" do
    test "a repeat answers already_merged; same, archived and foreign targets are refused" do
      %{tenant: t, work: work, kb: kb} = pair()
      {:ok, _} = Merge.merge_into(t.id, work.id, kb.id)

      assert {:ok, %{already_merged: true}} = Merge.merge_into(t.id, work.id, kb.id)
      assert {:error, :same_project} = Merge.merge_into(t.id, kb.id, kb.id)

      other = fixture(:project, %{tenant_id: t.id})
      assert {:error, :target_not_active} = Merge.merge_into(t.id, other.id, work.id)

      assert {:error, :source_not_active} =
               Merge.merge_into(t.id, work.id, fixture(:project, %{tenant_id: t.id}).id)

      foreign = fixture(:project)
      assert {:error, :not_found} = Merge.merge_into(t.id, other.id, foreign.id)
      assert {:error, :not_found} = Merge.merge_into(t.id, other.id, "not-a-uuid")
    end
  end

  describe "review fixes" do
    test "one UUID in two cases is the same project" do
      tenant = fixture(:tenant)
      p = fixture(:project, %{tenant_id: tenant.id, kind: :kb})

      assert {:error, :same_project} =
               Merge.merge_into(tenant.id, String.upcase(p.id), p.id)

      assert %{status: :active} = AdminRepo.get!(Project, p.id)
    end

    test "a project-scoped token budget moves; a budget on both projects conflicts" do
      %{tenant: t, work: work, kb: kb} = pair()
      budget = fixture(:token_budget, %{tenant_id: t.id, scope_type: :project, scope_id: work.id})

      assert {:ok, %{counts: %{"token_budgets" => 1}}} = Merge.merge_into(t.id, work.id, kb.id)
      assert AdminRepo.get!(Loopctl.TokenUsage.Budget, budget.id).scope_id == kb.id

      a = fixture(:project, %{tenant_id: t.id})
      b = fixture(:project, %{tenant_id: t.id})
      fixture(:token_budget, %{tenant_id: t.id, scope_type: :project, scope_id: a.id})
      fixture(:token_budget, %{tenant_id: t.id, scope_type: :project, scope_id: b.id})

      assert {:error, {:merge_conflicts, [%{table: "token_budgets"}]}} =
               Merge.merge_into(t.id, a.id, b.id)
    end

    test "a repeat merge moves rows written to the archived source since" do
      %{tenant: t, work: work, kb: kb} = pair()
      {:ok, _} = Merge.merge_into(t.id, work.id, kb.id)

      straggler = fixture(:article, %{tenant_id: t.id, project_id: work.id})

      assert {:ok, %{already_merged: true, counts: %{"articles" => 1}}} =
               Merge.merge_into(t.id, work.id, kb.id)

      assert project_of(Loopctl.Knowledge.Article, straggler.id) == kb.id

      assert [_] =
               AdminRepo.all(
                 from a in AuditLog,
                   where: a.entity_id == ^work.id and a.action == "merged_into_swept"
               )
    end

    test "the promoted target keeps an open channel" do
      %{tenant: t, work: work, kb: kb} = pair()
      {:ok, _} = Merge.merge_into(t.id, work.id, kb.id)
      assert %{kind: :work, open_channel: true} = AdminRepo.get!(Project, kb.id)

      outsider = fixture(:agent, %{tenant_id: t.id})
      assert :ok = Coordination.project_writable_by_agent(t.id, outsider.id, kb.id, :agent)
    end
  end

  describe "audit (TC-52.2.6)" do
    test "one merged_into entry on the source and one kind_promoted on the target" do
      %{tenant: t, work: work, kb: kb} = pair()
      {:ok, _} = Merge.merge_into(t.id, work.id, kb.id, actor_label: "user:test")

      assert [entry] =
               AdminRepo.all(
                 from a in AuditLog,
                   where:
                     a.tenant_id == ^t.id and a.entity_id == ^work.id and
                       a.action == "merged_into"
               )

      assert entry.metadata["target_id"] == kb.id
      assert entry.metadata["counts"]["stories"] == 1

      assert [promotion] =
               AdminRepo.all(
                 from a in AuditLog,
                   where:
                     a.tenant_id == ^t.id and a.entity_id == ^kb.id and
                       a.action == "kind_promoted"
               )

      assert promotion.old_state["kind"] == "kb"
      assert promotion.new_state["kind"] == "work"
    end
  end

  describe "intake sources keep their repo (#1113)" do
    # A work project holding acme/widgets with a live pr source for it.
    defp widgets(tenant) do
      project = fixture(:project, %{tenant_id: tenant.id, repo_url: nil})

      {_secret, source} =
        fixture(:intake_source, %{
          tenant_id: tenant.id,
          project_id: project.id,
          repo_full_name: "acme/widgets"
        })

      {AdminRepo.get!(Project, project.id), source}
    end

    test "a target holding another repo is refused and nothing moves" do
      t = fixture(:tenant)
      {source_project, source} = widgets(t)
      target = fixture(:project, %{tenant_id: t.id, repo_url: "acme/infra"})

      assert {:error, {:merge_strands_source, source.id, "acme/widgets"}} ==
               Merge.merge_into(t.id, source_project.id, target.id)

      assert project_of(Source, source.id) == source_project.id
      assert AdminRepo.get!(Project, source_project.id).status == :active
    end

    test "dry_run applies the same refusal" do
      t = fixture(:tenant)
      {source_project, source} = widgets(t)
      target = fixture(:project, %{tenant_id: t.id, repo_url: "acme/infra"})

      assert {:error, {:merge_strands_source, source_id, _}} =
               Merge.merge_into(t.id, source_project.id, target.id, dry_run: true)

      assert source_id == source.id
    end

    test "a target holding the same repo in another spelling merges" do
      t = fixture(:tenant)
      {source_project, source} = widgets(t)
      # The source project gives up the repo so the target can hold it beside it.
      AdminRepo.update_all(from(p in Project, where: p.id == ^source_project.id),
        set: [repo_url: nil, repo_key: nil]
      )

      target = fixture(:project, %{tenant_id: t.id, repo_url: "git@github.com:acme/widgets.git"})

      assert {:ok, %{promoted: false}} = Merge.merge_into(t.id, source_project.id, target.id)
      assert project_of(Source, source.id) == target.id
    end

    test "a repo-less target claims the sources' repo and resolves by it" do
      t = fixture(:tenant)
      {source_project, source} = widgets(t)
      target = fixture(:project, %{tenant_id: t.id, kind: :kb, repo_url: nil})

      assert {:ok, %{promoted: true}} = Merge.merge_into(t.id, source_project.id, target.id)

      merged = AdminRepo.get!(Project, target.id)
      assert merged.repo_key == "github.com/acme/widgets"
      assert merged.kind == :work
      assert project_of(Source, source.id) == target.id

      assert {:ok, %{id: resolved}, :repo_url} =
               Projects.resolve_project(t.id, repo_url: "https://github.com/acme/widgets")

      assert resolved == target.id
    end

    test "a repo-less target cannot claim a repo a third project holds; the merge rolls back" do
      t = fixture(:tenant)
      {source_project, source} = widgets(t)
      # The source project lets go of the repo, and a third project takes it.
      AdminRepo.update_all(from(p in Project, where: p.id == ^source_project.id),
        set: [repo_url: nil, repo_key: nil]
      )

      holder = fixture(:project, %{tenant_id: t.id, repo_url: "acme/widgets"})
      target = fixture(:project, %{tenant_id: t.id, repo_url: nil})

      assert {:error, {:repo_has_project, holder.id}} ==
               Merge.merge_into(t.id, source_project.id, target.id)

      assert project_of(Source, source.id) == source_project.id
      assert AdminRepo.get!(Project, source_project.id).status == :active
      assert is_nil(AdminRepo.get!(Project, target.id).repo_key)
    end

    test "dry_run refuses a repo a third project holds, as the merge would" do
      t = fixture(:tenant)
      {source_project, _source} = widgets(t)

      AdminRepo.update_all(from(p in Project, where: p.id == ^source_project.id),
        set: [repo_url: nil, repo_key: nil]
      )

      holder = fixture(:project, %{tenant_id: t.id, repo_url: "acme/widgets"})
      target = fixture(:project, %{tenant_id: t.id, repo_url: nil})

      assert {:error, {:repo_has_project, holder.id}} ==
               Merge.merge_into(t.id, source_project.id, target.id, dry_run: true)
    end

    test "the claim is audited on the target with the repo's old and new values" do
      t = fixture(:tenant)
      {source_project, _source} = widgets(t)
      target = fixture(:project, %{tenant_id: t.id, repo_url: nil})

      assert {:ok, %{promoted: false}} = Merge.merge_into(t.id, source_project.id, target.id)

      assert [entry] =
               AdminRepo.all(
                 from a in AuditLog,
                   where:
                     a.tenant_id == ^t.id and a.entity_id == ^target.id and
                       a.action == "repo_claimed"
               )

      assert entry.old_state["repo_url"] == nil
      assert entry.new_state["repo_url"] == "https://github.com/acme/widgets"
      assert entry.new_state["repo_key"] == "github.com/acme/widgets"
      assert entry.metadata["merged_from"] == source_project.id
    end

    test "revoked and ledger sources never block" do
      t = fixture(:tenant)
      {source_project, source} = widgets(t)

      AdminRepo.update_all(from(s in Source, where: s.id == ^source.id),
        set: [revoked_at: DateTime.utc_now()]
      )

      fixture(:ledger_source, %{
        tenant_id: t.id,
        project_id: source_project.id,
        repo_full_name: "acme/other"
      })

      target = fixture(:project, %{tenant_id: t.id, repo_url: "acme/infra"})

      assert {:ok, _} = Merge.merge_into(t.id, source_project.id, target.id)
      assert AdminRepo.get!(Project, target.id).repo_key == "github.com/acme/infra"
    end
  end

  describe "tenant isolation" do
    test "another tenant's rows under the same project id never move" do
      %{tenant: t, work: work, kb: kb} = pair()
      other = fixture(:tenant)
      other_project = fixture(:project, %{tenant_id: other.id})
      foreign_story = fixture(:story, %{tenant_id: other.id, project_id: other_project.id})

      {:ok, _} = Merge.merge_into(t.id, work.id, kb.id)
      assert project_of(Story, foreign_story.id) == other_project.id
      assert {:error, :not_found} = Merge.merge_into(other.id, work.id, kb.id)
      assert {:ok, _} = Projects.get_project(other.id, other_project.id)
    end
  end
end
