defmodule Loopctl.HnswIterativeScanEnvTest do
  @moduledoc """
  Environment guard for the test-env `:hnsw_iterative_scan` setting (#488).

  `config/test.exs` turns iterative scan ON so the suite reads ANN the way
  production does and tenant-filtered searches stop under-returning on the shared
  test HNSW indexes. `hnsw.iterative_scan` is a pgvector **>= 0.8** GUC: on an
  older server the `SET LOCAL` raises, which would surface as hundreds of
  unrelated ANN failures with no hint of the cause.

  This test turns that into ONE failure that names the problem. If it fails, the
  test database's pgvector is too old — upgrade it (CI uses the
  `pgvector/pgvector:pg16` image) or set `:hnsw_iterative_scan` back to `0` in
  `config/test.exs` and accept the flaky filtered recall.
  """

  use Loopctl.DataCase, async: true

  setup :verify_on_exit!

  alias Loopctl.AdminRepo

  test "pgvector supports hnsw.iterative_scan when config/test.exs enables it" do
    configured = Application.get_env(:loopctl, :hnsw_iterative_scan, 0)

    if configured != 0 do
      %{rows: [[version]]} =
        AdminRepo.query!("SELECT extversion FROM pg_extension WHERE extname = $1", ["vector"])

      assert Version.match?(normalize(version), ">= 0.8.0"),
             """
             config/test.exs sets :hnsw_iterative_scan to #{configured}, but the test
             database runs pgvector #{version}, which has no `hnsw.iterative_scan` GUC
             (needs >= 0.8.0). Every ANN read would raise on its `SET LOCAL`.

             Fix the database (CI image: pgvector/pgvector:pg16), or set
             :hnsw_iterative_scan back to 0 in config/test.exs.
             """
    end
  end

  # pgvector reports e.g. "0.8.2"; be tolerant of a two-segment "0.8".
  defp normalize(version) do
    case String.split(version, ".") do
      [major, minor] -> "#{major}.#{minor}.0"
      _ -> version
    end
  end
end
