defmodule Loopctl.Config do
  @moduledoc """
  Boot-time environment-variable parsing shared by `config/runtime.exs`.

  Lives in `lib/` (like `Loopctl.ObanConfig`) rather than inline in `runtime.exs` so the
  semantics can be pinned by a test: `runtime.exs` is `config_env() == :prod`-guarded and
  is therefore never evaluated by the suite.
  """

  # Only these disable an opt-out flag. Kept deliberately small — see `opt_out_enabled?/1`.
  @disable_values ~w(false 0)

  @doc """
  Parses an opt-OUT boolean env VALUE: `true` unless the value is `false` or `0`
  (surrounding whitespace trimmed, case-insensitive). `nil` (unset) is `true`.

  Takes the VALUE, not the variable NAME: `mix loopctl.check_env_docs` scans `runtime.exs`
  textually for `System.get_env("NAME")`, so the read must stay there to stay guarded.

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
end
