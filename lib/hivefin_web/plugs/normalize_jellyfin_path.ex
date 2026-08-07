defmodule HivefinWeb.Plugs.NormalizeJellyfinPath do
  @moduledoc """
  Canonicalizes common Jellyfin API path casings.

  jellyfin-web occasionally requests lowercase paths (`/system/info/public`).
  Our SPA catch-all used to answer those with `index.html`, so the client never
  received `ServerName` and showed the server as "undefined".
  """

  @behaviour Plug

  # Lowercased path_info segments → canonical segments used in the router.
  @canonical %{
    ["system", "info", "public"] => ["System", "Info", "Public"],
    ["system", "info"] => ["System", "Info"],
    ["system", "ping"] => ["System", "Ping"],
    ["system", "endpoint"] => ["System", "Endpoint"],
    ["users", "public"] => ["Users", "Public"],
    ["users", "authenticatebyname"] => ["Users", "AuthenticateByName"],
    ["users", "me"] => ["Users", "Me"],
    # Prefix rules below cover /users/:id and /users/:id/items/latest etc.
    ["branding", "configuration"] => ["Branding", "Configuration"],
    ["branding", "css"] => ["Branding", "Css"],
    ["branding", "css.css"] => ["Branding", "Css"],
    ["quickconnect", "enabled"] => ["QuickConnect", "Enabled"],
    ["startup", "configuration"] => ["Startup", "Configuration"],
    ["localization", "cultures"] => ["Localization", "Cultures"],
    ["localization", "options"] => ["Localization", "Options"],
    ["localization", "countries"] => ["Localization", "Countries"],
    ["localization", "parentalratings"] => ["Localization", "ParentalRatings"],
    ["userviews"] => ["UserViews"],
    ["useritems", "resume"] => ["UserItems", "Resume"],
    ["items"] => ["Items"],
    ["items", "latest"] => ["Items", "Latest"],
    # Prefix rule also covers /items/:id/intros|thememedia|playbackinfo
    ["sessions"] => ["Sessions"],
    ["sessions", "capabilities"] => ["Sessions", "Capabilities"],
    ["sessions", "capabilities", "full"] => ["Sessions", "Capabilities", "Full"],
    ["sessions", "playing"] => ["Sessions", "Playing"],
    ["sessions", "playing", "progress"] => ["Sessions", "Playing", "Progress"],
    ["sessions", "playing", "stopped"] => ["Sessions", "Playing", "Stopped"],
    ["displaypreferences"] => ["DisplayPreferences"],
    ["shows", "nextup"] => ["Shows", "NextUp"]
  }

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{path_info: path_info} = conn, _opts) do
    key = Enum.map(path_info, &String.downcase/1)

    case Map.get(@canonical, key) do
      nil ->
        # Prefix-normalize first segment for multi-segment API resources
        # e.g. /items/:id/images/primary, /users/:id/items
        case normalize_prefix(path_info) do
          ^path_info -> conn
          new_path -> %{conn | path_info: new_path}
        end

      canonical ->
        %{conn | path_info: canonical}
    end
  end

  defp normalize_prefix([]), do: []

  defp normalize_prefix([first | rest]) do
    case String.downcase(first) do
      "items" -> ["Items" | rest]
      "users" -> ["Users" | rest]
      "videos" -> ["Videos" | rest]
      "sessions" -> ["Sessions" | rest]
      "shows" -> ["Shows" | rest]
      "displaypreferences" -> ["DisplayPreferences" | rest]
      "branding" -> ["Branding" | rest]
      "system" -> ["System" | rest]
      "quickconnect" -> ["QuickConnect" | rest]
      "userviews" -> ["UserViews" | rest]
      "useritems" -> ["UserItems" | rest]
      "startup" -> ["Startup" | rest]
      "localization" -> ["Localization" | rest]
      _ -> [first | rest]
    end
  end
end
