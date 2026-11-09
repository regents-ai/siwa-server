defmodule SiwaServerWeb.ErrorJSON do
  @moduledoc """
  The body of every error answer. The endpoint renders its own errors here
  (see config/config.exs); a refusal also carries the agent's next steps from
  `SiwaServerWeb.Help`.
  """

  alias SiwaServerWeb.Help

  def render(<<status::binary-size(3), ".json">> = template, _assigns) do
    code =
      case status do
        "400" -> "bad_request"
        "401" -> "unauthorized"
        "404" -> "not_found"
        "413" -> "request_body_too_large"
        "415" -> "unsupported_media_type"
        "500" -> "internal_server_error"
        _status -> "request_failed"
      end

    %{
      "error" => %{
        "code" => code,
        "message" => Phoenix.Controller.status_message_from_template(template)
      }
    }
  end

  @doc "A refusal's body: its code and message, the agent's next steps, and any `extra` fields."
  @spec refusal(Plug.Conn.t(), String.t(), String.t(), map()) :: map()
  def refusal(conn, code, message, extra \\ %{}) do
    %{
      "error" =>
        Map.merge(%{"code" => code, "message" => message, "hint" => Help.hint(code, conn)}, extra)
    }
  end
end
