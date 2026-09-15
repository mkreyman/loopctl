defmodule LoopctlRunner.Contract do
  @moduledoc """
  The loopctl runner wire contract, vendored from mkreyman/loopctl
  `priv/runner_contract/v1.json` (JSON Schema 2020-12, `x-contract-version` 1.5.0).

  The file is copied, never re-typed: the server casts every payload against the same
  document, drops unknown fields at every depth, and refuses a mismatched major version.
  Validating outgoing payloads here turns a refusal the server would log into a test
  failure on this side.

  The validator covers exactly the keywords the contract uses — `type`, `required`,
  `properties`, `minimum`, `maximum`, `minLength`, `maxLength`, `pattern`, `enum`,
  `items`, `minItems`, `maxItems`, `uniqueItems`, `minProperties`, `additionalProperties` in all
  three of its forms, and `format` for the two formats it uses, `uuid` and `date-time`.
  A keyword or format it does not know fails the validation rather than being
  skipped, so a contract that grows a new constraint cannot be silently under-checked: loopctl
  casts ids as UUIDs, and a malformed one passing here would only surface as a refusal there.
  """

  @external_resource Path.expand("../../priv/runner_contract/v1.json", __DIR__)
  @schema @external_resource |> File.read!() |> Jason.decode!()

  # A keyword is implemented here BEFORE loopctl can publish it: an unimplemented one fails
  # validation, so a definition carrying it would refuse every payload on this side. That cost
  # 1.6.0 its `kinds` constraints — loopctl enforced minItems and uniqueItems while its exporter
  # dropped them, leaving the wire stricter than the published document. These two are here so
  # the exported set can carry them again.
  @known ~w(type required properties minimum maximum minLength maxLength pattern enum items
            minItems maxItems uniqueItems minProperties description format additionalProperties)

  @doc "Every keyword the validator implements. A keyword outside this list fails validation."
  @spec known_keywords() :: [String.t()]
  def known_keywords, do: @known

  @spec version() :: String.t()
  def version, do: Map.fetch!(@schema, "x-contract-version")

  @spec connection() :: map()
  def connection, do: Map.fetch!(@schema, "x-connection")

  @doc "One `$defs` entry of the vendored contract, e.g. \"RunnerStory\"."
  @spec schema_def(String.t()) :: map()
  def schema_def(name), do: Map.fetch!(Map.fetch!(@schema, "$defs"), name)

  @doc "Validates `payload` (string keys) against a `$defs` entry, e.g. \"RunnerJoin\"."
  @spec validate(String.t(), term()) :: :ok | {:error, [String.t()]}
  def validate(definition, payload) do
    schema =
      get_in(@schema, ["$defs", definition]) || raise ArgumentError, "no $defs #{definition}"

    validate_against(schema, payload, definition)
  end

  @doc """
  Validates `value` against an inline `schema` from the contract, naming it `path` in errors.

  `validate/2` is this with a `$defs` entry looked up by name. Taking a schema directly is what
  lets a keyword be tested on a constraint the vendored file does not happen to use yet, which
  is the order this validator needs: implemented here first, published by loopctl second.
  """
  @spec validate_against(map(), term(), String.t()) :: :ok | {:error, [String.t()]}
  def validate_against(schema, value, path \\ "value") do
    case check(schema, value, path) do
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

  defp keyword("minItems", min, value, path, _) when is_list(value),
    do: if(length(value) < min, do: ["#{path}: fewer than #{min} items"], else: [])

  # JSON value equality, not term equality: 1 and 1.0 are the same JSON number, so a list
  # holding both is not unique. Enum.uniq/1 would call them different and under-check.
  defp keyword("uniqueItems", unique?, value, path, _) when is_list(value) do
    if unique? and Enum.uniq_by(value, &json_value/1) != value,
      do: ["#{path}: items are not unique"],
      else: []
  end

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

  # The vendored file says true in both places it appears, and true is the JSON Schema default,
  # so this only bites when loopctl tightens a definition — which is exactly when the runner must
  # refuse the payload here rather than have loopctl refuse it on the wire. All three legal forms
  # are handled: false refuses any property `properties` does not name, a subschema validates
  # each of them, and true allows them.
  defp keyword("additionalProperties", allowed, value, path, schema) when is_map(value) do
    extra = Map.keys(value) -- Map.keys(Map.get(schema, "properties", %{}))

    case allowed do
      false when extra != [] ->
        ["#{path}: has #{Enum.join(Enum.sort(extra), ", ")}, which the schema does not allow"]

      sub when is_map(sub) ->
        Enum.flat_map(Enum.sort(extra), &check(sub, Map.fetch!(value, &1), "#{path}.#{&1}"))

      _allowed ->
        []
    end
  end

  # Annotations, and keywords whose value type does not apply to this instance.
  defp keyword(_keyword, _arg, _value, _path, _schema), do: []

  # 1 and 1.0 are the same JSON number, so an integral float compares as its integer. Exact and
  # total: `n / 1` raises on a bignum and collapses distinct integers above 2^53.
  defp json_value(n) when is_integer(n), do: {:number, n}

  defp json_value(n) when is_float(n) do
    truncated = trunc(n)
    if truncated == n, do: {:number, truncated}, else: {:number, n}
  end

  defp json_value(list) when is_list(list), do: Enum.map(list, &json_value/1)
  defp json_value(map) when is_map(map), do: Map.new(map, fn {k, v} -> {k, json_value(v)} end)
  defp json_value(other), do: other

  defp type?("object", v), do: is_map(v)
  defp type?("array", v), do: is_list(v)
  defp type?("string", v), do: is_binary(v)
  defp type?("integer", v), do: is_integer(v)
  defp type?("number", v), do: is_number(v)
  defp type?("boolean", v), do: is_boolean(v)
  defp type?("null", v), do: is_nil(v)
end
