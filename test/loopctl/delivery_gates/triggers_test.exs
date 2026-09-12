defmodule Loopctl.DeliveryGates.TriggersTest do
  use ExUnit.Case, async: true

  import Loopctl.Fixtures

  alias Loopctl.DeliveryGates.Glob
  alias Loopctl.DeliveryGates.RepoTriggers
  alias Loopctl.DeliveryGates.Triggers

  @repo "acme/claims-app"

  defp sha256(binary), do: :sha256 |> :crypto.hash(binary) |> Base.encode16(case: :lower)

  defp parse_doc(doc) do
    binary = Jason.encode!(doc)
    Triggers.parse(binary, sha256(binary))
  end

  defp put_repo_key(key, value) do
    config = build(:delivery_gates_config)
    put_in(config, ["repos", @repo, key], value)
  end

  describe "a valid document" do
    test "parses into compiled triggers for each repository" do
      binary = Jason.encode!(build(:delivery_gates_config))
      assert {:ok, %Triggers{} = triggers} = Triggers.parse(binary, sha256(binary))

      assert triggers.version == 1
      assert triggers.sha256 == sha256(binary)

      assert {:ok, %RepoTriggers{} = repo} = Triggers.fetch_repo(triggers, @repo)

      assert Enum.map(repo.effect_paths, & &1.source) ==
               ["priv/rates/**", "lib/app/payments/**", "config/runtime.exs"]

      assert Enum.map(repo.human_paths, & &1.source) ==
               ["lib/app_web/router.ex", "lib/**/data_migrations/**"]

      assert Enum.all?(repo.effect_paths ++ repo.human_paths, &match?(%Glob{}, &1))
      assert repo.max_files == 12
      assert repo.max_changed_lines == 1000
    end

    test "accepts the expected checksum in upper case" do
      binary = Jason.encode!(build(:delivery_gates_config))
      assert {:ok, %Triggers{}} = Triggers.parse(binary, String.upcase(sha256(binary)))
    end

    test "fetch_repo/2 is :error for a repository the document does not name" do
      {:ok, triggers} = parse_doc(build(:delivery_gates_config))
      assert Triggers.fetch_repo(triggers, "acme/other") == :error
      assert Triggers.fetch_repo(triggers, nil) == :error
    end
  end

  describe "fails closed on a missing or unverifiable document" do
    test "nil or empty binary" do
      assert Triggers.parse(nil, String.duplicate("a", 64)) == {:error, :missing_config}
      assert Triggers.parse("", sha256("")) == {:error, :missing_config}
    end

    test "a missing or malformed expected checksum" do
      binary = Jason.encode!(build(:delivery_gates_config))
      assert Triggers.parse(binary, nil) == {:error, :invalid_checksum_format}
      assert Triggers.parse(binary, "") == {:error, :invalid_checksum_format}
      assert Triggers.parse(binary, "abc") == {:error, :invalid_checksum_format}

      assert Triggers.parse(binary, String.duplicate("g", 64)) ==
               {:error, :invalid_checksum_format}
    end

    test "a checksum that does not match the bytes" do
      binary = Jason.encode!(build(:delivery_gates_config))
      other = Jason.encode!(build(:delivery_gates_config, %{"version" => 2}))
      assert Triggers.parse(binary, sha256(other)) == {:error, :checksum_mismatch}
    end

    test "a one-byte change to a pinned document is a mismatch, before it is decoded" do
      binary = Jason.encode!(build(:delivery_gates_config))
      pinned = sha256(binary)
      tampered = String.replace(binary, "priv/rates/**", "priv/ratez/**")
      assert tampered != binary
      assert Triggers.parse(tampered, pinned) == {:error, :checksum_mismatch}
    end

    test "invalid JSON, even with a matching checksum" do
      binary = "{\"version\": 1, \"repos\": "
      assert Triggers.parse(binary, sha256(binary)) == {:error, :invalid_json}
    end

    test "a document that is not a JSON object" do
      assert parse_doc([]) == {:error, {:not_an_object, []}}
      assert parse_doc("text") == {:error, {:not_an_object, []}}
    end
  end

  describe "fails closed on a malformed document" do
    test "unknown or unsupported version" do
      assert parse_doc(build(:delivery_gates_config, %{"version" => 2})) ==
               {:error, {:unsupported_version, 2}}

      assert parse_doc(build(:delivery_gates_config, %{"version" => "1"})) ==
               {:error, {:unsupported_version, "1"}}

      assert parse_doc(build(:delivery_gates_config, %{"version" => nil})) ==
               {:error, {:unsupported_version, nil}}
    end

    test "missing top-level keys" do
      assert parse_doc(Map.delete(build(:delivery_gates_config), "version")) ==
               {:error, {:missing_key, ["version"]}}

      assert parse_doc(Map.delete(build(:delivery_gates_config), "repos")) ==
               {:error, {:missing_key, ["repos"]}}
    end

    test "unknown top-level key" do
      assert parse_doc(build(:delivery_gates_config, %{"extra" => true})) ==
               {:error, {:unknown_key, ["extra"]}}
    end

    test "empty or non-object repos" do
      assert parse_doc(build(:delivery_gates_config, %{"repos" => %{}})) ==
               {:error, {:empty_repos, ["repos"]}}

      assert parse_doc(build(:delivery_gates_config, %{"repos" => []})) ==
               {:error, {:not_an_object, ["repos"]}}
    end

    test "a repository key that is not owner/repo" do
      entry = get_in(build(:delivery_gates_config), ["repos", @repo])

      assert parse_doc(build(:delivery_gates_config, %{"repos" => %{"claims-app" => entry}})) ==
               {:error, {:invalid_repo_name, "claims-app"}}
    end

    test "a missing key in a repository entry" do
      for key <- ~w(effect_paths human_paths limits) do
        config = build(:delivery_gates_config)
        {_, config} = pop_in(config, ["repos", @repo, key])
        assert parse_doc(config) == {:error, {:missing_key, ["repos", @repo, key]}}
      end
    end

    test "an unknown key in a repository entry, such as a misspelling" do
      assert parse_doc(put_repo_key("efect_paths", ["x/**"])) ==
               {:error, {:unknown_key, ["repos", @repo, "efect_paths"]}}
    end

    test "an empty pattern list" do
      assert parse_doc(put_repo_key("effect_paths", [])) ==
               {:error, {:empty_patterns, ["repos", @repo, "effect_paths"]}}

      assert parse_doc(put_repo_key("human_paths", [])) ==
               {:error, {:empty_patterns, ["repos", @repo, "human_paths"]}}
    end

    test "a pattern list that is not a list" do
      assert parse_doc(put_repo_key("effect_paths", "priv/rates/**")) ==
               {:error, {:invalid_patterns, ["repos", @repo, "effect_paths"]}}
    end

    test "an invalid pattern inside a list" do
      assert parse_doc(put_repo_key("human_paths", ["lib/app_web/router.ex", ""])) ==
               {:error, {:invalid_pattern, ["repos", @repo, "human_paths"], ""}}

      assert parse_doc(put_repo_key("effect_paths", [42])) ==
               {:error, {:invalid_pattern, ["repos", @repo, "effect_paths"], 42}}
    end

    test "limits that are missing, unknown, or not positive integers" do
      assert parse_doc(put_repo_key("limits", %{"max_files" => 12})) ==
               {:error, {:missing_key, ["repos", @repo, "limits", "max_changed_lines"]}}

      assert parse_doc(
               put_repo_key("limits", %{"max_files" => 12, "max_changed_lines" => 1, "x" => 1})
             ) == {:error, {:unknown_key, ["repos", @repo, "limits", "x"]}}

      assert parse_doc(put_repo_key("limits", 12)) ==
               {:error, {:not_an_object, ["repos", @repo, "limits"]}}

      for bad <- [0, -1, 1.5, "12", nil] do
        assert parse_doc(put_repo_key("limits", %{"max_files" => bad, "max_changed_lines" => 1})) ==
                 {:error, {:invalid_limit, ["repos", @repo, "limits", "max_files"]}}

        assert parse_doc(put_repo_key("limits", %{"max_files" => 1, "max_changed_lines" => bad})) ==
                 {:error, {:invalid_limit, ["repos", @repo, "limits", "max_changed_lines"]}}
      end
    end

    test "one bad repository fails the whole document" do
      config = build(:delivery_gates_config)
      good = get_in(config, ["repos", @repo])
      bad = Map.put(good, "effect_paths", [])
      config = put_in(config, ["repos"], %{@repo => good, "acme/zz-broken" => bad})

      assert parse_doc(config) ==
               {:error, {:empty_patterns, ["repos", "acme/zz-broken", "effect_paths"]}}
    end
  end
end
