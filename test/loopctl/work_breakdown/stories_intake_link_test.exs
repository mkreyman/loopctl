defmodule Loopctl.WorkBreakdown.StoriesIntakeLinkTest do
  @moduledoc """
  `stories.intake_record_id` (#803 §4, #805): which reported issue a story came from.

  Provenance, on the same terms as `implementer_dispatch_id` and `lifecycle_entered_at`:
  set once at creation from an OPTION, never reachable from a request body, never rewritten,
  and always optional.
  """

  use Loopctl.DataCase, async: true

  alias Loopctl.AdminRepo
  alias Loopctl.WorkBreakdown.Stories
  alias Loopctl.WorkBreakdown.Story

  setup :verify_on_exit!

  setup do
    tenant = fixture(:tenant)
    project = fixture(:project, %{tenant_id: tenant.id})
    epic = fixture(:epic, %{tenant_id: tenant.id, project_id: project.id})
    record = fixture(:intake_record, %{tenant_id: tenant.id, repo: AdminRepo})

    %{tenant: tenant, epic: epic, record: record}
  end

  test "a story created from an intake record records which one", ctx do
    assert {:ok, story} =
             Stories.create_story(ctx.tenant.id, attrs(ctx, "1.1"),
               intake_record_id: ctx.record.id
             )

    assert story.intake_record_id == ctx.record.id
    assert {:ok, reloaded} = Stories.get_story(ctx.tenant.id, story.id)
    assert reloaded.intake_record_id == ctx.record.id
  end

  test "the link is OPTIONAL: a story that came from nobody's issue has none", ctx do
    assert {:ok, story} = Stories.create_story(ctx.tenant.id, attrs(ctx, "1.2"))
    assert story.intake_record_id == nil
  end

  test "another tenant's record is refused, and no story is created", ctx do
    other = fixture(:tenant)
    other_record = fixture(:intake_record, %{tenant_id: other.id, repo: AdminRepo})

    assert {:error, :intake_record_not_found} =
             Stories.create_story(ctx.tenant.id, attrs(ctx, "1.3"),
               intake_record_id: other_record.id
             )

    assert {:ok, %{data: [], total: 0}} = Stories.list_stories(ctx.tenant.id, ctx.epic.id)
  end

  test "a record that does not exist is refused", ctx do
    assert {:error, :intake_record_not_found} =
             Stories.create_story(ctx.tenant.id, attrs(ctx, "1.4"),
               intake_record_id: Ecto.UUID.generate()
             )
  end

  test "a malformed id is refused rather than reaching the foreign key", ctx do
    assert {:error, :intake_record_not_found} =
             Stories.create_story(ctx.tenant.id, attrs(ctx, "1.5"), intake_record_id: "nope")
  end

  test "the link cannot be set through attrs on create", ctx do
    # It is provenance, so it must not be reachable from a request body. `create_changeset/2`
    # does not cast it, and `attrs` is what a controller passes through — as string keys,
    # which is the shape a JSON body actually arrives in.
    string_attrs =
      ctx
      |> attrs("1.6")
      |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)
      |> Map.put("intake_record_id", ctx.record.id)

    assert {:ok, story} = Stories.create_story(ctx.tenant.id, string_attrs)
    assert story.intake_record_id == nil

    # And with atom keys, which is how an internal caller would pass it.
    assert {:ok, atom_story} =
             Stories.create_story(
               ctx.tenant.id,
               Map.put(attrs(ctx, "1.8"), :intake_record_id, ctx.record.id)
             )

    assert atom_story.intake_record_id == nil
  end

  test "the link cannot be moved by an update, including through metadata", ctx do
    {:ok, story} =
      Stories.create_story(ctx.tenant.id, attrs(ctx, "1.7"), intake_record_id: ctx.record.id)

    other_record = fixture(:intake_record, %{tenant_id: ctx.tenant.id, repo: AdminRepo})

    # `PATCH /api/v1/stories/:id` whole-map-replaces `metadata`, which is exactly how the
    # `lifecycle_entered_at` marker was once erased. A column that `update_changeset/2` does
    # not cast cannot be moved that way.
    assert {:ok, updated} =
             Stories.update_story(ctx.tenant.id, story, %{
               "title" => "renamed",
               "metadata" => %{"anything" => "at all"},
               "intake_record_id" => other_record.id
             })

    assert updated.intake_record_id == ctx.record.id
    assert updated.title == "renamed"
  end

  test "at most ONE story per intake record", ctx do
    assert {:ok, _first} =
             Stories.create_story(ctx.tenant.id, attrs(ctx, "2.1"),
               intake_record_id: ctx.record.id
             )

    # Two stories from one reported issue means two closures aimed at one issue, and then
    # whichever verdict lands first decides what the reporter is told — a rejected sibling
    # closing her issue with "nothing has been deployed" while the real fix is still being
    # implemented. Design §4's triage contract emits one story per verdict, so this is an
    # invariant rather than a restriction.
    assert {:error, :intake_record_already_linked} =
             Stories.create_story(ctx.tenant.id, attrs(ctx, "2.2"),
               intake_record_id: ctx.record.id
             )

    # The refusal is the DATABASE's, and the second story does not exist.
    assert {:ok, %{total: 1}} = Stories.list_stories(ctx.tenant.id, ctx.epic.id)
  end

  test "the one-story rule does not constrain UNLINKED stories", ctx do
    # The index is partial on `intake_record_id IS NOT NULL`, so the ordinary case — many
    # authored stories, none from an issue — is untouched.
    for number <- ["3.1", "3.2", "3.3"] do
      assert {:ok, %{intake_record_id: nil}} =
               Stories.create_story(ctx.tenant.id, attrs(ctx, number))
    end

    assert {:ok, %{total: 3}} = Stories.list_stories(ctx.tenant.id, ctx.epic.id)
  end

  test "two tenants may each link a story to their OWN record of the same issue", ctx do
    other = fixture(:tenant)
    other_project = fixture(:project, %{tenant_id: other.id})
    other_epic = fixture(:epic, %{tenant_id: other.id, project_id: other_project.id})
    other_record = fixture(:intake_record, %{tenant_id: other.id, repo: AdminRepo})

    assert {:ok, _} =
             Stories.create_story(ctx.tenant.id, attrs(ctx, "4.1"),
               intake_record_id: ctx.record.id
             )

    # The index is keyed on (tenant_id, intake_record_id), so it is not a cross-tenant
    # bottleneck.
    assert {:ok, _} =
             Stories.create_story(
               other.id,
               %{epic_id: other_epic.id, number: "4.1", title: "theirs"},
               intake_record_id: other_record.id
             )
  end

  test "neither changeset casts the link", _ctx do
    for changeset <- [
          Story.create_changeset(%Story{}, %{
            "number" => "9.9",
            "title" => "t",
            "intake_record_id" => Ecto.UUID.generate()
          }),
          Story.update_changeset(%Story{}, %{"intake_record_id" => Ecto.UUID.generate()})
        ] do
      refute Map.has_key?(changeset.changes, :intake_record_id)
    end
  end

  defp attrs(ctx, number) do
    %{epic_id: ctx.epic.id, number: number, title: "story #{number}"}
  end
end
