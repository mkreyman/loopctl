defmodule Loopctl.Repo.Migrations.AddExtendedTelemetryFields do
  use Ecto.Migration

  @moduledoc """
  US-26.6.1 — Extends token_usage_reports with tool_call_count,
  cot_length_tokens, and tests_run_count for lazy-bastard scoring.
  """

  def change do
    alter table(:token_usage_reports) do
      add :tool_call_count, :integer
      add :cot_length_tokens, :integer
      add :tests_run_count, :integer
    end
  end
end
