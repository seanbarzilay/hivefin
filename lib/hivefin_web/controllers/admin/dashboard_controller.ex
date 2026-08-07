defmodule HivefinWeb.Admin.DashboardController do
  use HivefinWeb, :controller

  alias Hivefin.Accounts
  alias Hivefin.Jellyfin.SystemInfo
  alias Hivefin.Library.LibraryContext

  def index(conn, _params) do
    libraries = LibraryContext.list_libraries_with_stats()

    render(conn, :index,
      page_title: "Dashboard",
      active: :dashboard,
      current_user: conn.assigns.current_admin,
      libraries: libraries,
      user_count: Accounts.count_users(),
      item_count: LibraryContext.count_all_items(),
      system: %{
        product: SystemInfo.product_name(),
        version: SystemInfo.version(),
        hivefin_version: SystemInfo.hivefin_version(),
        server_name: SystemInfo.server_name()
      }
    )
  end
end
