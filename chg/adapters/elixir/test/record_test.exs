defmodule ChgAdapter.RecordTest do
  use ExUnit.Case, async: false

  alias ChgAdapter.{Digest, Record}

  setup do
    dir = Path.join(System.tmp_dir!(), "chg-record-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    on_exit(fn -> System.delete_env("CHG_COVER") end)
    %{path: Path.join(dir, "r.cover")}
  end

  defp raw!(path, fields) do
    base = %{
      vsn: Record.vsn(),
      elixir: System.version(),
      otp: to_string(:erlang.system_info(:otp_release)),
      sha: "0000000000000000000000000000000000000000",
      digests: %{},
      cover: %{},
      global: [],
      ms: %{"test/a_test.exs" => 5}
    }

    File.write!(path, :erlang.term_to_binary(Map.merge(base, fields)))
  end

  test "a record keeps the form of its digests", %{path: p} do
    Record.write!(p, %{sha: "abc", digests: %{}, cover: %{}, global: [], ms: %{}})
    assert {:ok, %{digest: v}} = Record.read(p)
    assert v == Digest.version()
  end

  test "a record without digests of this form still gives its times, not coverage", %{path: p} do
    raw!(p, %{})
    assert {:ok, %{ms: %{"test/a_test.exs" => 5}}} = Record.read(p)

    System.put_env("CHG_COVER", p)
    assert {:error, why} = Record.given("HEAD")
    assert why =~ "digests of form nil, this adapter makes form #{Digest.version()}"
  end

  test "a record of another format says so", %{path: p} do
    raw!(p, %{vsn: 99})
    assert {:error, why} = Record.read(p)
    assert why =~ "is format 99, this adapter reads #{Record.vsn()}"
  end
end
