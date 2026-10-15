defmodule Loopctl.Threads.KbRefsTest do
  @moduledoc """
  #978: a `message` or `checkpoint` entry names the knowledge articles it acted on, as data.
  The ids are checked against the articles the writing key can read before anything is
  written, bounded, de-duplicated, immutable with the entry, and chained in its audit event.
  """

  use Loopctl.DataCase, async: true

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.AuditChain.Entry, as: ChainEntry
  alias Loopctl.Knowledge
  alias Loopctl.Knowledge.Article
  alias Loopctl.Repo
  alias Loopctl.Threads
  alias Loopctl.Threads.Entry
  alias Loopctl.WorkBreakdown.Story

  setup :verify_on_exit!

  @epoch 3
  @sha1 String.duplicate("a", 40)
  @tree String.duplicate("c", 40)

  defp claimed_story do
    story = fixture(:stage_story, %{claim_epoch: @epoch, agent_status: :implementing})
    agent = fixture(:stage_agent, %{tenant_id: story.tenant_id})

    {:ok, _} =
      Repo.with_tenant(story.tenant_id, fn ->
        from(s in Story, where: s.id == ^story.id)
        |> Repo.update_all(set: [assigned_agent_id: agent.id])
      end)

    %{tenant_id: story.tenant_id, agent: agent, story: story}
  end

  defp article(ctx, attrs \\ %{}),
    do: fixture(:article, Map.put(attrs, :tenant_id, ctx.tenant_id))

  defp message(key, kb_refs, body \\ "per the decision"),
    do: %{"kind" => "message", "idempotency_key" => key, "body" => body, "kb_refs" => kb_refs}

  defp entry(ctx, attrs, opts \\ []) do
    Threads.record_entry(
      ctx.tenant_id,
      ctx.story.id,
      attrs,
      Keyword.merge(
        [author_principal: "agent:someone", actor_lineage: [], visibility_agent_id: nil],
        opts
      )
    )
  end

  defp checkpoint(ctx, overrides) do
    Threads.record_checkpoint(
      ctx.tenant_id,
      ctx.story.id,
      Keyword.merge(
        [
          agent_id: ctx.agent.id,
          claim_epoch: @epoch,
          commit_sha: @sha1,
          tree_sha: @tree,
          author_principal: "agent:#{ctx.agent.id}",
          actor_lineage: [],
          visibility_agent_id: nil
        ],
        overrides
      )
    )
  end

  # The article becomes another agent's private memory: unreadable by every other agent key.
  defp make_private(article) do
    AdminRepo.update_all(from(a in Article, where: a.id == ^article.id),
      set: [metadata: %{"visibility" => "private", "agent_id" => "owner"}]
    )
  end

  defp system_canonical(ctx) do
    {:ok, canonical} =
      Knowledge.create_article(ctx.tenant_id, %{
        title: "Shared canon decision",
        body: "canon body",
        category: :reference,
        scope: :system,
        status: :published
      })

    canonical
  end

  defp entries(ctx) do
    {:ok, thread} = Threads.get_thread(ctx.tenant_id, ctx.story.id)
    thread.entries
  end

  describe "a message" do
    test "records its references canonical, de-duplicated and in the order cited" do
      ctx = claimed_story()
      a = article(ctx)
      b = article(ctx)

      assert {:ok, entry, :created} =
               entry(ctx, message("m", [String.upcase(b.id), a.id, b.id]))

      assert entry.kb_refs == [b.id, a.id]
      assert [%{kb_refs: [b_id, a_id]}] = entries(ctx)
      assert {b_id, a_id} == {b.id, a.id}
    end

    test "an entry that cites nothing stores an empty list" do
      ctx = claimed_story()

      assert {:ok, %{kb_refs: []}, :created} =
               entry(ctx, Map.delete(message("m", nil), "kb_refs"))
    end

    test "an id naming no article refuses the whole entry, naming the id" do
      ctx = claimed_story()
      known = article(ctx)
      missing = Ecto.UUID.generate()

      assert {:error, :unprocessable_entity, %{code: "unknown_kb_refs", message: message}} =
               entry(ctx, message("m", [known.id, missing]))

      assert message =~ missing
      refute message =~ known.id
      assert entries(ctx) == []
    end

    test "tenant B cannot cite tenant A's article" do
      ctx = claimed_story()
      other = claimed_story()
      foreign = article(other)

      assert {:error, :unprocessable_entity, %{code: "unknown_kb_refs"}} =
               entry(ctx, message("m", [foreign.id]))

      assert entries(ctx) == []
    end

    test "an agent cites only what it can read: another agent's private memory is unknown" do
      ctx = claimed_story()
      private = article(ctx, %{metadata: %{"visibility" => "private", "agent_id" => "owner"}})

      assert {:error, :unprocessable_entity, %{code: "unknown_kb_refs"}} =
               entry(ctx, message("m1", [private.id]), visibility_agent_id: "someone-else")

      assert {:ok, %{kb_refs: [id]}, :created} =
               entry(ctx, message("m2", [private.id]), visibility_agent_id: "owner")

      assert id == private.id

      # A higher role passes `nil` and reads everything.
      assert {:ok, _, :created} = entry(ctx, message("m3", [private.id]))
    end

    test "a list over the bound, a non-list or a non-UUID is refused before any read" do
      ctx = claimed_story()
      over = for _ <- 1..(Entry.max_kb_refs() + 1), do: Ecto.UUID.generate()

      # `[nil]` and a 16-byte string would pass `Ecto.UUID`'s own cast, the second as a raw id.
      for refs <- [over, "not-a-list", ["nope"], [123], [nil], ["my-article-slug!"]] do
        assert {:error, %Ecto.Changeset{errors: errors}} = entry(ctx, message("m", refs))
        assert Keyword.has_key?(errors, :kb_refs)
      end

      assert entries(ctx) == []
    end

    test "the bound counts distinct articles, so repeats do not use it up" do
      ctx = claimed_story()
      a = article(ctx)
      refs = List.duplicate(a.id, Entry.max_kb_refs() + 5)

      assert {:ok, %{kb_refs: [id]}, :created} = entry(ctx, message("m", refs))
      assert id == a.id
    end

    test "a published system canonical is citable by any key" do
      ctx = claimed_story()
      canonical = system_canonical(ctx)

      assert {:ok, %{kb_refs: [id]}, :created} =
               entry(ctx, message("m", [canonical.id]), visibility_agent_id: "anyone")

      assert id == canonical.id

      # The review titles it from the same set.
      assert %{^id => %{title: "Shared canon decision"}} =
               Knowledge.article_refs(ctx.tenant_id, [id], "anyone")
    end

    test "a resend is answered from its row even after a cited article turned private" do
      ctx = claimed_story()
      a = article(ctx)

      {:ok, first, :created} = entry(ctx, message("m", [a.id]), visibility_agent_id: "writer")
      make_private(a)

      assert {:ok, ^first, :existing} =
               entry(ctx, message("m", [a.id]), visibility_agent_id: "writer")

      # A NEW write citing it is refused: the verdict binds new writes only.
      assert {:error, :unprocessable_entity, %{code: "unknown_kb_refs"}} =
               entry(ctx, message("m2", [a.id]), visibility_agent_id: "writer")
    end

    test "a resend with malformed references is refused, not matched to a row citing nothing" do
      ctx = claimed_story()
      {:ok, _first, :created} = entry(ctx, message("m", []))

      for refs <- ["nope", for(_ <- 0..Entry.max_kb_refs(), do: Ecto.UUID.generate())] do
        assert {:error, %Ecto.Changeset{errors: errors}} = entry(ctx, message("m", refs))
        assert Keyword.has_key?(errors, :kb_refs)
      end
    end

    test "citing without a visibility scope is a caller bug, not an unscoped read" do
      ctx = claimed_story()
      a = article(ctx)

      assert_raise KeyError, fn ->
        Threads.record_entry(ctx.tenant_id, ctx.story.id, message("m", [a.id]),
          author_principal: "agent:someone",
          actor_lineage: []
        )
      end

      # Citing nothing needs no scope, which is how the runner socket writes (#979).
      assert {:ok, _, :created} =
               Threads.record_entry(ctx.tenant_id, ctx.story.id, message("m", []),
                 author_principal: "agent:someone",
                 actor_lineage: []
               )
    end

    test "a resend is the same write only with the same references" do
      ctx = claimed_story()
      a = article(ctx)
      b = article(ctx)

      {:ok, first, :created} = entry(ctx, message("m", [a.id]))
      assert {:ok, ^first, :existing} = entry(ctx, message("m", [a.id]))

      assert {:error, {:conflict, "idempotency_key_reused", _}} =
               entry(ctx, message("m", [a.id, b.id]))
    end

    test "its audit event carries the references; one citing nothing carries no key" do
      ctx = claimed_story()
      a = article(ctx)
      {:ok, _, :created} = entry(ctx, message("cited", [a.id]))
      {:ok, _, :created} = entry(ctx, message("plain", []))

      [cited, plain] =
        Repo.all(
          from e in ChainEntry,
            where: e.tenant_id == ^ctx.tenant_id and e.entity_id == ^ctx.story.id,
            order_by: e.chain_position,
            select: e.payload
        )

      assert cited["kb_refs"] == [a.id]
      refute Map.has_key?(plain, "kb_refs")
    end
  end

  describe "a checkpoint" do
    test "stores its references on the checkpoint's entry, checked like a message's" do
      ctx = claimed_story()
      a = article(ctx)

      assert {:error, :unprocessable_entity, %{code: "unknown_kb_refs"}} =
               checkpoint(ctx, kb_refs: [Ecto.UUID.generate()])

      assert {:error, :unprocessable_entity, message} = checkpoint(ctx, kb_refs: "nope")
      assert message =~ "kb_refs"
      assert entries(ctx) == []

      assert {:ok, _cp, :created} = checkpoint(ctx, note: "why", kb_refs: [a.id])
      assert [%{kind: :checkpoint, kb_refs: [id]}] = entries(ctx)
      assert id == a.id
    end

    test "a resend is answered from its row even after a cited article turned private" do
      ctx = claimed_story()
      a = article(ctx)

      {:ok, cp, :created} = checkpoint(ctx, kb_refs: [a.id], visibility_agent_id: "writer")
      make_private(a)

      assert {:ok, ^cp, :existing} =
               checkpoint(ctx, kb_refs: [a.id], visibility_agent_id: "writer")
    end

    test "a resend that sends references must send the recorded ones; one that omits them replays" do
      ctx = claimed_story()
      a = article(ctx)
      b = article(ctx)

      {:ok, cp, :created} = checkpoint(ctx, note: "why", kb_refs: [a.id])
      assert {:ok, ^cp, :existing} = checkpoint(ctx, note: "why", kb_refs: [a.id])
      assert {:ok, ^cp, :existing} = checkpoint(ctx, note: "why")

      assert {:error, {:conflict, "checkpoint_conflict", message}} =
               checkpoint(ctx, note: "why", kb_refs: [b.id])

      assert message =~ "kb_refs"
    end
  end

  describe "the entry changeset" do
    test "a kind that cites nothing refuses references" do
      changeset =
        Entry.changeset(%Entry{}, %{
          "kind" => "finding",
          "idempotency_key" => "f",
          "body" => "b",
          "kb_refs" => [Ecto.UUID.generate()]
        })

      refute changeset.valid?
      assert {"only message and checkpoint entries cite articles", _} = changeset.errors[:kb_refs]
    end
  end

  describe "the database" do
    test "refuses references on a kind that cites nothing and past the bound" do
      ctx = claimed_story()

      for {kind, refs, constraint} <- [
            {"escalation", [Ecto.UUID.generate()], "thread_entries_kb_refs_kinds"},
            {"message", for(_ <- 0..Entry.max_kb_refs(), do: Ecto.UUID.generate()),
             "thread_entries_kb_refs_bound"}
          ] do
        # The refusal aborts the transaction, so its error is read from inside it rather than
        # from what `with_tenant/2` returns.
        Repo.with_tenant(ctx.tenant_id, fn ->
          send(
            self(),
            {:insert,
             Repo.query(
               "INSERT INTO thread_entries (id, tenant_id, story_id, seq, kind, author_principal, " <>
                 "idempotency_key, body, kb_refs, inserted_at) VALUES (gen_random_uuid(), $1, $2, " <>
                 "99, $3, 'agent:x', 'raw', 'b', $4::uuid[], now())",
               [
                 Ecto.UUID.dump!(ctx.tenant_id),
                 Ecto.UUID.dump!(ctx.story.id),
                 kind,
                 Enum.map(refs, &Ecto.UUID.dump!/1)
               ]
             )}
          )
        end)

        assert_received {:insert, {:error, %Postgrex.Error{postgres: %{constraint: ^constraint}}}}
      end
    end
  end
end
