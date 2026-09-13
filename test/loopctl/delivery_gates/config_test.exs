defmodule Loopctl.DeliveryGates.ConfigTest do
  use ExUnit.Case, async: true

  import Loopctl.Fixtures

  alias Loopctl.DeliveryGates
  alias Loopctl.DeliveryGates.Config
  alias Loopctl.DeliveryGates.GateB.Result
  alias Loopctl.DeliveryGates.Triggers

  defp sha256(binary), do: :sha256 |> :crypto.hash(binary) |> Base.encode16(case: :lower)

  defp valid_pair do
    document = Jason.encode!(build(:delivery_gates_config))
    [document: document, sha256: sha256(document)]
  end

  describe "triggers/0 reads the configured pair" do
    test "returns the configured document, verified against the configured checksum" do
      # config/test.exs pins a synthetic document for acme/widgets and its checksum.
      assert {:ok, %Triggers{} = triggers} = Config.triggers()
      assert triggers.sha256 == "2f3c86e749445d6820a406d7e3dc2127f452179b4c7f31e565a5c2d01bcc27a2"
      assert {:ok, repo} = Triggers.fetch_repo(triggers, "acme/widgets")
      assert Enum.map(repo.human_paths, & &1.source) == ["lib/widgets_web/router.ex"]
    end

    test "through the facade" do
      assert summary(DeliveryGates.load_triggers()) == summary(Config.triggers())
    end

    test "is exactly Triggers.parse/2 over the configured document and checksum" do
      config = Application.fetch_env!(:loopctl, Config)

      # Compiled regexes do not compare equal across compilations; compare their sources.
      assert summary(Config.triggers()) ==
               summary(
                 Triggers.parse(
                   Keyword.fetch!(config, :document),
                   Keyword.fetch!(config, :sha256)
                 )
               )
    end
  end

  defp summary({:ok, %Triggers{} = triggers}) do
    repos =
      Map.new(triggers.repos, fn {name, repo} ->
        {name,
         {Enum.map(repo.effect_paths, & &1.source), Enum.map(repo.human_paths, & &1.source),
          repo.max_files, repo.max_changed_lines}}
      end)

    {:ok, triggers.version, triggers.sha256, repos}
  end

  defp summary(other), do: other

  describe "from_config/1 never turns a missing pair into an empty trigger set" do
    test "unset" do
      assert Config.from_config([]) == {:error, :missing_config}
      assert Config.from_config(nil) == {:error, :missing_config}
      assert Config.from_config(document: nil, sha256: nil) == {:error, :missing_config}
    end

    test "an empty document, with or without a checksum" do
      assert Config.from_config(document: "", sha256: sha256("")) == {:error, :missing_config}
      assert Config.from_config(document: "", sha256: nil) == {:error, :missing_config}
    end

    test "a document without its checksum" do
      pair = Keyword.delete(valid_pair(), :sha256)
      assert Config.from_config(pair) == {:error, :invalid_checksum_format}

      assert Config.from_config(Keyword.put(pair, :sha256, "")) ==
               {:error, :invalid_checksum_format}
    end

    test "a checksum over different bytes" do
      pair = valid_pair()

      assert Config.from_config(Keyword.put(pair, :sha256, sha256("{}"))) ==
               {:error, :checksum_mismatch}

      # A trailing newline, the commonest shell accident, is different bytes.
      with_newline = Keyword.update!(pair, :document, &(&1 <> "\n"))
      assert Config.from_config(with_newline) == {:error, :checksum_mismatch}
    end

    if System.find_executable("sha256sum") do
      test "the deploy/FLY_SECRETS.md recipe produces a matching pair; hashing the file does not" do
        dir = Path.join(System.tmp_dir!(), "gates_recipe_#{System.unique_integer([:positive])}")
        File.mkdir_p!(dir)
        on_exit(fn -> File.rm_rf!(dir) end)

        # An editor-saved document: it ends in a newline.
        File.write!(
          Path.join(dir, "triggers.json"),
          Jason.encode!(build(:delivery_gates_config)) <> "\n"
        )

        # The recipe deploy/FLY_SECRETS.md documents (keep the two in step), with the value
        # `fly secrets set` would receive captured to a file instead, plus the wrong recipe
        # it warns against.
        script = """
        DOC="$(cat triggers.json)"
        printf '%s' "$DOC" > value.bin
        printf '%s' "$DOC" | sha256sum | cut -d' ' -f1
        sha256sum triggers.json | cut -d' ' -f1
        """

        {out, 0} = System.cmd("sh", ["-c", script], cd: dir)
        [recipe_sha, file_sha] = String.split(out, "\n", trim: true)
        value = File.read!(Path.join(dir, "value.bin"))

        assert {:ok, %Triggers{}} = Config.from_config(document: value, sha256: recipe_sha)

        assert Config.from_config(document: value, sha256: file_sha) ==
                 {:error, :checksum_mismatch}
      end
    end

    test "a non-keyword value" do
      assert Config.from_config(%{document: "x", sha256: "y"}) == {:error, :missing_config}
      assert Config.from_config(["x", "y"]) == {:error, :missing_config}
    end

    test "a valid pair parses" do
      assert {:ok, %Triggers{}} = Config.from_config(valid_pair())
    end
  end

  describe "every loader failure escalates through Gate B" do
    test "is :human, naming the configuration error, in both phases" do
      pair = valid_pair()

      failures = [
        [],
        [document: "", sha256: sha256("")],
        Keyword.delete(pair, :sha256),
        Keyword.put(pair, :sha256, sha256("{}"))
      ]

      for config <- failures, phase <- [:triage, :merge] do
        {:error, reason} = loaded = Config.from_config(config)

        assert %Result{outcome: :human, reasons: reasons} =
                 DeliveryGates.gate_b(phase, build(:gate_b_input), loaded)

        assert {:config_error, reason} in reasons
      end
    end

    test "while the same input over the valid pair is :clear" do
      assert %Result{outcome: :clear} =
               DeliveryGates.gate_b(
                 :merge,
                 build(:gate_b_input),
                 Config.from_config(valid_pair())
               )
    end
  end
end
