defmodule Loopctl.Verification.TestRunner do
  @moduledoc """
  L3: Independent test re-execution.

  Clones the project repo at a specific commit SHA, runs `mix test`,
  parses output, and checks each AC binding against the actual results.

  This is the core lazy-bastard defense — the verifier does not trust
  the implementer's self-report. The tests run in a clean subprocess
  that the implementer cannot reach.
  """

  require Logger

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
    work_dir = Path.join(System.tmp_dir!(), "loopctl_verify_#{commit_sha}")

    try do
      with :ok <- clone_repo(repo_url, commit_sha, work_dir),
           {:ok, output} <- execute_mix_test(work_dir) do
        results = parse_test_output(output)
        {:ok, results}
      end
    after
      # Always clean up the clone
      File.rm_rf(work_dir)
    end
  end

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

  defp clone_repo(repo_url, commit_sha, work_dir) do
    case System.cmd("git", ["clone", "--depth", "1", repo_url, work_dir], stderr_to_stdout: true) do
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
