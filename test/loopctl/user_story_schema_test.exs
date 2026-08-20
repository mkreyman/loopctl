defmodule Loopctl.UserStorySchemaTest do
  @moduledoc """
  Binds `docs/user_stories/story.schema.json` to the two things it is supposed to
  govern: the committed story corpus, and the import path's acceptance-criteria rule.

  Why a hand-rolled checker instead of an ex_json_schema dependency: the schema is a
  DECLARATION — the artifact `user-story-writer` emits against and a reviewer reads in
  one sitting — and the only place it must be executable is here. Adding a JSON-Schema
  runtime to the application to validate one shape on one endpoint would put a parser
  in the request path and buy less than this test does.

  The two declarations are deliberately NOT identical, and the third describe block is
  where that difference is pinned down. The authored-file schema is stricter (a
  non-empty criteria list, an `id` on every criterion) because a generated story should
  carry both. The import path is looser (criteria may be absent, `criterion` substitutes
  for `description`, `id` is optional) because importing a skeleton for pre-loopctl work
  is a supported path and #509 made `criterion` a first-class key. What the two MUST
  agree on is that a criterion present in a payload carries text.
  """
  use Loopctl.DataCase, async: true

  alias Loopctl.ImportExport

  @schema_path Path.join([__DIR__, "..", "..", "docs", "user_stories", "story.schema.json"])
  @stories_glob Path.join([__DIR__, "..", "..", "docs", "user_stories", "*", "us_*.json"])

  defp schema, do: @schema_path |> File.read!() |> Jason.decode!()

  defp story_files, do: Path.wildcard(@stories_glob)

  defp blank?(nil), do: true
  defp blank?(v) when is_binary(v), do: String.trim(v) == ""
  defp blank?(_), do: false

  describe "the schema itself" do
    test "parses, and declares the rules the rest of this file depends on" do
      s = schema()

      assert s["type"] == "object"
      assert is_list(s["required"])

      ac = s["properties"]["acceptance_criteria"]
      assert ac["type"] == "array"
      assert ac["minItems"] == 1
      assert "id" in ac["items"]["required"]
      assert "description" in ac["items"]["required"]
      assert ac["items"]["properties"]["description"]["minLength"] == 1
    end

    test "story files exist to validate against" do
      # Guards the whole corpus block below from passing vacuously if the glob
      # ever stops matching (a rename, a move, a wrong relative path).
      assert length(story_files()) > 100
    end
  end

  describe "the committed corpus conforms" do
    test "every story carries every required top-level key" do
      required = schema()["required"]

      offenders =
        for path <- story_files(),
            story = path |> File.read!() |> Jason.decode!(),
            key <- required,
            is_nil(story[key]),
            do: "#{Path.basename(path)}: missing #{key}"

      assert offenders == []
    end

    test "every story carries a non-empty acceptance_criteria list" do
      offenders =
        for path <- story_files(),
            story = path |> File.read!() |> Jason.decode!(),
            acs = story["acceptance_criteria"],
            not is_list(acs) or acs == [],
            do: Path.basename(path)

      assert offenders == []
    end

    test "every acceptance criterion carries a non-empty id and description" do
      required = schema()["properties"]["acceptance_criteria"]["items"]["required"]

      offenders =
        for path <- story_files(),
            story = path |> File.read!() |> Jason.decode!(),
            {ac, index} <- Enum.with_index(story["acceptance_criteria"] || []),
            key <- required,
            not is_map(ac) or blank?(ac[key]),
            do: "#{Path.basename(path)} acceptance_criteria[#{index}]: #{key}"

      assert offenders == []
    end

    test "every test case carries its required keys" do
      required = schema()["properties"]["test_cases"]["items"]["required"]

      offenders =
        for path <- story_files(),
            story = path |> File.read!() |> Jason.decode!(),
            {tc, index} <- Enum.with_index(story["test_cases"] || []),
            key <- required,
            not is_map(tc) or is_nil(tc[key]) or tc[key] == "" or tc[key] == [],
            do: "#{Path.basename(path)} test_cases[#{index}]: #{key}"

      assert offenders == []
    end

    test "nested story and epic objects carry their required keys" do
      s = schema()
      story_required = s["properties"]["story"]["required"]
      epic_required = s["properties"]["epic"]["required"]

      offenders =
        for path <- story_files(),
            doc = path |> File.read!() |> Jason.decode!(),
            {obj, required, label} <- [
              {doc["story"], story_required, "story"},
              {doc["epic"], epic_required, "epic"}
            ],
            key <- required,
            not is_map(obj) or blank?(obj[key]),
            do: "#{Path.basename(path)} #{label}: #{key}"

      assert offenders == []
    end
  end

  describe "schema and import validator cannot drift apart" do
    defp import_story(tenant, project, ac) do
      payload = %{
        "epics" => [
          %{
            "number" => 1,
            "title" => "Foundation",
            "stories" => [%{"number" => "1.1", "title" => "S", "acceptance_criteria" => ac}]
          }
        ]
      }

      ImportExport.import_project(tenant.id, project.id, payload,
        actor_id: uuid(),
        actor_label: "user:test"
      )
    end

    test "a criterion shaped exactly as the schema requires is accepted on import" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})

      # Build the criterion from the schema's OWN required list rather than a literal,
      # so adding a required key to the schema without teaching the import path fails
      # here instead of in a consumer's repo.
      criterion =
        schema()["properties"]["acceptance_criteria"]["items"]["required"]
        |> Map.new(fn key -> {key, "value for #{key}"} end)

      assert {:ok, _} = import_story(tenant, project, [criterion])
    end

    test "a criterion carrying no text is rejected by BOTH declarations" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})

      # The schema side: description is required and minLength 1.
      ac_item = schema()["properties"]["acceptance_criteria"]["items"]
      assert "description" in ac_item["required"]
      assert ac_item["properties"]["description"]["minLength"] == 1

      # The import side: same rule, reached through the public API.
      assert {:error, :validation, message} =
               import_story(tenant, project, [%{"id" => "AC-1", "description" => ""}])

      assert message =~ "acceptance_criteria[0]"
    end

    test "the looser import rule is intentional and stays looser" do
      tenant = fixture(:tenant)
      project = fixture(:project, %{tenant_id: tenant.id})
      other = fixture(:project, %{tenant_id: tenant.id})

      # These three are valid on the IMPORT path and invalid in an authored file.
      # If a future change makes the import path enforce the authored-file schema
      # wholesale, this test fails and names what that would break: #509's
      # `criterion` key, optional ids, and skeleton imports for backfilled work.
      assert {:ok, _} = import_story(tenant, project, [%{"criterion" => "no id here"}])
      assert {:ok, _} = import_story(tenant, other, nil)

      ac_item = schema()["properties"]["acceptance_criteria"]["items"]
      assert "id" in ac_item["required"], "authored files still require an id"
      assert schema()["properties"]["acceptance_criteria"]["minItems"] == 1
    end
  end
end
