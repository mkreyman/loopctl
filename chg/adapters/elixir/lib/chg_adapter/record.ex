defmodule ChgAdapter.Record do
  @moduledoc """
  A coverage record: what one full run on a commit learned, for coverage selection and
  time-balanced shards.

    * `sha`: the commit, which the tree was exactly;
    * `elixir`, `otp`: the toolchain, which digests depend on;
    * `digest`: the form of the digests (`ChgAdapter.Digest.version/0`);
    * `digests`: `ChgAdapter.Digest` of every project module;
    * `cover`: per test file, the project modules it executed (`ChgAdapter.Cover`);
    * `global`: modules executed outside any test's or test file compile's window (at
      boot, between tests) or by a compiling process whose file is unknown;
    * `reads`: per test file, the paths it read and `{:spawn, name}` for each
      subprocess (`ChgAdapter.Cover`);
    * `global_reads`: the same, outside any test's or test file compile's window;
    * `ms`: per test file, the summed time of its tests.

  `chg` decides where records live and which one to use. It names the file to write in
  `CHG_RECORD` (on the verifier's full run) and the record to judge a change by in
  `CHG_COVER` (on `affected`).
  """

  @vsn 2

  def vsn, do: @vsn

  @doc "Writes `record` to `path` atomically."
  def write!(path, record) do
    record =
      Map.merge(record, %{
        vsn: @vsn,
        elixir: System.version(),
        otp: otp(),
        digest: ChgAdapter.Digest.version()
      })

    ChgAdapter.write_atomic!(path, :erlang.term_to_binary(record, [:compressed]))
  end

  @doc """
  The record `chg` chose to judge a change on `rev` by (`CHG_COVER`), with how many
  first-parent commits it is behind `rev` as `:age`. `{:error, why}` when there is none,
  or it was made by another toolchain or holds another form of digest.
  """
  def given(rev) do
    with path when path not in [nil, ""] <- System.get_env("CHG_COVER"),
         {:ok, record} <- read(path),
         :ok <- same_digest(record),
         {n, 0} <- git(["rev-list", "--first-parent", "--count", "#{record.sha}..#{rev}"]),
         {age, ""} <- Integer.parse(String.trim(n)) do
      {:ok, Map.put(record, :age, age)}
    else
      empty when empty in [nil, ""] -> {:error, "no coverage record given"}
      {:error, why} -> {:error, why}
      _ -> {:error, "cannot place the coverage record behind #{rev}"}
    end
  end

  defp same_digest(r) do
    case {Map.get(r, :digest), ChgAdapter.Digest.version()} do
      {v, v} ->
        :ok

      {v, ours} ->
        {:error,
         "the coverage record holds digests of form #{inspect(v)}, this adapter makes form #{ours}"}
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
      {:error, why} ->
        {:error, "cannot read #{path}: #{inspect(why)}"}

      %{vsn: v} ->
        {:error,
         "the coverage record #{path} is format #{inspect(v)}, this adapter reads #{@vsn}"}

      _ ->
        {:error, "unreadable coverage record #{path}"}
    end
  end

  defp safe_decode(bin) do
    :erlang.binary_to_term(bin)
  rescue
    _ -> :invalid
  end

  defp otp, do: to_string(:erlang.system_info(:otp_release))
end
