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
  `Loopctl.Knowledge.EmbeddingClient` so nothing downstream ever sees a raw body.
  """

  @typedoc "A sanitized, value-free provider error term."
  @type t :: {:api_error, integer(), :provider_error} | term()

  @doc """
  Strip any provider response body, preserving only the status. Non-`api_error`
  terms pass through unchanged (transport reasons / atoms carry no secret).
  """
  @spec sanitize(term()) :: t()
  def sanitize({:api_error, status, _body}) when is_integer(status),
    do: {:api_error, status, :provider_error}

  def sanitize({:api_error, status}) when is_integer(status),
    do: {:api_error, status, :provider_error}

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
