defmodule Loopctl.Memory.SessionMemoryTest do
  use Loopctl.DataCase, async: true

  alias Loopctl.Memory.SessionMemory

  defp valid_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        session_id: "session-1",
        content: "hello",
        role: :user,
        expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      },
      overrides
    )
  end

  describe "create_changeset/2" do
    test "is valid with a scope and required fields" do
      changeset =
        %SessionMemory{tenant_id: Ecto.UUID.generate(), subject_id: "subject-A"}
        |> SessionMemory.create_changeset(valid_attrs())

      assert changeset.valid?
    end

    test "requires session_id, content, and expires_at" do
      changeset =
        %SessionMemory{tenant_id: Ecto.UUID.generate(), subject_id: "subject-A"}
        |> SessionMemory.create_changeset(%{})

      refute changeset.valid?
      errors = errors_on(changeset)
      assert Map.has_key?(errors, :session_id)
      assert Map.has_key?(errors, :content)
      assert Map.has_key?(errors, :expires_at)
    end

    test "is invalid when subject_id is nil" do
      changeset =
        %SessionMemory{subject_id: nil}
        |> SessionMemory.create_changeset(valid_attrs())

      refute changeset.valid?
      assert Map.has_key?(errors_on(changeset), :subject_id)
      assert Map.has_key?(errors_on(changeset), :tenant_id)
    end

    test "rejects a blank subject_id" do
      changeset =
        %SessionMemory{tenant_id: Ecto.UUID.generate(), subject_id: ""}
        |> SessionMemory.create_changeset(valid_attrs())

      refute changeset.valid?
      assert "must not be blank" in errors_on(changeset).subject_id
    end

    test "caps content byte size" do
      oversized = String.duplicate("x", SessionMemory.max_content_bytes() + 1)

      changeset =
        %SessionMemory{tenant_id: Ecto.UUID.generate(), subject_id: "subject-A"}
        |> SessionMemory.create_changeset(valid_attrs(%{content: oversized}))

      refute changeset.valid?
      assert [msg] = errors_on(changeset).content
      assert msg =~ "exceeds maximum size"
    end

    test "does not cast tenant_id or subject_id from params" do
      changeset =
        %SessionMemory{tenant_id: Ecto.UUID.generate(), subject_id: "subject-A"}
        |> SessionMemory.create_changeset(
          valid_attrs(%{tenant_id: Ecto.UUID.generate(), subject_id: "attacker"})
        )

      assert get_change(changeset, :tenant_id) == nil
      assert get_change(changeset, :subject_id) == nil
    end

    test "accepts every declared role" do
      for role <- SessionMemory.roles() do
        changeset =
          %SessionMemory{tenant_id: Ecto.UUID.generate(), subject_id: "subject-A"}
          |> SessionMemory.create_changeset(valid_attrs(%{role: role}))

        assert changeset.valid?, "expected role #{inspect(role)} to be valid"
      end
    end
  end

  describe "integration: fixtures and tenant isolation" do
    test "fixture(:session_memory) inserts an append-only row" do
      sm = fixture(:session_memory)
      assert sm.id
      assert sm.tenant_id
      assert sm.subject_id
      assert sm.inserted_at
    end

    # Mirrors article_test's isolation test (AdminRepo + explicit tenant predicate,
    # async). Repo-wide RLS enforcement on `session_memories` is proven by
    # Loopctl.Repo.RlsCoverageTest.
    test "a session memory is scoped to its tenant" do
      tenant_a = fixture(:tenant)
      tenant_b = fixture(:tenant)

      sm_a = fixture(:session_memory, %{tenant_id: tenant_a.id, subject_id: "A"})
      _sm_b = fixture(:session_memory, %{tenant_id: tenant_b.id, subject_id: "B"})

      in_a =
        SessionMemory
        |> where([s], s.tenant_id == ^tenant_a.id)
        |> Loopctl.AdminRepo.all()

      assert length(in_a) == 1
      assert hd(in_a).id == sm_a.id
    end
  end
end
