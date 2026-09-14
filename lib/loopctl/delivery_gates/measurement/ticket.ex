defmodule Loopctl.DeliveryGates.Measurement.Ticket do
  @moduledoc """
  One past ticket, as `gh issue list --json` emits it, for the Gate A replay (issue #828,
  design §12 build order step 3).

  A FILE rather than a live forge call, for two reasons the harness depends on: the run is
  offline and repeatable, and the corpus is a fixed artifact a later run can be compared
  against. The command that produces it is on `Mix.Tasks.Loopctl.Gates.MeasureA`.

  ## `intake?` — which tickets Gate A will actually see

  The delivery loop's Gate A judges tickets Larisa files through the in-app chat, which stamps
  a `[Bug] <agency>: ` or `[Feature] <agency>: ` prefix at FILING time. Every other issue in
  the repository is engineering work the loop never triages. So the corpus is reported in two
  strata and the intake one is the headline: it is the population Gate A is for, and its
  bug/feature split was decided by the intake chat rather than by a label somebody applied
  after the outcome was known.

  ## It refuses rather than guesses

  A record with no `number` or no `title` is `{:error, reason}` and is counted as
  unparseable. Defaulting a missing title to `""` would classify the ticket as a defect fix
  (no request-shaped signal found) and quietly lower the escalation rate.
  """

  @enforce_keys [:number, :title]
  defstruct [
    :number,
    :title,
    :body,
    :state,
    :state_reason,
    :created_at,
    labels: [],
    intake?: false
  ]

  @type t :: %__MODULE__{
          number: pos_integer(),
          title: String.t(),
          body: String.t() | nil,
          state: String.t() | nil,
          state_reason: String.t() | nil,
          created_at: String.t() | nil,
          labels: [String.t()],
          intake?: boolean()
        }

  @intake_prefix ~r/\A\[(Bug|Feature)\]\s+.+?:\s/

  @doc """
  Parses one decoded `gh issue list --json` object (string keys).
  """
  @spec parse(term()) :: {:ok, t()} | {:error, term()}
  def parse(%{"number" => number, "title" => title} = record)
      when is_integer(number) and number > 0 and is_binary(title) and title != "" do
    {:ok,
     %__MODULE__{
       number: number,
       title: title,
       body: string_or_nil(Map.get(record, "body")),
       state: string_or_nil(Map.get(record, "state")),
       state_reason: string_or_nil(Map.get(record, "stateReason")),
       created_at: string_or_nil(Map.get(record, "createdAt")),
       labels: labels(Map.get(record, "labels")),
       intake?: Regex.match?(@intake_prefix, title)
     }}
  end

  def parse(%{"number" => number}) when is_integer(number),
    do: {:error, {:missing_title, number}}

  def parse(record) when is_map(record), do: {:error, {:missing_number, Map.keys(record)}}
  def parse(_record), do: {:error, :not_an_object}

  @doc """
  Parses a whole decoded corpus, returning the tickets and the records it refused.

  Both, never just the tickets: a corpus reported without its rejects is a denominator nobody
  can check.
  """
  @spec parse_all(term()) :: {:ok, [t()], [term()]} | {:error, :not_a_list}
  def parse_all(records) when is_list(records) do
    {tickets, errors} =
      Enum.reduce(records, {[], []}, fn record, {tickets, errors} ->
        case parse(record) do
          {:ok, ticket} -> {[ticket | tickets], errors}
          {:error, reason} -> {tickets, [reason | errors]}
        end
      end)

    {:ok, Enum.reverse(tickets), Enum.reverse(errors)}
  end

  def parse_all(_records), do: {:error, :not_a_list}

  defp labels(list) when is_list(list) do
    for %{"name" => name} <- list, is_binary(name), do: name
  end

  defp labels(_list), do: []

  defp string_or_nil(value) when is_binary(value) and value != "", do: value
  defp string_or_nil(_value), do: nil
end
