defmodule HivefinWeb.ErrorHTML do
  @moduledoc """
  Renders HTML error pages.
  """
  use HivefinWeb, :html

  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end
