defmodule Loopctl.ReleaseSetTest do
  @moduledoc """
  US-52.7: `release/manifest.toml` names one compatible set, `mix loopctl.release_set`
  keeps it in step with each component's source version, and the server reports it.
  """
  use ExUnit.Case, async: true

  alias Loopctl.ReleaseSet
  alias Loopctl.ReleaseSet.Manifest
  alias Mix.Tasks.Loopctl.ReleaseSet, as: Task

  # The fixture sources carry the committed manifest's versions, so a bump of a real component
  # never breaks these tests: they judge the task, not today's numbers.
  defp sources do
    {:ok, manifest} = Manifest.parse(File.read!("release/manifest.toml"), "m")
    v = fn name -> manifest.components[name].version end

    %{
      "mix.exs" =>
        "defmodule A.MixProject do\n  def project, do: [\n      version: \"#{v.("server")}\",\n  ]\nend\n",
      "runner/mix.exs" => "  [\n      version: \"#{v.("runner")}\",\n  ]\n",
      "chg/cli/Cargo.toml" =>
        "[package]\nname = \"chg\"\nversion = \"#{v.("chg")}\"\n\n[dependencies]\nclap = { version = \"4.6\" }\n",
      "chg/adapters/elixir/mix.exs" => "      version: \"#{v.("chg_adapter_elixir")}\",\n",
      "mcp-server/package.json" => ~s({"name": "loopctl-mcp-server", "version": "#{v.("mcp")}"}\n)
    }
  end

  defp committed(name) do
    {:ok, manifest} = Manifest.parse(File.read!("release/manifest.toml"), "m")
    manifest.components[name].version
  end

  setup context do
    root =
      Path.join(Loopctl.RealTmpDir.path!(), "release-set-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(root) end)

    for {path, body} <- sources() do
      File.mkdir_p!(Path.dirname(Path.join(root, path)))
      File.write!(Path.join(root, path), body)
    end

    File.mkdir_p!(Path.join(root, "release"))
    File.cp!("release/manifest.toml", Path.join(root, "release/manifest.toml"))
    Map.put(context, :root, root)
  end

  describe "the committed manifest" do
    test "lists every component, the server's set, the runner's minimum unreported" do
      {:ok, manifest} = Manifest.parse(File.read!("release/manifest.toml"), "m")

      assert manifest.set == ReleaseSet.set()
      assert Map.keys(manifest.components) |> Enum.sort() == Enum.sort(Manifest.components())
      assert manifest.components["runner"].source == "runner/mix.exs"
      assert manifest.components["mcp"].source == "mcp-server/package.json"
      assert manifest.components["runner"].minimum == "unreported"
    end

    test "matches every source in this repository, and is exactly what --bump writes" do
      {:ok, manifest} = Manifest.parse(File.read!("release/manifest.toml"), "m")

      assert Manifest.drift(manifest, File.cwd!()) == {:ok, []}
      assert Manifest.render(manifest) == File.read!("release/manifest.toml")
    end

    test "ReleaseSet.component/1 is the manifest's version and minimum" do
      {:ok, manifest} = Manifest.parse(File.read!("release/manifest.toml"), "m")

      for name <- Manifest.components() do
        assert ReleaseSet.component(name) ==
                 Map.take(manifest.components[name], [:version, :minimum])
      end
    end
  end

  describe "parse/2" do
    test "names the file and the key at fault" do
      text = File.read!("release/manifest.toml")

      assert {:error, "m.toml: components.mcp is missing"} =
               Manifest.parse(
                 String.replace(text, "[components.mcp]", "[components.other]"),
                 "m.toml"
               )

      assert {:error,
              "m.toml: components.chg.version must be a semver version or \"unreported\"" <> _} =
               Manifest.parse(
                 String.replace(
                   text,
                   ~s([components.chg]\nversion = "#{committed("chg")}"),
                   ~s([components.chg]\nversion = "latest")
                 ),
                 "m.toml"
               )

      {:ok, manifest} = Manifest.parse(text, "m.toml")

      assert {:error, "m.toml: set must be a positive integer"} =
               Manifest.parse(
                 String.replace(text, "set = #{manifest.set}\n", "set = 0\n"),
                 "m.toml"
               )
    end

    # US-52.11: the retired repos survive a parse and a bump's re-render.
    test "carries the retired repos, and refuses a malformed list" do
      text = File.read!("release/manifest.toml")
      {:ok, manifest} = Manifest.parse(text, "m.toml")

      assert manifest.retired == ["mkreyman/chg", "mkreyman/loopctl-runner"]

      assert Manifest.render(Manifest.bump(manifest, [])) =~
               ~s(repos = ["mkreyman/chg", "mkreyman/loopctl-runner"])

      [head, _] = String.split(text, "[retired]")
      assert {:ok, %{retired: []}} = Manifest.parse(head, "m.toml")

      assert {:error, "m.toml: retired.repos must be a list of owner/name strings"} =
               Manifest.parse(head <> "[retired]\nrepos = [\"chg\"]\n", "m.toml")

      assert {:error, "m.toml: retired must be a table with a repos list"} =
               Manifest.parse(head <> "[retired]\nnames = []\n", "m.toml")
    end

    test "accepts semver with pre-release and build, and the literal unreported" do
      assert Manifest.valid_version?("1.2.3-rc.1+abc")
      assert Manifest.valid_version?("unreported")
      refute Manifest.valid_version?("1.2")
      refute Manifest.valid_version?("v1.2.3")
    end
  end

  describe "mix loopctl.release_set" do
    test "--check passes when every source matches", %{root: root} do
      assert Task.check(root) == :ok
    end

    test "--check names each differing component", %{root: root} do
      bump_source!(root, "runner/mix.exs", committed("runner"), "9.9.9")
      bump_source!(root, "mcp-server/package.json", committed("mcp"), "9.9.8")

      assert {:drift, [runner, mcp]} = Task.check(root)

      assert runner =~
               "runner: release/manifest.toml says #{committed("runner")}, its source says 9.9.9"

      assert mcp =~ "mcp: release/manifest.toml says #{committed("mcp")}, its source says 9.9.8"
    end

    test "--check names a source it cannot read", %{root: root} do
      File.rm!(Path.join(root, "chg/cli/Cargo.toml"))

      assert {:error, "chg/cli/Cargo.toml: no such file or directory"} = Task.check(root)
    end

    test "--bump moves the set and only the changed components", %{root: root} do
      bump_source!(root, "runner/mix.exs", committed("runner"), "9.9.9")
      {:ok, before} = Manifest.parse(File.read!("release/manifest.toml"), "m")
      set = before.set + 1

      assert {:bumped, ^set, ["runner"]} = Task.bump(root)

      {:ok, next} = Manifest.parse(File.read!(Path.join(root, "release/manifest.toml")), "m")

      assert next.set == set
      assert next.components["runner"].version == "9.9.9"
      assert next.components["runner"].minimum == before.components["runner"].version
      assert Map.delete(next.components, "runner") == Map.delete(before.components, "runner")
      assert Task.check(root) == :ok
    end

    test "--bump with nothing changed leaves the file byte-identical", %{root: root} do
      path = Path.join(root, "release/manifest.toml")
      File.write!(path, File.read!(path) <> "# a hand comment\n")
      before = File.read!(path)

      assert Task.bump(root) == :unchanged
      assert File.read!(path) == before
    end
  end

  describe "the deployment" do
    test "the Dockerfile copies the manifest into the build stage before mix compile" do
      lines = File.read!("Dockerfile") |> String.split("\n")
      copy = Enum.find_index(lines, &(&1 == "COPY release/manifest.toml release/manifest.toml"))
      compile = Enum.find_index(lines, &(&1 == "RUN mix compile"))

      assert copy && compile && copy < compile
    end

    test "mix precommit and the lint job run --check" do
      assert "loopctl.release_set --check" in Mix.Project.config()[:aliases][:precommit]

      lint = YamlElixir.read_from_file!(".github/workflows/ci.yml")["jobs"]["lint"]["steps"]
      assert Enum.any?(lint, &(&1["run"] == "mix loopctl.release_set --check"))
    end
  end

  defp bump_source!(root, path, from, to) do
    full = Path.join(root, path)
    File.write!(full, String.replace(File.read!(full), from, to))
  end
end
