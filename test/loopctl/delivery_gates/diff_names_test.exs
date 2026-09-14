defmodule Loopctl.DeliveryGates.DiffNamesTest do
  use ExUnit.Case, async: true

  alias Loopctl.DeliveryGates
  alias Loopctl.DeliveryGates.DiffNames
  alias Loopctl.DeliveryGates.GateB.Result
  alias Loopctl.DeliveryGates.Triggers
  alias Mix.Tasks.Loopctl.Gates.CheckDrift

  @repo "acme/widgets"

  # Synthetic triggers: one effect path, one human path.
  @triggers_doc Jason.encode!(%{
                  "version" => 1,
                  "repos" => %{
                    @repo => %{
                      "effect_paths" => ["priv/rates/**"],
                      "human_paths" => ["guarded/human/**"],
                      "limits" => %{"max_files" => 12, "max_changed_lines" => 1000}
                    }
                  }
                })

  defp triggers do
    Triggers.parse(@triggers_doc, :sha256 |> :crypto.hash(@triggers_doc) |> Base.encode16())
  end

  # -- a real repository ------------------------------------------------------------------

  # Hermetic git: no global or system config, and none of the GIT_* variables a pre-commit
  # hook exports — under the hook, GIT_INDEX_FILE would otherwise point every command here
  # at the OUTER repository's index.
  #
  # The environment comes from `CheckDrift.git_env/0` rather than a second list here. This file
  # used to carry its own, and the two were NOT nested: this one had the config isolation the
  # other lacked, the other had GIT_NAMESPACE and GIT_CEILING_DIRECTORIES this one lacked, and
  # the newer of the two was the weaker. One answer, one place.
  @identity [
    "-c",
    "user.name=Gate Test",
    "-c",
    "user.email=gate-test@example.com",
    "-c",
    "commit.gpgsign=false",
    "-c",
    "init.defaultBranch=main"
  ]

  defp git(dir, args) do
    {out, 0} =
      System.cmd("git", @identity ++ CheckDrift.git_config_args() ++ args,
        cd: dir,
        env: CheckDrift.git_env()
      )

    out
  end

  defp write(dir, path, content) do
    full = Path.join(dir, path)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, content)
  end

  defp commit(dir, message) do
    git(dir, ["add", "--all"])
    git(dir, ["commit", "-q", "-m", message])
    dir |> git(["rev-parse", "HEAD"]) |> String.trim()
  end

  # Distinct multi-line content per file, so rename detection pairs the right files.
  defp body(name), do: Enum.map_join(1..20, "\n", &"#{name} line #{&1}") <> "\n"

  setup do
    dir = Path.join(System.tmp_dir!(), "diff_names_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    git(dir, ["init", "-q"])

    for path <- [
          "README.md",
          "lib/mod.ex",
          "priv/rates/2026.csv",
          "guarded/human/keep.ex",
          "guarded/human/moved.ex",
          "guarded/human/gone.ex"
        ] do
      write(dir, path, body(path))
    end

    base = commit(dir, "base")
    %{dir: dir, base: base}
  end

  defp diff_names(dir, base, head, extra \\ []) do
    git(dir, ["diff", "--name-status", "-M"] ++ extra ++ ["-z", "#{base}...#{head}"])
  end

  defp merge_input(dir, head, parsed) do
    files = dir |> git(["ls-files", "-z", "--with-tree", head]) |> String.split(<<0>>, trim: true)

    DiffNames.merge_input(parsed, %{
      repo: @repo,
      repo_files: files,
      diffstat: %{files: 1, changed_lines: 10}
    })
  end

  describe "parse/1 over real git output" do
    test "every status the merge gate needs, including hostile path names", ctx do
      %{dir: dir, base: base} = ctx

      git(dir, ["mv", "guarded/human/moved.ex", "lib/moved.ex"])
      git(dir, ["rm", "-q", "guarded/human/gone.ex"])
      write(dir, "lib/mod.ex", body("lib/mod.ex") <> "changed\n")
      write(dir, "lib/tarifa_año.ex", body("tarifa"))
      write(dir, "docs/a b/c.md", body("docs"))
      head = commit(dir, "head")

      output = diff_names(dir, base, head)
      # -z prints the non-ASCII name raw, never git's quoted "\303\261" form.
      assert String.contains?(output, "lib/tarifa_año.ex")

      assert {:ok, %{files: files, renames: renames}} = DiffNames.parse(output)

      assert Enum.sort(files) ==
               Enum.sort([
                 "docs/a b/c.md",
                 "guarded/human/gone.ex",
                 "lib/mod.ex",
                 "lib/moved.ex",
                 "lib/tarifa_año.ex"
               ])

      assert renames == [{"guarded/human/moved.ex", "lib/moved.ex"}]
      refute "guarded/human/moved.ex" in files
    end

    test "fed to Gate B, a file moved out of a guarded path and a deleted one are :human",
         ctx do
      %{dir: dir, base: base} = ctx

      git(dir, ["mv", "guarded/human/moved.ex", "lib/moved.ex"])
      git(dir, ["rm", "-q", "guarded/human/gone.ex"])
      write(dir, "docs/a b/c.md", body("docs"))
      head = commit(dir, "head")

      input = merge_input(dir, head, DiffNames.parse(diff_names(dir, base, head)))

      assert %Result{outcome: :human, reasons: reasons} =
               DeliveryGates.gate_b(:merge, input, triggers())

      assert {:human_path, "guarded/human/moved.ex", "guarded/human/**"} in reasons
      assert {:human_path, "guarded/human/gone.ex", "guarded/human/**"} in reasons
      assert length(reasons) == 2
    end

    test "fed to Gate B, the same kind of change outside guarded paths is :clear", ctx do
      %{dir: dir, base: base} = ctx

      git(dir, ["mv", "lib/mod.ex", "lib/renamed.ex"])
      write(dir, "lib/tarifa_año.ex", body("tarifa"))
      write(dir, "docs/a b/c.md", body("docs"))
      head = commit(dir, "head")

      input = merge_input(dir, head, DiffNames.parse(diff_names(dir, base, head)))

      assert %Result{outcome: :clear, reasons: []} =
               DeliveryGates.gate_b(:merge, input, triggers())
    end

    test "a copy adds only its new path; the unchanged source is not touched", ctx do
      %{dir: dir, base: base} = ctx

      write(dir, "lib/copied.ex", body("guarded/human/keep.ex"))
      head = commit(dir, "head")

      output = diff_names(dir, base, head, ["-C", "--find-copies-harder"])
      assert String.starts_with?(output, "C100")

      assert {:ok, %{files: ["lib/copied.ex"], renames: []}} = DiffNames.parse(output)
    end

    test "an empty diff parses to nothing, which Gate B escalates", ctx do
      %{dir: dir, base: base} = ctx

      assert {:ok, %{files: [], renames: []}} =
               parsed = DiffNames.parse(diff_names(dir, base, base))

      assert %Result{outcome: :human, reasons: [:no_files]} =
               DeliveryGates.gate_b(:merge, merge_input(dir, base, parsed), triggers())
    end
  end

  describe "parse/1 refuses what it cannot read with certainty" do
    test "unmerged and unknown records, naming the path" do
      assert DiffNames.parse("M\0a.ex\0U\0b.ex\0") == {:error, {:unmerged, "b.ex"}}
      assert DiffNames.parse("X\0c.ex\0") == {:error, {:unknown_status, "c.ex"}}
      assert DiffNames.parse("U\0") == {:error, {:truncated, "U"}}
    end

    test "any status it does not recognise" do
      for status <- ["B", "M070", "Z", "m", "AM", "R", "C", " A", "A "] do
        assert {:error, {kind, _}} = DiffNames.parse(status <> "\0a.ex\0b.ex\0")
        assert kind in [:unrecognised_status, :invalid_score]
      end

      assert DiffNames.parse("B\0a.ex\0") == {:error, {:unrecognised_status, "B"}}
    end

    test "a rename or copy score that is not three digits up to 100" do
      for status <- ["R", "R1", "R99", "R101", "R1000", "Rabc", "C", "C101"] do
        assert DiffNames.parse(status <> "\0a.ex\0b.ex\0") ==
                 {:error, {:invalid_score, status}}
      end

      assert {:ok, _} = DiffNames.parse("R000\0a.ex\0b.ex\0")
      assert {:ok, _} = DiffNames.parse("C100\0a.ex\0b.ex\0")
    end

    test "a record missing a path" do
      assert DiffNames.parse("R100\0a.ex\0") == {:error, {:truncated, "R100"}}
      assert DiffNames.parse("M\0") == {:error, {:truncated, "M"}}
    end

    test "output cut off mid-field" do
      assert DiffNames.parse("M\0lib/a.ex") == {:error, :unterminated}
      assert DiffNames.parse("M\0lib/a.ex\0R100\0old.ex\0new") == {:error, :unterminated}
    end

    test "an empty path field" do
      assert DiffNames.parse("M\0\0") == {:error, {:empty_path, "M"}}
      assert DiffNames.parse("R100\0a.ex\0\0") == {:error, {:empty_path, "R100"}}
    end

    test "a path that is not UTF-8, on either side of a rename" do
      assert DiffNames.parse("A\0lib/caf\xE9.ex\0") == {:error, {:invalid_utf8, "A"}}
      assert DiffNames.parse("R100\0caf\xE9.ex\0b.ex\0") == {:error, {:invalid_utf8, "R100"}}
    end

    test "a status field that is not text is not echoed raw" do
      assert {:error, {:unrecognised_status, echoed}} = DiffNames.parse(<<0xFF>> <> "\0a\0")
      assert String.valid?(echoed)
    end

    test "a non-binary" do
      assert DiffNames.parse(nil) == {:error, :not_a_binary}
      assert DiffNames.parse(["M", "a.ex"]) == {:error, :not_a_binary}
    end
  end

  describe "parse/1 over well-formed records" do
    test "keeps diff order, removes duplicates, and pairs every rename with its new name" do
      output = "M\0b.ex\0A\0a.ex\0D\0c.ex\0T\0d\0R075\0old.ex\0new.ex\0M\0b.ex\0"

      assert DiffNames.parse(output) ==
               {:ok,
                %{files: ["b.ex", "a.ex", "c.ex", "d", "new.ex"], renames: [{"old.ex", "new.ex"}]}}
    end
  end

  describe "merge_input/2" do
    @base_input %{
      repo: @repo,
      files: ["caller/stale.ex"],
      renames: [{"caller/old.ex", "caller/stale.ex"}],
      repo_files: ["guarded/human/keep.ex", "priv/rates/2026.csv", "lib/a.ex"],
      diffstat: %{files: 1, changed_lines: 10}
    }

    test "a parse replaces any files and renames the caller set" do
      parsed = {:ok, %{files: ["lib/a.ex"], renames: []}}
      assert %{files: ["lib/a.ex"], renames: []} = DiffNames.merge_input(parsed, @base_input)

      assert %Result{outcome: :clear} =
               DeliveryGates.gate_b(
                 :merge,
                 DiffNames.merge_input(parsed, @base_input),
                 triggers()
               )
    end

    test "a parse error escalates to :human, naming the reason, and drops caller lists" do
      for output <- ["U\0lib/a.ex\0", "M\0lib/a.ex", "R1\0a\0b\0", "A\0caf\xE9\0", nil] do
        {:error, reason} = parsed = DiffNames.parse(output)
        input = DiffNames.merge_input(parsed, @base_input)

        assert input.files == {:error, {:unreadable_diff, reason}}
        refute Map.has_key?(input, :renames)

        for phase <- [:merge, :triage] do
          assert %Result{outcome: :human, reasons: reasons} =
                   DeliveryGates.gate_b(phase, input, triggers())

          assert {:unreadable_diff, reason} in reasons
        end
      end
    end

    test "a value that is not a parse at all escalates too" do
      for bogus <- [nil, :ok, {:ok, %{files: nil, renames: []}}, {:ok, ["lib/a.ex"]}] do
        input = DiffNames.merge_input(bogus, @base_input)
        assert {:error, {:unreadable_diff, {:not_a_parse, ^bogus}}} = input.files

        assert %Result{outcome: :human} = DeliveryGates.gate_b(:merge, input, triggers())
      end
    end

    test "through the facade" do
      assert %{files: ["a.ex"]} =
               DeliveryGates.merge_input(DeliveryGates.parse_diff_names("A\0a.ex\0"), %{})
    end
  end
end
