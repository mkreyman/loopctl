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
  """

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
    id = Map.get(criterion, "id") || Map.get(criterion, :id)

    text =
      Map.get(criterion, "description") || Map.get(criterion, :description) ||
        Map.get(criterion, "criterion") || Map.get(criterion, :criterion) || ""

    if is_binary(id) and id != "", do: "[#{id}] #{text}", else: to_string(text)
  end

  defp criterion_text(other) when is_binary(other), do: other
  defp criterion_text(_other), do: ""
end
