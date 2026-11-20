defmodule LoopctlRunner.GrantCanary do
  @moduledoc """
  What the suite may never do to the operator's REAL grant directory, checked once every test has
  run (`test/test_helper.exs`): leave a grant or a pending file this test BEAM owns, or remove a
  grant whose session is still running.

  Other sessions and the daemon arm and remove grants there all the time, so a check of the
  directory as a whole reads their work as the suite's. Each half is keyed to what only the
  suite's damage looks like. A grant another BEAM armed and removed was never the suite's, and a
  grant whose owner or recorded launcher has ended was removed by its own teardown or by a sweep
  that was right to. What is left is a grant, present when the suite started, whose owner BEAM
  AND launcher still run — a session in flight whose grant something took. A grant with no
  session line is not judged that way: its owner outlives its session, so nothing tells its own
  teardown from the suite.
  """

  alias LoopctlRunner.{GitGrant, Owner}

  @type snapshot :: [{String.t(), {Owner.t(), Owner.t() | nil}}]

  @doc """
  The grants in `dir` this runner wrote, with the owner and launcher each names — read before any
  test runs, since a grant that is gone at the end can no longer be read.
  """
  @spec snapshot(String.t() | nil) :: snapshot()
  def snapshot(dir) do
    for path <- GitGrant.list(dir),
        {_, _} = holders <- [GitGrant.holders(path)],
        do: {path, holders}
  end

  @doc """
  Every breach of the rule, each `{:left, path}` or `{:removed, path}`; [] when there is none.
  `suite` is this test BEAM's `LoopctlRunner.Owner`.
  """
  @spec violations(snapshot(), String.t() | nil, Owner.t()) :: [{:left | :removed, String.t()}]
  def violations(snapshot, dir, suite) do
    left =
      for path <- written(dir),
          {owner, _session} <- [GitGrant.holders(path)],
          Owner.same?(owner, suite),
          do: {:left, path}

    removed =
      for {path, {owner, session}} <- snapshot,
          not File.exists?(path),
          Owner.alive?(owner),
          # False for a grant with no session line (nil), which is never judged this way.
          Owner.process_alive?(session),
          do: {:removed, path}

    left ++ removed
  end

  # Grants and pending files alike: both carry the owner line, and a pending one the suite left
  # is a grant it prepared there.
  defp written(nil), do: []

  defp written(dir) do
    case File.ls(dir) do
      {:ok, names} ->
        for name <- names,
            String.starts_with?(name, [GitGrant.prefix(), GitGrant.pending_prefix()]),
            do: Path.join(dir, name)

      {:error, _} ->
        []
    end
  end
end
