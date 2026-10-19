defmodule Loopctl.ChangesTest do
  @moduledoc """
  US-47.1: story ↔ chg change bindings (`Loopctl.Changes`).
  """

  use Loopctl.DataCase, async: true

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.AuditChain.Entry
  alias Loopctl.Changes
  alias Loopctl.Changes.Binding
  alias Loopctl.Changes.UnboundEvent
  alias Loopctl.Repo
  alias Loopctl.WorkBreakdown.Story

  setup :verify_on_exit!

  setup do
    tenant = fixture(:tenant)
    story = fixture(:story, %{tenant_id: tenant.id})
    %{tenant: tenant, story: story}
  end

  defp attrs(story_id, change_id, repo \\ "mkreyman/loopctl"),
    do: %{story_id: story_id, repo: repo, change_id: change_id}

  defp nobody, do: %{agent_id: nil}

  defp chain_actions(tenant_id) do
    AdminRepo.all(
      from e in Entry,
        where: e.tenant_id == ^tenant_id and like(e.action, "change_%"),
        order_by: [asc: e.chain_position],
        select: {e.action, e.entity_id, e.payload}
    )
  end

  # Writes a binding straight through `Repo`, past `Changes.bind/4`, so the assertion is on the
  # database's own refusal. A failed insert aborts the transaction, so its changeset is carried
  # out through the rollback.
  defp insert_around_context(tenant_id, changeset) do
    Repo.with_tenant(tenant_id, fn ->
      case Repo.insert(changeset) do
        {:error, refused} -> Repo.rollback(refused)
        {:ok, row} -> row
      end
    end)
  end

  defp count_rows(schema, tenant_id),
    do: AdminRepo.aggregate(from(r in schema, where: r.tenant_id == ^tenant_id), :count)

  describe "bind/4 — AC-47.1.1 the binding row" do
    test "binds a change to the tenant's story", %{tenant: tenant, story: story} do
      assert {:ok, %Binding{} = binding} =
               Changes.bind(tenant.id, attrs(story.id, "C1"), nobody())

      assert binding.tenant_id == tenant.id
      assert binding.story_id == story.id
      assert binding.repo == "mkreyman/loopctl"
      assert binding.change_id == "C1"
      assert binding.superseded_at == nil
      assert Changes.current_binding(tenant.id, story.id).id == binding.id
    end

    test "tenant_id is never cast: a tenant_id in attrs is ignored", %{
      tenant: tenant,
      story: story
    } do
      other = fixture(:tenant)

      assert {:ok, binding} =
               Changes.bind(
                 tenant.id,
                 Map.put(attrs(story.id, "C1"), :tenant_id, other.id),
                 nobody()
               )

      assert binding.tenant_id == tenant.id
      assert count_rows(Binding, other.id) == 0
    end

    test "string-keyed attrs bind the same way", %{tenant: tenant, story: story} do
      assert {:ok, %Binding{change_id: "C1"}} =
               Changes.bind(
                 tenant.id,
                 %{"story_id" => story.id, "repo" => "mkreyman/loopctl", "change_id" => "C1"},
                 nobody()
               )
    end

    test "missing fields are a changeset error, and nothing is written", %{tenant: tenant} do
      assert {:error, %Ecto.Changeset{} = changeset} =
               Changes.bind(tenant.id, %{repo: "mkreyman/loopctl"}, nobody())

      assert %{story_id: [_], change_id: [_]} = errors_on(changeset)
      assert count_rows(Binding, tenant.id) == 0
      assert count_rows(UnboundEvent, tenant.id) == 0
    end

    test "overlong fields are refused", %{tenant: tenant, story: story} do
      long = String.duplicate("x", Binding.max_length() + 1)

      assert {:error, %Ecto.Changeset{} = changeset} =
               Changes.bind(tenant.id, attrs(story.id, long), nobody())

      assert %{change_id: [_]} = errors_on(changeset)
    end

    test "the RLS policy hides another tenant's bindings from a tenant-scoped read", %{
      tenant: tenant,
      story: story
    } do
      fixture(:change_binding, %{tenant_id: tenant.id, story_id: story.id})
      other = fixture(:tenant)

      {:ok, seen} = Repo.with_tenant(other.id, fn -> Repo.all(Binding) end)
      assert seen == []
    end
  end

  describe "bind/4 — idempotency and the one-story-per-change refusal" do
    test "re-binding the same change to the same story returns the existing row", %{
      tenant: tenant,
      story: story
    } do
      {:ok, first} = Changes.bind(tenant.id, attrs(story.id, "C1"), nobody())
      {:ok, again} = Changes.bind(tenant.id, attrs(story.id, "C1"), nobody())

      assert again.id == first.id
      assert again.superseded_at == nil
      assert count_rows(Binding, tenant.id) == 1

      # The re-bind wrote nothing, so it appended nothing.
      assert [{"change_bound", _, _}] = chain_actions(tenant.id)
    end

    test "the same change on a DIFFERENT story is refused, and nothing changes", %{
      tenant: tenant,
      story: story
    } do
      other_story = fixture(:story, %{tenant_id: tenant.id})
      {:ok, kept} = Changes.bind(tenant.id, attrs(other_story.id, "C0"), nobody())
      {:ok, first} = Changes.bind(tenant.id, attrs(story.id, "C1"), nobody())

      assert {:error, :change_bound_to_other_story} =
               Changes.bind(tenant.id, attrs(other_story.id, "C1"), nobody())

      # Neither story's current binding moved: the refusal rolled back before any supersede.
      assert Changes.current_binding(tenant.id, story.id).id == first.id
      assert Changes.current_binding(tenant.id, other_story.id).id == kept.id
    end

    test "the same change id in another repo is a different change", %{
      tenant: tenant,
      story: story
    } do
      other_story = fixture(:story, %{tenant_id: tenant.id})
      {:ok, _} = Changes.bind(tenant.id, attrs(story.id, "C1", "mkreyman/a"), nobody())

      assert {:ok, %Binding{}} =
               Changes.bind(tenant.id, attrs(other_story.id, "C1", "mkreyman/b"), nobody())
    end
  end

  describe "bind/4 — AC-47.1.2 exactly one current binding (TC-47.1.2)" do
    test "binding C2 supersedes C1 in the same transaction", %{tenant: tenant, story: story} do
      {:ok, c1} = Changes.bind(tenant.id, attrs(story.id, "C1"), nobody())
      {:ok, c2} = Changes.bind(tenant.id, attrs(story.id, "C2"), nobody())

      assert Changes.current_binding(tenant.id, story.id).id == c2.id

      assert [
               %Binding{id: id1, superseded_at: %DateTime{}},
               %Binding{id: id2, superseded_at: nil}
             ] =
               Changes.list_bindings(tenant.id, story.id)

      assert {id1, id2} == {c1.id, c2.id}

      assert [{"change_bound", _, _}, {"change_bound", story_id, payload}] =
               chain_actions(tenant.id)

      assert story_id == story.id
      assert payload["binding_id"] == c2.id
      assert payload["superseded_binding_ids"] == [c1.id]
    end

    test "a failed bind rolls the supersede back with it", %{tenant: tenant, story: story} do
      other_story = fixture(:story, %{tenant_id: tenant.id})
      {:ok, c1} = Changes.bind(tenant.id, attrs(story.id, "C1"), nobody())
      {:ok, _} = Changes.bind(tenant.id, attrs(other_story.id, "C2"), nobody())

      # C2 is another story's: refused, and C1 stays current.
      assert {:error, :change_bound_to_other_story} =
               Changes.bind(tenant.id, attrs(story.id, "C2"), nobody())

      assert Changes.current_binding(tenant.id, story.id).id == c1.id
    end

    test "the database refuses a second current binding for one story", %{
      tenant: tenant,
      story: story
    } do
      fixture(:change_binding, %{tenant_id: tenant.id, story_id: story.id})

      changeset =
        Binding.create_changeset(%Binding{tenant_id: tenant.id}, %{
          story_id: story.id,
          repo: "mkreyman/loopctl",
          change_id: "written-around-the-context"
        })

      assert {:error, %Ecto.Changeset{} = refused} = insert_around_context(tenant.id, changeset)

      assert %{tenant_id: ["has already been taken"]} = errors_on(refused)
    end

    test "the database refuses a second binding of one change", %{tenant: tenant, story: story} do
      fixture(:change_binding, %{tenant_id: tenant.id, story_id: story.id, change_id: "C1"})
      other_story = fixture(:story, %{tenant_id: tenant.id})

      changeset =
        Binding.create_changeset(%Binding{tenant_id: tenant.id}, %{
          story_id: other_story.id,
          repo: "mkreyman/loopctl",
          change_id: "C1"
        })

      assert {:error, %Ecto.Changeset{} = refused} = insert_around_context(tenant.id, changeset)

      assert %{tenant_id: ["has already been taken"]} = errors_on(refused)
    end

    test "a story with no binding has no current one", %{tenant: tenant, story: story} do
      assert Changes.current_binding(tenant.id, story.id) == nil
      assert Changes.list_bindings(tenant.id, story.id) == []
    end
  end

  describe "bind/4 — AC-47.1.3 foreign and unknown story ids (TC-47.1.1)" do
    test "a foreign story id binds nothing in either tenant and answers like an unknown id", %{
      tenant: tenant
    } do
      tenant_b = fixture(:tenant)
      story_b = fixture(:story, %{tenant_id: tenant_b.id})
      unknown_id = Ecto.UUID.generate()

      foreign_answer = Changes.bind(tenant.id, attrs(story_b.id, "C1"), nobody())
      unknown_answer = Changes.bind(tenant.id, attrs(unknown_id, "C2"), nobody())

      assert foreign_answer == {:ok, :unbound}
      assert foreign_answer == unknown_answer

      assert count_rows(Binding, tenant.id) == 0
      assert count_rows(Binding, tenant_b.id) == 0
      assert Changes.current_binding(tenant_b.id, story_b.id) == nil

      # Nothing at all lands in the owning tenant — no event row, no chain entry.
      assert count_rows(UnboundEvent, tenant_b.id) == 0
      assert chain_actions(tenant_b.id) == []
    end

    test "both are recorded as unbound events in the CALLING tenant, the same way", %{
      tenant: tenant
    } do
      story_b = fixture(:story, %{tenant_id: fixture(:tenant).id})
      unknown_id = Ecto.UUID.generate()

      {:ok, :unbound} = Changes.bind(tenant.id, attrs(story_b.id, "C1"), nobody())
      {:ok, :unbound} = Changes.bind(tenant.id, attrs(unknown_id, "C2"), nobody())

      assert [%UnboundEvent{claimed_story_id: foreign}] =
               Changes.list_unbound_events(tenant.id, "mkreyman/loopctl", "C1")

      assert [%UnboundEvent{claimed_story_id: unknown}] =
               Changes.list_unbound_events(tenant.id, "mkreyman/loopctl", "C2")

      assert {foreign, unknown} == {story_b.id, unknown_id}

      assert [{"change_unbound", _, p1}, {"change_unbound", _, p2}] = chain_actions(tenant.id)
      assert Map.keys(p1) == Map.keys(p2)
    end

    test "a malformed story id is answered as an unknown one", %{tenant: tenant} do
      assert {:ok, :unbound} = Changes.bind(tenant.id, attrs("not-a-uuid", "C1"), nobody())

      assert [%UnboundEvent{claimed_story_id: "not-a-uuid"}] =
               Changes.list_unbound_events(tenant.id, "mkreyman/loopctl", "C1")

      assert Changes.current_binding(tenant.id, "not-a-uuid") == nil
      assert Changes.list_bindings(tenant.id, "not-a-uuid") == []
    end

    test "a redelivered unbound bind records one event and one chain entry", %{tenant: tenant} do
      unknown_id = Ecto.UUID.generate()

      {:ok, :unbound} = Changes.bind(tenant.id, attrs(unknown_id, "C1"), nobody())
      {:ok, :unbound} = Changes.bind(tenant.id, attrs(unknown_id, "C1"), nobody())

      assert count_rows(UnboundEvent, tenant.id) == 1
      assert [{"change_unbound", _, _}] = chain_actions(tenant.id)
    end

    test "reads of another tenant's story are empty, not an error", %{tenant: tenant} do
      tenant_b = fixture(:tenant)
      story_b = fixture(:story, %{tenant_id: tenant_b.id})
      fixture(:change_binding, %{tenant_id: tenant_b.id, story_id: story_b.id})

      assert Changes.current_binding(tenant.id, story_b.id) == nil
      assert Changes.list_bindings(tenant.id, story_b.id) == []
      assert %Binding{} = Changes.current_binding(tenant_b.id, story_b.id)
    end
  end

  describe "bind/4 — AC-47.1.4 submitter is not custody (TC-47.1.3)" do
    test "a submitter who is not the claimant is flagged and re-anchors nothing", %{
      tenant: tenant
    } do
      %{story: story, agent: claimant, dispatch: dispatch} =
        fixture(:claimed_story, %{tenant_id: tenant.id})

      stranger = fixture(:agent, %{tenant_id: tenant.id})

      assert {:ok, %Binding{} = binding} =
               Changes.bind(tenant.id, attrs(story.id, "C1"), %{agent_id: stranger.id})

      assert binding.submitter_not_claimant
      assert binding.submitter_agent_id == stranger.id

      reloaded = AdminRepo.get!(Story, story.id)
      assert reloaded.assigned_agent_id == claimant.id
      assert reloaded.implementer_dispatch_id == dispatch.id

      assert [{"change_bound", _, %{"submitter_not_claimant" => true}}] =
               chain_actions(tenant.id)
    end

    test "the claimant's own submission is not flagged", %{tenant: tenant} do
      %{story: story, agent: claimant, dispatch: dispatch} =
        fixture(:claimed_story, %{tenant_id: tenant.id})

      assert {:ok, %Binding{submitter_not_claimant: false}} =
               Changes.bind(tenant.id, attrs(story.id, "C1"), %{agent_id: claimant.id})

      reloaded = AdminRepo.get!(Story, story.id)
      assert reloaded.assigned_agent_id == claimant.id
      assert reloaded.implementer_dispatch_id == dispatch.id
    end

    test "an unidentified submitter is not the claimant", %{tenant: tenant} do
      %{story: story} = fixture(:claimed_story, %{tenant_id: tenant.id})

      assert {:ok, %Binding{submitter_not_claimant: true, submitter_agent_id: nil}} =
               Changes.bind(tenant.id, attrs(story.id, "C1"), nobody())
    end

    test "on an unclaimed story no submitter holds the claim", %{tenant: tenant, story: story} do
      agent = fixture(:agent, %{tenant_id: tenant.id})

      assert {:ok, %Binding{submitter_not_claimant: true}} =
               Changes.bind(tenant.id, attrs(story.id, "C1"), %{agent_id: agent.id})

      assert AdminRepo.get!(Story, story.id).assigned_agent_id == nil
    end

    test "a submitter in attrs is ignored: only the submitter argument counts", %{
      tenant: tenant
    } do
      %{story: story, agent: claimant} = fixture(:claimed_story, %{tenant_id: tenant.id})

      forged =
        story.id
        |> attrs("C1")
        |> Map.merge(%{submitter_agent_id: claimant.id, submitter_not_claimant: false})

      assert {:ok, %Binding{submitter_not_claimant: true, submitter_agent_id: nil}} =
               Changes.bind(tenant.id, forged, nobody())
    end

    test "the submitter's lineage attributes the chain entry", %{tenant: tenant, story: story} do
      lineage = [Ecto.UUID.generate()]

      {:ok, _} =
        Changes.bind(tenant.id, attrs(story.id, "C1"), %{agent_id: nil, actor_lineage: lineage})

      assert [^lineage] =
               AdminRepo.all(
                 from e in Entry, where: e.tenant_id == ^tenant.id, select: e.actor_lineage
               )
    end
  end
end
