defmodule LoopctlWeb.TenantOnboardingLive do
  @moduledoc """
  US-26.0.1 — post-signup onboarding checklist.

  Rendered after a tenant completes the WebAuthn signup ceremony. Walks
  the operator through the first four setup steps:

  1. Audit key generation (US-26.0.2)
  2. System article tour
  3. First project creation
  4. First agent registration

  This LiveView is intentionally a skeleton: the individual step
  completion is tracked on the tenant's `settings.onboarding` jsonb
  map. Later stories will flesh out the individual step CTAs.
  """

  use LoopctlWeb, :live_view

  alias Loopctl.Tenants

  @steps [
    %{
      key: "audit_key",
      title: "Generate audit signing key",
      body:
        "Creates the ed25519 keypair that signs every audit chain entry for this tenant (US-26.0.2)."
    },
    %{
      key: "system_article_tour",
      title: "Read the system articles",
      body: "A guided tour of the chain-of-custody system articles shipped with the tenant."
    },
    %{
      key: "first_project",
      title: "Create your first project",
      body: "Projects are the planning unit — epics, stories, and dispatches all hang off them."
    },
    %{
      key: "first_agent",
      title: "Register your first agent",
      body: "Give an implementer agent its ephemeral key so it can start claiming stories."
    }
  ]

  @impl true
  def mount(%{"id" => tenant_id} = params, _session, socket) do
    token = Map.get(params, "token", "")

    # Verify the signed token from the signup redirect (valid for 15 min).
    case Phoenix.Token.verify(LoopctlWeb.Endpoint, "onboarding", token, max_age: 900) do
      {:ok, ^tenant_id} ->
        case Tenants.get_tenant(tenant_id) do
          {:ok, tenant} ->
            completed = completed_steps(tenant)

            {:ok,
             socket
             |> assign(:page_title, "Welcome to loopctl")
             |> assign(:tenant, tenant)
             |> assign(:steps, @steps)
             |> assign(:completed, completed)}

          {:error, :not_found} ->
            {:ok, push_navigate(socket, to: ~p"/")}
        end

      _ ->
        {:ok, push_navigate(socket, to: ~p"/")}
    end
  end

  defp completed_steps(tenant) do
    (tenant.settings || %{})
    |> Map.get("onboarding", %{})
    |> Map.get("completed", [])
    |> MapSet.new()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="mx-auto w-full max-w-2xl px-6 py-16" id="onboarding-page">
      <header class="mb-10">
        <h1 class="font-display text-2xl font-semibold text-slate-100">
          Welcome, {@tenant.name}
        </h1>
        <p class="mt-1 font-mono text-xs uppercase tracking-wide text-slate-500">
          tenant id <span class="text-slate-300">{@tenant.id}</span>
        </p>
        <p class="mt-4 text-sm text-slate-400">
          Your tenant is anchored to a hardware authenticator. Complete the remaining onboarding
          steps to bring loopctl online.
        </p>
      </header>

      <ol class="space-y-3" id="onboarding-steps">
        <li
          :for={{step, index} <- Enum.with_index(@steps)}
          id={"onboarding-step-#{step.key}"}
          class={[
            "flex items-start gap-4 rounded-md border border-slate-800 bg-slate-900/60 p-5",
            MapSet.member?(@completed, step.key) && "border-accent-500/50"
          ]}
        >
          <div class="flex h-8 w-8 shrink-0 items-center justify-center rounded-md border border-slate-700 font-mono text-xs text-slate-400">
            {index + 1}
          </div>
          <div class="flex-1">
            <h2 class="font-display text-sm text-slate-200">{step.title}</h2>
            <p class="mt-1 text-xs text-slate-500">{step.body}</p>
          </div>
          <.icon
            :if={MapSet.member?(@completed, step.key)}
            name="hero-check-circle"
            class="h-5 w-5 text-accent-400"
          />
        </li>
      </ol>
    </section>
    """
  end
end
