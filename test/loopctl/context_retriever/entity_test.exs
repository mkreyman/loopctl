defmodule Loopctl.ContextRetriever.EntityTest do
  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.ContextRetriever.Entity

  # tenant_id is set programmatically on the struct, never cast — mirror the real
  # create path so unique_constraint and the changeset shape match production.
  defp changeset(attrs) do
    %Entity{tenant_id: Ecto.UUID.generate()}
    |> Entity.create_changeset(attrs)
  end

  describe "create_changeset/2 — valid" do
    test "accepts an allowlisted field for the backing source" do
      cs =
        changeset(%{
          name: "story",
          backing_source: :stories,
          fields: [%{name: "title", type: :string, filterable: true, searchable: true}]
        })

      assert cs.valid?
    end

    test "accepts multiple allowlisted fields across sources" do
      cs =
        changeset(%{
          name: "project_view",
          backing_source: :projects,
          fields: [
            %{name: "name", type: :string, filterable: true, searchable: true},
            %{name: "status", type: :string, filterable: true, searchable: false}
          ]
        })

      assert cs.valid?
    end

    test "accepts string-keyed field maps (DB round-trip shape)" do
      cs =
        changeset(%{
          "name" => "story",
          "backing_source" => "stories",
          "fields" => [
            %{"name" => "title", "type" => "string", "filterable" => true, "searchable" => false}
          ]
        })

      assert cs.valid?
    end
  end

  describe "create_changeset/2 — security: column allowlist + identifier + enum" do
    test "rejects a field whose name is not in the source column allowlist" do
      # `tenant_id` is deliberately NOT in the stories allowlist — declaring it
      # would let the executor exfiltrate the isolation column.
      cs =
        changeset(%{
          name: "story",
          backing_source: :stories,
          fields: [%{name: "tenant_id", type: :string, filterable: true, searchable: false}]
        })

      refute cs.valid?
      assert Enum.any?(errors_on(cs).fields, &(&1 =~ "not an allowed column"))
    end

    test "rejects an unsanctioned column (metadata jsonb blob)" do
      cs =
        changeset(%{
          name: "story",
          backing_source: :stories,
          fields: [%{name: "metadata", type: :string, filterable: false, searchable: false}]
        })

      refute cs.valid?
      assert Enum.any?(errors_on(cs).fields, &(&1 =~ "not an allowed column"))
    end

    test "rejects a custody/dispatch column" do
      cs =
        changeset(%{
          name: "story",
          backing_source: :stories,
          fields: [
            %{
              name: "implementer_dispatch_id",
              type: :string,
              filterable: false,
              searchable: false
            }
          ]
        })

      refute cs.valid?
      assert Enum.any?(errors_on(cs).fields, &(&1 =~ "not an allowed column"))
    end

    test "rejects a field name that is not a safe identifier (SQL injection shape)" do
      cs =
        changeset(%{
          name: "story",
          backing_source: :stories,
          fields: [%{name: "status; DROP", type: :string, filterable: true, searchable: false}]
        })

      refute cs.valid?
      assert Enum.any?(errors_on(cs).fields, &(&1 =~ "not a safe identifier"))
    end

    test "rejects an unknown backing_source (Ecto.Enum)" do
      cs =
        changeset(%{
          name: "story",
          backing_source: :tenant_supplied,
          fields: [%{name: "status", type: :string, filterable: true, searchable: false}]
        })

      refute cs.valid?
      assert Map.has_key?(errors_on(cs), :backing_source)
    end

    test "rejects an unknown field type" do
      cs =
        changeset(%{
          name: "story",
          backing_source: :stories,
          fields: [%{name: "title", type: :jsonb, filterable: true, searchable: false}]
        })

      refute cs.valid?
      assert Enum.any?(errors_on(cs).fields, &(&1 =~ "is not one of"))
    end

    test "rejects non-boolean filterable/searchable" do
      cs =
        changeset(%{
          name: "story",
          backing_source: :stories,
          fields: [%{name: "title", type: :string, filterable: "yes", searchable: nil}]
        })

      refute cs.valid?
      assert Enum.any?(errors_on(cs).fields, &(&1 =~ "filterable must be a boolean"))
      assert Enum.any?(errors_on(cs).fields, &(&1 =~ "searchable must be a boolean"))
    end

    test "rejects a field element that is not a map" do
      cs =
        changeset(%{
          name: "story",
          backing_source: :stories,
          fields: ["status"]
        })

      refute cs.valid?
      assert Map.has_key?(errors_on(cs), :fields)
    end

    test "rejects an entity that declares zero fields (empty list)" do
      cs =
        changeset(%{
          name: "story",
          backing_source: :stories,
          fields: []
        })

      refute cs.valid?
      assert Map.has_key?(errors_on(cs), :fields)
    end

    test "rejects an entity with fields omitted" do
      cs =
        changeset(%{
          name: "story",
          backing_source: :stories
        })

      refute cs.valid?
      assert Map.has_key?(errors_on(cs), :fields)
    end

    test "rejects duplicate field names" do
      cs =
        changeset(%{
          name: "story",
          backing_source: :stories,
          fields: [
            %{name: "title", type: :string, filterable: true, searchable: true},
            %{name: "title", type: :string, filterable: false, searchable: false}
          ]
        })

      refute cs.valid?
      assert Map.has_key?(errors_on(cs), :fields)
    end

    test "rejects duplicate field names across string/atom key shapes" do
      cs =
        changeset(%{
          name: "story",
          backing_source: :stories,
          fields: [
            %{name: "title", type: :string, filterable: true, searchable: true},
            %{"name" => "title", "type" => "string", "filterable" => false, "searchable" => false}
          ]
        })

      refute cs.valid?
      assert Map.has_key?(errors_on(cs), :fields)
    end

    test "rejects a non-identifier entity name" do
      cs =
        changeset(%{
          name: "Bad Name!",
          backing_source: :stories,
          fields: [%{name: "title", type: :string, filterable: true, searchable: false}]
        })

      refute cs.valid?
      assert Map.has_key?(errors_on(cs), :name)
    end

    test "requires name and backing_source" do
      cs = changeset(%{})

      refute cs.valid?
      errors = errors_on(cs)
      assert Map.has_key?(errors, :name)
      assert Map.has_key?(errors, :backing_source)
    end
  end

  describe "introspection helpers" do
    test "column_allowlist/0 excludes isolation and custody columns" do
      allow = Entity.column_allowlist()

      refute :tenant_id in allow.stories
      refute :metadata in allow.stories
      refute :implementer_dispatch_id in allow.stories
      assert :agent_status in allow.stories
      # `projects` exposes its own `status`, `stories` deliberately does not
      # (only `agent_status`/`verified_status`).
      assert :status in allow.projects
      refute :status in allow.stories
    end

    test "backing_sources/0 is loopctl-internal only" do
      assert Entity.backing_sources() == [:projects, :stories, :epics]
    end
  end
end
