defmodule Loopctl.Secrets.LocalFileAdapterTest do
  @moduledoc """
  #496 — the self-host file-backed secrets adapter. Every test runs against a store in its
  own `tmp_dir` through the `path` argument (`get/2`, `set/3`, `delete/2`), never the
  configured `:secrets_file` other tests share.
  """
  use ExUnit.Case, async: true

  alias Loopctl.Secrets.LocalFileAdapter

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    %{path: Path.join(tmp_dir, "secrets.json")}
  end

  test "set then get round-trips a raw binary value (not just strings)", %{path: path} do
    value = :crypto.strong_rand_bytes(32)
    assert :ok = LocalFileAdapter.set("TENANT_AUDIT_KEY_ACME", value, path)
    assert {:ok, ^value} = LocalFileAdapter.get("TENANT_AUDIT_KEY_ACME", path)
  end

  test "get on a missing name returns :not_found", %{path: path} do
    assert {:error, :not_found} = LocalFileAdapter.get("NOPE", path)
  end

  test "get on a missing FILE is an empty store, not an error", %{path: path} do
    assert {:error, :not_found} = LocalFileAdapter.get("ANY", path)
  end

  test "delete removes a name", %{path: path} do
    :ok = LocalFileAdapter.set("K", "v", path)
    assert {:ok, "v"} = LocalFileAdapter.get("K", path)
    assert :ok = LocalFileAdapter.delete("K", path)
    assert {:error, :not_found} = LocalFileAdapter.get("K", path)
  end

  test "set overwrites an existing value and preserves other keys", %{path: path} do
    :ok = LocalFileAdapter.set("A", "1", path)
    :ok = LocalFileAdapter.set("B", "2", path)
    :ok = LocalFileAdapter.set("A", "1-updated", path)

    assert {:ok, "1-updated"} = LocalFileAdapter.get("A", path)
    assert {:ok, "2"} = LocalFileAdapter.get("B", path)
  end

  test "the on-disk file is 0600 (owner-only)", %{path: path} do
    :ok = LocalFileAdapter.set("K", "v", path)
    %File.Stat{mode: mode} = File.stat!(path)
    # low 9 bits are the rwx perms; 0o600 = owner rw only.
    assert Bitwise.band(mode, 0o777) == 0o600
  end

  test "a corrupt (non-JSON) file is refused rather than silently treated as empty", %{path: path} do
    File.write!(path, "this is not json{")
    assert {:error, :corrupt_secrets_file} = LocalFileAdapter.get("K", path)
  end

  test "a non-string JSON value is reported as corrupt, not a FunctionClauseError crash", %{
    path: path
  } do
    # A hand-corrupted secrets.json where a value is a number (not base64 string).
    File.write!(path, Jason.encode!(%{"AUDIT_KEY" => 123}))
    assert {:error, :corrupt_secret} = LocalFileAdapter.get("AUDIT_KEY", path)
  end

  test "concurrent set/2 with distinct names never loses a key (write-lock serialization)", %{
    path: path
  } do
    # This is the load-bearing property of the `:global.trans/2` write lock: without
    # it, two concurrent read-modify-write cycles last-rename-wins-drop each other's
    # key — permanently breaking the losing tenant's audit-chain signing. Spawn many
    # concurrent writers of DISTINCT keys and assert every key survives.
    names = for n <- 1..25, do: "CONCURRENT_KEY_#{n}"

    names
    |> Task.async_stream(
      fn name -> :ok = LocalFileAdapter.set(name, "value-#{name}", path) end,
      max_concurrency: 25,
      timeout: 30_000
    )
    |> Stream.run()

    for name <- names do
      assert {:ok, value} = LocalFileAdapter.get(name, path)
      assert value == "value-#{name}"
    end
  end
end
