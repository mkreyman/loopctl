defmodule Loopctl.Repo.Migrations.ChangeCursorAttention do
  @moduledoc """
  US-50.2: loopctl no longer pulls a change's events from chg-server (there is none), so
  `change_cursors.last_pulled_at` is dropped. In its place a change the reconcile sweep found
  gapped or stale carries `attention` (`gap` or `stale`) and `attention_at`: the operator is
  alerted once per change per condition, the dashboard lists it, and the next applied event
  clears it.

  Dropping `last_pulled_at` during the rolling deploy is safe here: the code it removes reads
  the column only on an arriving change event or a sweep with `CHG_SERVER_URL` set, and no
  production source sends events or sets that variable yet.
  """

  use Ecto.Migration

  def up do
    alter table(:change_cursors) do
      remove :last_pulled_at
      add :attention, :string
      add :attention_at, :utc_datetime_usec
    end

    create constraint(:change_cursors, :change_cursors_attention_known,
             check: "attention IS NULL OR attention IN ('gap', 'stale')"
           )

    create constraint(:change_cursors, :change_cursors_attention_at_with_attention,
             check: "(attention IS NULL) = (attention_at IS NULL)"
           )
  end

  def down do
    drop constraint(:change_cursors, :change_cursors_attention_at_with_attention)
    drop constraint(:change_cursors, :change_cursors_attention_known)

    alter table(:change_cursors) do
      remove :attention_at
      remove :attention
      add :last_pulled_at, :utc_datetime_usec
    end
  end
end
