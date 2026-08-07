defmodule HivefinWeb.CoreComponents do
  @moduledoc """
  Minimal UI helpers for the admin console.
  """
  use Phoenix.Component

  alias Phoenix.LiveView.JS

  attr :id, :string, default: "flash-info"
  attr :flash, :map, required: true
  attr :kind, :atom, values: [:info, :error], default: :info

  def flash(assigns) do
    ~H"""
    <div
      :if={msg = Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      role="alert"
      class={[
        "mb-4 rounded-lg border px-4 py-3 text-sm",
        @kind == :info && "border-primary/30 bg-primary/10 text-base-content",
        @kind == :error && "border-error/40 bg-error/10 text-error"
      ]}
    >
      {msg}
    </div>
    """
  end

  attr :title, :string, default: nil
  slot :inner_block, required: true
  slot :actions

  def page_header(assigns) do
    ~H"""
    <div class="mb-6 flex flex-wrap items-end justify-between gap-3">
      <div>
        <h1 :if={@title} class="text-2xl font-semibold tracking-tight">{@title}</h1>
        <p :if={@inner_block != []} class="mt-1 text-sm text-base-content/60">
          {render_slot(@inner_block)}
        </p>
      </div>
      <div :if={@actions != []} class="flex flex-wrap gap-2">
        {render_slot(@actions)}
      </div>
    </div>
    """
  end

  attr :class, :string, default: nil
  slot :inner_block, required: true

  def card(assigns) do
    ~H"""
    <div class={["rounded-xl border border-base-300 bg-base-200/60 p-5 shadow-sm", @class]}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  Renders a simple button. Use `variant` for style: primary | ghost | danger | secondary.
  """
  attr :type, :string, default: "button"
  attr :variant, :string, default: "primary"
  attr :class, :string, default: nil
  attr :rest, :global, include: ~w(disabled form name value)
  slot :inner_block, required: true

  def button(assigns) do
    ~H"""
    <button
      type={@type}
      class={[
        "btn btn-sm",
        @variant == "primary" && "btn-primary",
        @variant == "secondary" && "btn-secondary",
        @variant == "ghost" && "btn-ghost",
        @variant == "danger" && "btn-error",
        @class
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  attr :for, :any, default: nil
  attr :as, :any, default: nil
  attr :action, :string, default: nil
  attr :method, :string, default: "post"
  attr :class, :string, default: nil
  attr :multipart, :boolean, default: false
  slot :inner_block, required: true

  def simple_form(assigns) do
    ~H"""
    <.form
      for={@for}
      as={@as}
      action={@action}
      method={@method}
      multipart={@multipart}
      class={["space-y-4", @class]}
    >
      {render_slot(@inner_block)}
    </.form>
    """
  end

  attr :id, :string, default: nil
  attr :name, :string, required: true
  attr :label, :string, default: nil
  attr :type, :string, default: "text"
  attr :value, :any, default: nil
  attr :required, :boolean, default: false
  attr :rest, :global, include: ~w(autocomplete placeholder minlength maxlength min max step disabled readonly)

  def input(assigns) do
    ~H"""
    <label class="form-control w-full">
      <div :if={@label} class="label py-1">
        <span class="label-text text-sm font-medium">{@label}</span>
      </div>
      <input
        id={@id || @name}
        type={@type}
        name={@name}
        value={@value}
        required={@required}
        class="input input-bordered w-full bg-base-100"
        {@rest}
      />
    </label>
    """
  end

  attr :id, :string, default: nil
  attr :name, :string, required: true
  attr :label, :string, default: nil
  attr :value, :any, default: nil
  attr :options, :list, required: true
  attr :required, :boolean, default: false
  attr :rest, :global

  def select(assigns) do
    ~H"""
    <label class="form-control w-full">
      <div :if={@label} class="label py-1">
        <span class="label-text text-sm font-medium">{@label}</span>
      </div>
      <select
        id={@id || @name}
        name={@name}
        required={@required}
        class="select select-bordered w-full bg-base-100"
        {@rest}
      >
        <option :for={{label, val} <- @options} value={val} selected={to_string(val) == to_string(@value)}>
          {label}
        </option>
      </select>
    </label>
    """
  end

  def show(js \\ %JS{}, selector) do
    JS.show(js, to: selector)
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js, to: selector)
  end
end
