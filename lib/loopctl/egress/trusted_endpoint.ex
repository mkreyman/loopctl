defmodule Loopctl.Egress.TrustedEndpoint do
  @moduledoc """
  A host a tenant ATTESTS is their own (US-41.4, AC-41.4.5).

  ## This is an unverified tenant attestation, not network locality

  loopctl does NOT prove the declaring tenant owns the host. Everywhere this list
  surfaces — the posture report, the US-41.7 custody claim, the MCP tool
  descriptions, the README — a declared endpoint is labelled
  **"tenant-declared (unverified attestation), not network-local"** and is NEVER
  presented as network-local.

  ## Three enforced constraints

  The list is tenant-writable (role `:user`), so without these it would be a
  self-service SSRF primitive into the operator network — the class
  GHSA-jh42-wf7g-f5rg closed:

    1. **Public addresses only.** Rejected at WRITE time (here) and re-checked at
       PIN time (`Loopctl.Egress.Policy`) unless every address the host resolves
       to still passes `Loopctl.Net.UrlGuard`'s full denylist. Loopback, `0/8`,
       `10/8`, `127/8`, `169.254/16`, `172.16-31`, `192.168/16`, `100.64/10` and
       `fdaa::/16` can never be declared — literally or via a public hostname
       that resolves there. Private/link-local/CGNAT/6PN carve-outs are available
       ONLY through the operator-controlled deployment allowlist.
    2. **Purpose-scoped.** Each declaration names its purposes (`inference`,
       `webhook` and/or `ingest`). A host declared for an Ollama box does NOT
       authorize webhook POSTs of tenant content to it, nor loopctl FETCHING
       tenant-supplied URLs from it (`ingest`, the content-ingestion path) — one
       list must never become an ambient capability across subsystems.
    3. **Vendor hosts excluded.** `api.openai.com` / `api.anthropic.com` are
       never local and may never be declared. This two-name check is a GUARDRAIL
       against the obvious mistake, NOT an integrity control (trivially defeated
       by a proxy or a CNAME) — constraints 1 and 2 carry the security weight.

  A declaration carves NOTHING out of the SSRF denylist (AC-41.4.9): it only
  changes the LOCALITY VERDICT for hosts that already pass it.
  """

  use Loopctl.Schema

  alias Loopctl.Net.UrlGuard

  @type t :: %__MODULE__{}

  @purposes ~w(inference webhook ingest)
  @vendor_hosts ~w(api.openai.com api.anthropic.com)

  schema "egress_trusted_endpoints" do
    tenant_field()

    field :host, :string
    field :purposes, {:array, :string}, default: []
    field :note, :string
    field :declared_by_actor_type, :string
    field :declared_by_actor_id, Ecto.UUID

    timestamps()
  end

  @doc "The closed set of declarable purposes."
  @spec purposes() :: [String.t()]
  def purposes, do: @purposes

  @doc "Vendor hosts that may never be declared (guardrail, not an integrity control)."
  @spec vendor_hosts() :: [String.t()]
  def vendor_hosts, do: @vendor_hosts

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(endpoint, attrs) do
    endpoint
    |> cast(attrs, [:host, :purposes, :note, :declared_by_actor_type, :declared_by_actor_id])
    |> update_change(:host, &normalize_host/1)
    |> validate_required([:host, :purposes])
    # NOT `validate_length(min: 1)`: `[]` equals the field DEFAULT, so Ecto records
    # no change and every change-based validation is skipped — an unscoped
    # declaration would slip through. (The DB CHECK cannot catch it either:
    # `array_length('{}', 1)` is NULL, and `NULL >= 1` is NULL, not false.) Check
    # the resolved field value instead, so constraint 2 (purpose scoping) is
    # actually enforced.
    |> validate_purposes_present()
    |> validate_subset(:purposes, @purposes)
    |> validate_not_vendor()
    |> validate_public_address()
    |> unique_constraint([:tenant_id, :host])
  end

  defp normalize_host(host) when is_binary(host) do
    host
    |> String.trim()
    |> String.downcase()
    |> strip_scheme()
    |> String.trim_trailing("/")
  end

  defp normalize_host(host), do: host

  # A caller may declare "https://ollama.example.com" — keep only the authority.
  defp strip_scheme(host) do
    case URI.parse(host) do
      %URI{host: h} when is_binary(h) and h != "" -> h
      _ -> host
    end
  end

  defp validate_purposes_present(changeset) do
    case get_field(changeset, :purposes) do
      [_ | _] ->
        changeset

      _ ->
        add_error(
          changeset,
          :purposes,
          "must name at least one purpose (#{Enum.join(@purposes, ", ")}) — a declaration " <>
            "is purpose-scoped and must never become an ambient capability across subsystems"
        )
    end
  end

  defp validate_not_vendor(changeset) do
    validate_change(changeset, :host, fn :host, host ->
      if host in @vendor_hosts do
        [
          host:
            "vendor endpoints are never local and may never be declared " <>
              "(#{Enum.join(@vendor_hosts, ", ")})"
        ]
      else
        []
      end
    end)
  end

  # CONSTRAINT 1, at WRITE time. `UrlGuard.pin/2` resolves the host (A + AAAA)
  # and rejects it if ANY resolved address is loopback/private/CGNAT/link-local/
  # ULA — so a public hostname whose DNS answers 10.0.0.5 is refused here, not
  # only at pin time. Re-checked at pin time too (DNS can change after a write).
  defp validate_public_address(changeset) do
    validate_change(changeset, :host, fn :host, host ->
      case UrlGuard.pin("https://" <> host) do
        {:ok, _pinned} ->
          []

        {:error, :blocked_ip} ->
          [
            host:
              "resolves to a private, loopback, CGNAT, link-local or ULA address; " <>
                "only PUBLIC addresses may be declared. Private-range carve-outs are " <>
                "available only through the operator-controlled deployment allowlist."
          ]

        {:error, reason} ->
          [host: "could not be validated as a public endpoint (#{reason})"]
      end
    end)
  end
end
