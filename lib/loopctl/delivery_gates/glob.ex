defmodule Loopctl.DeliveryGates.Glob do
  @moduledoc """
  The path matcher behind Gate B's triggers, compiled once and matched many times.

  Semantics, and nothing else:

  - `**` matches any run of characters INCLUDING `/`
  - `*` matches any run of characters EXCEPT `/`
  - `?` matches exactly one character that is not `/`
  - every other character is literal (so `.`, `[`, `{` carry no meaning)

  Matching is anchored at both ends and case-sensitive, because `git ls-files` output is.

  Two refinements, both of which only ever make a pattern match MORE paths, never fewer:

  - `/**/` also matches a single `/`, so `lib/**/data_migrations/**` catches
    `lib/data_migrations/x.ex` as well as `lib/app/data_migrations/x.ex`
  - a leading `**/` also matches nothing, so `**/runtime.exs` catches a root-level
    `runtime.exs`

  Read literally, `**` = "any characters" would require the slashes on both sides of it to
  be present. A trigger is a guard, and a pattern that silently misses the shallowest
  instance of what it names is a leak; widening is the fail-closed direction.
  """

  @enforce_keys [:source, :regex]
  defstruct [:source, :regex]

  @type t :: %__MODULE__{source: String.t(), regex: Regex.t()}

  # Order matters: the longer, more specific tokens must be tried before `**` and `*`.
  @token ~r{/\*\*/|\A\*\*/|\*\*|\*|\?}

  @doc """
  Compiles a pattern. A non-binary, empty, or non-UTF-8 pattern is `{:error, :invalid_pattern}`.
  """
  @spec compile(term()) :: {:ok, t()} | {:error, :invalid_pattern}
  def compile(pattern) when is_binary(pattern) and pattern != "" do
    if String.valid?(pattern) do
      body =
        @token
        |> Regex.split(pattern, include_captures: true, trim: true)
        |> Enum.map_join(&fragment/1)

      # `s` so `**` crosses a newline in a path too; `u` so `?` is one codepoint, not one byte.
      {:ok, %__MODULE__{source: pattern, regex: Regex.compile!("\\A" <> body <> "\\z", "su")}}
    else
      {:error, :invalid_pattern}
    end
  end

  def compile(_pattern), do: {:error, :invalid_pattern}

  @doc """
  Whether `path` matches the compiled pattern. A non-binary path never matches.
  """
  @spec match?(t(), term()) :: boolean()
  def match?(%__MODULE__{regex: regex}, path) when is_binary(path) do
    String.valid?(path) and Regex.match?(regex, path)
  end

  def match?(%__MODULE__{}, _path), do: false

  defp fragment("/**/"), do: "(?:/|/.*/)"
  defp fragment("**/"), do: "(?:.*/)?"
  defp fragment("**"), do: ".*"
  defp fragment("*"), do: "[^/]*"
  defp fragment("?"), do: "[^/]"
  defp fragment(literal), do: Regex.escape(literal)
end
