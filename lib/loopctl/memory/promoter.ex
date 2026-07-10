defmodule Loopctl.Memory.Promoter do
  @moduledoc """
  Memory promotion compiler core (Epic 29, Agent Memory Part 2 / auto-promotion).

  `compile/2` is a PURE function that turns a session's short-term turns into a
  small, bounded set of durable "candidate" facts, ready to be promoted to
  long-term memory by US-29.2. It:

    1. loads the session's short-term turns via `Loopctl.Memory.session_history/2`
       (scope-enforced on `(tenant_id, subject_id, session_id)`);
    2. short-circuits an empty or single-turn session to `{:ok, []}` WITHOUT an
       LLM call (cost guard, AC-29.1.7);
    3. sends the turns to the configured LLM (deterministically, framed as
       UNTRUSTED data) to extract structured candidates;
    4. defensively parses the response (fail-closed on malformed output);
    5. gates candidates by a configurable confidence threshold and caps the result
       to the top-N by confidence;
    6. hardens every candidate: byte-caps `text`, caps `tags`, and validates every
       `cross_link` to be an article id belonging to the CALLER's tenant (dropping
       any that fail);
    7. RETURNS `{:ok, [candidate]}`.

  It PERSISTS NOTHING and does NO dedupe — that is US-29.2.

  ## Candidate shape

  Each candidate is a map with atom keys:

      %{
        text: String.t(),          # the durable fact (byte-capped)
        when_to_apply: String.t(), # when the fact applies
        tags: [String.t()],        # capped list of tag strings
        confidence: float(),       # in [0.0, 1.0]
        cross_links: [Ecto.UUID.t()] # in-tenant article ids only (may be [])
      }

  ## Security

  Session content is ATTACKER-INFLUENCED. Defense is layered (see the wiki pattern
  "Auto-Extracted Knowledge Requires Defense-in-Depth"): the LLM system prompt
  frames the turns as untrusted data, and THIS module independently caps every
  field and validates cross_links against the caller's tenant. Neither layer is
  trusted alone. Isolation is `(tenant_id, subject_id)` — `project_id` is metadata
  only, never an isolation key (matches epic_28 US-28.2 AC-28.2.2).

  ## Determinism

  The LLM call uses `temperature: 0` and a fixed prompt, so the same session
  content yields the same candidates — a precondition for US-29.2's
  session-content-hash idempotency.
  """

  import Ecto.Query

  require Logger

  alias Loopctl.AdminRepo
  alias Loopctl.Knowledge.Article
  alias Loopctl.Memory
  alias Loopctl.Memory.Memory, as: MemorySchema
  alias Loopctl.Memory.Scope

  @default_confidence_threshold 0.5
  @default_max_candidates 5
  @max_tags 20

  @type candidate :: %{
          text: String.t(),
          when_to_apply: String.t(),
          tags: [String.t()],
          confidence: float(),
          cross_links: [Ecto.UUID.t()]
        }

  @doc """
  Compiles the session `session_id` in `scope` into durable memory candidates.

  Returns `{:ok, [candidate]}` on success (possibly `[]`), or `{:error, reason}`
  when the LLM call fails or its output cannot be parsed (fail-closed — never
  garbage candidates). Writes nothing.

  An empty or single-turn session short-circuits to `{:ok, []}` without an LLM
  call. A session belonging to another tenant/subject yields `{:ok, []}` (its
  scope-enforced `session_history/2` returns no rows, so the LLM is never called
  with foreign content).
  """
  @spec compile(Scope.t(), String.t()) :: {:ok, [candidate()]} | {:error, term()}
  def compile(%Scope{} = scope, session_id) when is_binary(session_id) do
    turns = load_turns(scope, session_id)

    # Cost guard + scope safety (AC-29.1.6 / AC-29.1.7): an empty or single-turn
    # session — including a foreign-scope session whose scope-enforced history is
    # empty — short-circuits BEFORE resolving or calling the LLM. There is nothing
    # durable to extract from 0/1 turns, and the LLM must never see foreign content.
    if length(turns) <= 1 do
      {:ok, []}
    else
      compile_turns(scope, turns)
    end
  end

  defp load_turns(scope, session_id) do
    # session_history/2 is scope-enforced: WHERE tenant_id AND session_id AND
    # subject_id — a foreign tenant/subject yields results: []. Cap the read so a
    # pathological session can't blow the LLM budget; oldest-first order is preserved.
    %{results: results} = Memory.session_history(scope, session_id: session_id, limit: 200)
    results
  end

  defp compile_turns(scope, turns) do
    content = assemble_content(turns)

    with {:ok, text} <- llm().extract(scope.tenant_id, content, []),
         {:ok, raw_candidates} <- parse_candidates(text) do
      candidates =
        raw_candidates
        |> Enum.map(&normalize_candidate/1)
        |> Enum.reject(&is_nil/1)
        |> gate_by_confidence()
        |> cap_to_top_n()
        |> validate_cross_links(scope)

      {:ok, candidates}
    end
  end

  # Assemble the ordered turns into a single delimited string. Each turn is
  # prefixed with its role so the model can distinguish user/assistant/fact turns;
  # the whole blob is treated as untrusted data by the LLM frame.
  defp assemble_content(turns) do
    Enum.map_join(turns, "\n", fn %{role: role, content: content} -> "[#{role}] #{content}" end)
  end

  # ===========================================================================
  # Defensive, fail-closed parser (AC-29.1.3)
  # ===========================================================================

  # Parse the assistant text into a list of raw candidate maps. Mirrors
  # ClaudeContentExtractor: strip markdown fences, JSON.decode, require a list,
  # and fail closed (never raise, never garbage) on anything malformed.
  defp parse_candidates(text) when is_binary(text) do
    text = strip_markdown_fences(text)

    case JSON.decode(text) do
      {:ok, list} when is_list(list) ->
        {:ok, list}

      {:ok, %{"candidates" => list}} when is_list(list) ->
        {:ok, list}

      {:ok, _other} ->
        Logger.warning("Loopctl.Memory.Promoter: unexpected JSON structure from LLM")
        {:error, :unexpected_llm_output}

      {:error, reason} ->
        Logger.warning("Loopctl.Memory.Promoter: JSON parse error (error=#{inspect(reason)})")
        {:error, {:json_parse_error, reason}}
    end
  end

  defp parse_candidates(_), do: {:error, :unexpected_llm_output}

  # Strip markdown code fences the model may wrap JSON in.
  defp strip_markdown_fences(text) do
    text
    |> String.trim()
    |> then(fn t ->
      if String.starts_with?(t, "```") do
        t
        |> String.replace(~r/\A```(?:json)?\s*\n?/, "")
        |> String.replace(~r/\n?```\s*\z/, "")
      else
        t
      end
    end)
  end

  # ===========================================================================
  # Normalization + per-field hardening (AC-29.1.5)
  # ===========================================================================

  # Normalize a raw LLM candidate map into the pinned candidate shape, applying
  # per-field caps. Returns nil (dropped) when the shape is unusable — a candidate
  # with no usable `text` or `confidence` is not promotable.
  defp normalize_candidate(raw) when is_map(raw) do
    text = raw["text"]
    confidence = normalize_confidence(raw["confidence"])

    if is_binary(text) and text != "" and confidence != nil do
      %{
        text: cap_text(text),
        when_to_apply: normalize_when_to_apply(raw["when_to_apply"]),
        tags: normalize_tags(raw["tags"]),
        confidence: confidence,
        # cross_links are collected here (structurally cleaned) and tenant-validated
        # in a single batched query after gating/capping.
        cross_links: collect_cross_link_ids(raw["cross_links"])
      }
    else
      nil
    end
  end

  defp normalize_candidate(_), do: nil

  # Byte-cap the text at the epic_28 memories.text cap so a candidate can never
  # exceed what the long-term store will accept. Truncate on a valid UTF-8
  # boundary so the result is never invalid UTF-8.
  defp cap_text(text) do
    max = MemorySchema.max_text_bytes()

    if byte_size(text) > max do
      truncate_bytes(text, max)
    else
      text
    end
  end

  # Take the largest UTF-8 prefix of `text` that fits in `max` bytes.
  defp truncate_bytes(text, max) do
    binary = binary_part(text, 0, max)

    case String.chunk(binary, :valid) do
      [] -> ""
      chunks -> chunks |> Enum.take_while(&String.valid?/1) |> Enum.join()
    end
  end

  defp normalize_when_to_apply(value) when is_binary(value), do: cap_text(value)
  defp normalize_when_to_apply(_), do: ""

  defp normalize_tags(tags) when is_list(tags) do
    tags
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.downcase/1)
    |> Enum.take(@max_tags)
  end

  defp normalize_tags(_), do: []

  # Coerce confidence into a float in [0.0, 1.0], or nil if unusable. A candidate
  # with no parseable confidence cannot be confidence-gated, so it is dropped.
  defp normalize_confidence(c) when is_float(c), do: clamp_confidence(c)
  defp normalize_confidence(c) when is_integer(c), do: clamp_confidence(c * 1.0)

  defp normalize_confidence(c) when is_binary(c) do
    case Float.parse(c) do
      {f, _} -> clamp_confidence(f)
      :error -> nil
    end
  end

  defp normalize_confidence(_), do: nil

  defp clamp_confidence(c), do: c |> max(0.0) |> min(1.0)

  # Structurally clean the cross_links list: keep only well-formed UUID strings.
  # Tenant-ownership validation happens later (batched).
  defp collect_cross_link_ids(links) when is_list(links) do
    links
    |> Enum.filter(&valid_uuid?/1)
    |> Enum.uniq()
  end

  defp collect_cross_link_ids(_), do: []

  defp valid_uuid?(value) when is_binary(value), do: match?({:ok, _}, Ecto.UUID.cast(value))
  defp valid_uuid?(_), do: false

  # ===========================================================================
  # Confidence gate + top-N cap (AC-29.1.4)
  # ===========================================================================

  defp gate_by_confidence(candidates) do
    threshold = confidence_threshold()
    Enum.filter(candidates, &(&1.confidence >= threshold))
  end

  # Cap to the top-N by confidence (descending). Ties keep a stable order.
  defp cap_to_top_n(candidates) do
    candidates
    |> Enum.sort_by(& &1.confidence, :desc)
    |> Enum.take(max_candidates())
  end

  # ===========================================================================
  # cross_link tenant validation (AC-29.1.5)
  # ===========================================================================

  # Validate every candidate's cross_links against the CALLER's tenant in ONE
  # batched query, then drop any id not owned by the tenant (foreign-tenant or
  # non-existent) — never stored. Mirrors `Loopctl.Knowledge.get_article/3`'s
  # AdminRepo tenant-scoped lookup, batched across all surviving candidates.
  defp validate_cross_links(candidates, scope) do
    all_ids =
      candidates
      |> Enum.flat_map(& &1.cross_links)
      |> Enum.uniq()

    valid_ids = in_tenant_article_ids(all_ids, scope.tenant_id)

    Enum.map(candidates, fn candidate ->
      %{candidate | cross_links: Enum.filter(candidate.cross_links, &(&1 in valid_ids))}
    end)
  end

  defp in_tenant_article_ids([], _tenant_id), do: MapSet.new()

  defp in_tenant_article_ids(ids, tenant_id) do
    Article
    |> where([a], a.id in ^ids and a.tenant_id == ^tenant_id)
    |> select([a], a.id)
    |> AdminRepo.all()
    |> MapSet.new()
  end

  # ===========================================================================
  # Config-based DI + tunables
  # ===========================================================================

  # Resolve the LLM impl exactly like `merge_synthesizer/0` in Loopctl.Knowledge.
  defp llm do
    Application.get_env(:loopctl, :promoter_llm, Loopctl.Memory.Promoter.DefaultLLM)
  end

  @doc "Confidence threshold below which candidates are dropped (default #{@default_confidence_threshold})."
  @spec confidence_threshold() :: float()
  def confidence_threshold do
    Application.get_env(
      :loopctl,
      :memory_promotion_confidence_threshold,
      @default_confidence_threshold
    )
  end

  @doc "Maximum number of candidates returned (top-N by confidence; default #{@default_max_candidates})."
  @spec max_candidates() :: pos_integer()
  def max_candidates do
    Application.get_env(:loopctl, :memory_promotion_max_candidates, @default_max_candidates)
  end
end
