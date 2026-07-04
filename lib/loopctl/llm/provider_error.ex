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
          {:api_error, integer(), :provider_error}
          | {:request_failed, atom()}
          | {:embedding_crash, :exception}
          | atom()
          | tuple()

  @doc """
  Strip any provider response body/secret. Collapses the key-bearing provider
  shapes (and bare body strings/maps) to a value-free term; preserves bare atoms and
  structured domain-error tuples (which are provably key-free).
  """
  @spec sanitize(term()) :: t()
  def sanitize({:api_error, status, _body}) when is_integer(status),
    do: {:api_error, status, :provider_error}

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
  A short, log-safe tag for a provider error (never includes a body). Accepts a
  bare error term or an `{:error, term}` tuple.
  """
  @spec log_tag(term()) :: String.t()
  def log_tag({:error, inner}), do: log_tag(inner)
  def log_tag({:api_error, status, _}), do: "api_error status=#{status}"
  def log_tag({:api_error, status}), do: "api_error status=#{status}"
  def log_tag({:request_failed, _}), do: "request_failed"
  def log_tag({:embedding_crash, _}), do: "embedding_crash"
  def log_tag(atom) when is_atom(atom), do: to_string(atom)
  def log_tag(_other), do: "provider_error"
end
