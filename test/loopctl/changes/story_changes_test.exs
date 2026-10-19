defmodule Loopctl.Changes.StoryChangesTest do
  @moduledoc """
  US-47.7: `Loopctl.Changes.story_changes/2`, the reader behind
  `GET /api/v1/stories/:id/changes` — ordering, the applied-only filter, both bounds and
  tenant isolation.
  """

  use Loopctl.DataCase, async: true

  alias Loopctl.AdminRepo
  alias Loopctl.Changes
  alias Loopctl.Changes.Binding

  setup :verify_on_exit!

  @repo "mkreyman/loopctl"

  setup do
    tenant = fixture(:tenant)
    story = fixture(:story, %{tenant_id: tenant.id})
    {_secret, source} = fixture(:intake_source, %{tenant_id: tenant.id})
    %{tenant: tenant, story: story, source: source}
  end

  defp bind(tenant, story, change_id) do
    fixture(:change_binding, %{
      tenant_id: tenant.id,
      story_id: story.id,
      repo: @repo,
      change_id: change_id
    })
  end

  defp event(ctx, change_id, seq, attrs \\ %{}) do
    fixture(
      :change_event,
      Map.merge(
        %{
          tenant_id: ctx.tenant.id,
          source_id: ctx.source.id,
          repo: @repo,
          change_id: change_id,
          event_seq: seq
        },
        attrs
      )
    )
  end

  # `inserted_at` is the app's clock, so nothing stops a current binding being stamped EARLIER
  # than one it superseded (clock skew between nodes, a backfill). Moving it is how a test lays
  # that out.
  defp stamp(binding_id, %DateTime{} = at) do
    {1, _} =
      AdminRepo.update_all(from(b in Binding, where: b.id == ^binding_id),
        set: [inserted_at: at]
      )
  end

  describe "story_changes/2" do
    test "a tenant story with no binding is an empty list, not a 404", %{tenant: t, story: s} do
      assert {:ok, %{bindings: [], binding_count: 0}} = Changes.story_changes(t.id, s.id)
    end

    test "bindings oldest first, the superseded one before the current one", ctx do
      first = bind(ctx.tenant, ctx.story, "chg-first")
      second = bind(ctx.tenant, ctx.story, "chg-second")

      assert {:ok, %{bindings: [a, b], binding_count: 2}} =
               Changes.story_changes(ctx.tenant.id, ctx.story.id)

      assert a.binding.id == first.id
      refute is_nil(a.binding.superseded_at)
      assert b.binding.id == second.id
      assert is_nil(b.binding.superseded_at)
    end

    test "each binding carries ITS change's applied events, in event_seq order", ctx do
      bind(ctx.tenant, ctx.story, "chg-a")
      bind(ctx.tenant, ctx.story, "chg-b")

      # Inserted out of order, so the ordering is the query's, not the insert's.
      event(ctx, "chg-a", 2, %{kind: "check_passed"})
      event(ctx, "chg-a", 1, %{kind: "submitted"})
      event(ctx, "chg-b", 1, %{kind: "submitted"})

      assert {:ok, %{bindings: [a, b]}} = Changes.story_changes(ctx.tenant.id, ctx.story.id)

      assert Enum.map(a.events, &{&1.change_id, &1.event_seq, &1.kind}) ==
               [{"chg-a", 1, "submitted"}, {"chg-a", 2, "check_passed"}]

      assert a.applied_event_count == 2
      assert Enum.map(b.events, &{&1.change_id, &1.event_seq}) == [{"chg-b", 1}]
      assert b.applied_event_count == 1
    end

    test "an event held ahead of a gap is not listed and not counted", ctx do
      bind(ctx.tenant, ctx.story, "chg-gap")
      event(ctx, "chg-gap", 1)
      event(ctx, "chg-gap", 3, %{applied: false})

      assert {:ok, %{bindings: [b]}} = Changes.story_changes(ctx.tenant.id, ctx.story.id)
      assert Enum.map(b.events, & &1.event_seq) == [1]
      assert b.applied_event_count == 1
    end

    test "at most max_events_per_change events, the newest, with the full count", ctx do
      max = Changes.max_events_per_change()
      extra = 3
      bind(ctx.tenant, ctx.story, "chg-long")
      for seq <- 1..(max + extra), do: event(ctx, "chg-long", seq)

      assert {:ok, %{bindings: [b]}} = Changes.story_changes(ctx.tenant.id, ctx.story.id)
      assert length(b.events) == max
      assert Enum.map(b.events, & &1.event_seq) == Enum.to_list((extra + 1)..(max + extra))
      assert b.applied_event_count == max + extra
    end

    test "at most max_bindings bindings, the newest, so the current one is always listed",
         ctx do
      max = Changes.max_bindings()
      ids = for n <- 1..(max + 2), do: bind(ctx.tenant, ctx.story, "chg-#{n}").id

      assert {:ok, %{bindings: listed, binding_count: total}} =
               Changes.story_changes(ctx.tenant.id, ctx.story.id)

      assert total == max + 2
      assert Enum.map(listed, & &1.binding.id) == Enum.drop(ids, 2)
      assert is_nil(List.last(listed).binding.superseded_at)
    end

    test "the current binding is listed last even when its inserted_at is the OLDEST", ctx do
      first = bind(ctx.tenant, ctx.story, "chg-first")
      current = bind(ctx.tenant, ctx.story, "chg-current")
      stamp(current.id, DateTime.add(first.inserted_at, -3600, :second))

      assert {:ok, %{bindings: [a, b], binding_count: 2}} =
               Changes.story_changes(ctx.tenant.id, ctx.story.id)

      assert a.binding.id == first.id
      assert b.binding.id == current.id
      assert is_nil(b.binding.superseded_at)
    end

    test "past max_bindings, a current binding with the OLDEST inserted_at is still listed",
         ctx do
      max = Changes.max_bindings()
      bindings = for n <- 1..(max + 2), do: bind(ctx.tenant, ctx.story, "chg-#{n}")
      {superseded, [current]} = Enum.split(bindings, -1)
      stamp(current.id, DateTime.add(hd(bindings).inserted_at, -3600, :second))

      assert {:ok, %{bindings: listed, binding_count: total}} =
               Changes.story_changes(ctx.tenant.id, ctx.story.id)

      assert total == max + 2
      assert length(listed) == max
      # The window keeps the current one and the NEWEST superseded ones, oldest first.
      assert Enum.map(listed, & &1.binding.id) ==
               Enum.map(Enum.take(superseded, -(max - 1)), & &1.id) ++ [current.id]
    end

    test "answers the story's canonical id, whatever case the caller sent", ctx do
      upper = String.upcase(ctx.story.id)
      refute upper == ctx.story.id

      assert {:ok, %{story_id: story_id}} = Changes.story_changes(ctx.tenant.id, upper)
      assert story_id == ctx.story.id
    end

    test "unknown, malformed and another tenant's story ids all answer :not_found", ctx do
      other = fixture(:tenant)
      foreign = fixture(:story, %{tenant_id: other.id})
      fixture(:change_binding, %{tenant_id: other.id, story_id: foreign.id})

      assert {:error, :not_found} = Changes.story_changes(ctx.tenant.id, foreign.id)
      assert {:error, :not_found} = Changes.story_changes(ctx.tenant.id, Ecto.UUID.generate())
      assert {:error, :not_found} = Changes.story_changes(ctx.tenant.id, "not-a-uuid")
    end

    test "tenant isolation: another tenant's events under the same change key are not read",
         ctx do
      bind(ctx.tenant, ctx.story, "chg-shared")
      event(ctx, "chg-shared", 1)

      other = fixture(:tenant)

      fixture(:change_event, %{
        tenant_id: other.id,
        repo: @repo,
        change_id: "chg-shared",
        event_seq: 2
      })

      assert {:ok, %{bindings: [b]}} = Changes.story_changes(ctx.tenant.id, ctx.story.id)
      assert Enum.map(b.events, & &1.event_seq) == [1]
      assert b.applied_event_count == 1
    end
  end
end
