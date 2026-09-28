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
  against it — i.e. it executes **third-party code**. It is NOT a sandbox.

  Because of that, it is **disabled by default** and only runs when an operator
  explicitly opts in with:

      config :loopctl, :enable_local_test_runner, true

  When the flag is off (the default in every environment, including prod),
  `run_tests/3` returns `{:error, :runner_disabled}` before any clone or
  subprocess runs. Turn it on ONLY inside an egress-restricted, ephemeral
  sandbox — enabling it on a host with outbound network + `git`/`mix` exposes
  the untrusted-code-exec and clone-time SSRF surface described below.

  The remaining containment, in order of strength:

    1. **Off by default** (the flag above) — the primary mitigation.
    2. **Input validation** in this module and in
       `Loopctl.Verification.VerificationRun` — a `commit_sha` is constrained to
       a hex git object id and a `repo_url` to a well-formed `http(s)` URL — so
       neither can inject a subprocess argument or escape the temp directory.
    3. In production the release image also ships no `git`/`mix`, so even if the
       flag were flipped there the clone would fail: `timeout` (coreutils, which the
       Debian runtime image carries as an essential package) finds no `git` and
       exits 127, recorded `clone_failed`.

  True isolation (running each verification in an ephemeral, network-restricted
  container with a CPU/memory budget) is the intended future hardening and is
  deliberately out of scope for this change. Two narrower bounds are in place
  (US-26.4.6):

    * **Environment.** Every command runs with loopctl's own environment
      SCRUBBED (`command_env/2`): every variable but a short allowlist is unset,
      so `GITHUB_TOKEN`, `DATABASE_URL`, `SECRET_KEY_BASE` and the Cloak keys never
      reach `mix deps.get` or `mix test`, which run the tenant's code. The
      verification credential reaches `git clone` and `git fetch` ONLY, through
      `Loopctl.Verification.Credential.git_env/1`. The filesystem is NOT scrubbed:
      anything readable under `HOME` stays readable, which is one more reason
      this belongs in a sandbox.
    * **Time.** Every command runs under coreutils `timeout` with its own budget
      (`steps/5`); one that runs out ends the run `{:error, :local_timeout}`.

  ## Input hardening (advisory ie-04, GHSA-pv74-gwwh-g92x)

    * `commit_sha` is re-validated here (defence in depth — the schema already
      validates it) before it is used in `git checkout` or a path. A hex-only
      value (`[0-9a-f]{7,64}`) cannot be a `-`-leading git flag nor contain `/`
      or `..`.
    * `repo_url` is validated to an `http(s)` URL with a real host, closing the
      `ext::sh -c '…'` / `file://` / local-path / `-`-leading remote-helper RCE
      vectors.
    * `git clone` passes `--` before its positional args (`clone --depth 1 --
      <repo_url> <work_dir>`) so a `-`-leading URL can't be read as a flag.
      `git checkout <commit_sha>` does **not** use `--` (that would make git
      treat the value as a *pathspec* rather than a revision); it is safe purely
      because `commit_sha` is validated to `[0-9a-f]{7,64}` and so can never be a
      flag.
    * The working directory uses a random, non-user-derived name, and cleanup
      (`File.rm_rf/1`) only ever fires against a path provably inside the system
      temp directory.

  ### Clone-time SSRF is only partially mitigated

  `repo_url` is also screened by the shared SSRF egress guard
  (`Loopctl.Net.UrlGuard`) just before the clone, but that guard resolves DNS
  once. `git clone` is a separate subprocess that **re-resolves the hostname at
  connect time** and cannot be pinned to the validated IP the way a `Req`
  request can (there is no SNI/`Host`/connect-IP override via the git CLI). A
  hostile authoritative server answering with TTL=0 can therefore return a
  public address to the guard and a private one to `git` (DNS rebinding), so the
  guard does **not** fully close clone-time SSRF. The syntactic rejections
  (`ext::`/`file://`/leading-dash/non-http scheme) ARE fully effective; the
  DNS-rebinding residual is the reason this runner must only be enabled inside an
  egress-restricted sandbox (see the disable flag above).
  """

  @behaviour Loopctl.Verification.LocalRunner

  require Logger

  alias Loopctl.Net.UrlGuard
  alias Loopctl.Verification.Credential
  alias Loopctl.Verification.VerificationRun

  @allowed_repo_schemes ~w(https http)

  # What a toolchain needs to find itself and run, and nothing else (`command_env/2`):
  #   PATH                  finds git, mix, erl
  #   HOME                  git's global config; hex's and mix's caches default under it
  #   LANG, LC_ALL          Elixir warns, and some deps misbehave, outside a UTF-8 locale
  #   TMPDIR                compilers' and test suites' scratch space
  #   MIX_HOME, HEX_HOME    where the hex archive and caches live when not under HOME
  #   ASDF_DIR, ASDF_DATA_DIR  asdf shims on PATH resolve the toolchain through them when it
  #                         is installed outside the default ~/.asdf
  # The Erlang runtime needs nothing more: `erl` derives ROOTDIR/BINDIR from its own location,
  # and inheriting a release's ROOTDIR/RELEASE_* would point the child at loopctl's runtime.
  # Proxy variables are deliberately NOT kept: a proxy URL can carry credentials, and a
  # sandbox should restrict egress at its network rather than in an environment the tenant's
  # code can read.
  @env_allowlist ~w(PATH HOME LANG LC_ALL TMPDIR MIX_HOME HEX_HOME ASDF_DIR ASDF_DATA_DIR)

  # Wall-clock budgets, in seconds, one per command, each enforced by coreutils `timeout`,
  # which sends TERM at the budget and KILL `@kill_after_seconds` later:
  #   clone     a --depth 1 --no-checkout clone moves the refs and one tip's objects;
  #             five minutes covers a large repository on a slow link
  #   fetch     one commit at depth 1: the same order of transfer as the clone
  #   checkout  local only (the objects are fetched); two minutes is a very large tree on a
  #             slow disk
  #   deps.get  resolves and downloads the whole dependency tree from hex and git
  #   test      compiles the project and every dependency in :test, then runs the suite;
  #             half an hour is well past a healthy suite and short of a hung one
  @clone_seconds 300
  @fetch_seconds 300
  @checkout_seconds 120
  @deps_get_seconds 600
  @test_seconds 1_800
  @kill_after_seconds 30

  # `timeout`'s own exit statuses: 124 the budget ran out and TERM ended the command, 137
  # (128 + 9) it ignored TERM and KILL did.
  @timeout_statuses [124, 137]

  @doc """
  The longest a run's commands can take in total: every budget plus its KILL grace. The
  verification worker waits a little longer than this before it gives up on a run.
  """
  @spec max_run_seconds() :: pos_integer()
  def max_run_seconds do
    @clone_seconds + @fetch_seconds + @checkout_seconds + @deps_get_seconds + @test_seconds +
      5 * @kill_after_seconds
  end

  @doc """
  Clones `repo_url` at `commit_sha` through the verification credential (US-26.4.6) and runs
  its suite. The clone and the fetch authenticate through `Credential.git_env/1`, the same
  seam the CI read went through, so a private repository the tenant was licensed to read is
  cloned with that licence and nothing else; no other command sees the credential.

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
  A command that outlives its budget is `{:error, :local_timeout}`.
  """
  @impl true
  @spec run_tests(String.t(), String.t(), Credential.t()) :: {:ok, map()} | {:error, term()}
  def run_tests(repo_url, commit_sha, %Credential{} = credential) do
    # Validate BEFORE building a path or spawning any subprocess. A bad SHA or
    # URL must never reach `git`, `mix`, or `File.rm_rf/1`. The runner-enabled
    # gate is checked AFTER validation (validation is pure and side-effect-free)
    # but still BEFORE any clone/exec, so a disabled runner never touches the
    # network or filesystem.
    with :ok <- validate_commit_sha(commit_sha),
         :ok <- validate_repo_url_syntax(repo_url),
         :ok <- check_runner_enabled(),
         :ok <- validate_repo_url_egress(repo_url) do
      work_dir = build_work_dir()

      try do
        with {:ok, output} <- run_steps(steps(repo_url, commit_sha, work_dir, credential)) do
          {:ok, parse_test_output(output)}
        end
      after
        # Always clean up the clone — but only ever inside the temp dir.
        safe_rm_rf(work_dir)
      end
    end
  end

  @doc """
  The commands a run executes, in order, as data: `command` and `args` (run under `exec/1`'s
  `timeout`), `opts` for `System.cmd/3`, the `budget` in seconds, and what a non-zero exit
  means (`on_failure`: an error tag, or `:continue` for `mix deps.get`, whose failure `mix
  test` reports, and for `mix test`, whose failure IS the result).

  `parent_env` is the environment the commands would otherwise inherit (loopctl's own); it is
  a parameter so the scrub is testable without touching the VM's environment.
  """
  @spec steps(String.t(), String.t(), String.t(), Credential.t(), %{String.t() => String.t()}) ::
          [map()]
  def steps(
        repo_url,
        commit_sha,
        work_dir,
        %Credential{} = credential,
        parent_env \\ System.get_env()
      ) do
    git = command_env({:git, credential}, parent_env)
    plain = command_env(:plain, parent_env)

    [
      # `--` before positional args: a `-`-leading repo_url can't become a flag.
      %{
        command: "git",
        args: ["clone", "--depth", "1", "--no-checkout", "--", repo_url, work_dir],
        opts: [env: git],
        budget: @clone_seconds,
        on_failure: :clone_failed
      },
      # A shallow clone holds only the default branch's tip, so checking out any other commit
      # failed `checkout_failed` for every commit that was not the tip. The commit is FETCHED
      # by id instead (GitHub serves any reachable commit that way), which needs the full id
      # the verification worker resolved (AC-26.4.6.7).
      %{
        command: "git",
        args: ["fetch", "--depth", "1", "origin", commit_sha],
        opts: [cd: work_dir, env: git],
        budget: @fetch_seconds,
        on_failure: :fetch_failed
      },
      # Local: the objects are already fetched, so it needs no credential.
      %{
        command: "git",
        args: ["checkout", commit_sha],
        opts: [cd: work_dir, env: plain],
        budget: @checkout_seconds,
        on_failure: :checkout_failed
      },
      %{
        command: "mix",
        args: ["deps.get"],
        opts: [cd: work_dir, env: plain],
        budget: @deps_get_seconds,
        on_failure: :continue
      },
      %{
        command: "mix",
        args: ["test", "--no-color"],
        opts: [cd: work_dir, env: plain],
        budget: @test_seconds,
        on_failure: :continue
      }
    ]
  end

  @doc """
  The `env:` of one command: every variable of `parent_env` outside the allowlist UNSET (a
  `nil` value), then `MIX_ENV=test`, then — for `{:git, credential}` only —
  `Credential.git_env/1`. So the credential reaches git's own process and nothing else, and no
  command inherits loopctl's secrets.
  """
  @spec command_env(:plain | {:git, Credential.t()}, %{String.t() => String.t()}) ::
          [{String.t(), String.t() | nil}]
  def command_env(kind, parent_env \\ System.get_env()) do
    set = [{"MIX_ENV", "test"} | credential_env(kind)]
    set_names = Enum.map(set, &elem(&1, 0))

    unset =
      for {name, _value} <- parent_env,
          name not in @env_allowlist and name not in set_names,
          do: {name, nil}

    unset ++ set
  end

  defp credential_env({:git, %Credential{} = credential}), do: Credential.git_env(credential)
  defp credential_env(:plain), do: []

  @doc """
  Runs one step under `timeout --kill-after=#{@kill_after_seconds}s <budget>s`. Returns
  `{:ok, output, exit_status}`, or `{:error, :local_timeout}` when the budget ran out.
  """
  @spec exec(map()) :: {:ok, String.t(), non_neg_integer()} | {:error, :local_timeout}
  def exec(%{command: command, args: args, opts: opts, budget: budget}) do
    argv = ["--kill-after=#{@kill_after_seconds}s", "#{budget}s", command | args]

    case System.cmd("timeout", argv, [stderr_to_stdout: true] ++ opts) do
      {_output, status} when status in @timeout_statuses -> {:error, :local_timeout}
      {output, status} -> {:ok, output, status}
    end
  end

  # Runs the steps in order and answers the LAST one's output (`mix test`'s).
  defp run_steps(steps) do
    Enum.reduce_while(steps, {:ok, ""}, fn step, _acc ->
      case exec(step) do
        {:error, :local_timeout} = timeout -> {:halt, timeout}
        {:ok, output, 0} -> {:cont, {:ok, output}}
        {:ok, output, _status} when step.on_failure == :continue -> {:cont, {:ok, output}}
        {:ok, output, _status} -> {:halt, {:error, {step.on_failure, output}}}
      end
    end)
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
  Returns whether the local test runner is enabled.

  Disabled by default — the runner executes untrusted third-party code and is
  subject to a clone-time DNS-rebinding SSRF residual, so it must be explicitly
  opted in (and run inside an egress-restricted sandbox) via
  `config :loopctl, :enable_local_test_runner, true`.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(:loopctl, :enable_local_test_runner, false) == true
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

  defp check_runner_enabled do
    if enabled?(), do: :ok, else: {:error, :runner_disabled}
  end

  defp validate_commit_sha(commit_sha) do
    if VerificationRun.valid_commit_sha?(commit_sha) do
      :ok
    else
      {:error, :invalid_commit_sha}
    end
  end

  # Pure syntactic guard: closes the RCE/arg-injection vectors (ext::/file://,
  # non-http scheme, missing host, leading dash). No network I/O — runs before
  # the enable gate so a syntactically bad URL is rejected even when the runner
  # is disabled.
  defp validate_repo_url_syntax(repo_url) do
    if safe_repo_url?(repo_url), do: :ok, else: {:error, :invalid_repo_url}
  end

  # SSRF egress guard (resolves DNS). Runs ONLY after the enable gate and only
  # just before the clone, so a disabled runner performs no network I/O. NOTE:
  # this does not fully close clone-time SSRF — `git clone` re-resolves DNS at
  # connect time and can't be IP-pinned (see the moduledoc's DNS-rebinding
  # note); it is defence in depth, not a complete barrier.
  defp validate_repo_url_egress(repo_url) do
    case UrlGuard.validate_egress(repo_url) do
      {:ok, _uri} -> :ok
      {:error, _reason} -> {:error, :invalid_repo_url}
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
