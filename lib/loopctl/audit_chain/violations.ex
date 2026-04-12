defmodule Loopctl.AuditChain.Violations do
  @moduledoc """
  US-26.1.4 — Context module for pre-existing violation management.
  """

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.AuditChain.PendingViolation

  @doc "Lists pending violations with optional filters."
  @spec list_violations(keyword()) :: %{data: [PendingViolation.t()], meta: map()}
  def list_violations(opts \\ []) do
    limit = opts |> Keyword.get(:limit, 50) |> max(1) |> min(100)
    offset = opts |> Keyword.get(:offset, 0) |> max(0)

    base = from(v in PendingViolation, order_by: [desc: v.discovered_at])

    base =
      case Keyword.get(opts, :tenant_id) do
        nil -> base
        tid -> from(v in base, where: v.tenant_id == ^tid)
      end

    base =
      case Keyword.get(opts, :violation_type) do
        nil -> base
        vt -> from(v in base, where: v.violation_type == ^vt)
      end

    base =
      case Keyword.get(opts, :status) do
        nil -> from(v in base, where: v.status == "pending")
        "all" -> base
        status -> from(v in base, where: v.status == ^status)
      end

    total_count = AdminRepo.aggregate(base, :count, :id)

    data =
      base
      |> limit(^limit)
      |> offset(^offset)
      |> AdminRepo.all()

    %{data: data, meta: %{total_count: total_count, limit: limit, offset: offset}}
  end

  @doc "Counts pending violations. Used by the merge-readiness indicator."
  @spec pending_count() :: non_neg_integer()
  def pending_count do
    from(v in PendingViolation, where: v.status == "pending")
    |> AdminRepo.aggregate(:count, :id)
  end

  @doc "Resolves a violation with a note."
  @spec resolve(Ecto.UUID.t(), String.t(), Ecto.UUID.t() | nil) ::
          {:ok, PendingViolation.t()} | {:error, term()}
  def resolve(violation_id, note, resolved_by_key_id \\ nil) do
    case AdminRepo.get(PendingViolation, violation_id) do
      nil ->
        {:error, :not_found}

      violation ->
        violation
        |> PendingViolation.changeset(%{
          status: "resolved",
          resolved_at: DateTime.utc_now(),
          resolved_by_api_key_id: resolved_by_key_id,
          resolution_note: note
        })
        |> AdminRepo.update()
    end
  end

  @doc "Ignores a violation."
  @spec ignore(Ecto.UUID.t(), String.t()) :: {:ok, PendingViolation.t()} | {:error, term()}
  def ignore(violation_id, note) do
    case AdminRepo.get(PendingViolation, violation_id) do
      nil ->
        {:error, :not_found}

      violation ->
        violation
        |> PendingViolation.changeset(%{
          status: "ignored",
          resolved_at: DateTime.utc_now(),
          resolution_note: note
        })
        |> AdminRepo.update()
    end
  end
end
