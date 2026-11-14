defmodule SiwaServerWeb.FallbackController do
  use SiwaServerWeb, :controller

  alias SiwaServerWeb.ErrorJSON

  def call(conn, {:error, {status, code, message}}) do
    conn
    |> put_status(status)
    |> json(ErrorJSON.refusal(conn, code, message))
  end

  # A control API body whose fields broke their rules: each field's reasons.
  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(
      ErrorJSON.refusal(conn, "control_fields_invalid", "some fields are not valid", %{
        "fields" => fields(changeset)
      })
    )
  end

  defp fields(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _whole, name ->
        opts |> Keyword.get(String.to_existing_atom(name), name) |> to_string()
      end)
    end)
  end
end
