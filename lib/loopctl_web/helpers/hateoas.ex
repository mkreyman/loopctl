defmodule LoopctlWeb.Helpers.Hateoas do
  @moduledoc """
  US-26.3.2 — HATEOAS helpers for enriching API responses with
  `next_actions` and `remediation` metadata.
  """

  alias Loopctl.Progress.StateMachine

  @doc """
  Adds `next_actions` to a response map based on the story's current state.
  """
  @spec with_next_actions(map(), map(), atom()) :: map()
  def with_next_actions(response, story, role) do
    Map.put(response, :next_actions, StateMachine.next_actions(story, role))
  end

  @doc """
  Builds a standardized error response with remediation guidance.
  """
  @spec error_with_remediation(String.t(), integer(), map()) :: map()
  def error_with_remediation(code, status, opts \\ %{}) do
    %{
      error: %{
        code: code,
        status: status,
        message: Map.get(opts, :message, humanize_code(code)),
        remediation: %{
          description: Map.get(opts, :description, ""),
          next_action: Map.get(opts, :next_action, ""),
          learn_more: "https://loopctl.com/wiki/#{slug_from_code(code)}",
          example: Map.get(opts, :example)
        }
      }
    }
  end

  defp humanize_code(code) do
    code
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp slug_from_code(code) do
    String.replace(code, "_", "-")
  end
end
