[
  # Upstream Ecto.Multi + MapSet opaque-type warnings pre-existing on
  # `research/chain-of-custody-v2`. The `%Ecto.Multi{}` and `%MapSet{}`
  # structs were made opaque in recent versions of Ecto / Elixir so
  # every `Multi.new() |> Multi.insert(...) |> Multi.update(...)` chain
  # and every `MapSet.put(set, node)` call trips dialyzer. 50+ sites
  # across the codebase. US-26.0.1 introduces no net-new warnings
  # (baseline had a matching `auth.ex:80` site that US-26.0.1 replaced
  # with `tenants.ex:97`).
  #
  # Fix tracked at Ecto upstream — once Ecto ships a non-opaque
  # version, remove this file. Regex targets the specific warning
  # types so any other dialyzer issue still fails the build.
  ~r/call_without_opaque/,
  ~r/call_with_opaque/
]
