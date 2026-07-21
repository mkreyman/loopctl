defmodule Loopctl.Llm.ChatBaseUrl do
  @moduledoc """
  The ONE shape validator + normalizer for the tenant-supplied `chat_base_url`
  (US-41.3 review).

  `Loopctl.Llm.TenantLlmSettings` (write-time validation) and
  `Loopctl.Llm.ChatProbe` (pre-write probe + endpoint-change detection) both went
  through their own copy of "scheme is http(s) and host is non-empty". Two copies
  of a URL rule drift, and they had already drifted from what the client actually
  does with the value: `Loopctl.Llm.OpenAiChat.completions_url/1` blindly appends
  `/chat/completions`, so a base carrying a query string or fragment produces a
  URL the tenant never intended (`https://host/v1?api-key=SECRET/chat/completions`)
  and surfaces as an opaque transport/4xx instead of a validation message.

  This module is therefore the single source of the SHAPE rules:

    * absolute `http`/`https` with a non-empty host;
    * BARE — no `userinfo`, no query string, no fragment. A credential embedded in
      the URL would additionally be persisted in plaintext (the column is NOT
      encrypted — `chat_base_url` is explicitly "not a secret"), written into the
      audit entry, echoed by `Loopctl.Llm.settings_view/1` and repeated in every
      probe error message;
    * bounded length;
    * normalized identically everywhere (trim + strip the trailing `/`), so a
      re-sent endpoint compares EQUAL to the stored one instead of reading as a
      host change.

  It is deliberately NOT an egress decision — locality/denylist stays in the one
  `Loopctl.Egress.Policy` (AC-41.4.9). `plaintext?/1` only reports the scheme; the
  policy consultation that gates it lives in `Loopctl.Llm.ChatProbe`.
  """

  @max_length 500

  @type reason :: :not_a_string | :invalid_url | :too_long | :url_not_bare

  @doc """
  Validates + normalizes a tenant-supplied chat base URL.

  Returns `{:ok, normalized}` (trimmed, trailing `/` stripped) or
  `{:error, reason}`. `normalize/1` is TOTAL — it never raises on garbage input.
  """
  @spec normalize(term()) :: {:ok, String.t()} | {:error, reason()}
  def normalize(value) when is_binary(value) do
    trimmed = value |> String.trim() |> String.trim_trailing("/")
    uri = URI.parse(trimmed)

    cond do
      String.length(trimmed) > @max_length ->
        {:error, :too_long}

      uri.scheme not in ["http", "https"] ->
        {:error, :invalid_url}

      not (is_binary(uri.host) and uri.host != "") ->
        {:error, :invalid_url}

      not is_nil(uri.userinfo) or not is_nil(uri.query) or not is_nil(uri.fragment) ->
        {:error, :url_not_bare}

      true ->
        {:ok, trimmed}
    end
  rescue
    # URI.parse/1 can raise on a few pathological inputs; a malformed URL is a
    # validation error, never a 500.
    _e -> {:error, :invalid_url}
  end

  def normalize(_value), do: {:error, :not_a_string}

  @doc """
  Normalizes for COMPARISON only: returns the normalized form when the value is a
  valid base URL, and the input unchanged otherwise (the caller's validator
  reports the real error).

  Used by `Loopctl.Llm.ChatProbe` so a PATCH re-sending the stored endpoint with a
  trailing slash or surrounding whitespace does not read as a host change and
  demand a credential acknowledgement for a no-op write.
  """
  @spec normalize_for_compare(term()) :: term()
  def normalize_for_compare(value) do
    case normalize(value) do
      {:ok, normalized} -> normalized
      {:error, _reason} -> value
    end
  end

  @doc "Whether `url` is PLAINTEXT http (as opposed to https)."
  @spec plaintext?(term()) :: boolean()
  def plaintext?(url) when is_binary(url), do: URI.parse(url).scheme == "http"
  def plaintext?(_url), do: false

  @doc "The maximum accepted length of a chat base URL."
  @spec max_length() :: pos_integer()
  def max_length, do: @max_length

  @doc "A human-readable message for a `normalize/1` failure reason."
  @spec message(reason()) :: String.t()
  def message(:not_a_string), do: "must be a string"

  def message(:too_long), do: "is too long (max #{@max_length} characters)"

  def message(:invalid_url),
    do:
      "must be an absolute http(s) URL naming the API base of an OpenAI-compatible " <>
        "server (the client appends /chat/completions)"

  def message(:url_not_bare),
    do:
      "must be a BARE API base URL — no query string, no fragment and no embedded " <>
        "credentials. The client appends /chat/completions to it, so a query or " <>
        "fragment would send the request somewhere you did not intend; and unlike " <>
        "chat_api_key this column is NOT encrypted, so a credential in the URL would " <>
        "be stored, audited and echoed back in plaintext"
end
