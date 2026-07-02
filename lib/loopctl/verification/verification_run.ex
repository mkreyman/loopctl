defmodule Loopctl.Verification.VerificationRun do
  @moduledoc """
  Schema for the `verification_runs` table.

  Each run represents an independent re-execution of a story's
  acceptance criteria against the committed code.
  """

  use Loopctl.Schema

  @type t :: %__MODULE__{}

  @statuses ~w(pending running pass fail error)

  # A git object id: lowercase hex only, 7–64 chars (covers an abbreviated SHA,
  # a full SHA-1 (40), and a full SHA-256 (64)). A hex-only value cannot contain
  # `/`, `..`, or a leading `-`, which closes both the path-traversal and the
  # `git checkout` argument-injection vectors when the SHA flows into
  # `Loopctl.Verification.TestRunner`. Advisory ie-04 (GHSA-pv74-gwwh-g92x).
  @commit_sha_format ~r/\A[0-9a-f]{7,64}\z/
  @commit_sha_error "must be a lowercase hexadecimal git object id (7-64 chars)"

  @doc "Valid runner types for verification."
  def runner_types, do: ~w(ci_github ci_gitlab fly_machine manual)

  schema "verification_runs" do
    field :tenant_id, Ecto.UUID
    field :story_id, Ecto.UUID
    field :commit_sha, :string
    field :commit_content_hash, :binary
    field :status, :string, default: "pending"
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :runner_type, :string
    field :ac_results, :map, default: %{}
    field :logs_url, :string
    field :machine_id, :string

    timestamps()
  end

  @doc false
  def changeset(run \\ %__MODULE__{}, attrs) do
    run
    |> cast(attrs, [
      :commit_sha,
      :commit_content_hash,
      :status,
      :started_at,
      :completed_at,
      :runner_type,
      :ac_results,
      :logs_url,
      :machine_id
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_commit_sha(attrs)
  end

  @doc """
  Returns `true` when `sha` is a well-formed git object id (lowercase hex,
  7-64 chars). Used both here and defensively in
  `Loopctl.Verification.TestRunner` before the SHA is ever passed to a
  subprocess or interpolated into a filesystem path.
  """
  @spec valid_commit_sha?(term()) :: boolean()
  def valid_commit_sha?(sha) when is_binary(sha), do: Regex.match?(@commit_sha_format, sha)
  def valid_commit_sha?(_sha), do: false

  # A commit SHA is optional (a run may be created before a commit exists), so
  # `nil`/absent is allowed. But any value that IS supplied must be a valid git
  # object id — a blank string or a traversal/flag-shaped value is rejected so
  # it never reaches the runner. `cast/3` drops `""` from the changes, so we
  # inspect the raw attrs to distinguish "absent" from "explicitly blank".
  defp validate_commit_sha(changeset, attrs) do
    case commit_sha_input(attrs) do
      {:present, sha} when not is_nil(sha) ->
        if valid_commit_sha?(sha) do
          changeset
        else
          add_error(changeset, :commit_sha, @commit_sha_error)
        end

      _absent_or_nil ->
        changeset
    end
  end

  defp commit_sha_input(attrs) do
    cond do
      Map.has_key?(attrs, :commit_sha) -> {:present, Map.get(attrs, :commit_sha)}
      Map.has_key?(attrs, "commit_sha") -> {:present, Map.get(attrs, "commit_sha")}
      true -> :absent
    end
  end
end
