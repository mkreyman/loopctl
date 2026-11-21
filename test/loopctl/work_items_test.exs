defmodule Loopctl.WorkItemsTest do
  @moduledoc """
  US-52.17: a work item's notes. Only the item's current holder (or an orchestrator+ key)
  writes one, each write is a note and a `note_written` event together, a repeated
  idempotency key writes nothing, and the list pages oldest first with the newest note of
  each section on its first page.
  """

  use Loopctl.DataCase, async: true

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Delivery.StageEvent
  alias Loopctl.Holders
  alias Loopctl.WorkBreakdown.Story
  alias Loopctl.WorkItems
  alias Loopctl.WorkItems.Note

  setup :verify_on_exit!

  defp holder(tenant_id, agent_id, session_id) do
    attrs = %{"kind" => "interactive", "session_id" => session_id, "host" => "minis"}
    {:ok, %{holder: holder}} = Holders.register(tenant_id, agent_id, attrs)
    holder.id
  end

  defp held_story(holder_id) do
    story = fixture(:story, %{})

    {1, [held]} =
      AdminRepo.update_all(
        from(s in Story, where: s.id == ^story.id, select: s),
        set: [assigned_holder_id: holder_id]
      )

    held
  end

  defp setup_held(_ctx) do
    agent = fixture(:agent, %{})
    holder_id = holder(agent.tenant_id, agent.id, "session-a")
    story = fixture(:story, %{tenant_id: agent.tenant_id})

    {1, [story]} =
      AdminRepo.update_all(
        from(s in Story, where: s.id == ^story.id, select: s),
        set: [assigned_holder_id: holder_id]
      )

    author = %{api_key_id: Ecto.UUID.generate(), role: :agent, holder_id: holder_id}
    %{agent: agent, holder_id: holder_id, story: story, author: author}
  end

  defp note_events(tenant_id, story_id) do
    AdminRepo.all(
      from e in StageEvent,
        where: e.tenant_id == ^tenant_id and e.story_id == ^story_id and e.event == "note_written"
    )
  end

  defp write!(story, author, section, body) do
    {:ok, note} =
      WorkItems.write_note(
        story.tenant_id,
        story.id,
        %{"section" => section, "body" => body},
        author
      )

    note
  end

  defp note_count(tenant_id, story_id) do
    AdminRepo.aggregate(
      from(n in Note, where: n.tenant_id == ^tenant_id and n.story_id == ^story_id),
      :count
    )
  end

  describe "the table (TC-52.17.1)" do
    setup :setup_held

    test "a section outside the four and a body over 16384 bytes are refused",
         %{story: story, author: author} do
      t = story.tenant_id

      assert {:error, %Ecto.Changeset{errors: errors}} =
               WorkItems.write_note(t, story.id, %{"section" => "diary", "body" => "b"}, author)

      assert Keyword.has_key?(errors, :section)

      body = String.duplicate("é", 8193)

      assert {:error, %Ecto.Changeset{errors: errors}} =
               WorkItems.write_note(t, story.id, %{"section" => "plan", "body" => body}, author)

      assert Keyword.has_key?(errors, :body)
      assert note_count(t, story.id) == 0
    end

    test "the DB CHECKs hold the same bounds", %{story: story} do
      row = fn attrs ->
        Map.merge(
          %{
            id: Ecto.UUID.generate(),
            tenant_id: story.tenant_id,
            story_id: story.id,
            author_api_key_id: Ecto.UUID.generate(),
            section: "plan",
            body: "b",
            inserted_at: DateTime.utc_now()
          },
          attrs
        )
      end

      assert_raise Postgrex.Error, ~r/story_notes_section_known/, fn ->
        AdminRepo.insert_all(Note, [row.(%{section: "diary"})])
      end

      assert_raise Postgrex.Error, ~r/story_notes_body_size/, fn ->
        AdminRepo.insert_all(Note, [row.(%{body: ""})])
      end
    end

    test "a credential-shaped body is refused", %{story: story, author: author} do
      body = "token: ghp_" <> String.duplicate("a", 36)

      assert {:error, %Ecto.Changeset{errors: errors}} =
               WorkItems.write_note(
                 story.tenant_id,
                 story.id,
                 %{"section" => "progress", "body" => body},
                 author
               )

      assert Keyword.has_key?(errors, :body)
    end
  end

  describe "who writes (TC-52.17.2)" do
    setup :setup_held

    test "the current holder writes, naming itself", %{story: story, author: author} do
      assert {:ok, %Note{} = note} =
               WorkItems.write_note(
                 story.tenant_id,
                 story.id,
                 %{"section" => "plan", "body" => "split the migration"},
                 author
               )

      assert note.holder_id == author.holder_id
      assert note.author_api_key_id == author.api_key_id
    end

    test "another session of the same agent is held_by_other_holder",
         %{agent: agent, holder_id: holder_id, story: story} do
      other = holder(agent.tenant_id, agent.id, "session-b")
      author = %{api_key_id: Ecto.UUID.generate(), role: :agent, holder_id: other}

      assert {:error, {:held_by_other_holder, ^holder_id}} =
               WorkItems.write_note(
                 story.tenant_id,
                 story.id,
                 %{"section" => "plan", "body" => "b"},
                 author
               )

      assert note_count(story.tenant_id, story.id) == 0
      assert note_events(story.tenant_id, story.id) == []
    end

    test "an agent key with no holder is held_by_other_holder on a held item",
         %{holder_id: holder_id, story: story} do
      author = %{api_key_id: Ecto.UUID.generate(), role: :agent, holder_id: nil}

      assert {:error, {:held_by_other_holder, ^holder_id}} =
               WorkItems.write_note(
                 story.tenant_id,
                 story.id,
                 %{"section" => "plan", "body" => "b"},
                 author
               )
    end

    test "on an item nobody holds an agent is not_holder, an orchestrator writes" do
      story = fixture(:story, %{})
      agent = %{api_key_id: Ecto.UUID.generate(), role: :agent, holder_id: nil}
      orch = %{api_key_id: Ecto.UUID.generate(), role: :orchestrator, holder_id: nil}
      attrs = %{"section" => "decision", "body" => "park it"}

      assert {:error, :not_holder} = WorkItems.write_note(story.tenant_id, story.id, attrs, agent)

      assert {:ok, %Note{holder_id: nil}} =
               WorkItems.write_note(story.tenant_id, story.id, attrs, orch)
    end

    test "an orchestrator writes on another session's item, naming no holder",
         %{story: story} do
      orch = %{api_key_id: Ecto.UUID.generate(), role: :orchestrator, holder_id: nil}

      assert {:ok, %Note{holder_id: nil}} =
               WorkItems.write_note(
                 story.tenant_id,
                 story.id,
                 %{"section" => "question", "body" => "why?"},
                 orch
               )
    end
  end

  describe "note and event together (TC-52.17.3)" do
    setup :setup_held

    test "a note writes one note_written event naming the holder and section",
         %{story: story, author: author} do
      {:ok, note} =
        WorkItems.write_note(
          story.tenant_id,
          story.id,
          %{"section" => "progress", "body" => "tests green"},
          author
        )

      assert [event] = note_events(story.tenant_id, story.id)
      assert event.actor_holder_id == author.holder_id
      assert event.reason == "progress note"
      assert event.data == %{"note_id" => note.id, "section" => "progress"}
    end

    test "when the event cannot be written the note is not either", %{
      story: story,
      author: author
    } do
      # The story row is passed as a value whose id names no story, so the event's own
      # story read refuses inside the transaction.
      ghost = %{story | id: Ecto.UUID.generate()}

      assert {:error, :not_found} =
               WorkItems.write_note(
                 story.tenant_id,
                 ghost.id,
                 %{"section" => "plan", "body" => "b"},
                 author,
                 story: ghost
               )

      assert AdminRepo.aggregate(from(n in Note, where: n.story_id == ^ghost.id), :count) == 0
    end

    test "a holder id from another tenant refuses the event, and so the note" do
      other = fixture(:agent, %{})
      foreign_holder = holder(other.tenant_id, other.id, "foreign")
      story = held_story(foreign_holder)
      author = %{api_key_id: Ecto.UUID.generate(), role: :agent, holder_id: foreign_holder}

      assert {:error, :invalid_holder} =
               WorkItems.write_note(
                 story.tenant_id,
                 story.id,
                 %{"section" => "plan", "body" => "b"},
                 author
               )

      assert note_count(story.tenant_id, story.id) == 0
    end
  end

  describe "idempotency (TC-52.17.4)" do
    setup :setup_held

    test "the same key returns the first note and writes nothing more",
         %{story: story, author: author} do
      attrs = %{"section" => "plan", "body" => "first", "idempotency_key" => "k-1"}
      {:ok, first} = WorkItems.write_note(story.tenant_id, story.id, attrs, author)

      again = %{attrs | "body" => "second"}
      assert {:ok, ^first} = WorkItems.write_note(story.tenant_id, story.id, again, author)

      assert note_count(story.tenant_id, story.id) == 1
      assert length(note_events(story.tenant_id, story.id)) == 1
    end

    test "a retry after the item changed hands still returns the first note",
         %{agent: agent, story: story, author: author} do
      attrs = %{"section" => "plan", "body" => "first", "idempotency_key" => "k-moved"}
      {:ok, first} = WorkItems.write_note(story.tenant_id, story.id, attrs, author)

      next = holder(agent.tenant_id, agent.id, "session-next")

      {1, _} =
        AdminRepo.update_all(from(s in Story, where: s.id == ^story.id),
          set: [assigned_holder_id: next]
        )

      assert {:ok, ^first} = WorkItems.write_note(story.tenant_id, story.id, attrs, author)
    end

    test "a note row already holding the key is answered even if its event is missing",
         %{story: story, author: author} do
      # The race the unique index settles: another write committed the note first.
      existing = %{
        id: Ecto.UUID.generate(),
        tenant_id: story.tenant_id,
        story_id: story.id,
        author_api_key_id: author.api_key_id,
        section: "plan",
        body: "raced",
        idempotency_key: "k-race",
        inserted_at: DateTime.utc_now()
      }

      {1, _} = AdminRepo.insert_all(Note, [existing])

      attrs = %{"section" => "plan", "body" => "mine", "idempotency_key" => "k-race"}

      assert {:ok, %Note{body: "raced"}} =
               WorkItems.write_note(story.tenant_id, story.id, attrs, author)
    end
  end

  describe "list_notes/3 (TC-52.17.5)" do
    setup :setup_held

    test "oldest first, with current carrying the newest note per section",
         %{story: story, author: author} do
      a = write!(story, author, "plan", "p1")
      b = write!(story, author, "progress", "g1")
      c = write!(story, author, "plan", "p2")

      assert {:ok, page} = WorkItems.list_notes(story.tenant_id, story.id)
      assert Enum.map(page.data, & &1.id) == [a.id, b.id, c.id]
      assert page.current["plan"].id == c.id
      assert page.current["progress"].id == b.id
      refute Map.has_key?(page.current, "decision")
      refute page.has_more
      assert page.next_cursor == nil
    end

    test "a section filter and a cursor page through, current only on the first page",
         %{story: story, author: author} do
      # A plan note first and between, so an unfiltered page would carry it.
      _first_plan = write!(story, author, "plan", "p0")
      [n1, n2, n3] = for i <- 1..3, do: write!(story, author, "progress", "g#{i}")
      _mid_plan = write!(story, author, "plan", "p1")
      notes = [n1, n2, n3, write!(story, author, "progress", "g4")]

      assert {:ok, first} =
               WorkItems.list_notes(story.tenant_id, story.id, section: "progress", limit: 2)

      assert Enum.map(first.data, & &1.id) == Enum.map(Enum.take(notes, 2), & &1.id)
      assert first.has_more
      assert is_map(first.current)

      assert {:ok, second} =
               WorkItems.list_notes(story.tenant_id, story.id,
                 section: "progress",
                 limit: 2,
                 after: first.next_cursor
               )

      assert Enum.map(second.data, & &1.id) == Enum.map(Enum.slice(notes, 2, 2), & &1.id)
      assert second.current == nil
    end

    test "the limit defaults to 50 and is clamped to 1..200", %{story: story, author: author} do
      now = DateTime.utc_now()

      rows =
        for i <- 1..201 do
          %{
            id: Ecto.UUID.generate(),
            tenant_id: story.tenant_id,
            story_id: story.id,
            author_api_key_id: author.api_key_id,
            section: "progress",
            body: "n#{i}",
            inserted_at: DateTime.add(now, i, :microsecond)
          }
        end

      {201, _} = AdminRepo.insert_all(Note, rows)

      assert {:ok, %{data: big, has_more: true}} =
               WorkItems.list_notes(story.tenant_id, story.id, limit: 10_000)

      assert length(big) == 200

      assert {:ok, %{data: default}} = WorkItems.list_notes(story.tenant_id, story.id)
      assert length(default) == 50

      assert {:ok, %{data: [_]}} = WorkItems.list_notes(story.tenant_id, story.id, limit: 0)
      assert WorkItems.page_limits() == {50, 200}
    end

    test "an unknown section and a foreign cursor are refused", %{story: story} do
      assert {:error, :invalid_section} =
               WorkItems.list_notes(story.tenant_id, story.id, section: "diary")

      assert {:error, :invalid_cursor} =
               WorkItems.list_notes(story.tenant_id, story.id, after: "not-a-cursor")
    end
  end

  describe "tenant isolation (TC-52.17.7)" do
    setup :setup_held

    test "another tenant's story is not_found, and its notes never appear",
         %{story: story, author: author} do
      _ = write!(story, author, "plan", "tenant A's plan")
      other = fixture(:tenant, %{})

      assert {:error, :not_found} = WorkItems.list_notes(other.id, story.id)

      orch = %{api_key_id: Ecto.UUID.generate(), role: :orchestrator, holder_id: nil}

      assert {:error, :not_found} =
               WorkItems.write_note(
                 other.id,
                 story.id,
                 %{"section" => "plan", "body" => "b"},
                 orch
               )

      assert {:ok, %{data: [_]}} = WorkItems.list_notes(story.tenant_id, story.id)
    end

    test "a cursor minted for one tenant does not decode for another",
         %{story: story, author: author} do
      for i <- 1..3, do: write!(story, author, "plan", "p#{i}")
      {:ok, page} = WorkItems.list_notes(story.tenant_id, story.id, limit: 1)
      other = fixture(:tenant, %{})

      assert {:error, :invalid_cursor} =
               WorkItems.list_notes(other.id, story.id, after: page.next_cursor)
    end
  end
end
