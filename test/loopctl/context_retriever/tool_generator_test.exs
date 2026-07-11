defmodule Loopctl.ContextRetriever.ToolGeneratorTest do
  # ToolGenerator is a pure function of the entity — no DB, no side effects
  # (technical_notes, us_30.2.json:39,42) — so this is a pure ExUnit.Case unit
  # test, not Loopctl.DataCase (which checks out a SQL-sandbox connection this
  # module never uses).
  use ExUnit.Case, async: true

  alias Loopctl.ContextRetriever.Entity
  alias Loopctl.ContextRetriever.ToolGenerator

  # A representative sample of loopctl's static MCP tool names, to prove the
  # `cr_` prefix cannot collide with the existing tool surface (AC-30.2.3).
  @static_mcp_tool_names ~w(
    list_projects list_stories verify_story claim_story start_story
    contract_story get_story knowledge_search knowledge_get knowledge_context
    knowledge_index knowledge_create
  )

  describe "specs_for/1 — TC-30.2.1 (mixed filterable/searchable/neither fields)" do
    setup do
      entity = %Entity{
        name: "story",
        backing_source: :stories,
        fields: [
          %{name: "status", type: "string", filterable: true, searchable: false},
          %{name: "priority", type: "integer", filterable: true, searchable: false},
          %{name: "active", type: "boolean", filterable: true, searchable: false},
          %{name: "due", type: "datetime", filterable: true, searchable: false},
          %{name: "description", type: "string", filterable: false, searchable: true},
          %{name: "secret", type: "string", filterable: false, searchable: false}
        ]
      }

      %{entity: entity, specs: ToolGenerator.specs_for(entity)}
    end

    test "emits a filter tool for each filterable field, typed correctly", %{specs: specs} do
      by_name = Map.new(specs, &{&1.name, &1})

      assert %{input_schema: %{"properties" => %{"status" => %{"type" => "string"}}}} =
               by_name["cr_filter_story_by_status"]

      assert %{input_schema: %{"properties" => %{"priority" => %{"type" => "integer"}}}} =
               by_name["cr_filter_story_by_priority"]

      assert %{input_schema: %{"properties" => %{"active" => %{"type" => "boolean"}}}} =
               by_name["cr_filter_story_by_active"]

      assert %{
               input_schema: %{
                 "properties" => %{"due" => %{"type" => "string", "format" => "date-time"}}
               }
             } = by_name["cr_filter_story_by_due"]
    end

    test "emits a single cr_search_story tool", %{specs: specs} do
      names = Enum.map(specs, & &1.name)
      assert "cr_search_story" in names
      assert Enum.count(names, &(&1 == "cr_search_story")) == 1
    end

    test "no tool references the non-filterable, non-searchable field", %{specs: specs} do
      refute Enum.any?(specs, fn spec ->
               spec.name =~ "secret" or spec.metadata[:field] == "secret"
             end)
    end

    test "every spec carries (entity, field, operation) dispatch metadata", %{specs: specs} do
      Enum.each(specs, fn spec ->
        assert spec.metadata.entity == "story"
        assert spec.metadata.backing_source == :stories
        assert spec.metadata.operation in [:filter, :search]
        assert Map.has_key?(spec.metadata, :field)
      end)

      filter_specs = Enum.filter(specs, &(&1.metadata.operation == :filter))
      assert Enum.all?(filter_specs, &is_binary(&1.metadata.field))
      assert Enum.all?(filter_specs, &is_binary(&1.metadata.field_type))

      search_spec = Enum.find(specs, &(&1.metadata.operation == :search))
      assert search_spec.metadata.field == nil
      assert search_spec.metadata.searchable_fields == ["description"]
    end

    test "filter tool input schemas require the field and expose pagination", %{specs: specs} do
      status_spec = Enum.find(specs, &(&1.name == "cr_filter_story_by_status"))

      assert status_spec.input_schema["required"] == ["status"]
      assert status_spec.input_schema["properties"]["limit"] == %{"type" => "integer"}
      # Pagination is offset-based to match the US-30.3 executor (AC-30.3.5).
      assert status_spec.input_schema["properties"]["offset"] == %{"type" => "integer"}
      refute Map.has_key?(status_spec.input_schema["properties"], "cursor")
    end

    test "search tool input schema requires query and exposes pagination", %{specs: specs} do
      search_spec = Enum.find(specs, &(&1.name == "cr_search_story"))

      assert search_spec.input_schema["required"] == ["query"]
      assert search_spec.input_schema["properties"]["query"] == %{"type" => "string"}
      assert search_spec.input_schema["properties"]["limit"] == %{"type" => "integer"}
      # Pagination is offset-based to match the US-30.3 executor (AC-30.3.5).
      assert search_spec.input_schema["properties"]["offset"] == %{"type" => "integer"}
      refute Map.has_key?(search_spec.input_schema["properties"], "cursor")
    end
  end

  describe "specs_for/1 — TC-30.2.3 (no searchable field)" do
    test "emits only filter tools, no search tool" do
      entity = %Entity{
        name: "project_view",
        backing_source: :projects,
        fields: [
          %{name: "name", type: "string", filterable: true, searchable: false},
          %{name: "status", type: "string", filterable: true, searchable: false}
        ]
      }

      specs = ToolGenerator.specs_for(entity)
      names = Enum.map(specs, & &1.name)

      assert "cr_filter_project_view_by_name" in names
      assert "cr_filter_project_view_by_status" in names
      refute Enum.any?(names, &(&1 =~ "search"))
      refute "cr_search_project_view" in names
    end
  end

  describe "specs_for/1 — AC-30.2.4 (allowlist is exact)" do
    test "a filterable == false field produces no filter tool" do
      entity = %Entity{
        name: "epic",
        backing_source: :epics,
        fields: [
          %{name: "title", type: "string", filterable: false, searchable: true}
        ]
      }

      specs = ToolGenerator.specs_for(entity)
      names = Enum.map(specs, & &1.name)

      refute "cr_filter_epic_by_title" in names
      assert "cr_search_epic" in names
    end

    test "an entity with no fields at all produces no specs" do
      entity = %Entity{name: "empty", backing_source: :epics, fields: []}

      assert ToolGenerator.specs_for(entity) == []
    end
  end

  describe "specs_for/1 — TC-30.2.2 (determinism + collision-safe prefix)" do
    test "calling twice on the same entity returns identical specs" do
      entity = %Entity{
        name: "story",
        backing_source: :stories,
        fields: [
          %{name: "status", type: "string", filterable: true, searchable: false},
          %{name: "title", type: "string", filterable: false, searchable: true}
        ]
      }

      assert ToolGenerator.specs_for(entity) == ToolGenerator.specs_for(entity)
    end

    test "every generated tool name starts with the cr_ prefix" do
      entity = %Entity{
        name: "story",
        backing_source: :stories,
        fields: [
          %{name: "status", type: "string", filterable: true, searchable: false},
          %{name: "title", type: "string", filterable: false, searchable: true}
        ]
      }

      specs = ToolGenerator.specs_for(entity)
      assert specs != []
      assert Enum.all?(specs, &String.starts_with?(&1.name, "cr_"))
    end

    test "generated tool names never collide with a sample of loopctl static tool names" do
      entity = %Entity{
        name: "story",
        backing_source: :stories,
        fields: [
          %{name: "status", type: "string", filterable: true, searchable: false},
          %{name: "title", type: "string", filterable: false, searchable: true}
        ]
      }

      generated_names = entity |> ToolGenerator.specs_for() |> Enum.map(& &1.name)

      assert MapSet.disjoint?(
               MapSet.new(generated_names),
               MapSet.new(@static_mcp_tool_names)
             )
    end
  end

  describe "specs_for/1 — key-shape robustness" do
    test "string-keyed and atom-keyed field maps produce identical specs" do
      string_keyed = %Entity{
        name: "story",
        backing_source: :stories,
        fields: [
          %{
            "name" => "status",
            "type" => "string",
            "filterable" => true,
            "searchable" => false
          },
          %{
            "name" => "title",
            "type" => "string",
            "filterable" => false,
            "searchable" => true
          }
        ]
      }

      atom_keyed = %Entity{
        name: "story",
        backing_source: :stories,
        fields: [
          %{name: "status", type: "string", filterable: true, searchable: false},
          %{name: "title", type: "string", filterable: false, searchable: true}
        ]
      }

      assert ToolGenerator.specs_for(string_keyed) == ToolGenerator.specs_for(atom_keyed)
    end
  end

  describe "specs_for/1 — AC-30.2.1 (search tool requires a searchable TEXT field)" do
    test "a searchable non-text field alone does not trigger the search tool" do
      entity = %Entity{
        name: "story",
        backing_source: :stories,
        fields: [
          %{name: "estimated_hours", type: "integer", filterable: false, searchable: true}
        ]
      }

      specs = ToolGenerator.specs_for(entity)

      assert specs == []
      refute Enum.any?(specs, &(&1.name == "cr_search_story"))
    end

    test "a searchable non-text field does not expand the search tool's field set" do
      entity = %Entity{
        name: "story",
        backing_source: :stories,
        fields: [
          %{name: "estimated_hours", type: "integer", filterable: false, searchable: true},
          %{name: "description", type: "string", filterable: false, searchable: true}
        ]
      }

      specs = ToolGenerator.specs_for(entity)
      search_spec = Enum.find(specs, &(&1.name == "cr_search_story"))

      assert search_spec
      assert search_spec.metadata.searchable_fields == ["description"]
    end
  end

  describe "specs_for/1 — AC-30.3.4 (search tool suppressed when a searchable field is not vector-indexed)" do
    test "a searchable text field not covered by the source search_vector suppresses the search tool" do
      # agent_status is an allowlisted stories column (so it may be declared) that
      # the generated search_vector (title + description) does NOT cover. Declaring
      # it searchable must NOT produce a search tool the executor would answer over
      # title/description instead.
      entity = %Entity{
        name: "story",
        backing_source: :stories,
        fields: [
          %{name: "agent_status", type: "string", filterable: false, searchable: true}
        ]
      }

      assert ToolGenerator.specs_for(entity) == []
    end

    test "a mix of vector-covered and non-covered searchable fields still suppresses the tool" do
      # title IS covered but agent_status is not; because the fixed vector cannot
      # index agent_status, the whole search tool is suppressed rather than emit
      # one that silently omits the declared-but-unindexed column.
      entity = %Entity{
        name: "story",
        backing_source: :stories,
        fields: [
          %{name: "title", type: "string", filterable: false, searchable: true},
          %{name: "agent_status", type: "string", filterable: false, searchable: true}
        ]
      }

      specs = ToolGenerator.specs_for(entity)

      refute Enum.any?(specs, &(&1.name == "cr_search_story"))
    end
  end

  describe "specs_for/1 — json schema type mapping (float + fallback)" do
    test "types a float field as JSON Schema number" do
      entity = %Entity{
        name: "epic",
        backing_source: :epics,
        fields: [
          %{name: "position", type: "float", filterable: true, searchable: false}
        ]
      }

      specs = ToolGenerator.specs_for(entity)
      spec = Enum.find(specs, &(&1.name == "cr_filter_epic_by_position"))

      assert spec.input_schema["properties"]["position"] == %{"type" => "number"}
      assert spec.metadata.field_type == "float"
    end

    test "falls back to string for an unrecognized field type" do
      entity = %Entity{
        name: "epic",
        backing_source: :epics,
        fields: [
          %{name: "phase", type: "unrecognized_type", filterable: true, searchable: false}
        ]
      }

      specs = ToolGenerator.specs_for(entity)
      spec = Enum.find(specs, &(&1.name == "cr_filter_epic_by_phase"))

      assert spec.input_schema["properties"]["phase"] == %{"type" => "string"}
    end
  end

  describe "specs_for/1 — Entity.field_types/0 coverage (schema-drift guard)" do
    # Regression: json_schema_type/1's silent `%{"type" => "string"}` fallback
    # made it possible for a future Entity.@field_types addition to be mapped
    # to a wrong JSON Schema type with no compile warning and no test failure.
    # ToolGenerator now raises a CompileError if any Entity.field_types/0
    # member lacks an explicit @json_schema_types / @field_type_classification
    # entry (enforced at compile time — this module already compiled clean, so
    # that guard passed). This test is a second, runtime-visible line of
    # defense: it proves every declared type maps to its OWN distinct,
    # non-fallback JSON Schema type shape, not merely "some non-string shape".
    test "every Entity.field_types/0 member produces a distinct, non-fallback JSON Schema type" do
      schema_types_by_field_type =
        Map.new(Entity.field_types(), fn type ->
          entity = %Entity{
            name: "probe",
            backing_source: :epics,
            fields: [%{name: "position", type: type, filterable: true, searchable: false}]
          }

          [spec] = ToolGenerator.specs_for(entity)
          {type, spec.input_schema["properties"]["position"]}
        end)

      # No two distinct Entity field types collapse onto the same JSON Schema
      # shape as the fallback (%{"type" => "string"}) would silently cause for
      # any type not explicitly handled.
      fallback = %{"type" => "string"}

      non_string_types = Entity.field_types() -- ["string"]

      Enum.each(non_string_types, fn type ->
        refute schema_types_by_field_type[type] == fallback,
               "Entity field type #{inspect(type)} silently fell back to #{inspect(fallback)} " <>
                 "in ToolGenerator.json_schema_type/1 — add an explicit mapping"
      end)

      assert schema_types_by_field_type["string"] == fallback
    end
  end
end
