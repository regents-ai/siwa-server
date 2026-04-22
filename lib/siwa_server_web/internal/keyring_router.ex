defmodule SiwaServerWeb.Internal.KeyringRouter do
  @moduledoc """
  Internal routes for the local wallet service.
  """

  use Plug.Router
  require Logger

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
    case run_keyring_request(:create_wallet, fn -> SiwaKeyring.create_wallet() end) do
      {:ok, wallet} -> send_json(conn, 200, wallet)
      {:error, _reason} -> send_error(conn, 422, "wallet_create_failed")
    end
  end

  post "/has-wallet" do
    case run_keyring_request(:has_wallet, fn -> SiwaKeyring.has_wallet?() end) do
      {:ok, result} -> send_json(conn, 200, result)
      {:error, _reason} -> send_error(conn, 422, "wallet_check_failed")
    end
  end

  post "/get-address" do
    case run_keyring_request(:get_address, fn -> SiwaKeyring.get_address() end) do
      {:ok, address} -> send_json(conn, 200, %{address: address})
      {:error, :wallet_missing} -> send_error(conn, 404, "wallet_not_found")
      {:error, _reason} -> send_error(conn, 422, "wallet_lookup_failed")
    end
  end

  post "/sign-message" do
    with {:ok, message} <- required_text(conn.body_params, "message", :message_required),
         {:ok, signature} <-
           run_keyring_request(:sign_message, fn -> SiwaKeyring.sign_message(message) end) do
      send_json(conn, 200, %{signature: signature})
    else
      {:error, :message_required} -> send_error(conn, 400, "message_required")
      {:error, _reason} -> send_error(conn, 422, "message_sign_failed")
    end
  end

  post "/sign-raw-message" do
    with {:ok, payload} <- required_text(conn.body_params, "payload", :payload_required),
         {:ok, signature} <-
           run_keyring_request(:sign_raw_message, fn -> SiwaKeyring.sign_raw_message(payload) end) do
      send_json(conn, 200, %{signature: signature})
    else
      {:error, :payload_required} -> send_error(conn, 400, "payload_required")
      {:error, _reason} -> send_error(conn, 422, "raw_message_sign_failed")
    end
  end

  post "/sign-transaction" do
    with {:ok, transaction} <-
           required_object(conn.body_params, "transaction", :transaction_required),
         {:ok, signed} <-
           run_keyring_request(:sign_transaction, fn ->
             SiwaKeyring.sign_transaction(transaction)
           end) do
      send_json(conn, 200, signed)
    else
      {:error, :transaction_required} -> send_error(conn, 400, "transaction_required")
      {:error, _reason} -> send_error(conn, 422, "transaction_sign_failed")
    end
  end

  post "/sign-authorization" do
    with {:ok, authorization} <-
           required_object(conn.body_params, "authorization", :authorization_required),
         {:ok, signed} <-
           run_keyring_request(:sign_authorization, fn ->
             SiwaKeyring.sign_authorization(authorization)
           end) do
      send_json(conn, 200, signed)
    else
      {:error, :authorization_required} -> send_error(conn, 400, "authorization_required")
      {:error, _reason} -> send_error(conn, 422, "authorization_sign_failed")
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
      :ok ->
        conn

      {:error, reason} ->
        Logger.warning("keyring request authorization failed: #{inspect(reason)}")
        conn |> send_error(401, "unauthorized") |> halt()
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

  defp required_text(params, key, error_code) do
    case Map.get(params, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, error_code}
          _trimmed -> {:ok, value}
        end

      _value ->
        {:error, error_code}
    end
  end

  defp required_object(params, key, error_code) do
    case Map.get(params, key) do
      value when is_map(value) and map_size(value) > 0 -> {:ok, value}
      _value -> {:error, error_code}
    end
  end

  defp run_keyring_request(action, fun) do
    fun.()
  rescue
    error ->
      Logger.error(
        "keyring #{action} crashed: #{Exception.format(:error, error, __STACKTRACE__)}"
      )

      {:error, :internal_failure}
  catch
    kind, reason ->
      Logger.error("keyring #{action} exited: #{inspect({kind, reason})}")
      {:error, :internal_failure}
  else
    {:ok, result} ->
      {:ok, result}

    {:error, reason} = error ->
      Logger.warning("keyring #{action} failed: #{inspect(reason)}")
      error

    other ->
      Logger.error("keyring #{action} returned an unexpected response: #{inspect(other)}")
      {:error, :internal_failure}
  end

  defp header(conn, key), do: Plug.Conn.get_req_header(conn, key) |> List.first() |> to_string()

  defp send_error(conn, status, error) do
    send_json(conn, status, %{error: error})
  end

  defp send_json(conn, status, payload) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(payload))
  end
end
