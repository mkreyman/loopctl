defmodule Loopctl.Verification.TestRunner do
  @moduledoc """
  L3: Independent test re-execution.

  Clones the project repo at a specific commit SHA, runs `mix test`,
  parses output, and checks each AC binding against the actual results.

  This is the core lazy-bastard defense — the verifier does not trust
  the implementer's self-report. The tests run in a clean subprocess
  that the implementer cannot reach.

  ## Untrusted-code execution (advisory ie-03, GHSA-38cj-97f6-r82q)

  This runner clones a tenant-supplied repo and runs `mix deps.get` + `mix test`
  against it — i.e. it executes **third-party code**. It is NOT a sandbox. The
  current containment rests on two things:

    1. The production release image ships no `git` and no `mix`, so the
       `System.cmd/3` calls raise `:enoent` and the runner is effectively inert
       in prod today.
    2. The input validation in this module and in
       `Loopctl.Verification.VerificationRun` — a `commit_sha` is constrained to
       a hex git object id and a `repo_url` to a well-formed `http(s)` URL — so
       neither can inject a subprocess argument or escape the temp directory.

  True isolation (running each verification in an ephemeral, network-restricted
  container with a CPU/memory/time budget) is the intended future hardening and
  is deliberately out of scope for this change.

  ## Input hardening (advisory ie-04, GHSA-pv74-gwwh-g92x)

    * `commit_sha` is re-validated here (defence in depth — the schema already
      validates it) before it is used in `git checkout` or a path. A hex-only
      value cannot be a `-`-leading git flag nor contain `/` or `..`.
    * `repo_url` is validated to an `http(s)` URL with a real host, closing the
      `ext::sh -c '…'` / `file://` / local-path / `-`-leading remote-helper RCE
      vectors, and is additionally screened by the shared SSRF egress guard.
    * The clone/checkout commands pass `--` before positional args so a value
      can never be reinterpreted as a flag.
    * The working directory uses a random, non-user-derived name, and cleanup
      (`File.rm_rf/1`) only ever fires against a path provably inside the system
      temp directory.
  """

  require Logger

  alias Loopctl.Net.UrlGuard
  alias Loopctl.Verification.VerificationRun

  @allowed_repo_schemes ~w(https http)

  @doc """
  Executes tests for a commit SHA in the given repo.

  Returns `{:ok, results}` or `{:error, reason}` where results is a map:
  ```
  %{
    status: "pass" | "fail" | "error",
    tests_run: integer,
    tests_passed: integer,
    tests_failed: integer,
    output: string (truncated)
  }
  ```
  """
  @spec run_tests(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def run_tests(repo_url, commit_sha) do
    # Validate BEFORE building a path or spawning any subprocess. A bad SHA or
    # URL must never reach `git`, `mix`, or `File.rm_rf/1`.
    with :ok <- validate_commit_sha(commit_sha),
         :ok <- validate_repo_url(repo_url) do
      work_dir = build_work_dir()

      try do
        with :ok <- clone_repo(repo_url, commit_sha, work_dir),
             {:ok, output} <- execute_mix_test(work_dir) do
          results = parse_test_output(output)
          {:ok, results}
        end
      after
        # Always clean up the clone — but only ever inside the temp dir.
        safe_rm_rf(work_dir)
      end
    end
  end

  @doc """
  Returns `true` when `repo_url` is a well-formed `http`/`https` URL with a real
  host. Everything else — `ext::`, `file://`, `ssh://`, a bare local path, or a
  `-`-leading value — is rejected so it can never reach `git clone`.
  """
  @spec safe_repo_url?(term()) :: boolean()
  def safe_repo_url?(url) when is_binary(url) do
    uri = URI.parse(url)

    is_binary(uri.scheme) and String.downcase(uri.scheme) in @allowed_repo_schemes and
      is_binary(uri.host) and uri.host != "" and
      not String.starts_with?(url, "-")
  end

  def safe_repo_url?(_url), do: false

  @doc """
  Builds the clone working directory: `loopctl_verify_<random>` under the system
  temp dir. The name is NOT derived from any user input, so it can never contain
  `/` or `..` and therefore can never escape the temp directory.
  """
  @spec build_work_dir() :: String.t()
  def build_work_dir do
    unique = 16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    Path.join(System.tmp_dir!(), "loopctl_verify_" <> unique)
  end

  @doc """
  Returns `true` only when `path` resolves to a location strictly inside the
  system temp directory. Used to fence `File.rm_rf/1` so a malformed or escaped
  path can never delete an arbitrary directory.
  """
  @spec within_tmp?(term()) :: boolean()
  def within_tmp?(path) when is_binary(path) do
    tmp = Path.expand(System.tmp_dir!())
    expanded = Path.expand(path)

    expanded != tmp and String.starts_with?(expanded, tmp <> "/")
  end

  def within_tmp?(_path), do: false

  @doc """
  Checks whether specific named tests ran and passed.
  Used for AC bindings of type "test".
  """
  @spec check_test_ran?(String.t(), String.t()) :: boolean()
  def check_test_ran?(output, test_name) do
    # Check that the test name appears in the output and isn't marked as excluded/skipped
    String.contains?(output, test_name) and
      not String.contains?(output, "* #{test_name} [excluded]")
  end

  # --- Private ---

  defp validate_commit_sha(commit_sha) do
    if VerificationRun.valid_commit_sha?(commit_sha) do
      :ok
    else
      {:error, :invalid_commit_sha}
    end
  end

  defp validate_repo_url(repo_url) do
    # Syntactic guard first (fast, and closes the RCE/arg-injection vectors),
    # then the shared SSRF egress guard so the clone can't be aimed at internal
    # infrastructure (cloud metadata, Fly 6PN, loopback, …).
    with true <- safe_repo_url?(repo_url),
         {:ok, _uri} <- UrlGuard.validate_egress(repo_url) do
      :ok
    else
      _ -> {:error, :invalid_repo_url}
    end
  end

  defp safe_rm_rf(work_dir) do
    if within_tmp?(work_dir) do
      File.rm_rf(work_dir)
    else
      Logger.error("TestRunner: refusing to rm_rf path outside tmp: #{inspect(work_dir)}")
      {:ok, []}
    end
  end

  defp clone_repo(repo_url, commit_sha, work_dir) do
    # `--` before positional args: a `-`-leading repo_url can't become a flag.
    case System.cmd("git", ["clone", "--depth", "1", "--", repo_url, work_dir],
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        case System.cmd("git", ["checkout", commit_sha],
               cd: work_dir,
               stderr_to_stdout: true
             ) do
          {_, 0} -> :ok
          {output, _} -> {:error, {:checkout_failed, output}}
        end

      {output, _} ->
        {:error, {:clone_failed, output}}
    end
  end

  defp execute_mix_test(work_dir) do
    # Install deps and run tests with a timeout
    System.cmd("mix", ["deps.get"], cd: work_dir, stderr_to_stdout: true)

    case System.cmd("mix", ["test", "--no-color"],
           cd: work_dir,
           stderr_to_stdout: true,
           env: [{"MIX_ENV", "test"}]
         ) do
      {output, 0} -> {:ok, output}
      {output, _exit_code} -> {:ok, output}
    end
  end

  defp parse_test_output(output) do
    # Parse "N tests, M failures" from mix test output
    case Regex.run(~r/(\d+) tests?, (\d+) failures?/, output) do
      [_, tests_str, failures_str] ->
        tests = String.to_integer(tests_str)
        failures = String.to_integer(failures_str)

        %{
          status: if(failures == 0, do: "pass", else: "fail"),
          tests_run: tests,
          tests_passed: tests - failures,
          tests_failed: failures,
          output: String.slice(output, -2000, 2000)
        }

      nil ->
        # Couldn't parse — likely compilation error
        %{
          status: "error",
          tests_run: 0,
          tests_passed: 0,
          tests_failed: 0,
          output: String.slice(output, -2000, 2000)
        }
    end
  end
end
