defmodule ChgAdapter.Record do
  @moduledoc """
  A coverage record: what one full run on a commit learned, for coverage selection and
  time-balanced shards.

    * `sha`: the commit, which the tree was exactly;
    * `elixir`, `otp`: the toolchain, which digests depend on;
    * `digests`: `ChgAdapter.Digest` of every project module;
    * `cover`: per test file, the project modules it executed (`ChgAdapter.Cover`);
    * `global`: modules executed at boot or while compiling tests;
    * `ms`: per test file, the summed time of its tests.

  `chg` decides where records live and which one to use. It names the file to write in
  `CHG_RECORD` (on the verifier's full run) and the record to judge a change by in
  `CHG_COVER` (on `affected`).
  """

  @vsn 1

  def vsn, do: @vsn

  @doc "Writes `record` to `path` atomically."
  def write!(path, record) do
    record = Map.merge(record, %{vsn: @vsn, elixir: System.version(), otp: otp()})
    ChgAdapter.write_atomic!(path, :erlang.term_to_binary(record, [:compressed]))
  end

  @doc """
  The record `chg` chose to judge a change on `rev` by (`CHG_COVER`), with how many
  first-parent commits it is behind `rev` as `:age`. `{:error, why}` when there is none,
  or it was made by another toolchain.
  """
  def given(rev) do
    with path when path not in [nil, ""] <- System.get_env("CHG_COVER"),
         {:ok, record} <- read(path),
         {n, 0} <- git(["rev-list", "--first-parent", "--count", "#{record.sha}..#{rev}"]),
         {age, ""} <- Integer.parse(String.trim(n)) do
      {:ok, Map.put(record, :age, age)}
    else
      empty when empty in [nil, ""] -> {:error, "no coverage record given"}
      {:error, why} -> {:error, why}
      _ -> {:error, "cannot place the coverage record behind #{rev}"}
    end
  end

  defp git(args), do: System.cmd("git", args, stderr_to_stdout: true)

  @doc "Reads a record; `{:error, why}` when it is unreadable, stale in format, or from another toolchain."
  def read(path) do
    with {:ok, bin} <- File.read(path),
         %{vsn: @vsn} = r <- safe_decode(bin) do
      if r.elixir == System.version() and r.otp == otp(),
        do: {:ok, r},
        else: {:error, "the coverage record was made by Elixir #{r.elixir}/OTP #{r.otp}"}
    else
      {:error, why} -> {:error, "cannot read #{path}: #{inspect(why)}"}
      _ -> {:error, "unreadable coverage record #{path}"}
    end
  end

  defp safe_decode(bin) do
    :erlang.binary_to_term(bin)
  rescue
    _ -> :invalid
  end

  defp otp, do: to_string(:erlang.system_info(:otp_release))
end
