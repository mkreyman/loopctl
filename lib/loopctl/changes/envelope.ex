defmodule Loopctl.Changes.Envelope do
  @moduledoc """
  The chg event envelope, v1 (US-47.3, Epic 47 PRD §5; confirmed on mkreyman/chg#33):

      {"v": 1, "repo": "owner/name", "change_id": "<ULID>", "event_seq": 3,
       "kind": "landed", "revision": 2, "sha": "<revision commit>",
       "occurred_at": "2026-10-18T23:59:59Z", "data": {...}}

  Decoded from the SAME raw bytes the signature was checked over, and only after that check,
  so nothing unauthenticated is ever parsed here. Every field is required. `kind` is any
  lowercase identifier — chg may add kinds without a loopctl release, and an unmapped one is
  recorded rather than refused (AC-47.3.6). `data` must be a JSON object; its contents are
  per-kind and stay untrusted.

  Shape only. Whether the envelope's `repo` is the source's repository is the caller's
  check, because the answer to a mismatch is an authentication refusal, not a 400.
  """

  alias Loopctl.Changes.Binding
  alias Loopctl.GitSha
  alias Loopctl.Intake.Source

  @type t :: %{
          v: 1,
          repo: String.t(),
          change_id: String.t(),
          event_seq: pos_integer(),
          kind: String.t(),
          revision: pos_integer(),
          sha: String.t(),
          occurred_at: DateTime.t(),
          data: map()
        }

  @types %{
    v: :integer,
    repo: :string,
    change_id: :string,
    event_seq: :integer,
    kind: :string,
    revision: :integer,
    sha: :string,
    occurred_at: :utc_datetime_usec,
    data: :map
  }

  # A change id is a client ULID on chg's side; it is also a path segment of the gap pull, so
  # it is held to URL-safe characters here rather than escaped later.
  @change_id_format ~r/\A[A-Za-z0-9._:-]+\z/
  @kind_format ~r/\A[a-z][a-z0-9_]{0,63}\z/
  # bigint / integer column bounds.
  @max_event_seq 9_223_372_036_854_775_807
  @max_revision 2_147_483_647

  @doc "Decodes and validates a raw JSON body."
  @spec decode(binary()) :: {:ok, t()} | {:error, :invalid_event}
  def decode(raw_body) when is_binary(raw_body) do
    case Jason.decode(raw_body) do
      {:ok, %{} = map} -> validate(map)
      _ -> {:error, :invalid_event}
    end
  end

  @doc "Validates an already-decoded envelope map (string keys, as JSON decodes)."
  @spec validate(term()) :: {:ok, t()} | {:error, :invalid_event}
  def validate(%{} = map) do
    {%{}, @types}
    |> Ecto.Changeset.cast(map, Map.keys(@types))
    |> Ecto.Changeset.validate_required(Map.keys(@types))
    |> Ecto.Changeset.validate_inclusion(:v, [1])
    |> Ecto.Changeset.validate_format(:repo, Source.repo_format())
    |> Ecto.Changeset.validate_length(:change_id, max: Binding.max_length())
    |> Ecto.Changeset.validate_format(:change_id, @change_id_format)
    |> Ecto.Changeset.validate_number(:event_seq,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: @max_event_seq
    )
    |> Ecto.Changeset.validate_number(:revision,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: @max_revision
    )
    |> Ecto.Changeset.validate_format(:kind, @kind_format)
    |> Ecto.Changeset.validate_change(:sha, fn :sha, sha ->
      if GitSha.valid?(sha), do: [], else: [sha: "must be a git object id"]
    end)
    |> Ecto.Changeset.apply_action(:validate)
    |> case do
      {:ok, envelope} -> {:ok, envelope}
      {:error, _changeset} -> {:error, :invalid_event}
    end
  end

  def validate(_other), do: {:error, :invalid_event}
end
