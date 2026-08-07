defmodule HivefinWeb.Layouts do
  @moduledoc """
  Layouts for HTML responses (admin console).
  """
  use HivefinWeb, :html

  embed_templates "layouts/*"

  attr :flash, :map, required: true
  attr :current_user, :any, default: nil
  attr :active, :atom, default: :dashboard
  slot :inner_block, required: true

  def admin(assigns) do
    ~H"""
    <div class="min-h-screen bg-base-100 text-base-content">
      <div class="navbar border-b border-base-300 bg-base-200/80 px-4 backdrop-blur">
        <div class="flex-1 gap-3">
          <a href={~p"/admin"} class="text-lg font-semibold tracking-tight">
            Hivefin <span class="text-primary">Admin</span>
          </a>
          <nav class="hidden gap-1 sm:flex">
            <.nav_link href={~p"/admin"} active={@active == :dashboard}>Dashboard</.nav_link>
            <.nav_link href={~p"/admin/libraries"} active={@active == :libraries}>Libraries</.nav_link>
            <.nav_link href={~p"/admin/users"} active={@active == :users}>Users</.nav_link>
            <.nav_link href={~p"/admin/settings"} active={@active == :settings}>Settings</.nav_link>
          </nav>
        </div>
        <div class="flex-none gap-2">
          <span :if={@current_user} class="hidden text-sm text-base-content/60 sm:inline">
            {@current_user.username}
          </span>
          <.form :if={@current_user} for={%{}} action={~p"/admin/logout"} method="post">
            <input type="hidden" name="_method" value="delete" />
            <.button type="submit" variant="ghost">Log out</.button>
          </.form>
        </div>
      </div>

      <main class="mx-auto max-w-5xl px-4 py-8">
        <.flash kind={:info} flash={@flash} />
        <.flash kind={:error} flash={@flash} id="flash-error" />
        {render_slot(@inner_block)}
      </main>
    </div>
    """
  end

  attr :href, :string, required: true
  attr :active, :boolean, default: false
  slot :inner_block, required: true

  defp nav_link(assigns) do
    ~H"""
    <a
      href={@href}
      class={[
        "rounded-lg px-3 py-1.5 text-sm font-medium transition",
        @active && "bg-primary/15 text-primary",
        !@active && "text-base-content/70 hover:bg-base-300/60 hover:text-base-content"
      ]}
    >
      {render_slot(@inner_block)}
    </a>
    """
  end
end
