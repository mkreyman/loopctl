defmodule Loopctl.Llm.ShapeError do
  @moduledoc """
  The legible, agent-readable "the model could not produce the required
  structure" failure (US-41.3, AC-41.3.4).

  ## Why this exists

  Local models are materially weaker at structured output than Claude. The
  Anthropic-era impls were written against a model that reliably returns the
  requested JSON, so their tolerant parsers degrade a bad response to
  `{:ok, []}` or silently DROP the malformed items (see
  `Loopctl.Knowledge.ClaudeContentExtractor.normalize_article/1`, which returns
  `nil` for anything that doesn't validate and then filters it out). On a local
  endpoint that behaviour is wrong twice over: an ingestion that quietly produces
  zero articles looks like "nothing worth extracting" rather than "your model
  can't do this", and a half-valid response writes whatever survived the filter.

  So on the OpenAI-compatible path a shape failure is a CONFIGURATION problem,
  reported as one:

    * the reason NAMES the endpoint and the model, so an operator/agent knows
      exactly which configuration to change;
    * it is PERMANENT — `oban_result/1` maps it to `{:cancel, reason}`, never
      `{:error, _}`. A model that cannot produce the structure will not start
      producing it on attempt 2, and blind retries just burn `max_attempts` and
      re-POST the tenant's full document three more times;
    * no partial/malformed article is ever written.

  The details map is VALUE-FREE with respect to secrets: it carries the endpoint
  URL (not a secret — it is the tenant's own declared host, already echoed by the
  posture report), the model id and a bounded `reason` atom. It NEVER carries the
  provider response body or the API key, so it is safe to persist into
  `oban_jobs.errors` and to render into any API/tool result.
  """

  @typedoc "The bounded set of shape-failure reasons."
  @type reason ::
          :not_json
          | :not_a_list
          | :no_valid_items
          | :missing_required_fields
          | :missing_choices
          | :non_text_content

  @typedoc "The details a shape error carries. Secret-free by construction."
  @type details :: %{
          endpoint: String.t(),
          model: String.t(),
          reason: reason(),
          detail: String.t() | nil
        }

  @typedoc "The tagged shape-failure term."
  @type t :: {:invalid_response_shape, details()}

  @doc """
  True for a shape-failure term.

  A GUARD (not a plain function) so worker/executor call sites can match it in a
  function head, mirroring `Loopctl.Egress.is_egress_refusal/1`.
  """
  defguard is_shape_error(term)
           when is_tuple(term) and tuple_size(term) == 2 and
                  elem(term, 0) == :invalid_response_shape

  @doc """
  Builds the tagged shape-failure term for `endpoint` + `model`.

  `detail` is an OPTIONAL short, caller-authored clarification (e.g. "expected a
  JSON array of articles"). It must never be built from the provider response.
  """
  @spec new(String.t(), String.t(), reason(), String.t() | nil) :: t()
  def new(endpoint, model, reason, detail \\ nil)
      when is_binary(endpoint) and is_binary(model) and is_atom(reason) do
    {:invalid_response_shape, %{endpoint: endpoint, model: model, reason: reason, detail: detail}}
  end

  @doc """
  A one-line, agent-readable reason naming the endpoint and the model.

  This is what lands in `oban_jobs.cancelled_at` / `errors`, so it must be
  actionable from the record alone.
  """
  @spec message(t() | term()) :: String.t()
  def message({:invalid_response_shape, %{} = details}) do
    base =
      "invalid_response_shape: the configured chat model could not produce the " <>
        "required structure (reason=#{details.reason} endpoint=#{details.endpoint} " <>
        "model=#{details.model})"

    case details[:detail] do
      nil -> base <> ". This is a CONFIGURATION problem, not a transient failure."
      detail -> base <> " — " <> detail <> ". This is a CONFIGURATION problem."
    end
  end

  def message(other), do: inspect(other)

  @doc """
  The ONE mapping from a shape failure to an Oban worker result: always
  `{:cancel, message}` — never a retry (AC-41.3.4, "not retried blindly").
  """
  @spec oban_result(t()) :: {:cancel, String.t()}
  def oban_result({:invalid_response_shape, %{}} = term), do: {:cancel, message(term)}
end
