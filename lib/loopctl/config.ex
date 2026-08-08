defmodule Loopctl.Config do
  @moduledoc """
  Boot-time environment-variable parsing shared by `config/runtime.exs`.

  Lives in `lib/` (like `Loopctl.ObanConfig`) rather than inline in `runtime.exs` so the
  semantics can be pinned by a test: `runtime.exs` is `config_env() == :prod`-guarded and
  is therefore never evaluated by the suite.
  """

  alias Cloak.Ciphers.AES.GCM

  # Only these disable an opt-out flag. Kept deliberately small — see `opt_out_enabled?/1`.
  @disable_values ~w(false 0)

  @doc """
  Parses an opt-OUT boolean env VALUE: `true` unless the value is `false` or `0`
  (surrounding whitespace trimmed, case-insensitive). `nil` (unset) is `true`.

  Takes the VALUE, not the variable name — the caller keeps the `System.get_env/1` read.
  That used to be load-bearing (`mix loopctl.check_env_docs` scanned only `runtime.exs`,
  so a read moved in here fell out of the guard); since #566 the guard scans `lib/` too,
  and either placement stays guarded.

  Deliberately ASYMMETRIC with the `in ~w(true 1)` opt-IN vars in `runtime.exs`. It is
  for switches whose safe failure mode is ON (`SCALE_ALERTS_ENABLED`, #376): an unset,
  empty or mistyped value must leave the thing ENABLED, where its guard is still
  watching, never silently off. Do not "normalize" this to the opt-in shape.
  """
  @spec opt_out_enabled?(String.t() | nil) :: boolean()
  def opt_out_enabled?(nil), do: true

  def opt_out_enabled?(value) when is_binary(value) do
    normalized = value |> String.trim() |> String.downcase()

    normalized not in @disable_values
  end

  # The cipher tag stamped into every ciphertext header written before CLOAK_KEY_TAG
  # existed. Kept as the default so an install that never rotates is byte-identical.
  @cloak_default_tag "AES.GCM.V1"

  # Cloak.Ciphers.AES.GCM hardcodes :aes_256_gcm, so anything but a 32-byte key fails at
  # the FIRST encrypt/decrypt rather than at boot. Checked here so it fails at boot.
  @cloak_key_bytes 32

  # A retired key exists to be re-encrypted AWAY from. More than a handful means the
  # re-encryption pass is not being run, which is a backlog to work off, not a config to
  # grow — and every entry is a linear probe on every decrypt.
  @cloak_max_retired_keys 16

  # Positional labels for retired ciphers, written LITERALLY rather than interpolated.
  # `cloak_ciphers!/3` already caps entries at @cloak_max_retired_keys, so zipping against
  # this list can never truncate. The assertion below keeps the two from drifting.
  @retired_labels [
    :retired_0,
    :retired_1,
    :retired_2,
    :retired_3,
    :retired_4,
    :retired_5,
    :retired_6,
    :retired_7,
    :retired_8,
    :retired_9,
    :retired_10,
    :retired_11,
    :retired_12,
    :retired_13,
    :retired_14,
    :retired_15
  ]

  length(@retired_labels) == @cloak_max_retired_keys ||
    raise "@retired_labels must carry exactly @cloak_max_retired_keys entries"

  @doc "The cipher tag used when `CLOAK_KEY_TAG` is unset."
  @spec cloak_default_tag() :: String.t()
  def cloak_default_tag, do: @cloak_default_tag

  @doc """
  Builds the vault's `:ciphers` list from the CLOAK_* env VALUES (never the names —
  the `System.get_env/1` reads stay in `config/runtime.exs`, under the env-docs guard).

  The active key is first, which is what Cloak encrypts new writes with
  (`Cloak.Vault.encrypt/2` takes `hd(ciphers)`, NOT the `:default` label). Every retired
  key follows and is decrypt-only.

  `retired` is a comma-separated list of `TAG:BASE64_KEY` entries, matching how
  `CLOAK_KEY` itself is encoded (base64 of 32 raw bytes) with the ciphertext-header tag
  prefixed. Standard base64 uses none of `,` or `:`, so neither separator is ambiguous.

  ## Why the tag is part of the entry, and why a collision raises

  Cloak picks a decrypt cipher by matching the TAG in the ciphertext header
  (`Cloak.Vault.find_module_to_decrypt/2` -> `AES.GCM.can_decrypt?/2`), and it takes the
  FIRST match. Two ciphers sharing a tag are therefore indistinguishable: rows written
  under the older key would be handed to the newer key, fail the GCM auth check, and read
  as corrupt. So a rotation MUST bump `CLOAK_KEY_TAG` alongside `CLOAK_KEY`, and a retired
  entry reusing the active tag raises here — at boot, loudly — instead of surfacing later
  as unreadable rows.

  Every malformed entry raises for the same reason: a dropped retired key is not a
  degraded config, it is data nobody can decrypt.
  """
  @spec cloak_ciphers!(String.t(), String.t() | nil, String.t() | nil) :: keyword()
  def cloak_ciphers!(active_key, active_tag \\ nil, retired \\ nil) do
    tag = cloak_tag!(active_tag)
    active = cloak_cipher(tag, cloak_key!(active_key, "CLOAK_KEY"))

    [default: active] ++ cloak_retired_ciphers!(retired, tag)
  end

  @doc """
  Parses `CLOAK_RETIRED_KEYS` into decrypt-only cipher entries, rejecting `active_tag`.

  Public so `cloak_ciphers!/3`'s validation can be exercised on its own; prefer
  `cloak_ciphers!/3` at a call site, which is what pins the active cipher to position 0.
  """
  @spec cloak_retired_ciphers!(String.t() | nil, String.t()) :: keyword()
  def cloak_retired_ciphers!(nil, _active_tag), do: []
  def cloak_retired_ciphers!("", _active_tag), do: []

  def cloak_retired_ciphers!(retired, active_tag) when is_binary(retired) do
    # Indexed BEFORE blanks are dropped, so the position every error message names is the
    # operator's own comma-separated field number. Counting survivors instead reported
    # "entry 1" for the third field of ",,TAG:KEY", which is not a position anyone can act on.
    entries =
      retired
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.with_index(1)
      |> Enum.reject(fn {entry, _position} -> entry == "" end)

    if entries == [] do
      raise ArgumentError,
            "CLOAK_RETIRED_KEYS is set but names no entries — every comma-separated field is " <>
              "blank. A deploy that built the value from an empty list must UNSET the variable; " <>
              "accepting it as 'no retired keys' is how a dropped key becomes undecryptable rows."
    end

    if length(entries) > @cloak_max_retired_keys do
      raise ArgumentError,
            "CLOAK_RETIRED_KEYS carries #{length(entries)} entries, more than the " <>
              "#{@cloak_max_retired_keys} allowed. Run mix loopctl.reencrypt_secrets and drop " <>
              "the keys no ciphertext still uses."
    end

    entries
    |> Enum.map(&parse_retired_entry!(&1, active_tag))
    |> reject_duplicate_tags!()
  end

  defp parse_retired_entry!({entry, position}, active_tag) do
    case String.split(entry, ":", parts: 2) do
      [tag, key] ->
        tag = String.trim(tag)
        validate_retired_tag!(tag, position, active_tag)

        {tag,
         cloak_cipher(tag, cloak_key!(String.trim(key), "CLOAK_RETIRED_KEYS entry #{position}"))}

      _no_separator ->
        raise ArgumentError,
              "CLOAK_RETIRED_KEYS entry #{position} is not TAG:BASE64_KEY (no ':' found). " <>
                "Each entry names the cipher tag its ciphertext carries, e.g. " <>
                "#{@cloak_default_tag}:BASE64_OF_32_RAW_BYTES."
    end
  end

  defp validate_retired_tag!("", position, _active_tag) do
    raise ArgumentError, "CLOAK_RETIRED_KEYS entry #{position} has a blank tag."
  end

  defp validate_retired_tag!(tag, position, active_tag) when tag == active_tag do
    raise ArgumentError,
          "CLOAK_RETIRED_KEYS entry #{position} reuses the ACTIVE tag #{tag}. Cloak matches a " <>
            "decrypt cipher by tag and takes the first hit, so two ciphers sharing one tag make " <>
            "the older key's rows unreadable. Bump CLOAK_KEY_TAG when you rotate CLOAK_KEY."
  end

  defp validate_retired_tag!(_tag, _position, _active_tag), do: :ok

  defp reject_duplicate_tags!(entries) do
    duplicates =
      entries
      |> Enum.map(fn {tag, _cipher} -> tag end)
      |> Enum.frequencies()
      |> Enum.filter(fn {_tag, count} -> count > 1 end)
      |> Enum.map(fn {tag, _count} -> tag end)

    if duplicates != [] do
      raise ArgumentError,
            "CLOAK_RETIRED_KEYS repeats the tag(s) #{Enum.join(duplicates, ", ")}. Only the " <>
              "first cipher for a tag is ever tried, so the rest are silently dead."
    end

    # Labels are positional and never derived from operator input. They are taken from a
    # LITERAL list rather than interpolated (`:"retired_#{index}"`) so that no atom is
    # constructed at runtime at all: interpolation here was bounded in practice — the index
    # comes from Enum.with_index/1, not from the operator's string — but "bounded because
    # of where the number came from" is an argument a reader has to re-derive, and Sobelow's
    # DOS.BinToAtom check cannot see it either. A literal table makes it structural.
    # The label itself is inert: Cloak resolves one only for `encrypt/2, label`, which
    # nothing here calls.
    entries
    |> Enum.zip(@retired_labels)
    |> Enum.map(fn {{_tag, cipher}, label} -> {label, cipher} end)
  end

  defp cloak_tag!(nil), do: @cloak_default_tag

  defp cloak_tag!(tag) when is_binary(tag) do
    case String.trim(tag) do
      "" -> @cloak_default_tag
      trimmed -> trimmed
    end
  end

  defp cloak_cipher(tag, key) do
    {GCM, tag: tag, key: key, iv_length: 12}
  end

  defp cloak_key!(encoded, source) do
    case Base.decode64(encoded) do
      {:ok, key} when byte_size(key) == @cloak_key_bytes ->
        key

      {:ok, key} ->
        raise ArgumentError,
              "#{source} decodes to #{byte_size(key)} bytes; AES-256-GCM needs " <>
                "#{@cloak_key_bytes}. Generate one with: " <>
                ":crypto.strong_rand_bytes(#{@cloak_key_bytes}) |> Base.encode64()"

      :error ->
        raise ArgumentError,
              "#{source} is not valid base64. (The value is not echoed here — it is key " <>
                "material.) Generate one with: " <>
                ":crypto.strong_rand_bytes(#{@cloak_key_bytes}) |> Base.encode64()"
    end
  end
end
