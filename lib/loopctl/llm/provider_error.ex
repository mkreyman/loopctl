defmodule Loopctl.Llm.ProviderError do
  @moduledoc """
  Shared, vendor-agnostic sanitizer for external LLM/embedding provider errors.

  Provider error RESPONSE BODIES routinely echo a masked fragment of the caller's
  API key (e.g. OpenAI's `"Incorrect API key provided: sk-...ZXY"`). If that raw
  body is returned as an Oban `{:error, reason}` it is persisted verbatim into
  `oban_jobs.errors` (a table without `tenant_llm_settings`' access controls, and
  already surfaced to tenants via `Knowledge.list_extraction_errors/2`), and if it
  is `inspect/1`-ed into a log line it leaks there too.

  `sanitize/1` returns a bounded, VALUE-FREE representation — it drops the body,
  keeping only the status (for retry/breaker classification). It is arity-preserving
  for the `{:api_error, status, body}` shape so existing 3-tuple matches keep working.
  Apply it at the boundary in BOTH `Loopctl.Llm.Anthropic` and
  `Loopctl.Knowledge.EmbeddingClient`, AND at every worker boundary that turns an
  error term into an Oban `{:error, _}` / `{:discard, _}` reason, so nothing
  downstream ever sees a raw provider body.

  The ONLY way a tenant's API key reaches this function is inside a provider
  RESPONSE BODY — which always arrives either wrapped as `{:api_error, status,
  body}` (collapsed here) or, defensively, as a bare decoded body (a string or a
  map — also collapsed, review #6). A structured DOMAIN error tuple (e.g.
  `{:insert_failed, step, changeset}`, `{:url_blocked, reason}`) never contains the
  key and IS preserved — collapsing it would replace a precise operator-facing
  reason with a misleading `:provider_error`. Bare atoms (`:timeout`, `:no_api_key`)
  are inherently value-free and preserved.
  """

  @typedoc "A sanitized provider error term (never carries a response body)."
  @type t ::
          {:api_error, integer(), tag()}
          | {:api_error, integer(), tag(), non_neg_integer() | nil}
          | {:request_failed, atom()}
          | {:embedding_crash, :exception}
          | atom()
          | tuple()

  @typedoc """
  The closed set of value-free classifications a provider body may collapse to.

  A tag is a FIXED atom chosen by `classify/1`, never a fragment of the body — so
  keeping one is as safe as the bare `:provider_error` it replaces, and unlike it,
  says WHY.
  """
  @type tag :: :provider_error | :context_length_exceeded

  @tags [:provider_error, :context_length_exceeded]

  # Substrings that identify an input-too-long rejection. Matched case-insensitively
  # against the body's `error.message` and `error.code` only. Vendor-agnostic by
  # listing several spellings rather than by parsing a single provider's schema.
  @context_length_signatures [
    "maximum context length",
    "context_length_exceeded",
    "reduce the length",
    "string too long",
    "too many tokens",
    "input is too long"
  ]

  @doc """
  Classify a provider error body as one of the value-free `t:tag/0` atoms.

  This is the ONLY thing read out of a body and kept. It returns an atom from
  `@tags`, so no byte of the body (and therefore no masked key fragment) can reach
  a log line or `oban_jobs.errors` through it.

  Total and idempotent: an already-classified tag is returned unchanged, which is
  what lets `sanitize/1` run again at a worker boundary without downgrading a
  classification back to the generic `:provider_error` (the same idempotency the
  throttle 4-tuple needs).
  """
  @spec classify(term()) :: tag()
  def classify(tag) when tag in @tags, do: tag

  def classify(body) do
    case body_signal(body) do
      nil ->
        :provider_error

      text ->
        if Enum.any?(@context_length_signatures, &String.contains?(text, &1)),
          do: :context_length_exceeded,
          else: :provider_error
    end
  end

  # The classifiable surface of a body. Vendor-agnostic in SHAPE as well as in
  # spelling: OpenAI nests the text under `{"error" => %{"message" => ...}}`, but
  # OpenAI-COMPATIBLE servers a tenant may point `base_url` at answer with a bare
  # string body, a string-valued `"error"`, or a top-level `"detail"`/`"message"`
  # (vLLM, TEI, FastAPI gateways). Reading only the nested map left those providers
  # classified `:provider_error`, which discards a length rejection as permanent and
  # never runs the shrink ladder — the same hourly re-enqueue loop, one provider over.
  # Widening what is READ cannot widen what is KEPT: the output is still a fixed atom.
  defp body_signal(body) when is_binary(body), do: String.downcase(body)

  defp body_signal(body) when is_map(body) and not is_struct(body) do
    [body["error"], body["message"], body["detail"], body["code"]]
    |> Enum.flat_map(&signal_parts/1)
    |> case do
      [] -> nil
      parts -> parts |> Enum.join(" ") |> String.downcase()
    end
  end

  defp body_signal(_other), do: nil

  defp signal_parts(text) when is_binary(text), do: [text]

  defp signal_parts(err) when is_map(err) and not is_struct(err),
    do: Enum.filter([err["message"], err["code"]], &is_binary/1)

  defp signal_parts(_other), do: []

  @doc """
  Strip any provider response body/secret. Collapses the key-bearing provider
  shapes (and bare body strings/maps) to a value-free term; preserves bare atoms and
  structured domain-error tuples (which are provably key-free).
  """
  @spec sanitize(term()) :: t()
  # US-37.3: an already-sanitized throttle 4-tuple carries only a status + a
  # parsed Retry-After integer (both value-free) — preserve it idempotently so a
  # second sanitize pass at a worker boundary never drops the Retry-After.
  def sanitize({:api_error, status, tag, retry_after})
      when is_integer(status) and tag in @tags and
             (is_integer(retry_after) or is_nil(retry_after)),
      do: {:api_error, status, tag, retry_after}

  # `classify/1` is idempotent on a tag, so a second sanitize pass at a worker
  # boundary preserves `:context_length_exceeded` instead of flattening it — the
  # retry ladder in the embedding workers dispatches on exactly that atom.
  def sanitize({:api_error, status, body}) when is_integer(status),
    do: {:api_error, status, classify(body)}

  def sanitize({:api_error, status}) when is_integer(status),
    do: {:api_error, status, :provider_error}

  # A transport reason that is a bare atom (`:timeout`, `:closed`, `:econnrefused`)
  # is safe and useful — keep it. A struct/string/other reason could carry arbitrary
  # data, so collapse it to a value-free tag.
  def sanitize({:request_failed, reason}) when is_atom(reason), do: {:request_failed, reason}
  def sanitize({:request_failed, _reason}), do: {:request_failed, :transport_error}

  # A crash detail is an Exception.message string — collapse it.
  def sanitize({:embedding_crash, _detail}), do: {:embedding_crash, :exception}

  # A RAW provider body (the ONLY key-bearing shape besides {:api_error, ...}) can
  # only arrive as a bare string or a decoded JSON map — collapse both (review #6).
  # Structs are maps, but a struct only reaches here bare (never a domain error,
  # which is always a TUPLE); collapsing a stray bare struct body is correct.
  def sanitize(body) when is_binary(body) or is_map(body), do: :provider_error

  # Bare atoms and structured domain-error tuples are key-free — preserve them.
  def sanitize(other), do: other

  @doc """
  Sanitize an `{:api_error, status, body}` while attaching a parsed provider
  `Retry-After` (US-37.3). A `nil` Retry-After collapses to the arity-preserving
  3-tuple (unchanged legacy shape); a present one produces the throttle 4-tuple
  `{:api_error, status, :provider_error, retry_after}` that the breaker cooldown
  and Oban worker snooze read via `Loopctl.Provider.RetryAfter.from_error/1`.
  """
  @spec sanitize(term(), non_neg_integer() | nil) :: t()
  def sanitize(reason, nil), do: sanitize(reason)

  # `classify(body)`, not a literal `:provider_error`: a gateway can answer a throttle
  # with a body that still echoes the provider's length complaint, and flattening the
  # tag on THIS path would silently disable the shrink ladder while sanitize/1 keeps
  # it — the same downgrade the idempotency clause above exists to prevent.
  def sanitize({:api_error, status, body}, retry_after)
      when is_integer(status) and is_integer(retry_after),
      do: {:api_error, status, classify(body), retry_after}

  def sanitize({:api_error, status}, retry_after)
      when is_integer(status) and is_integer(retry_after),
      do: {:api_error, status, :provider_error, retry_after}

  # A Retry-After on any non-api_error shape is meaningless — sanitize normally.
  def sanitize(reason, _retry_after), do: sanitize(reason)

  @doc """
  A short, log-safe tag for a provider error (never includes a body). Accepts a
  bare error term or an `{:error, term}` tuple.
  """
  @spec log_tag(term()) :: String.t()
  def log_tag({:error, inner}), do: log_tag(inner)
  def log_tag({:api_error, status, body, _}), do: "api_error status=#{status} #{classify(body)}"
  def log_tag({:api_error, status, body}), do: "api_error status=#{status} #{classify(body)}"
  def log_tag({:api_error, status}), do: "api_error status=#{status}"
  def log_tag({:request_failed, _}), do: "request_failed"
  def log_tag({:embedding_crash, _}), do: "embedding_crash"
  def log_tag(atom) when is_atom(atom), do: to_string(atom)
  def log_tag(_other), do: "provider_error"
end
