defmodule Loopctl.ImportExport.DecompressionLimitTest do
  @moduledoc """
  US-27.16 (#3): decompression-bomb defense for archive imports. Pure (no DB),
  fully async.
  """
  use ExUnit.Case, async: true

  alias Loopctl.ImportExport.DecompressionLimit, as: DL

  # Build a valid `.tar.gz` whose UNCOMPRESSED content is `uncompressed_bytes` of
  # zeros (which compress ~1000×), so the COMPRESSED form is tiny — a decompression
  # bomb.
  defp bomb_targz(uncompressed_bytes) do
    big = :binary.copy(<<0>>, uncompressed_bytes)
    tmp = Path.join(System.tmp_dir!(), "dl-#{System.unique_integer([:positive])}.tar.gz")
    on_exit_file(tmp)
    :ok = :erl_tar.create(String.to_charlist(tmp), [{~c"big.bin", big}], [:compressed])
    File.read!(tmp)
  end

  defp on_exit_file(path), do: ExUnit.Callbacks.on_exit(fn -> File.rm(path) end)

  describe "extract_tar_gz/1 decompression budget" do
    test "a valid small archive extracts" do
      tmp = Path.join(System.tmp_dir!(), "dl-ok-#{System.unique_integer([:positive])}.tar.gz")
      on_exit_file(tmp)
      :ok = :erl_tar.create(String.to_charlist(tmp), [{~c"a.md", "hello"}], [:compressed])
      bin = File.read!(tmp)

      assert {:ok, entries} = DL.extract_tar_gz(bin)
      assert Enum.any?(entries, fn {n, c} -> to_string(n) == "a.md" and c == "hello" end)
    end

    test "a gzip bomb is rejected MID-decompression (never fully inflated)" do
      # Inflates to ~8 MB, well past the 5 MB test budget, but the compressed bytes
      # are tiny (zeros compress ~1000x). The streaming inflate must abort.
      bomb = bomb_targz(8_000_000)
      assert byte_size(bomb) < 1_000_000, "bomb should be small compressed"

      assert {:error, :payload_too_large} = DL.extract_tar_gz(bomb)
    end

    test "an over-large COMPRESSED input is rejected before any inflation" do
      # > the 1 MB test compressed cap. We don't even need it to be valid gzip —
      # the size guard fires first.
      big_input = <<0x1F, 0x8B, 0x08>> <> :binary.copy(<<0xAB>>, 1_500_000)
      assert {:error, :payload_too_large} = DL.extract_tar_gz(big_input)
    end
  end

  describe "guard_compressed_size/1" do
    test "passes a small input, rejects an over-cap input" do
      assert :ok = DL.guard_compressed_size(:binary.copy(<<0>>, 100))

      assert {:error, :payload_too_large} =
               DL.guard_compressed_size(:binary.copy(<<0>>, DL.max_compressed_bytes() + 1))
    end
  end
end
