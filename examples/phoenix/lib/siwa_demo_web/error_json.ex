defmodule SiwaDemoWeb.ErrorJSON do
  @moduledoc false

  def render(template, _assigns),
    do: %{error: %{message: Phoenix.Controller.status_message_from_template(template)}}
end
