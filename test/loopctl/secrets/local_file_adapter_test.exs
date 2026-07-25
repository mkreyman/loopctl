defmodule Loopctl.Secrets.LocalFileAdapterTest do
  @moduledoc """
  #496 — the self-host file-backed secrets adapter. `async: false`: it reads/writes a
  single VM-global file path (`:secrets_file`) shared across tests, so concurrent tests
  would clobber each other's store.
  """
  use ExUnit.Case, async: false

  alias Loopctl.Secrets.LocalFileAdapter

  setup do
    path = Application.fetch_env!(:loopctl, :secrets_file)
    File.rm(path)
    on_exit(fn -> File.rm(path) end)
    %{path: path}
  end

  test "set then get round-trips a raw binary value (not just strings)" do
    value = :crypto.strong_rand_bytes(32)
    assert :ok = LocalFileAdapter.set("TENANT_AUDIT_KEY_ACME", value)
    assert {:ok, ^value} = LocalFileAdapter.get("TENANT_AUDIT_KEY_ACME")
  end

  test "get on a missing name returns :not_found" do
    assert {:error, :not_found} = LocalFileAdapter.get("NOPE")
  end

  test "get on a missing FILE is an empty store, not an error" do
    assert {:error, :not_found} = LocalFileAdapter.get("ANY")
  end

  test "delete removes a name" do
    :ok = LocalFileAdapter.set("K", "v")
    assert {:ok, "v"} = LocalFileAdapter.get("K")
    assert :ok = LocalFileAdapter.delete("K")
    assert {:error, :not_found} = LocalFileAdapter.get("K")
  end

  test "set overwrites an existing value and preserves other keys", %{path: _path} do
    :ok = LocalFileAdapter.set("A", "1")
    :ok = LocalFileAdapter.set("B", "2")
    :ok = LocalFileAdapter.set("A", "1-updated")

    assert {:ok, "1-updated"} = LocalFileAdapter.get("A")
    assert {:ok, "2"} = LocalFileAdapter.get("B")
  end

  test "the on-disk file is 0600 (owner-only)", %{path: path} do
    :ok = LocalFileAdapter.set("K", "v")
    %File.Stat{mode: mode} = File.stat!(path)
    # low 9 bits are the rwx perms; 0o600 = owner rw only.
    assert Bitwise.band(mode, 0o777) == 0o600
  end

  test "a corrupt (non-JSON) file is refused rather than silently treated as empty", %{path: path} do
    File.write!(path, "this is not json{")
    assert {:error, :corrupt_secrets_file} = LocalFileAdapter.get("K")
  end

  test "a non-string JSON value is reported as corrupt, not a FunctionClauseError crash", %{
    path: path
  } do
    # A hand-corrupted secrets.json where a value is a number (not base64 string).
    File.write!(path, Jason.encode!(%{"AUDIT_KEY" => 123}))
    assert {:error, :corrupt_secret} = LocalFileAdapter.get("AUDIT_KEY")
  end

  test "concurrent set/2 with distinct names never loses a key (write-lock serialization)" do
    # This is the load-bearing property of the `:global.trans/2` write lock: without
    # it, two concurrent read-modify-write cycles last-rename-wins-drop each other's
    # key — permanently breaking the losing tenant's audit-chain signing. Spawn many
    # concurrent writers of DISTINCT keys and assert every key survives.
    names = for n <- 1..25, do: "CONCURRENT_KEY_#{n}"

    names
    |> Task.async_stream(
      fn name -> :ok = LocalFileAdapter.set(name, "value-#{name}") end,
      max_concurrency: 25,
      timeout: 30_000
    )
    |> Stream.run()

    for name <- names do
      assert {:ok, value} = LocalFileAdapter.get(name)
      assert value == "value-#{name}"
    end
  end
end
