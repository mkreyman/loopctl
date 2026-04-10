defmodule LoopctlWeb.KnowledgeIngestionJSON do
  @moduledoc """
  JSON rendering helpers for the knowledge ingestion endpoints.
  """

  @doc "Renders a newly queued ingestion job response."
  def queued(%{job: job, content_hash: content_hash, source_type: source_type}) do
    %{
      data: %{
        id: job.id,
        status: "queued",
        content_hash: content_hash,
        source_type: source_type,
        inserted_at: job.inserted_at
      }
    }
  end

  @doc "Renders an already-queued duplicate response."
  def already_queued(%{content_hash: content_hash, job: job}) do
    %{
      data: %{
        id: job.id,
        status: "already_queued",
        content_hash: content_hash
      }
    }
  end

  @doc "Renders the ingestion jobs index."
  def index(jobs) do
    %{
      data: Enum.map(jobs, &render_job/1)
    }
  end

  @doc """
  Renders a batch ingestion response. `results` is a list of per-item result
  maps produced by `KnowledgeIngestionController.enqueue_item_result/2`.
  """
  def batch(results) when is_list(results) do
    %{data: Enum.map(results, &render_batch_result/1)}
  end

  defp render_batch_result(%{status: "queued"} = r) do
    %{
      status: "queued",
      id: r.id,
      content_hash: r.content_hash,
      source_type: r.source_type,
      inserted_at: r.inserted_at
    }
  end

  defp render_batch_result(%{status: "already_queued"} = r) do
    %{
      status: "already_queued",
      id: r.id,
      content_hash: r.content_hash
    }
  end

  defp render_batch_result(%{status: "error", error: error}) do
    %{status: "error", error: error}
  end

  defp render_job(job) do
    args = job.args || %{}

    %{
      id: job.id,
      state: job.state,
      source_type: args["source_type"],
      url: args["url"],
      content_hash: args["content_hash"],
      inserted_at: job.inserted_at,
      completed_at: job.completed_at,
      errors: render_errors(job.errors)
    }
  end

  defp render_errors(nil), do: []
  defp render_errors(errors) when is_list(errors), do: errors
  defp render_errors(_), do: []
end
