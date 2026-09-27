defmodule LoopctlWeb.ThreadHTTP do
  @moduledoc """
  The ONE copy of what the change-thread endpoints share (`LoopctlWeb.ThreadController` and
  `LoopctlWeb.ThreadReviewController`): how an entry and a checkpoint are rendered, how a path
  id and a `claim_epoch` are read, and the status a write answers. Two copies had already
  drifted, marking a finding's `location` untrusted on one endpoint and not the other.
  """

  alias LoopctlWeb.ClaimEpochParam

  @doc """
  An entry as every thread endpoint returns it. `body` and `location` are text a session or a
  person wrote, marked untrusted.
  """
  @spec entry(Loopctl.Threads.Entry.t()) :: map()
  def entry(entry) do
    %{
      id: entry.id,
      seq: entry.seq,
      kind: entry.kind,
      author_principal: entry.author_principal,
      dispatch_id: entry.dispatch_id,
      idempotency_key: entry.idempotency_key,
      body: entry.body,
      body_untrusted: true,
      checkpoint_id: entry.checkpoint_id,
      review_id: entry.review_id,
      severity: entry.severity,
      location: entry.location,
      location_untrusted: true,
      introduced_by: entry.introduced_by,
      finding_ids: entry.finding_ids,
      inserted_at: entry.inserted_at
    }
  end

  @doc "A checkpoint as every thread endpoint returns it."
  @spec checkpoint(Loopctl.Threads.Checkpoint.t()) :: map()
  def checkpoint(checkpoint) do
    %{
      id: checkpoint.id,
      seq: checkpoint.seq,
      kind: checkpoint.kind,
      commit_sha: checkpoint.commit_sha,
      tree_sha: checkpoint.tree_sha,
      parent_checkpoint_id: checkpoint.parent_checkpoint_id,
      claim_epoch: checkpoint.claim_epoch,
      dispatch_id: checkpoint.dispatch_id,
      merge_commit_sha: checkpoint.merge_commit_sha,
      gate_evidence: checkpoint.gate_evidence,
      inserted_at: checkpoint.inserted_at
    }
  end

  @doc """
  A path id. A malformed one cannot name a row, and answering 404 keeps it from reaching a
  query that would raise on the cast.
  """
  @spec uuid(term()) :: {:ok, Ecto.UUID.t()} | {:error, :not_found}
  def uuid(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :not_found}
    end
  end

  @doc """
  A UUID from the request BODY, named `field`: a malformed or (when `required`) missing one is
  `422 invalid_uuid` naming the field. Unlike `uuid/1`, which reads a PATH id and answers 404,
  a bad body value is the caller's request being wrong, not a resource being absent.
  """
  @spec body_uuid(map(), String.t(), :required | :optional) ::
          {:ok, Ecto.UUID.t() | nil} | {:error, {:unprocessable_entity, String.t(), String.t()}}
  def body_uuid(params, field, presence) do
    case {Map.get(params, field), presence} do
      {nil, :optional} ->
        {:ok, nil}

      {value, _presence} ->
        case Ecto.UUID.cast(value) do
          {:ok, uuid} -> {:ok, uuid}
          :error -> {:error, {:unprocessable_entity, "invalid_uuid", "#{field} must be a UUID"}}
        end
    end
  end

  @doc "A required `claim_epoch`; a missing or malformed one is 400."
  @spec claim_epoch(map()) :: {:ok, non_neg_integer()} | {:error, :bad_request, String.t()}
  def claim_epoch(params) do
    case ClaimEpochParam.fetch(params) do
      {:ok, epoch} -> {:ok, epoch}
      _ -> {:error, :bad_request, "claim_epoch must be a non-negative integer"}
    end
  end

  @doc "201 for a write that created its row, 200 for a resend answered from one."
  @spec status(:created | :existing) :: :created | :ok
  def status(:created), do: :created
  def status(:existing), do: :ok
end
