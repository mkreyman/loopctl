defmodule LoopctlWeb.CoreComponents do
  @moduledoc """
  Minimal core UI components used by loopctl LiveViews.

  This module is intentionally small: loopctl is an API-first project
  with a thin web surface (landing page + signup LiveView). It provides
  just enough Phoenix.Component wrappers to avoid open-coding forms and
  icons across the UI.

  All components follow `docs/design-system.md`:

  - dark mode only
  - `slate-*` palette, no warm grays
  - `rounded-md` cards, never `rounded-xl`
  - Geist typography via `font-body` / `font-display`
  - terminal aesthetic, no gradients, no glassmorphism
  """

  use Phoenix.Component

  alias Phoenix.LiveView.JS

  @doc """
  Renders a form input.

  Supports regular `<input>` elements for text, email, etc. Accepts a
  form field (via `@form[:field]`) or explicit `name` / `value` props.
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any

  attr :type, :string,
    default: "text",
    values: ~w(text email password number search tel url)

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"

  attr :errors, :list, default: []
  attr :checked, :boolean, doc: "the checked flag for checkbox inputs"
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "the options to pass to Phoenix.HTML.Form.options_for_select/2"
  attr :multiple, :boolean, default: false, doc: "the multiple flag for select inputs"

  attr :rest, :global,
    include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                pattern placeholder readonly required rows size step)

  slot :inner_block

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error/1))
    |> assign_new(:name, fn -> field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(assigns) do
    ~H"""
    <div class="space-y-1.5">
      <label :if={@label} for={@id} class="block text-xs uppercase tracking-wide text-slate-400">
        {@label}
      </label>
      <input
        type={@type}
        name={@name}
        id={@id}
        value={Phoenix.HTML.Form.normalize_value(@type, @value)}
        class={[
          "block w-full rounded-md border border-slate-800 bg-slate-900 px-3 py-2",
          "font-mono text-sm text-slate-100 placeholder:text-slate-600",
          "focus:border-accent-500 focus:outline-none focus:ring-1 focus:ring-accent-500",
          @errors != [] && "border-rose-500 focus:border-rose-500 focus:ring-rose-500"
        ]}
        {@rest}
      />
      <p :for={msg <- @errors} class="mt-1 text-xs text-rose-400">{msg}</p>
    </div>
    """
  end

  @doc """
  Renders a named icon. Defaults to a rendered inline SVG for the
  handful of icons loopctl actually uses so the page has no dependency
  on an external heroicons CSS bundle.
  """
  attr :name, :string, required: true
  attr :class, :string, default: nil

  def icon(%{name: "hero-key"} = assigns) do
    ~H"""
    <span class={["inline-flex", @class]} aria-hidden="true" data-icon="hero-key">
      <svg
        xmlns="http://www.w3.org/2000/svg"
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        stroke-width="1.75"
        stroke-linecap="round"
        stroke-linejoin="round"
        class="h-full w-full"
      >
        <path d="M15.75 5.25a3 3 0 1 1 3 3m-9.75 9.75 6.75-6.75" />
        <path d="m5.25 21 4.5-4.5-3-3-4.5 4.5v3h3Z" />
      </svg>
    </span>
    """
  end

  def icon(%{name: "hero-shield-check"} = assigns) do
    ~H"""
    <span class={["inline-flex", @class]} aria-hidden="true" data-icon="hero-shield-check">
      <svg
        xmlns="http://www.w3.org/2000/svg"
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        stroke-width="1.75"
        stroke-linecap="round"
        stroke-linejoin="round"
        class="h-full w-full"
      >
        <path d="M12 3 4 6v5c0 5.5 3.5 9.5 8 10 4.5-.5 8-4.5 8-10V6l-8-3Z" />
        <path d="m9 12 2 2 4-4" />
      </svg>
    </span>
    """
  end

  def icon(%{name: "hero-check-circle"} = assigns) do
    ~H"""
    <span class={["inline-flex", @class]} aria-hidden="true" data-icon="hero-check-circle">
      <svg
        xmlns="http://www.w3.org/2000/svg"
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        stroke-width="1.75"
        stroke-linecap="round"
        stroke-linejoin="round"
        class="h-full w-full"
      >
        <circle cx="12" cy="12" r="9" />
        <path d="m8 12 3 3 5-6" />
      </svg>
    </span>
    """
  end

  def icon(%{name: "hero-x-mark"} = assigns) do
    ~H"""
    <span class={["inline-flex", @class]} aria-hidden="true" data-icon="hero-x-mark">
      <svg
        xmlns="http://www.w3.org/2000/svg"
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        stroke-width="1.75"
        stroke-linecap="round"
        stroke-linejoin="round"
        class="h-full w-full"
      >
        <path d="M6 6l12 12M6 18 18 6" />
      </svg>
    </span>
    """
  end

  def icon(assigns) do
    ~H"""
    <span class={["inline-flex", @class]} aria-hidden="true" data-icon={@name}></span>
    """
  end

  @doc """
  Renders a flash notice group. Kept minimal — loopctl's LiveViews
  surface errors inline, so this is mostly a safety net for transient
  notices from the live socket itself.
  """
  attr :flash, :map, required: true
  attr :id, :string, default: "flash-group"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} class="fixed top-4 right-4 z-50 flex flex-col gap-2">
      <div
        :if={msg = Phoenix.Flash.get(@flash, :info)}
        id="flash-info"
        role="alert"
        phx-click={JS.hide(to: "#flash-info")}
        class="rounded-md border border-accent-500/40 bg-slate-900 px-4 py-3 text-sm text-slate-200"
      >
        {msg}
      </div>
      <div
        :if={msg = Phoenix.Flash.get(@flash, :error)}
        id="flash-error"
        role="alert"
        phx-click={JS.hide(to: "#flash-error")}
        class="rounded-md border border-rose-500/50 bg-slate-900 px-4 py-3 text-sm text-rose-200"
      >
        {msg}
      </div>
    </div>
    """
  end

  @doc false
  def translate_error({msg, opts}) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "<%= #{key} %>", fn _ -> to_string(value) end)
      |> String.replace("%{#{key}}", to_string(value))
    end)
  end

  def translate_error(msg) when is_binary(msg), do: msg
end
