defmodule LoopctlWeb.KnowledgePipelineJSON do
  @moduledoc """
  JSON rendering helpers for the knowledge pipeline status endpoint.
  """

  @doc "Renders the knowledge pipeline status response."
  def status(%{
        pending_extractions: pending,
        recent_drafts: drafts,
        publish_rate: rate,
        extraction_errors: errors,
        auto_extract_enabled: auto_extract
      }) do
    %{
      data: %{
        pending_extractions: pending,
        recent_drafts: Enum.map(drafts, &render_draft/1),
        publish_rate: Float.round(rate * 1.0, 4),
        extraction_errors: %{
          count: errors.count,
          recent: Enum.map(errors.recent, &render_error/1)
        },
        auto_extract_enabled: auto_extract
      }
    }
  end

  defp render_draft(draft) do
    %{
      id: draft.id,
      title: draft.title,
      source_id: draft.source_id,
      inserted_at: draft.inserted_at
    }
  end

  defp render_error(error) do
    %{
      id: error.id,
      state: error.state,
      error_reason: error.error_reason,
      attempted_at: error.attempted_at
    }
  end
end
