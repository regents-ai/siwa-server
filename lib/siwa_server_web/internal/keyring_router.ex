defmodule SiwaServerWeb.Internal.KeyringRouter do
  use Plug.Router

  plug(Plug.Logger)

  plug(Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason,
    body_reader: {__MODULE__, :read_body, []}
  )

  plug(:match)
  plug(:authorize)
  plug(:dispatch)

  get "/health" do
    send_json(conn, 200, %{status: "ok"})
  end

  post "/create-wallet" do
    case SiwaKeyring.create_wallet() do
      {:ok, wallet} -> send_json(conn, 200, wallet)
      {:error, reason} -> send_json(conn, 422, %{error: inspect(reason)})
    end
  end

  post "/has-wallet" do
    {:ok, result} = SiwaKeyring.has_wallet?()
    send_json(conn, 200, result)
  end

  post "/get-address" do
    case SiwaKeyring.get_address() do
      {:ok, address} -> send_json(conn, 200, %{address: address})
      {:error, reason} -> send_json(conn, 404, %{error: inspect(reason)})
    end
  end

  post "/sign-message" do
    case SiwaKeyring.sign_message(conn.body_params["message"] || "") do
      {:ok, signature} -> send_json(conn, 200, %{signature: signature})
      {:error, reason} -> send_json(conn, 422, %{error: inspect(reason)})
    end
  end

  post "/sign-raw-message" do
    case SiwaKeyring.sign_raw_message(conn.body_params["payload"] || "") do
      {:ok, signature} -> send_json(conn, 200, %{signature: signature})
      {:error, reason} -> send_json(conn, 422, %{error: inspect(reason)})
    end
  end

  post "/sign-transaction" do
    case SiwaKeyring.sign_transaction(conn.body_params["transaction"] || %{}) do
      {:ok, signed} -> send_json(conn, 200, signed)
      {:error, reason} -> send_json(conn, 422, %{error: inspect(reason)})
    end
  end

  post "/sign-authorization" do
    case SiwaKeyring.sign_authorization(conn.body_params["authorization"] || %{}) do
      {:ok, signed} -> send_json(conn, 200, signed)
      {:error, reason} -> send_json(conn, 422, %{error: inspect(reason)})
    end
  end

  match _ do
    send_json(conn, 404, %{error: "not_found"})
  end

  defp authorize(%Plug.Conn{request_path: "/internal/keyring/health"} = conn, _opts), do: conn

  defp authorize(conn, _opts) do
    secret = Application.fetch_env!(:siwa_keyring, :secret)
    body = conn.private[:raw_body] || Jason.encode!(conn.body_params || %{})

    case SiwaKeyring.Auth.verify_hmac(
           secret,
           conn.method,
           conn.request_path,
           body,
           header(conn, "x-keyring-timestamp"),
           header(conn, "x-keyring-signature")
         ) do
      :ok -> conn
      {:error, reason} -> conn |> send_json(401, %{error: inspect(reason)}) |> halt()
    end
  end

  def read_body(conn, opts) do
    previous = conn.private[:raw_body] || ""

    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} ->
        full_body = previous <> body
        {:ok, body, Plug.Conn.put_private(conn, :raw_body, full_body)}

      {:more, body, conn} ->
        full_body = previous <> body
        {:more, body, Plug.Conn.put_private(conn, :raw_body, full_body)}
    end
  end

  defp header(conn, key), do: Plug.Conn.get_req_header(conn, key) |> List.first() |> to_string()

  defp send_json(conn, status, payload) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(payload))
  end
end
