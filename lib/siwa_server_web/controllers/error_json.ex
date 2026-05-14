defmodule SiwaServerWeb.ErrorJSON do
  @moduledoc """
  This module is invoked by your endpoint in case of errors on JSON requests.

  See config/config.exs.
  """

  def render("error.json", %{code: code, message: message}) do
    error(code, message)
  end

  def render(template, _assigns) do
    error(
      status_code_from_template(template),
      Phoenix.Controller.status_message_from_template(template)
    )
  end

  def error(code, message) when is_binary(code) and is_binary(message) do
    %{
      "ok" => false,
      "error" => %{
        "code" => code,
        "message" => message
      }
    }
  end

  def error(code, message, meta) when is_binary(code) and is_binary(message) and is_map(meta) do
    %{
      "ok" => false,
      "error" =>
        Map.merge(
          %{
            "code" => code,
            "message" => message
          },
          meta
        )
    }
  end

  defp status_code_from_template(<<code::binary-size(3), ".json">>) do
    case code do
      "400" -> "bad_request"
      "401" -> "unauthorized"
      "404" -> "not_found"
      "413" -> "request_body_too_large"
      "415" -> "unsupported_media_type"
      "500" -> "internal_server_error"
      _code -> "request_failed"
    end
  end

  defp status_code_from_template(_template), do: "request_failed"
end
