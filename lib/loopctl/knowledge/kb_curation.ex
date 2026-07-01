defmodule Loopctl.Knowledge.KbCuration do
  @moduledoc """
  Toggleable, concise, human-readable log of KB CURATION adjustments — the "what did the KB
  change" feed for analyzing the agents'-KB rollout, distinct from the verbose immutable
  `audit_log`.

  **Toggle:** per-tenant, via `tenant.settings["kb_curation_log"]` (default off). Flip it
  with the admin tenant API (`PATCH /api/v1/admin/tenants/:id` with
  `settings: {"kb_curation_log": true}`); read the current value from
  `GET /api/v1/admin/tenants/:id`. When off, `record/4` is a no-op (no rows, no overhead),
  so you turn it on for the rollout months and off after.

  Call sites `record/4` at each mutation (gate decisions, conflict supersede/merge/dismiss);
  the log is read back via `list/2` (`GET /api/v1/knowledge/curation-log`).
  """

  import Ecto.Query

  alias Loopctl.AdminRepo
  alias Loopctl.Knowledge.KbCurationEvent
  alias Loopctl.Tenants.Tenant

  @max_summary 500

  @doc """
  Record one curation adjustment — but ONLY when the tenant has `kb_curation_log` on.
  Fire-and-forget: always returns `:ok`, never raises or blocks the caller.

  Opts: `:refs` (article ids), `:actor`, `:confidence`, `:metadata`, `:at`.
  """
  @spec record(Ecto.UUID.t() | nil, String.t(), String.t(), keyword()) :: :ok
  def record(tenant_id, kind, summary, opts \\ [])

  def record(nil, _kind, _summary, _opts), do: :ok

  def record(tenant_id, kind, summary, opts) when is_binary(tenant_id) do
    if enabled?(tenant_id) do
      insert_event(tenant_id, kind, summary, opts)
    end

    :ok
  end

  @doc "Whether curation logging is on for a tenant (its `settings[\"kb_curation_log\"]`)."
  @spec enabled?(Ecto.UUID.t()) :: boolean()
  def enabled?(tenant_id) do
    case AdminRepo.get(Tenant, tenant_id) do
      %Tenant{settings: settings} when is_map(settings) ->
        Map.get(settings, "kb_curation_log", false) == true

      _ ->
        false
    end
  end

  @doc """
  The curation feed, most recent first. Opts: `:kind` (filter), `:since` (a `Date` or
  `DateTime` lower bound), `:limit` (default 50, max 500), `:offset`. Returns
  `%{data: [event maps], meta: %{limit, offset, total_count}}`.
  """
  @spec list(Ecto.UUID.t(), keyword()) :: %{data: [map()], meta: map()}
  def list(tenant_id, opts \\ []) do
    limit = opts |> Keyword.get(:limit, 50) |> max(1) |> min(500)
    offset = opts |> Keyword.get(:offset, 0) |> max(0)

    base =
      from(e in KbCurationEvent, where: e.tenant_id == ^tenant_id)
      |> filter_kind(Keyword.get(opts, :kind))
      |> filter_since(Keyword.get(opts, :since))

    total_count = AdminRepo.aggregate(base, :count, :id)

    data =
      from(e in base,
        order_by: [desc: e.at, desc: e.id],
        limit: ^limit,
        offset: ^offset,
        select: %{
          at: e.at,
          kind: e.kind,
          summary: e.summary,
          refs: e.refs,
          actor: e.actor,
          confidence: e.confidence
        }
      )
      |> AdminRepo.all()

    %{data: data, meta: %{limit: limit, offset: offset, total_count: total_count}}
  end

  defp insert_event(tenant_id, kind, summary, opts) do
    attrs = %{
      kind: kind,
      summary: String.slice(summary, 0, @max_summary),
      refs: Keyword.get(opts, :refs, []),
      actor: Keyword.get(opts, :actor),
      confidence: Keyword.get(opts, :confidence),
      metadata: Keyword.get(opts, :metadata, %{}),
      at: Keyword.get(opts, :at) || DateTime.utc_now()
    }

    %KbCurationEvent{tenant_id: tenant_id}
    |> KbCurationEvent.changeset(attrs)
    |> AdminRepo.insert()
  end

  defp filter_kind(query, nil), do: query
  defp filter_kind(query, kind), do: where(query, [e], e.kind == ^kind)

  defp filter_since(query, nil), do: query

  defp filter_since(query, %Date{} = d) do
    filter_since(query, DateTime.new!(d, ~T[00:00:00.000000], "Etc/UTC"))
  end

  defp filter_since(query, %DateTime{} = dt), do: where(query, [e], e.at >= ^dt)
end
