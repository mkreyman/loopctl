defmodule LoopctlRunner.Capability do
  @moduledoc """
  A run's capability tokens: random, written into the run directory where the command that
  requires one checks it, and handed to the session in its PROMPT and nowhere else — a triage
  run's verdict and escalate tokens (`LoopctlRunner.TriageVerdict`) and a review run's judgement
  token (`LoopctlRunner.ReviewJudgements`).

  The boundary is between the session and what it dispatches: a subagent inherits the
  environment and the session's allow-rules, but is given a task, not the session's prompt, so it
  cannot state what the token guards by accident. It is NOT a boundary against another process of
  this user: the token is a file in the run directory and an argv element of every call that
  carries it.
  """

  @doc """
  Mints a token named `name` in `run_dir` and returns it: created empty, narrowed to this user,
  and only then written.
  """
  @spec mint(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def mint(run_dir, name) do
    token = 24 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    path = Path.join(run_dir, name)

    # Created empty and narrowed BEFORE the token is in it: File.write/2 creates at the umask's
    # mode, so writing first leaves a window where any local user can read the capability. A
    # chmod that fails fails the mint, rather than returning a credential at 0644 — the same
    # standard `ControlConfig` holds the daemon's token to.
    with :ok <- File.touch(path),
         :ok <- File.chmod(path, 0o600),
         :ok <- File.write(path, token) do
      {:ok, token}
    else
      {:error, reason} ->
        File.rm(path)
        {:error, "#{name} could not be written: #{:file.format_error(reason)}"}
    end
  end
end
