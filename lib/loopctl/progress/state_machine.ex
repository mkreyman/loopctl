defmodule Loopctl.Progress.StateMachine do
  @moduledoc """
  US-26.3.2 — Declares the legal state transitions for stories.

  The `next_actions/2` function returns HATEOAS-style guidance for
  agents: what they can do next given the current story state and role.
  """

  @doc """
  Returns the legal next actions for a story given its current status
  and the caller's role.
  """
  @spec next_actions(map(), atom()) :: [map()]
  def next_actions(story, role) do
    case {story.agent_status, story.verified_status, role} do
      {:pending, _, _} ->
        [
          %{
            action: "contract",
            method: "POST",
            path: "/api/v1/stories/#{story.id}/contract",
            required_body: %{
              story_title: story.title,
              ac_count: length(story.acceptance_criteria || [])
            },
            preconditions: ["Story must be in pending status"],
            learn_more: "https://loopctl.com/wiki/agent-pattern"
          }
        ]

      {:contracted, _, _} ->
        [
          %{
            action: "claim",
            method: "POST",
            path: "/api/v1/stories/#{story.id}/claim",
            required_body: %{},
            preconditions: ["Story must be contracted"],
            learn_more: "https://loopctl.com/wiki/agent-pattern"
          }
        ]

      {:assigned, _, :agent} ->
        [
          %{
            action: "start",
            method: "POST",
            path: "/api/v1/stories/#{story.id}/start",
            required_body: %{},
            preconditions: ["Story must be assigned to you"],
            learn_more: "https://loopctl.com/wiki/agent-pattern"
          }
        ]

      {:implementing, _, :agent} ->
        [
          %{
            action: "request_review",
            method: "POST",
            path: "/api/v1/stories/#{story.id}/request-review",
            required_body: %{},
            preconditions: ["Implementation complete", "Tests passing"],
            learn_more: "https://loopctl.com/wiki/agent-pattern"
          }
        ]

      {:reported_done, :unverified, role} when role in [:orchestrator, :user] ->
        [
          %{
            action: "verify",
            method: "POST",
            path: "/api/v1/stories/#{story.id}/verify",
            required_body: %{summary: "Review summary"},
            preconditions: ["Review must be complete", "review_record must exist"],
            learn_more: "https://loopctl.com/wiki/agent-pattern"
          },
          %{
            action: "reject",
            method: "POST",
            path: "/api/v1/stories/#{story.id}/reject",
            required_body: %{reason: "Rejection reason"},
            preconditions: ["Review found issues"],
            learn_more: "https://loopctl.com/wiki/agent-pattern"
          }
        ]

      _ ->
        []
    end
  end
end
