defmodule Loopctl.Delivery.RunnerThreadSession do
  @moduledoc """
  What `Loopctl.Delivery.RunnerThreads` (checkpoints and notes, US-45.2) and
  `Loopctl.Delivery.RunnerReviews` (findings and verdicts, US-45.3) share: the one read of the
  ledger row a runner's thread message names, the epoch check that read makes possible, and
  the translation of a write's 422 into what the runner channel publishes. ONE copy, so the
  two coordinators cannot drift apart on how a thread message is resolved or refused.

  Each caller applies its own KIND rule to the row this returns: an `implement` session writes
  checkpoints and notes, a `review` session writes judgements, and a row of the other kind is
  `:unknown_dispatch` to either.
  """

  import Ecto.Query

  alias Loopctl.Delivery.Stages
  alias Loopctl.Repo
  alias Loopctl.Runners.DispatchRecord

  @type row :: %{
          status: String.t(),
          kind: String.t() | nil,
          story_id: Ecto.UUID.t(),
          claim_epoch: integer(),
          slot_generation: integer()
        }

  @doc """
  The ledger row `runner_id` holds for the message's dispatch, whatever its status, provided
  the message's `claim_epoch` is the dispatch's. A row another runner or tenant holds reads as
  none (`:unknown_dispatch`). Contention on the read is `:busy`, counted under
  `[:loopctl, :threads, :busy]` and logged as `what`.

  The epoch check is not the fence: `Loopctl.Threads` reads the story's epoch under its lock,
  which is what decides. A message that does not even match the dispatch it names is refused
  here for the cost of the read already made.
  """
  @spec read(
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          %{
            required(:dispatch_id) => Ecto.UUID.t(),
            required(:claim_epoch) => integer(),
            optional(atom()) => term()
          },
          String.t()
        ) ::
          {:ok, row()} | {:error, :busy | :unknown_dispatch | :stale_claim_epoch}
  def read(tenant_id, runner_id, message, what) do
    read = fn ->
      {:ok, row} =
        Repo.with_tenant(tenant_id, fn ->
          Repo.one(
            from r in DispatchRecord,
              where: r.tenant_id == ^tenant_id and r.runner_id == ^runner_id,
              where: r.dispatch_id == ^message.dispatch_id,
              select: %{
                status: r.status,
                kind: r.kind,
                story_id: r.story_id,
                claim_epoch: r.claim_epoch,
                slot_generation: r.slot_generation
              }
          )
        end)

      {:ok, row}
    end

    with {:ok, row} <- Stages.answering_busy(tenant_id, [:loopctl, :threads, :busy], what, read),
         {:ok, row} <- found(row),
         :ok <- dispatch_epoch_matches(row, message) do
      {:ok, row}
    end
  end

  defp found(nil), do: {:error, :unknown_dispatch}
  defp found(row), do: {:ok, row}

  defp dispatch_epoch_matches(%{claim_epoch: epoch}, %{claim_epoch: epoch}), do: :ok
  defp dispatch_epoch_matches(_row, _message), do: {:error, :stale_claim_epoch}

  @doc """
  A write's structured 422 as the channel publishes it: `:secret_blocked` for a credential,
  otherwise `invalid_payload` carrying the message. Total, because a clause missing here raises
  inside the channel.
  """
  @spec unprocessable(term()) :: :secret_blocked | {:invalid, [String.t()]}
  def unprocessable(%{code: "secret_blocked"}), do: :secret_blocked
  def unprocessable(%{message: message}) when is_binary(message), do: {:invalid, [message]}
  def unprocessable(message) when is_binary(message), do: {:invalid, [message]}
  def unprocessable(detail), do: {:invalid, [inspect(detail)]}

  @doc "A changeset's errors as `\"field message\"` lines, for `invalid_payload`."
  @spec changeset_messages(Ecto.Changeset.t()) :: [String.t()]
  def changeset_messages(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string_safe(value))
      end)
    end)
    |> Enum.flat_map(fn {field, messages} -> Enum.map(messages, &"#{field} #{&1}") end)
  end

  defp to_string_safe(value) when is_binary(value) or is_number(value) or is_atom(value),
    do: to_string(value)

  defp to_string_safe(value), do: inspect(value)
end
