defmodule Loopctl.Holders.Holder do
  @moduledoc """
  One session: the unit that holds work (US-52.13, Epic 52 release 3).

  Every fleet session authenticates with one shared agent key, so the agent cannot tell two
  sessions apart (loopctl#707). A holder is the session itself: what kind it is, the host and
  worktree it runs in, and a lease it keeps alive by heartbeating. The agent stays the account
  that owns keys; a holder hangs off it, and its credential is an `api_keys` row carrying its
  `holder_id`.

  Every field is set by `Loopctl.Holders`, never cast from a request: `tenant_id` and
  `agent_id` come from the authenticating key, `dispatch_id` from placement (US-52.15), and the
  lease columns from the clock. `registration_changeset/2` casts only what the session itself
  describes about where it runs.
  """

  use Loopctl.Schema

  @type t :: %__MODULE__{}

  @kinds [:runner_session, :interactive, :cloud]
  @ended_reasons [:ended, :lapsed]

  schema "holders" do
    tenant_field()
    field :agent_id, :binary_id
    field :kind, Ecto.Enum, values: @kinds
    field :session_id, :string
    field :host, :string
    field :worktree, :string
    field :dispatch_id, :binary_id
    field :last_seen_at, :utc_datetime_usec
    field :lease_until, :utc_datetime_usec
    field :ended_at, :utc_datetime_usec
    field :ended_reason, Ecto.Enum, values: @ended_reasons

    timestamps()
  end

  @doc "The kinds of session a holder can be."
  @spec kinds() :: [atom()]
  def kinds, do: @kinds

  @doc """
  The session's own description of itself: kind, session id, host and worktree. Everything
  else on the row is set programmatically by `Loopctl.Holders`.
  """
  @spec registration_changeset(t(), map()) :: Ecto.Changeset.t()
  def registration_changeset(holder, attrs) do
    holder
    |> cast(attrs, [:kind, :session_id, :host, :worktree])
    |> validate_required([:kind, :session_id, :host])
    |> validate_length(:session_id, min: 1, max: 255)
    |> validate_length(:host, min: 1, max: 255)
    |> validate_length(:worktree, max: 4096)
    |> unique_constraint([:tenant_id, :agent_id, :session_id],
      name: :holders_live_session_uidx,
      message: "a live holder already exists for this session"
    )
  end
end
