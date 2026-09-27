defmodule Loopctl.Threads.IssueLink do
  @moduledoc """
  Schema for `thread_issue_links` (US-45.7, AC-45.7.4): loopctl's record that it posted, or
  will post, the comment linking a story's intake issue to the story's thread page.

  One row per story, by a unique index, so the comment is intended once however many
  checkpoints the thread records. `:pending` is the drainer's candidate set; `:commented` and
  `:abandoned` are terminal. Every field is set by `Loopctl.Threads.IssueLinks`; nothing is
  cast from a caller.
  """

  use Loopctl.Schema

  @type t :: %__MODULE__{}

  schema "thread_issue_links" do
    tenant_field()

    field :story_id, :binary_id
    field :repo_full_name, :string
    field :issue_number, :integer
    field :status, Ecto.Enum, values: [:pending, :commented, :abandoned], default: :pending
    field :commented_at, :utc_datetime_usec
    field :attempts, :integer, default: 0
    field :next_attempt_at, :utc_datetime_usec
    field :last_error, :string

    timestamps()
  end
end
