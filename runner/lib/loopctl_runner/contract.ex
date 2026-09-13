defmodule LoopctlRunner.Contract do
  @moduledoc """
  The loopctl runner wire contract, vendored from mkreyman/loopctl
  `priv/runner_contract/v1.json` (JSON Schema 2020-12, `x-contract-version` 1.1.0).

  The file is copied, never re-typed: the server casts every payload against the same
  document, drops unknown fields at every depth, and refuses a mismatched major version.
  Validating outgoing payloads here turns a refusal the server would log into a test
  failure on this side.

  The validator covers exactly the keywords the contract uses — `type`, `required`,
  `properties`, `minimum`, `maximum`, `minLength`, `maxLength`, `pattern`, `enum`,
  `items`, `maxItems`, `minProperties`, and `format` for the two formats it uses, `uuid` and
  `date-time`. A keyword or format it does not know fails the validation rather than being
  skipped, so a contract that grows a new constraint cannot be silently under-checked: loopctl
  casts ids as UUIDs, and a malformed one passing here would only surface as a refusal there.
  """

  @external_resource Path.expand("../../priv/runner_contract/v1.json", __DIR__)
  @schema @external_resource |> File.read!() |> Jason.decode!()

  @known ~w(type required properties minimum maximum minLength maxLength pattern enum items
            maxItems minProperties description format additionalProperties)

  @spec version() :: String.t()
  def version, do: Map.fetch!(@schema, "x-contract-version")

  @spec connection() :: map()
  def connection, do: Map.fetch!(@schema, "x-connection")

  @doc "Validates `payload` (string keys) against a `$defs` entry, e.g. \"RunnerJoin\"."
  @spec validate(String.t(), term()) :: :ok | {:error, [String.t()]}
  def validate(definition, payload) do
    schema =
      get_in(@schema, ["$defs", definition]) || raise ArgumentError, "no $defs #{definition}"

    case check(schema, payload, "#{definition}") do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  defp check(schema, value, path) do
    unknown = Map.keys(schema) -- @known

    if unknown != [] do
      ["#{path}: validator does not implement #{Enum.join(unknown, ", ")}"]
    else
      Enum.flat_map(schema, fn {keyword, arg} -> keyword(keyword, arg, value, path, schema) end)
    end
  end

  defp keyword("type", types, value, path, _schema) do
    if Enum.any?(List.wrap(types), &type?(&1, value)),
      do: [],
      else: ["#{path}: expected #{inspect(types)}, got #{inspect(value)}"]
  end

  defp keyword("required", keys, value, path, _schema) when is_map(value) do
    for key <- keys, not Map.has_key?(value, key), do: "#{path}: missing #{key}"
  end

  defp keyword("properties", props, value, path, _schema) when is_map(value) do
    Enum.flat_map(props, fn {key, sub} ->
      if Map.has_key?(value, key), do: check(sub, value[key], "#{path}.#{key}"), else: []
    end)
  end

  defp keyword("minimum", min, value, path, _) when is_number(value) and value < min,
    do: ["#{path}: below minimum #{min}"]

  defp keyword("maximum", max, value, path, _) when is_number(value) and value > max,
    do: ["#{path}: above maximum #{max}"]

  defp keyword("minLength", min, value, path, _) when is_binary(value),
    do: if(String.length(value) < min, do: ["#{path}: shorter than #{min}"], else: [])

  defp keyword("maxLength", max, value, path, _) when is_binary(value),
    do: if(String.length(value) > max, do: ["#{path}: longer than #{max}"], else: [])

  defp keyword("pattern", pattern, value, path, _) when is_binary(value) do
    if Regex.match?(Regex.compile!(pattern), value),
      do: [],
      else: ["#{path}: #{inspect(value)} does not match #{pattern}"]
  end

  defp keyword("enum", allowed, value, path, _) do
    if value in allowed, do: [], else: ["#{path}: #{inspect(value)} not in #{inspect(allowed)}"]
  end

  defp keyword("items", sub, value, path, _) when is_list(value) do
    value |> Enum.with_index() |> Enum.flat_map(fn {v, i} -> check(sub, v, "#{path}[#{i}]") end)
  end

  defp keyword("maxItems", max, value, path, _) when is_list(value),
    do: if(length(value) > max, do: ["#{path}: more than #{max} items"], else: [])

  defp keyword("format", "uuid", value, path, _) when is_binary(value) do
    if Regex.match?(~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i, value),
      do: [],
      else: ["#{path}: #{inspect(value)} is not a uuid"]
  end

  defp keyword("format", "date-time", value, path, _) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, _, _} -> []
      {:error, _} -> ["#{path}: #{inspect(value)} is not an RFC 3339 date-time"]
    end
  end

  defp keyword("format", format, _value, path, _) when format not in ["uuid", "date-time"],
    do: ["#{path}: validator does not implement format #{format}"]

  defp keyword("minProperties", min, value, path, _) when is_map(value),
    do: if(map_size(value) < min, do: ["#{path}: fewer than #{min} properties"], else: [])

  # Annotations, and keywords whose value type does not apply to this instance.
  defp keyword(_keyword, _arg, _value, _path, _schema), do: []

  defp type?("object", v), do: is_map(v)
  defp type?("array", v), do: is_list(v)
  defp type?("string", v), do: is_binary(v)
  defp type?("integer", v), do: is_integer(v)
  defp type?("number", v), do: is_number(v)
  defp type?("boolean", v), do: is_boolean(v)
  defp type?("null", v), do: is_nil(v)
end
