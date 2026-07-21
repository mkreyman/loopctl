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
    6. hardens every candidate: byte-caps `text`, caps `tags` and `cross_links`,
       and validates every `cross_link` to be an article VISIBLE to the compiling
       subject (in-tenant AND not another agent's private/owner article — dropping
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
        cross_links: [Ecto.UUID.t()] # subject-visible in-tenant article ids (may be [])
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

  require Logger

  alias Loopctl.Knowledge
  alias Loopctl.Memory
  alias Loopctl.Memory.Memory, as: MemorySchema
  alias Loopctl.Memory.Scope

  @default_confidence_threshold 0.5
  @default_max_candidates 5
  @max_tags 20
  # Cross_links come from attacker-influenced session content, so cap their count
  # per candidate for symmetry with the byte-capped `text` and the count-capped
  # `tags` — an LLM coaxed into emitting thousands of UUIDs can't produce an
  # unbounded `a.id IN (...)` validation query.
  @max_cross_links 20

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

  @doc """
  Returns the idempotency FINGERPRINT of a session WITHOUT calling the LLM.

  Used by US-29.2's promotion watermark: the `content_hash` is a deterministic
  SHA-256 hex over the SAME assembled turns `compile/2` would send to the LLM (same
  ordering, same read window), so an unchanged session hashes identically across runs
  and is skipped. `last_turn_inserted_at` is the newest loaded turn's insert time and
  `last_turn_seq` its monotonic `seq` — together a cheap pre-filter for the sweep
  (`seq` tiebreaks a turn appended at the same microsecond as the stored watermark).
  `turn_count` is how many turns were assembled.

  A session with no turns yields the hash of the empty string, a nil
  `last_turn_inserted_at`, and a nil `last_turn_seq`. This never calls the LLM and never
  crosses scope (its `session_history/2` read is scope-enforced).
  """
  @spec session_fingerprint(Scope.t(), String.t()) :: %{
          content_hash: String.t(),
          last_turn_inserted_at: DateTime.t() | nil,
          last_turn_seq: integer() | nil,
          turn_count: non_neg_integer()
        }
  def session_fingerprint(%Scope{} = scope, session_id) when is_binary(session_id) do
    turns = load_turns(scope, session_id)
    content = assemble_content(turns)
    last_turn = List.last(turns)

    %{
      content_hash: :sha256 |> :crypto.hash(content) |> Base.encode16(case: :lower),
      last_turn_inserted_at: turn_inserted_at(last_turn),
      last_turn_seq: turn_seq(last_turn),
      turn_count: length(turns)
    }
  end

  defp turn_seq(nil), do: nil
  defp turn_seq(%{seq: seq}), do: seq

  defp turn_inserted_at(nil), do: nil
  defp turn_inserted_at(%{inserted_at: inserted_at}), do: inserted_at

  # Keep the read window pinned to Loopctl.Memory's list-limit ceiling. load_turns/2
  # keeps the MOST-RECENT window by issuing an offset query with `limit: @read_window`;
  # Memory.session_history clamps that limit to `max_list_limit()`. If @read_window
  # ever EXCEEDED that ceiling the offset query's limit would silently clamp down and
  # return a MIDDLE slice — dropping the most-recent turns (where durable decisions
  # accumulate) and breaking the temperature-0 idempotency US-29.2 depends on. Deriving
  # it from the source of truth makes the coupling explicit and regression-proof.
  @read_window Loopctl.Memory.max_list_limit()

  defp load_turns(scope, session_id) do
    # session_history/2 is scope-enforced: WHERE tenant_id AND session_id AND
    # subject_id — a foreign tenant/subject yields results: []. Cap the read so a
    # pathological session can't blow the LLM budget.
    #
    # session_history/2 orders oldest-first, so a naive `limit: @read_window` would
    # keep the OLDEST turns and drop everything after. Durable decisions/conclusions
    # accumulate toward the END of a session, so we deliberately keep the MOST-RECENT
    # `@read_window` turns (offset past the older ones) while preserving chronological
    # order. Small sessions (<= window) take a single query.
    %{results: results, meta: %{total_count: total}} =
      Memory.session_history(scope, session_id: session_id, limit: @read_window)

    if total > @read_window do
      %{results: recent} =
        Memory.session_history(scope,
          session_id: session_id,
          limit: @read_window,
          offset: total - @read_window
        )

      recent
    else
      results
    end
  end

  defp compile_turns(scope, turns) do
    content = assemble_content(turns)

    # US-41.4 (AC-41.4.2): the session content is POSTed to the model provider, so
    # the call carries the memory scope's PROJECT (a partition key on the memory
    # scope, but a real egress scope here) — a project-only `local_only` marking
    # must refuse promotion just as it refuses ingestion.
    egress_scope = Loopctl.Egress.Scope.new(scope.tenant_id, scope.project_id)

    with {:ok, text} <- llm().extract(egress_scope, content, []),
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

  # Structurally clean the cross_links list: keep only well-formed UUIDs, KEEPING
  # the canonical (lowercase) cast result — not the original string. Tenant-ownership
  # validation later compares against `select a.id`, which returns canonical lowercase
  # ids; keeping the original case here would silently drop an in-tenant link the LLM
  # happened to emit in uppercase/mixed case. Tenant-ownership validation happens later
  # (batched).
  defp collect_cross_link_ids(links) when is_list(links) do
    links
    |> Enum.flat_map(fn v ->
      case Ecto.UUID.cast(v) do
        {:ok, id} -> [id]
        :error -> []
      end
    end)
    |> Enum.uniq()
    |> Enum.take(@max_cross_links)
  end

  defp collect_cross_link_ids(_), do: []

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

  # Validate every candidate's cross_links against the CALLER's tenant AND its
  # article visibility in ONE batched query, then drop any id not visible to the
  # compiling subject (foreign-tenant, non-existent, OR another agent's
  # private/owner article #163) — never stored. Delegates to
  # `Loopctl.Knowledge.visible_article_ids/3` (the Knowledge context owns the
  # Article schema), keeping tenant-scoped article validation with the context that
  # owns it rather than reaching across the boundary.
  #
  # We thread `scope.subject_id` as the visibility agent id, mirroring
  # `LoopctlWeb.ChangeController.filter_visible_changes/3` ("a link can't leak a
  # private memory's id/edge"). For an agent-role key the subject IS the verified
  # `agent_id` that Knowledge stamps into `metadata.agent_id`
  # (`Loopctl.Memory.subject_id_for/1` ⇔ `ArticleController.bind_agent_identity/2`),
  # so an agent can cross-link only shared articles plus its OWN private/owner
  # articles — closing the defense-in-depth gap where a promoted candidate could
  # otherwise carry an edge to another agent's private article in the same tenant.
  # For a higher-role subject (whose subject is its key id, never stamped as an
  # article `agent_id`) this restricts cross_links to shared articles — the safe
  # direction for attacker-influenced content.
  defp validate_cross_links(candidates, scope) do
    all_ids =
      candidates
      |> Enum.flat_map(& &1.cross_links)
      |> Enum.uniq()

    valid_ids = Knowledge.visible_article_ids(scope.tenant_id, all_ids, scope.subject_id)

    Enum.map(candidates, fn candidate ->
      %{candidate | cross_links: Enum.filter(candidate.cross_links, &(&1 in valid_ids))}
    end)
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
