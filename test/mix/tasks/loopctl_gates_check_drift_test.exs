defmodule Mix.Tasks.Loopctl.Gates.CheckDriftTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Loopctl.DeliveryGates.Triggers
  alias Mix.Tasks.Loopctl.Gates.CheckDrift

  # Pure over the report shape and the checksum resolution. The task's I/O — reading a checkout,
  # exiting non-zero on drift — is exercised by running it; what is asserted here is the
  # redaction and the operator's checksum pin, which are the two things a public repository
  # cannot get wrong twice.

  @coverage [
    %{kind: :effect, index: 0, pattern: "priv/rates/**", matches: 5},
    %{kind: :effect, index: 1, pattern: "lib/app/gone/**", matches: 0},
    %{kind: :human, index: 0, pattern: "lib/app_web/router.ex", matches: 1}
  ]

  # The meta the TASK actually builds, key for key. A trimmed stub is why the first redaction
  # test could not see the leak it was written to catch: there was no `checkout` in it to drop.
  @meta %{
    repo: "acme/app",
    checkout: "/home/someone/workspace/acme-app",
    ref: "HEAD",
    head: "03ad989c711a433812727fdb4bee8d512857fe5d",
    tree_files: 3982,
    trigger_fingerprint: "0123456789ab",
    trigger_checksum_source: "operator_pin",
    generated_at: "2026-09-14T03:18:58.260680Z",
    harness: "mix loopctl.gates.check_drift"
  }

  describe "report/3 redaction" do
    test "a committed artifact carries no pattern text and no match count" do
      report = CheckDrift.report(@coverage, @meta, :redacted)

      assert report.patterns == [
               %{kind: :effect, index: 0, matched: true},
               %{kind: :effect, index: 1, matched: false},
               %{kind: :human, index: 0, matched: true}
             ]
    end

    test "a committed artifact carries no local checkout path and no target tree size" do
      report = CheckDrift.report(@coverage, @meta, :redacted)

      refute Map.has_key?(report.meta, :checkout)
      refute Map.has_key?(report.meta, :tree_files)
      refute Map.has_key?(report.meta, :ref)
    end

    test "a meta key NOBODY allow-listed does not reach a redacted artifact" do
      # The point of the allow-list, and the thing the deny-list it replaced could not do: a key
      # added by somebody who never thought about redaction is full-detail only by default.
      meta = Map.put(@meta, :some_future_key, "/home/someone/secrets/path")

      redacted = CheckDrift.report(@coverage, meta, :redacted)

      refute Map.has_key?(redacted.meta, :some_future_key)
      assert CheckDrift.report(@coverage, meta, :full).meta.some_future_key =~ "secrets"
    end

    test "the run is still identifiable without describing the target" do
      # Named LITERALLY, never derived from published_meta_keys/0. A test that builds its
      # expectation from the thing under test moves with any change to it and can never go red
      # when a key is dropped — the self-referential trap #830's own second round hit.
      meta = CheckDrift.report(@coverage, @meta, :redacted).meta

      assert meta.repo == "acme/app"
      assert meta.head == "03ad989c711a433812727fdb4bee8d512857fe5d"
      assert meta.trigger_fingerprint == "0123456789ab"
      assert meta.trigger_checksum_source == "operator_pin"
      assert meta.generated_at == "2026-09-14T03:18:58.260680Z"
      assert meta.harness == "mix loopctl.gates.check_drift"
    end

    test "nothing anywhere in the encoded artifact names a path, a pattern or a machine" do
      encoded = @coverage |> CheckDrift.report(@meta, :redacted) |> Jason.encode!()

      for needle <- ["/home/", "/Users/", ".ex", "**", "3982"] do
        refute String.contains?(encoded, needle),
               "the redacted artifact contains #{inspect(needle)}"
      end
    end

    test "the unredacted artifact carries all of it, for writing outside this repository" do
      report = CheckDrift.report(@coverage, @meta, :full)

      assert report.patterns == @coverage
      assert report.meta == @meta
    end
  end

  describe "one redaction rule, not two" do
    # Two implementations of one redaction rule is the underlying defect behind the leak, and
    # this task still has its own list only because the measurement harness is not on this
    # branch yet (PR #830 is unmerged, so a call to it would not compile). This test is the
    # forcing function: the moment that module IS available, the suite goes red until the
    # duplicate list is deleted and the routing done. A reminder in a comment would not.
    @report_module Module.concat([:Loopctl, :DeliveryGates, :Measurement, :Report])

    test "the local allow-list is deleted as soon as #830's is callable" do
      refute Code.ensure_loaded?(@report_module), """
      #{inspect(@report_module)} is now on this branch, so this task must stop defining its own
      allow-list.

      Do this, in the same commit as the merge that brought it in:

        1. delete @published_meta_keys and published_meta_keys/0 from
           Mix.Tasks.Loopctl.Gates.CheckDrift
        2. defp meta(meta, _redacted), do: Map.take(meta, Report.published_meta_keys())
        3. add :trigger_checksum_source to Report's @meta_published, with the reason: it is a
           property of the RUN rather than of the machine or the target, and it is the only
           field that says whether the fingerprint was verified against the checksum production
           pinned or merely recomputed from a local file
        4. replace this test with one asserting both call sites redact ONE input to the same
           key set, with the keys named literally

      Verified equivalent against #830 at 3d260ca: for this task's meta,
      Map.take(meta, Report.published_meta_keys()) yields the same keys as
      Report.gate_b([], meta, detail: :redacted).meta, plus :trigger_checksum_source once
      step 3 is done.
      """
    end

    test "this task publishes nothing #830's allow-list would not, bar the one added key" do
      # #830's list, transcribed literally at 3d260ca rather than read from the module — the
      # module is not here, and transcribing is what makes this go red if the lists diverge.
      eight_thirty = [
        :corpus,
        :corpus_fingerprint,
        :generated_at,
        :gate,
        :harness,
        :head,
        :limit,
        :repo,
        :since,
        :tickets,
        :trigger_fingerprint,
        :trigger_shape,
        :trigger_status,
        :unparseable_records,
        :until
      ]

      assert CheckDrift.published_meta_keys() -- eight_thirty == [:trigger_checksum_source],
             "this task publishes a key #830's allow-list does not, beyond the one agreed"
    end
  end

  describe "report/3 totals" do
    test "counts the patterns, each kind, and the drifted ones" do
      report = CheckDrift.report(@coverage, @meta, :redacted)

      assert report.totals == %{
               patterns: 3,
               effect_patterns: 2,
               human_patterns: 1,
               unmatched: 1
             }
    end
  end

  describe "checksum/2 — the operator's pin" do
    @document ~s({"version":1})
    @document_hash :sha256 |> :crypto.hash(~s({"version":1})) |> Base.encode16(case: :lower)

    test "with no pin, the document's own bytes are hashed" do
      assert CheckDrift.checksum(@document, nil) == @document_hash
    end

    test "a pin is returned VERBATIM, so a mismatch reaches Triggers.parse and is refused" do
      pinned = String.duplicate("a", 64)

      assert CheckDrift.checksum(@document, pinned) == pinned

      # The failure this exists to prevent: replacing a mismatched pin with the hash of
      # whatever is on disk verifies the document against itself and can never fail.
      refute CheckDrift.checksum(@document, pinned) == @document_hash

      assert Triggers.parse(
               @document,
               CheckDrift.checksum(@document, pinned)
             ) == {:error, :checksum_mismatch}
    end

    test "a matching pin verifies, which is what makes the trailing-newline trap catchable" do
      assert CheckDrift.checksum(@document, @document_hash) == @document_hash

      # The same JSON WITH a trailing newline is a different document under the same pin.
      assert Triggers.parse(
               @document <> "\n",
               CheckDrift.checksum(@document <> "\n", @document_hash)
             ) == {:error, :checksum_mismatch}
    end

    test "a pin is case-insensitive, as Triggers.parse/2 accepts it" do
      assert CheckDrift.checksum(@document, String.upcase(@document_hash)) == @document_hash
    end
  end

  # -- run/1, against a real git fixture -----------------------------------------------------
  #
  # Everything above is pure over report/3 and checksum/2. NONE of it executed run/1, so the
  # WIRING was untested: which detail level reaches which file, whether a drift actually exits
  # non-zero, whether the refusals refuse. A reviewer proved all of that by mutation — flipping
  # :redacted to :full on the public artifact, and replacing Mix.raise with Mix.shell().info,
  # each left the whole suite green.
  #
  # These tests build a throwaway git repository per test (unique directory, removed on exit),
  # so the file stays async.

  describe "run/1 — which detail level reaches which file" do
    test "the --out artifact is redacted and the --full-out artifact is not" do
      repo = fixture_repo([{"lib/app/claims.ex", "x"}, {"config/runtime.exs", "y"}])
      triggers = trigger_file(repo, ["lib/app/**"], ["config/runtime.exs"])
      out = tmp_path("out.json")
      full = tmp_path("full.json")

      capture_io(fn ->
        CheckDrift.run(argv(repo, triggers, out: out, full_out: full))
      end)

      redacted = read_json(out)
      unredacted = read_json(full)

      # The public one: no pattern text, no counts, meta is exactly the six.
      assert Enum.all?(redacted["patterns"], &(not Map.has_key?(&1, "pattern")))
      assert Enum.all?(redacted["patterns"], &(not Map.has_key?(&1, "matches")))
      assert Enum.all?(redacted["patterns"], &is_boolean(&1["matched"]))

      assert Enum.sort(Map.keys(redacted["meta"])) == [
               "generated_at",
               "harness",
               "head",
               "repo",
               "trigger_checksum_source",
               "trigger_fingerprint"
             ]

      refute String.contains?(File.read!(out), repo)

      # The gitignored one: everything, or it is not worth writing.
      assert Enum.any?(unredacted["patterns"], &(&1["pattern"] == "lib/app/**"))
      assert Enum.any?(unredacted["patterns"], &is_integer(&1["matches"]))
      assert unredacted["meta"]["checkout"] == repo
      assert is_integer(unredacted["meta"]["tree_files"])
    end

    test "the COMMITTED tree is read, never the working tree" do
      # Adjacent to the resolve-then-read wiring and testable where the race is not: a file
      # present on disk and absent from HEAD must not satisfy a pattern.
      repo = fixture_repo([{"lib/app/claims.ex", "x"}, {"config/runtime.exs", "y"}])
      File.mkdir_p!(Path.join(repo, "priv/rates"))
      File.write!(Path.join(repo, "priv/rates/staged.csv"), "a,b")
      # STAGED, not committed: in the index, absent from HEAD. An untracked file would not
      # distinguish `ls-tree HEAD` from `ls-files`, which is the substitution worth catching.
      git!(repo, ["add", "priv/rates/staged.csv"])

      triggers = trigger_file(repo, ["lib/app/**", "priv/rates/**"], ["config/runtime.exs"])

      error =
        assert_raise Mix.Error, fn ->
          capture_io(fn ->
            CheckDrift.run(argv(repo, triggers, out: tmp_path("out.json")))
          end)
        end

      assert error.message =~ "effect pattern #1"
    end

    test "a --ref that is not HEAD is resolved, and the artifact records what was read" do
      repo = fixture_repo([{"lib/app/claims.ex", "x"}, {"config/runtime.exs", "y"}])
      first = repo |> git!(["rev-parse", "HEAD"]) |> String.trim()

      File.write!(Path.join(repo, "lib/app/claims.ex"), "changed")
      git!(repo, ["add", "lib/app/claims.ex"])
      git!(repo, ["commit", "--quiet", "-m", "second"])

      triggers = trigger_file(repo, ["lib/app/**"], ["config/runtime.exs"])
      out = tmp_path("out.json")

      capture_io(fn ->
        CheckDrift.run(argv(repo, triggers, out: out) ++ ["--ref", first])
      end)

      assert read_json(out)["meta"]["head"] == first
      refute read_json(out)["meta"]["head"] == String.trim(git!(repo, ["rev-parse", "HEAD"]))
    end

    test "the head on the artifact is the head the file list was read at" do
      repo = fixture_repo([{"lib/app/claims.ex", "x"}, {"config/runtime.exs", "y"}])
      triggers = trigger_file(repo, ["lib/app/**"], ["config/runtime.exs"])
      out = tmp_path("out.json")

      capture_io(fn -> CheckDrift.run(argv(repo, triggers, out: out)) end)

      # Through git!/2, never a bare System.cmd: an unscrubbed call here read the REAL
      # repository's HEAD under the hook's GIT_DIR and failed this assertion against it.
      head = repo |> git!(["rev-parse", "HEAD"]) |> String.trim()

      assert read_json(out)["meta"]["head"] == head
    end
  end

  describe "run/1 — the refusals actually refuse" do
    test "a drifted pattern exits non-zero, naming its kind and index and never its text" do
      repo = fixture_repo([{"lib/app/claims.ex", "x"}, {"config/runtime.exs", "y"}])
      triggers = trigger_file(repo, ["lib/app/**", "priv/gone/**"], ["config/runtime.exs"])

      error =
        assert_raise Mix.Error, fn ->
          capture_io(fn ->
            CheckDrift.run(argv(repo, triggers, out: tmp_path("out.json")))
          end)
        end

      assert error.message =~ "1 configured pattern(s) match NOTHING"
      assert error.message =~ "effect pattern #1"
      refute error.message =~ "priv/gone"
    end

    test "a tree with no files exits non-zero rather than passing vacuously" do
      repo = empty_fixture_repo()
      triggers = trigger_file(repo, ["lib/app/**"], ["config/runtime.exs"])

      error =
        assert_raise Mix.Error, fn ->
          capture_io(fn ->
            CheckDrift.run(argv(repo, triggers, out: tmp_path("out.json")))
          end)
        end

      assert error.message =~ "lists no files"
      assert error.message =~ "refusing a vacuous pass"
    end

    test "a checksum pin that does not match the bytes exits non-zero, naming the trap" do
      repo = fixture_repo([{"lib/app/claims.ex", "x"}, {"config/runtime.exs", "y"}])
      triggers = trigger_file(repo, ["lib/app/**"], ["config/runtime.exs"])

      # The document, plus the trailing newline an editor adds. Same JSON, different bytes.
      File.write!(triggers, File.read!(triggers) <> "\n")

      error =
        assert_raise Mix.Error, fn ->
          capture_io(fn ->
            CheckDrift.run(
              argv(repo, triggers, out: tmp_path("out.json"), sha256: sha256_of(triggers, "\n"))
            )
          end)
        end

      assert error.message =~ "does not hash to the checksum given as --sha256"
      assert error.message =~ "trailing newline"
    end

    test "a malformed checksum pin exits non-zero before anything is read" do
      repo = fixture_repo([{"lib/app/claims.ex", "x"}, {"config/runtime.exs", "y"}])
      triggers = trigger_file(repo, ["lib/app/**"], ["config/runtime.exs"])

      error =
        assert_raise Mix.Error, fn ->
          capture_io(fn ->
            CheckDrift.run(argv(repo, triggers, out: tmp_path("out.json"), sha256: "nope"))
          end)
        end

      assert error.message =~ "--sha256 must be 64 hex characters"
    end

    test "a document that does not name the repo exits non-zero" do
      repo = fixture_repo([{"lib/app/claims.ex", "x"}, {"config/runtime.exs", "y"}])
      triggers = trigger_file(repo, ["lib/app/**"], ["config/runtime.exs"], "other/repo")

      error =
        assert_raise Mix.Error, fn ->
          capture_io(fn ->
            CheckDrift.run(argv(repo, triggers, out: tmp_path("out.json")))
          end)
        end

      assert error.message =~ "does not name acme/app"
    end

    test "a document that does not parse exits non-zero WITHOUT printing the bad pattern" do
      repo = fixture_repo([{"lib/app/claims.ex", "x"}, {"config/runtime.exs", "y"}])
      triggers = tmp_path("bad.json")

      # An empty pattern is invalid, and the reason carries it plus the repository name.
      File.write!(
        triggers,
        Jason.encode!(%{
          "version" => 1,
          "repos" => %{
            "acme/app" => %{
              "effect_paths" => [""],
              "human_paths" => ["config/runtime.exs"],
              "limits" => %{"max_files" => 12, "max_changed_lines" => 1000}
            }
          }
        })
      )

      error =
        assert_raise Mix.Error, fn ->
          capture_io(fn ->
            CheckDrift.run(argv(repo, triggers, out: tmp_path("out.json")))
          end)
        end

      assert error.message =~ "did not parse: invalid_pattern"
      assert error.message =~ "key path depth 3"
      refute error.message =~ "acme/app"
      refute error.message =~ "effect_paths"
    end

    test "a clean tree says so and writes both artifacts" do
      repo = fixture_repo([{"lib/app/claims.ex", "x"}, {"config/runtime.exs", "y"}])
      triggers = trigger_file(repo, ["lib/app/**"], ["config/runtime.exs"])
      out = tmp_path("out.json")
      full = tmp_path("full.json")

      output =
        capture_io(fn ->
          CheckDrift.run(argv(repo, triggers, out: out, full_out: full))
        end)

      assert output =~ "no drift: 2 configured patterns, every one matching"
      assert File.exists?(out)
      assert File.exists?(full)
    end
  end

  describe "--repo means --repo, whatever the environment says" do
    test "git_env/0 clears every override that redirects repository discovery" do
      cleared = Map.new(CheckDrift.git_env())

      # Named literally. Each of these makes git ignore where it was pointed, and git EXPORTS
      # them to hooks.
      for name <- ~w(GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY
                     GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE GIT_PREFIX
                     GIT_CEILING_DIRECTORIES) do
        assert Map.fetch(cleared, name) == {:ok, nil},
               "#{name} is not cleared before spawning git"
      end
    end

    @tag :tmp_dir
    test "an inherited GIT_DIR does not redirect the read to another repository" do
      # This is not hypothetical. git hooks EXPORT GIT_DIR, `mix precommit` runs the suite from
      # inside one, and before the scrub this file's own fixture helper staged a one-byte
      # config/runtime.exs into loopctl's real index and committed it to the branch — because
      # `-C` changes directory while GIT_DIR overrides discovery. The failure mode for the TASK
      # is quieter and worse: it reads a tree it was not pointed at and certifies no drift.
      #
      # Run in a SUBPROCESS with the poisoned environment rather than System.put_env, which
      # would leak GIT_DIR to every other test in this async run.
      repo = fixture_repo([{"lib/app/claims.ex", "x"}, {"config/runtime.exs", "y"}])
      other = fixture_repo([{"README.md", "unrelated"}])
      triggers = trigger_file(repo, ["lib/app/**"], ["config/runtime.exs"])
      out = tmp_path("out.json")

      {output, status} =
        System.cmd(
          "mix",
          ["loopctl.gates.check_drift"] ++ argv(repo, triggers, out: out),
          env: [{"GIT_DIR", Path.join(other, ".git")}, {"MIX_ENV", "test"}],
          stderr_to_stdout: true,
          cd: File.cwd!()
        )

      assert status == 0, output

      assert read_json(out)["meta"]["head"] ==
               repo |> git!(["rev-parse", "HEAD"]) |> String.trim()

      refute read_json(out)["meta"]["head"] ==
               other |> git!(["rev-parse", "HEAD"]) |> String.trim()
    end
  end

  # -- fixtures ------------------------------------------------------------------------------

  defp argv(repo, triggers, opts) do
    base = [
      "--repo",
      repo,
      "--repo-name",
      "acme/app",
      "--triggers",
      triggers,
      "--out",
      Keyword.fetch!(opts, :out),
      "--full-out",
      Keyword.get(opts, :full_out, tmp_path("full.json"))
    ]

    case Keyword.get(opts, :sha256) do
      nil -> base
      pin -> base ++ ["--sha256", pin]
    end
  end

  defp trigger_file(repo, effect, human, repo_name \\ "acme/app") do
    path = Path.join(repo, "triggers.json")

    File.write!(
      path,
      Jason.encode!(%{
        "version" => 1,
        "repos" => %{
          repo_name => %{
            "effect_paths" => effect,
            "human_paths" => human,
            "limits" => %{"max_files" => 12, "max_changed_lines" => 1000}
          }
        }
      })
    )

    path
  end

  defp sha256_of(path, suffix) do
    # The checksum of the document WITHOUT the suffix — what the operator pinned before an
    # editor appended a newline.
    contents = path |> File.read!() |> String.replace_suffix(suffix, "")
    :sha256 |> :crypto.hash(contents) |> Base.encode16(case: :lower)
  end

  defp tmp_path(name) do
    path = Path.join(tmp_dir(), name)
    File.mkdir_p!(Path.dirname(path))
    path
  end

  defp tmp_dir do
    dir =
      Path.join(
        System.tmp_dir!(),
        "check_drift_#{System.unique_integer([:positive, :monotonic])}_#{:erlang.phash2(self())}"
      )

    # Measure 3, checked rather than assumed.
    outside_project!(dir)
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp fixture_repo(files), do: fixture_repo_at(tmp_dir(), files)

  defp fixture_repo_at(dir, files) do
    init_repo_at(dir)

    for {path, contents} <- files do
      full = Path.join(dir, path)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, contents)
    end

    # Explicit paths, never `git add .` — the same discipline the repository applies to its own
    # commits, and it keeps triggers.json out of the tree the check reads.
    git!(dir, ["add" | Enum.map(files, &elem(&1, 0))])
    git!(dir, ["commit", "--quiet", "-m", "fixture"])
    dir
  end

  defp empty_fixture_repo do
    dir = init_repo_at(tmp_dir())
    git!(dir, ["commit", "--quiet", "--allow-empty", "-m", "no files"])
    dir
  end

  defp init_repo_at(dir) do
    # Measure 3 again, because fixture_repo_at/2 can be handed a directory tmp_dir/0 did not
    # make — which is exactly how the guard gets tested.
    outside_project!(dir)
    File.mkdir_p!(dir)

    # `init` is the one call that cannot be preceded by the toplevel check: there is no
    # repository to ask yet. It runs with measures 1, 2 and 3, and the check fires immediately
    # afterwards — before a single file is written or staged.
    git_raw!(dir, ["init", "--quiet"])
    inside_fixture!(dir)

    # --local, always. An unscoped `git config` wrote core.bare and a fixture identity into the
    # REAL repository's config, which every linked worktree shares.
    git!(dir, ["config", "--local", "user.email", "fixture@example.invalid"])
    git!(dir, ["config", "--local", "user.name", "fixture"])
    git!(dir, ["config", "--local", "commit.gpgsign", "false"])
    dir
  end

  describe "the fixture cannot reach the real repository" do
    # These test the GUARDS THEMSELVES, not the destructive path behind them, and that is
    # deliberate. A first attempt asserted that `fixture_repo_at(File.cwd!(), [])` refuses —
    # and when the guard was mutated off to check the assertion could fail, the test did the
    # thing the guard exists to prevent: it ran `git init` and `git config` with --git-dir
    # resolved to the REAL repository. Mutating a safety guard must not arm the hazard.

    test "outside_project!/1 refuses the repository root itself" do
      error = assert_raise RuntimeError, fn -> outside_project!(File.cwd!()) end

      assert error.message =~ "inside this repository"
    end

    test "outside_project!/1 refuses any path beneath the repository" do
      for path <- ["tmp/x", "lib/app", "deep/nested/fixture", ".git/hooks"] do
        error =
          assert_raise RuntimeError, fn -> outside_project!(Path.join(File.cwd!(), path)) end

        assert error.message =~ "refusing to build a git fixture"
      end
    end

    test "outside_project!/1 permits a path outside it, or every fixture would be refused" do
      assert outside_project!(tmp_dir()) == :ok
      assert outside_project!("/tmp") == :ok
    end

    test "outside_project!/1 is not fooled by a sibling with the root as a prefix" do
      # `<root>-scratch` starts with the root string but is NOT inside it.
      assert outside_project!(File.cwd!() <> "-scratch") == :ok
    end

    test "inside_fixture!/1 refuses when git does not name the fixture as the toplevel" do
      # A directory that exists and is not a repository. Under a redirected environment git
      # answers for somewhere else; the guard demands it answer for here.
      dir = tmp_dir()

      error = assert_raise RuntimeError, fn -> inside_fixture!(dir) end

      assert error.message =~ "refusing to run git for a fixture"
      assert error.message =~ "toplevel"
    end

    test "inside_fixture!/1 refuses a directory INSIDE a repository that is not its root" do
      # status 0 with a FOREIGN toplevel — the half a status-only check cannot see, and the
      # shape a leaked GIT_DIR produces.
      repo = fixture_repo([{"a.txt", "x"}])
      nested = Path.join(repo, "nested")
      File.mkdir_p!(nested)

      error = assert_raise RuntimeError, fn -> inside_fixture!(nested) end

      assert error.message =~ "git reports the toplevel as"
    end

    test "inside_fixture!/1 permits a real fixture, or every fixture would be refused" do
      assert inside_fixture!(fixture_repo([{"a.txt", "x"}])) == :ok
    end

    test "the guard is WIRED into the fixture builder, not merely defined" do
      # Targets a gitignored path under tmp/, so if the guard is ever mutated off this test
      # creates a throwaway repo there and nothing else — never the real one. Cleanup is
      # registered before the call, so it runs even then.
      inside =
        Path.join(File.cwd!(), "tmp/fixture_guard_wiring_#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm_rf(inside) end)

      error =
        assert_raise RuntimeError, fn ->
          fixture_repo_at(inside, [{"config/runtime.exs", "y"}])
        end

      assert error.message =~ "inside this repository"
      refute File.exists?(inside)
    end

    test "the fixture's config writes are --local, so they cannot reach a shared config" do
      repo = fixture_repo([{"lib/app/claims.ex", "x"}])

      assert repo |> git!(["config", "--local", "--get", "user.name"]) |> String.trim() ==
               "fixture"

      # And the real repository's identity is untouched by that write.
      {real_ident, 0} = System.cmd("git", ["var", "GIT_AUTHOR_IDENT"], cd: File.cwd!())

      refute real_ident =~ "fixture@example.invalid"
    end
  end

  # -- fixture isolation ----------------------------------------------------------------------
  #
  # Four measures, and KB d1f32cc7 is explicit that no ONE of them isolates a fixture. This
  # suite learned it the expensive way: it committed to loopctl's own branch and pushed, because
  # `git -C` does NOT beat `GIT_DIR`, and the quality gate runs the suite from inside a
  # pre-commit hook, which exports GIT_DIR, GIT_WORK_TREE and GIT_INDEX_FILE into every test
  # process.
  #
  #   1. the discovery environment is cleared       — CheckDrift.git_env/0
  #   2. --git-dir and --work-tree are explicit     — git_raw!/2
  #   3. the fixture lives outside the project      — outside_project!/1
  #   4. git must AGREE the toplevel is the fixture — inside_fixture!/1
  #
  # Both guards run BEFORE the thing they protect, never around it: the damage began at
  # File.write!, before any git ran, so a guard wrapped only around the commit would have let
  # the file through and only caught it on the way out.

  defp outside_project!(dir) do
    root = Path.expand(File.cwd!())
    target = Path.expand(dir)

    if target == root or String.starts_with?(target, root <> "/") do
      raise """
      refusing to build a git fixture at #{target}: it is inside this repository (#{root}).

      A fixture under the project tree is one mis-scoped git invocation away from committing to
      the repository you are working in. That has already happened here once.
      """
    end

    :ok
  end

  defp inside_fixture!(dir) do
    expected = Path.expand(dir)

    # Deliberately WITHOUT --git-dir. Asking git where it thinks it is while TELLING it where
    # it is makes the answer tautological: --show-toplevel then just echoes -C. The value of
    # this guard is that it re-derives the answer the way an UNSCOPED call would, so a leaked
    # GIT_DIR — the exact failure that put two commits on this branch — yields a foreign
    # toplevel here and is refused, instead of being masked by the very flag under test.
    {output, status} =
      System.cmd("git", ["-C", expected, "rev-parse", "--show-toplevel"],
        stderr_to_stdout: true,
        env: CheckDrift.git_env()
      )

    actual = String.trim(output)

    unless status == 0 and Path.expand(actual) == expected do
      raise """
      refusing to run git for a fixture at #{expected}: git reports the toplevel as #{inspect(actual)}.

      This is the guard that turns a recurrence into a red test instead of more phantom commits.
      If it fires, something is still redirecting discovery — look at GIT_DIR first.
      """
    end

    :ok
  end

  # Measures 1, 2 and 4 on every invocation. Never a bare System.cmd("git", ...) in this file:
  # one that slipped through read the REAL repository's HEAD under the hook's GIT_DIR.
  defp git!(dir, args) do
    inside_fixture!(dir)
    git_raw!(dir, args)
  end

  # Measures 1, 2 and 3 — no toplevel check, for the one call that CREATES the repository the
  # check needs in order to be answerable.
  defp git_raw!(dir, args) do
    expanded = Path.expand(dir)

    case System.cmd(
           "git",
           ["--git-dir", Path.join(expanded, ".git"), "--work-tree", expanded, "-C", expanded] ++
             args,
           stderr_to_stdout: true,
           env: CheckDrift.git_env()
         ) do
      {output, 0} -> output
      {output, status} -> raise "git #{Enum.join(args, " ")} exited #{status}: #{output}"
    end
  end

  defp read_json(path), do: path |> File.read!() |> Jason.decode!()
end
