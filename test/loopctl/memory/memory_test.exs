defmodule Loopctl.Memory.MemoryTest do
  use Loopctl.DataCase, async: true

  alias Loopctl.AdminRepo
  alias Loopctl.Auth.ApiKey
  alias Loopctl.Memory
  alias Loopctl.Memory.Memory, as: MemorySchema

  describe "create_changeset/2" do
    test "is valid with a scope and text" do
      changeset =
        %MemorySchema{tenant_id: Ecto.UUID.generate(), subject_id: "subject-A"}
        |> MemorySchema.create_changeset(%{text: "a durable fact"})

      assert changeset.valid?
    end

    # TC-28.1.2: subject_id resolved to nil -> invalid, errors include subject_id
    test "is invalid when subject_id is nil (and tenant_id absent)" do
      changeset =
        %MemorySchema{subject_id: nil}
        |> MemorySchema.create_changeset(%{text: "a fact with no owner"})

      refute changeset.valid?
      assert %{subject_id: _} = errors_on(changeset)
      assert %{tenant_id: _} = errors_on(changeset)
    end

    test "is invalid when subject_id is blank (leak-prone empty owner)" do
      changeset =
        %MemorySchema{tenant_id: Ecto.UUID.generate(), subject_id: "   "}
        |> MemorySchema.create_changeset(%{text: "a fact"})

      refute changeset.valid?
      assert "must not be blank" in errors_on(changeset).subject_id
    end

    # TC-28.1.3: text over the byte cap -> invalid with a length error on text
    test "is invalid when text exceeds the byte cap" do
      oversized = String.duplicate("x", MemorySchema.max_text_bytes() + 1)

      changeset =
        %MemorySchema{tenant_id: Ecto.UUID.generate(), subject_id: "subject-A"}
        |> MemorySchema.create_changeset(%{text: oversized})

      refute changeset.valid?
      assert [msg] = errors_on(changeset).text
      assert msg =~ "exceeds maximum size"
    end

    test "does not cast tenant_id or subject_id from params" do
      changeset =
        %MemorySchema{tenant_id: Ecto.UUID.generate(), subject_id: "subject-A"}
        |> MemorySchema.create_changeset(%{
          text: "a fact",
          tenant_id: Ecto.UUID.generate(),
          subject_id: "attacker-supplied"
        })

      assert get_change(changeset, :tenant_id) == nil
      assert get_change(changeset, :subject_id) == nil
    end

    test "does not cast superseded_by from params (cross-tenant self-FK is set programmatically)" do
      changeset =
        %MemorySchema{tenant_id: Ecto.UUID.generate(), subject_id: "subject-A"}
        |> MemorySchema.create_changeset(%{
          text: "a fact",
          superseded_by: Ecto.UUID.generate()
        })

      assert get_change(changeset, :superseded_by) == nil
    end

    test "does not cast project_id from params (cross-tenant FK is set programmatically)" do
      changeset =
        %MemorySchema{tenant_id: Ecto.UUID.generate(), subject_id: "subject-A"}
        |> MemorySchema.create_changeset(%{
          text: "a fact",
          project_id: Ecto.UUID.generate()
        })

      assert get_change(changeset, :project_id) == nil
    end

    test "normalizes an explicit tags: nil back to [] (would be a raw NOT NULL DB error otherwise)" do
      memory = fixture(:memory, %{tags: nil})
      assert memory.tags == []
    end

    test "rejects an explicit confidence: nil (would be a raw NOT NULL DB error otherwise)" do
      changeset =
        %MemorySchema{tenant_id: Ecto.UUID.generate(), subject_id: "subject-A"}
        |> MemorySchema.create_changeset(%{text: "a fact", confidence: nil})

      refute changeset.valid?
      assert Map.has_key?(errors_on(changeset), :confidence)
    end

    test "rejects confidence outside [0, 1]" do
      changeset =
        %MemorySchema{tenant_id: Ecto.UUID.generate(), subject_id: "subject-A"}
        |> MemorySchema.create_changeset(%{text: "a fact", confidence: 1.5})

      refute changeset.valid?
      assert Map.has_key?(errors_on(changeset), :confidence)
    end

    test "defaults confidence, source, and tags" do
      memory = fixture(:memory)
      assert memory.confidence == 1.0
      assert memory.source == :explicit
      assert memory.tags == []
      assert is_nil(memory.embedding)
    end

    test "accepts :promoted source (written by Part 2 compiler)" do
      changeset =
        %MemorySchema{tenant_id: Ecto.UUID.generate(), subject_id: "subject-A"}
        |> MemorySchema.create_changeset(%{text: "a fact", source: :promoted})

      assert changeset.valid?
      assert get_field(changeset, :source) == :promoted
    end

    # Review finding (US-28.4): the memory_remember MCP tool / HTTP API advertise
    # a generic `metadata` param, but the long_term tier used to have no column
    # for it at all — a caller's metadata was silently discarded. Prove it casts.
    test "casts metadata" do
      changeset =
        %MemorySchema{tenant_id: Ecto.UUID.generate(), subject_id: "subject-A"}
        |> MemorySchema.create_changeset(%{
          text: "a fact",
          metadata: %{"source" => "code_review", "pr" => 320}
        })

      assert changeset.valid?
      assert get_field(changeset, :metadata) == %{"source" => "code_review", "pr" => 320}
    end

    test "defaults metadata to an empty map when omitted" do
      memory = fixture(:memory)
      assert memory.metadata == %{}
    end

    test "normalizes an explicit metadata: nil back to %{} (would be a raw NOT NULL DB error otherwise)" do
      memory = fixture(:memory, %{metadata: nil})
      assert memory.metadata == %{}
    end
  end

  describe "embedding_changeset/3" do
    test "accepts a 1536-dimension embedding" do
      memory = fixture(:memory)
      embedding = List.duplicate(0.1, 1536)

      changeset = MemorySchema.embedding_changeset(memory, embedding, "hash")
      assert changeset.valid?
    end

    test "rejects a wrong-dimension embedding" do
      memory = fixture(:memory)
      embedding = List.duplicate(0.1, 768)

      changeset = MemorySchema.embedding_changeset(memory, embedding)
      refute changeset.valid?
      assert [msg] = errors_on(changeset).embedding
      assert msg =~ "dimension mismatch"
    end
  end

  describe "subject_id_for/1" do
    # AC-28.1.4: agent-role key -> agent_id; else api_key.id; total resolution.
    test "resolves an agent-role key to its agent_id" do
      assert {:ok, "agent-123"} =
               Memory.subject_id_for(%ApiKey{role: :agent, agent_id: "agent-123", id: "key-1"})
    end

    test "falls back to api_key.id for an agent key with no agent_id" do
      assert {:ok, "key-1"} =
               Memory.subject_id_for(%ApiKey{role: :agent, agent_id: nil, id: "key-1"})
    end

    test "resolves non-agent keys to api_key.id" do
      assert {:ok, "key-9"} =
               Memory.subject_id_for(%ApiKey{role: :user, agent_id: nil, id: "key-9"})

      assert {:ok, "key-9"} =
               Memory.subject_id_for(%ApiKey{
                 role: :orchestrator,
                 agent_id: "ignored",
                 id: "key-9"
               })
    end

    test "returns an explicit error rather than a nil scope" do
      assert {:error, :subject_id_unresolvable} =
               Memory.subject_id_for(%ApiKey{role: :agent, agent_id: nil, id: nil})
    end
  end

  describe "integration: superseded_by on_delete nilify_all" do
    # TC-28.1.4: deleting the superseding memory nilifies the back-reference.
    test "reloading a memory whose superseder was deleted yields nil superseded_by" do
      tenant = fixture(:tenant)
      a = fixture(:memory, %{tenant_id: tenant.id, subject_id: "A", text: "old"})
      b = fixture(:memory, %{tenant_id: tenant.id, subject_id: "A", text: "new"})

      a
      |> Ecto.Changeset.change(superseded_by: b.id)
      |> AdminRepo.update!()

      AdminRepo.delete!(b)

      reloaded = AdminRepo.get!(MemorySchema, a.id)
      assert reloaded.superseded_by == nil
    end
  end

  describe "integration: tenant isolation" do
    # TC-28.1.5: a memory inserted under tenant_a is scoped to tenant_a. Mirrors
    # article_test's isolation test — AdminRepo + explicit (tenant_id) predicate,
    # keeping the test async. Repo-wide RLS *enforcement* on `memories` is proven
    # by Loopctl.Repo.RlsCoverageTest (the table auto-enrolls via its tenant_id
    # column + enable_rls/1). tenant_id/subject_id are set programmatically by the
    # fixture, never from cast params.
    test "a memory is scoped to its tenant" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)

      memory_a = fixture(:memory, %{tenant_id: tenant_a.id, subject_id: "A", text: "secret-a"})
      _memory_b = fixture(:memory, %{tenant_id: tenant_b.id, subject_id: "B", text: "secret-b"})

      in_a =
        MemorySchema
        |> where([m], m.tenant_id == ^tenant_a.id)
        |> AdminRepo.all()

      in_b =
        MemorySchema
        |> where([m], m.tenant_id == ^tenant_b.id)
        |> AdminRepo.all()

      assert length(in_a) == 1
      assert hd(in_a).id == memory_a.id
      assert length(in_b) == 1
      refute hd(in_b).id == memory_a.id
    end
  end
end
