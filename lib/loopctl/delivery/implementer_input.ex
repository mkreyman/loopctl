defmodule Loopctl.Delivery.ImplementerInput do
  @moduledoc """
  Builds the input an implementer session receives — FROM A STORY ONLY (issue #804).

  This is the triage-to-implementer boundary, and it is the strongest control against
  prompt injection the delivery loop has: the implementer, the session with commit
  authority, never reads what a reporter wrote. Its input is the story the triage trio
  wrote. Reporter text reaches triage fenced as untrusted data
  (`Loopctl.Delivery.Untrusted`) and stops there.

  Two things make that hold in code rather than in intent:

  - `build/1` accepts a `Loopctl.WorkBreakdown.Story` and nothing else. An intake record,
    a map, or any other struct is a `FunctionClauseError`.
  - It reads an explicit ALLOWLIST of story fields: `number`, `title`, `description` and
    the text of each acceptance criterion. `metadata` is deliberately NOT on it: it is a
    free-form map, whole-map-replaced by `PATCH /api/v1/stories/:id`, and precisely where a
    careless writer would park an intake reference or a quote from the ticket.

  `test/loopctl/delivery/implementer_input_test.exs` seeds canary strings through a real
  signed webhook delivery, puts them in reach of a story every way this module could
  plausibly pick them up, and asserts none appears in the output. It also fails when an
  intake record's untrusted fields are named anywhere in `lib/` outside the modules that
  own the boundary, and when this module reads a story field off its allowlist.

  What this cannot stop: a triage session that copies reporter text VERBATIM into a
  story's title, description or criteria. That is the trio's output contract to hold, which
  is why reporter text reaches triage only fenced, and why an injection attempt escalates at
  intake, before triage ever runs.

  ## Two shapes, one allowlist

  `build/1` renders the prose an in-process caller reads. `story_object/2` builds the TYPED
  object a runner dispatch carries (contract 1.5.0): loopctl sends a runner fields, never a
  prompt, because a dispatch runs as that machine's user and a control plane able to hand a
  runner prose to execute is able to run anything on it. The runner composes its own prompt
  from the fields with its own template.

  Both read the same story allowlist, and `metadata` is on neither. That matters more for the
  object than for the prose: three of the object's fields — `test_cases`, `touches`,
  `domain_reference` — have no first-class column on `stories` yet, and `metadata` is exactly
  where a careless writer would park them. They are OPTIONS the dispatch composer passes from
  the triage output it holds, never a map read off the story.
  """

  alias Loopctl.ApiSpec.RunnerContract.ByteRule
  alias Loopctl.ApiSpec.RunnerContract.RunnerStory
  alias Loopctl.WorkBreakdown.Story

  @doc "The implementer's input for `story`. See the moduledoc for the field allowlist."
  @spec build(Story.t()) :: String.t()
  def build(%Story{} = story) do
    criteria =
      story.acceptance_criteria
      |> List.wrap()
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {criterion, index} ->
        "#{index}. #{criterion_text(criterion)}"
      end)

    """
    # Story #{story.number}: #{story.title}

    ## Description

    #{story.description}

    ## Acceptance criteria

    #{criteria}
    """
  end

  defp criterion_text(%{} = criterion) do
    criterion
    |> criterion_body()
    |> labelled(criterion_id(criterion))
  end

  defp criterion_text(other) when is_binary(other), do: other
  defp criterion_text(_other), do: ""

  defp criterion_id(criterion), do: Map.get(criterion, "id") || Map.get(criterion, :id)

  defp criterion_body(criterion) do
    Map.get(criterion, "description") || Map.get(criterion, :description) ||
      Map.get(criterion, "criterion") || Map.get(criterion, :criterion) || ""
  end

  # A criterion with no usable text is EMPTY however it is labelled. Prefixing an id onto
  # nothing produced "[AC-3] ", which reads as a criterion, clears the wire's `minLength: 1`,
  # and states no requirement — so the emptiness is judged on the text BEFORE the label is
  # attached, and `violations/1` names what this returns.
  defp labelled(text, id) do
    cond do
      String.trim(to_string(text)) == "" -> ""
      is_binary(id) and id != "" -> "[#{id}] #{text}"
      true -> to_string(text)
    end
  end

  @doc """
  The `RunnerStory` object an `implement` dispatch carries (contract 1.5.0), string-keyed so
  it drops straight into the dispatch payload.

  A pure function of the story row and `opts`, so the same story builds the same object every
  time: a re-dispatch of a `dispatch_id` whose push was dropped recomputes an identical
  payload rather than a second, different one.

  ## Options

  The three fields loopctl holds nowhere first-class, supplied by the dispatch composer from
  the triage output and NEVER read off the story's `metadata` (see the moduledoc):

  - `:test_cases` — a list of strings
  - `:touches` — the paths triage predicted, a list of strings
  - `:domain_reference` — the domain document this change belongs to

  Each is omitted from the object when absent or empty, which is what the wire expects: every
  one of them is optional, and an empty array says something an absent field does not.

  ## Refusal

  `{:error, {:story_not_dispatchable, violations}}` when the story cannot be sent AS IT
  STANDS, with one message per violation. It is never trimmed to fit: a dropped acceptance
  criterion is a story built to the wrong spec, and an implementer cannot tell a story that
  had three criteria from one whose fourth was cut. `Loopctl.Delivery.StoryPayload` is what
  turns that refusal into an escalation.

  Two kinds of violation, and the second is the one that nearly slipped through as a silent
  trim:

  - a cap — a field, an item count, or the whole object's byte budget;
  - an item with no usable TEXT. A criterion whose text is missing or whitespace renders as
    `""` — its id alone does not save it, because `[AC-3] ` states no requirement — and that
    is judged on the TRIMMED text, not on exact emptiness. An earlier version tested `== ""`
    after formatting, so `%{"id" => "AC-3", "description" => ""}` rendered `[AC-3] `, cleared
    `minLength: 1`, and dispatched content-free; the version before THAT dropped the entry
    entirely, so a story imported with 21 criteria one of them blank yielded 20 on the wire,
    under the cap, with no violation and no escalation. Both are the wrong-spec outcome this
    module exists to prevent, reached once by a filter and once by a formatting artefact. The
    entry is now KEPT so the COUNT is honest and the cap binds, and NAMED so nothing
    dispatches. The same trimmed test covers the title and the option lists.

  Lengths are counted with `String.length/1` — GRAPHEMES, the unit `OpenApiSpex` counts a
  `maxLength` in — so this refuses exactly what the schema would, and the byte budget is the
  contract's one `ByteRule`.
  """
  @spec story_object(Story.t(), keyword()) ::
          {:ok, map()} | {:error, {:story_not_dispatchable, [String.t()]}}
  def story_object(%Story{} = story, opts \\ []) do
    object =
      %{"id" => story.id, "title" => story.title || ""}
      |> put_present("description", story.description)
      |> put_list("acceptance_criteria", criteria_strings(story))
      |> put_list("test_cases", strings(Keyword.get(opts, :test_cases)))
      |> put_list("touches", strings(Keyword.get(opts, :touches)))
      |> put_present("domain_reference", Keyword.get(opts, :domain_reference))

    case violations(object) do
      [] -> {:ok, object}
      violations -> {:error, {:story_not_dispatchable, violations}}
    end
  end

  # EVERY criterion, including one that renders empty. Rejecting the empty ones here was a
  # silent trim: the count went down, the cap stopped binding, and a story shipped one
  # criterion short with nothing refused. `violations/1` names it instead.
  defp criteria_strings(%Story{acceptance_criteria: criteria}) do
    criteria
    |> List.wrap()
    |> Enum.map(&criterion_text/1)
  end

  defp strings(nil), do: []

  # Same rule as the criteria: an empty option entry is kept and named, never dropped.
  defp strings(values) when is_list(values), do: Enum.map(values, &to_string/1)

  defp put_present(object, _key, nil), do: object
  defp put_present(object, _key, ""), do: object
  defp put_present(object, key, value), do: Map.put(object, key, value)

  defp put_list(object, _key, []), do: object
  defp put_list(object, key, values), do: Map.put(object, key, values)

  # Every cap the contract declares, read from `RunnerStory` so no number is restated here,
  # plus the shape rules a cap cannot express.
  defp violations(object) do
    blank_violation(object, "title") ++
      length_violation(object, "title", RunnerStory.max_title_length()) ++
      length_violation(object, "description", RunnerStory.max_description_length()) ++
      list_violations(
        object,
        "acceptance_criteria",
        RunnerStory.max_criteria(),
        RunnerStory.max_criterion_length()
      ) ++
      list_violations(
        object,
        "test_cases",
        RunnerStory.max_test_cases(),
        RunnerStory.max_test_case_length()
      ) ++
      list_violations(
        object,
        "touches",
        RunnerStory.max_touches(),
        RunnerStory.max_touch_length()
      ) ++
      length_violation(object, "domain_reference", RunnerStory.max_domain_reference_length()) ++
      bytes_violation(object)
  end

  # The schema requires a non-empty title, so a story with none cannot be dispatched. Named
  # here rather than left to the cast: the caller's remedy is an escalation, and
  # `invalid_payload` from the wire would tell it the payload was malformed instead.
  defp blank_violation(object, key) do
    if blank?(Map.get(object, key)), do: ["#{key} is empty"], else: []
  end

  # TRIMMED, not `== ""`. A title of three spaces satisfies the wire's `minLength: 1` and says
  # nothing, which is the same defect as a content-free criterion one field over.
  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false

  defp length_violation(object, key, max) do
    case Map.get(object, key) do
      value when is_binary(value) and value != "" ->
        if String.length(value) > max,
          do: ["#{key} is longer than #{max} characters"],
          else: []

      _absent ->
        []
    end
  end

  defp list_violations(object, key, max_items, max_length) do
    values = Map.get(object, key, [])

    count =
      if length(values) > max_items,
        do: ["#{key} has more than #{max_items} items"],
        else: []

    too_long =
      for {value, index} <- Enum.with_index(values),
          String.length(value) > max_length,
          do: "#{key}[#{index}] is longer than #{max_length} characters"

    # An entry that renders empty is NAMED, never dropped — dropping it is the silent trim
    # this module exists to refuse, and it takes the item count down with it so the cap stops
    # binding. The schema refuses an empty item too (`minLength: 1`); this is the copy that
    # answers with an escalation instead of a malformed-payload refusal from the wire.
    empty =
      for {value, index} <- Enum.with_index(values),
          blank?(value),
          do: "#{key}[#{index}] renders empty"

    count ++ too_long ++ empty
  end

  defp bytes_violation(object) do
    bytes = ByteRule.bytes(object)

    if bytes > RunnerStory.max_bytes(),
      do: ["the story is #{bytes} bytes under the byte rule, over #{RunnerStory.max_bytes()}"],
      else: []
  end
end
