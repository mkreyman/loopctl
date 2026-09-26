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
    # The three lenses' own judgements, keyed by lens (contract 1.15.0), or nil for a verdict
    # sent without them. Gate A reads this and nothing a caller supplies (US-44.1).
    field :lens_verdicts, :map
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

  # NIL-VALUED KEYS ARE DROPPED, and that is not tidiness. `verdict`, `incomplete` and
  # `detail` are all `nullable: true` on the wire, so a runner may send `"incomplete": null`
  # beside a verdict — and the cast KEEPS a key that is present-with-null while dropping one
  # that is absent. A runner whose first attempt emits explicit nulls and whose retry path
  # rebuilds the object without them would get `already_recorded`, permanently, for the same
  # verdict: exactly the failure this digest exists to prevent, one level down.
  defp canonical(%{} = map) when not is_struct(map) do
    inner =
      map
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Enum.map(fn {k, v} -> {to_string(k), v} end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_join(",", fn {k, v} -> canonical(k) <> ":" <> canonical(v) end)

    "{" <> inner <> "}"
  end

  defp canonical(list) when is_list(list),
    do: "[" <> Enum.map_join(list, ",", &canonical/1) <> "]"

  defp canonical(nil), do: "null"

  # `printable_limit: :infinity`, because `inspect/1` TRUNCATES a binary at 4096 characters by
  # default — so two different verdicts sharing a 4096-character prefix would digest
  # identically and the second would be accepted as a REPLAY of the first. That is the
  # dangerous direction: a different verdict applied silently, which on a reject is a second
  # close on the reporter's ticket. No field cap reaches 4096 today; the moment one grows past
  # it, this would have become live and silent.
  defp canonical(value) when is_binary(value),
    do: inspect(value, printable_limit: :infinity, limit: :infinity)

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
    |> cast(attrs, [:outcome, :incomplete_reason, :confidence, :payload, :detail, :lens_verdicts])
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
    |> check_constraint(:lens_verdicts,
      name: :triage_verdicts_lens_verdicts_shape,
      message: "lens_verdicts is an object keyed by lens"
    )
    |> unique_constraint([:tenant_id, :dispatch_id],
      name: :triage_verdicts_dispatch_uidx,
      message: "this dispatch already recorded a verdict"
    )
  end
end
