defmodule Loopctl.Delivery.TriageVerdictRecord do
  @moduledoc """
  The one verdict a triage dispatch produced (`triage_verdicts`, contract 1.9.0).

  A row here is the record that a verdict was RECEIVED, kept apart from the transition it
  drove: the stage row says where the story went, and this says what the session actually
  said — its evidence, its contradictions, the story it drafted, or the reason it produced
  nothing. An operator reading an escalation needs the second, and the stage machine only
  ever carried the first.

  ## The row is the idempotency key

  `triage_verdicts_dispatch_uidx` is unique on `(tenant_id, dispatch_id)`, and that is
  deliberate rather than defensive. A triage session records one verdict per run and cannot
  restate it, so a runner whose push was refused for anything transient has no move except
  resending the same bytes. `payload_digest` is how "the same bytes" is decided — a sha256
  over a canonical form, never a comparison of two json documents whose key order no encoder
  guarantees.

  ## UNTRUSTED

  Every string in `payload` and `detail` was written by a session that had just read
  attacker-controllable reporter text. They are stored, bounded and never executed; anything
  that later puts them in a prompt fences them as `Loopctl.Delivery.Untrusted` does.
  `tenant_id`, `dispatch_id`, `story_id` and `claim_epoch` are set programmatically and are
  never cast.
  """

  use Loopctl.Schema

  alias Loopctl.ApiSpec.RunnerContract.RunnerTriageVerdict
  alias Loopctl.ApiSpec.RunnerContract.RunnerTriageVerdictMessage

  @type t :: %__MODULE__{}

  schema "triage_verdicts" do
    tenant_field()

    field :dispatch_id, :binary_id
    field :story_id, :binary_id
    field :outcome, :string
    field :incomplete_reason, :string
    field :confidence, :string
    field :payload, :map
    field :detail, :string
    field :payload_digest, :string
    field :claim_epoch, :integer

    timestamps()
  end

  @doc """
  The digest that decides whether a resend is the SAME verdict.

  Canonical by construction: every map is walked with its keys SORTED and every key rendered
  as a string, so two encoders that disagree about key order — or about atom versus string
  keys, which the cast layer does — produce the same digest for the same content. Comparing
  `Jason.encode!/1` output directly would make a resend's digest depend on the order a map
  happened to enumerate in, and a runner would be told its identical verdict differed.
  """
  @spec digest(term()) :: String.t()
  def digest(term) do
    :sha256 |> :crypto.hash(canonical(term)) |> Base.encode16(case: :lower)
  end

  defp canonical(%{} = map) when not is_struct(map) do
    inner =
      map
      |> Enum.map(fn {k, v} -> {to_string(k), v} end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_join(",", fn {k, v} -> canonical(k) <> ":" <> canonical(v) end)

    "{" <> inner <> "}"
  end

  defp canonical(list) when is_list(list),
    do: "[" <> Enum.map_join(list, ",", &canonical/1) <> "]"

  defp canonical(nil), do: "null"
  defp canonical(value) when is_binary(value), do: inspect(value)
  defp canonical(value), do: to_string(value)

  @doc """
  Changeset for a received verdict. Everything identifying is on the struct already.

  `outcome` and `incomplete_reason` are validated against the CONTRACT's own enums rather
  than a list repeated here, so an outcome added to the wire and forgotten in the table is a
  compile-time reference that fails loudly instead of a string that silently stores.
  """
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(%__MODULE__{} = record, attrs) do
    record
    |> cast(attrs, [:outcome, :incomplete_reason, :confidence, :payload, :detail])
    |> validate_inclusion(:outcome, RunnerTriageVerdict.outcomes())
    |> validate_inclusion(
      :incomplete_reason,
      RunnerTriageVerdictMessage.incomplete_reasons()
    )
    |> validate_length(:detail, max: RunnerTriageVerdictMessage.max_detail_length())
    |> validate_required([:payload_digest, :claim_epoch])
    |> check_constraint(:outcome,
      name: :triage_verdicts_exactly_one_result,
      message: "exactly one of outcome and incomplete_reason"
    )
    |> check_constraint(:payload,
      name: :triage_verdicts_verdict_shape,
      message:
        "a verdict carries a payload and a confidence; an incomplete report carries neither"
    )
    |> unique_constraint([:tenant_id, :dispatch_id],
      name: :triage_verdicts_dispatch_uidx,
      message: "this dispatch already recorded a verdict"
    )
  end
end
