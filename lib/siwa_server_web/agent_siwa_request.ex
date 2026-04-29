defmodule SiwaServerWeb.AgentSiwaRequest do
  @moduledoc false

  defmodule Nonce do
    use Ecto.Schema

    @primary_key false
    embedded_schema do
      field :wallet_address, :string
      field :chain_id, :integer
      field :registry_address, :string
      field :token_id, :string
      field :audience, :string
    end
  end

  defmodule Verify do
    use Ecto.Schema

    @primary_key false
    embedded_schema do
      field :wallet_address, :string
      field :chain_id, :integer
      field :registry_address, :string
      field :token_id, :string
      field :audience, :string
      field :nonce, :string
      field :message, :string
      field :signature, :string
    end
  end

  defmodule HttpVerify do
    use Ecto.Schema

    @primary_key false
    embedded_schema do
      field :method, :string
      field :path, :string
      field :headers, :map
      field :body, :string
    end
  end

  @nonce_fields ~w(wallet_address chain_id registry_address token_id audience)
  @verify_fields ~w(wallet_address chain_id registry_address token_id audience nonce message signature)
  @http_verify_fields ~w(method path headers body)
  @base_chain_ids [8453, 84_532]

  def cast_nonce(params), do: cast(params, Nonce, @nonce_fields, @nonce_fields)
  def cast_verify(params), do: cast(params, Verify, @verify_fields, @verify_fields)

  def cast_http_verify(params),
    do: cast(params, HttpVerify, @http_verify_fields, @http_verify_fields -- ["body"])

  def to_params(%Nonce{} = request) do
    %{
      "wallet_address" => request.wallet_address,
      "chain_id" => request.chain_id,
      "registry_address" => request.registry_address,
      "token_id" => request.token_id,
      "audience" => request.audience
    }
  end

  def to_params(%Verify{} = request) do
    request
    |> Map.from_struct()
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
  end

  def to_params(%HttpVerify{} = request) do
    %{
      "method" => request.method,
      "path" => request.path,
      "headers" => request.headers,
      "body" => request.body
    }
  end

  defp cast(params, module, allowed_fields, required_fields) when is_map(params) do
    with :ok <- ensure_no_extra_fields(params, allowed_fields),
         {:ok, values} <- cast_fields(params, allowed_fields, required_fields) do
      {:ok, struct(module, values)}
    end
  end

  defp cast(_params, _module, _allowed_fields, _required_fields), do: invalid_request()

  defp ensure_no_extra_fields(params, allowed_fields) do
    extras = params |> Map.keys() |> Enum.reject(&(&1 in allowed_fields))

    if extras == [], do: :ok, else: invalid_request()
  end

  defp cast_fields(params, allowed_fields, required_fields) do
    Enum.reduce_while(allowed_fields, {:ok, %{}}, fn field, {:ok, acc} ->
      case cast_field(params, field, field in required_fields) do
        {:ok, :skip} -> {:cont, {:ok, acc}}
        {:ok, value} -> {:cont, {:ok, Map.put(acc, String.to_atom(field), value)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp cast_field(params, "chain_id", true) do
    case Map.get(params, "chain_id") do
      value when is_integer(value) ->
        if value in @base_chain_ids, do: {:ok, value}, else: invalid_request()

      _value ->
        invalid_request()
    end
  end

  defp cast_field(params, "headers", true) do
    case Map.get(params, "headers") do
      headers when is_map(headers) ->
        if Enum.all?(headers, fn {key, value} -> is_binary(key) and is_binary(value) end),
          do: {:ok, headers},
          else: invalid_request()

      _value ->
        invalid_request()
    end
  end

  defp cast_field(params, field, true) do
    case Map.get(params, field) do
      value when is_binary(value) ->
        if String.trim(value) == "", do: invalid_request(), else: {:ok, value}

      _value ->
        invalid_request()
    end
  end

  defp cast_field(params, field, false) do
    case Map.get(params, field) do
      nil -> {:ok, :skip}
      value when is_binary(value) -> {:ok, value}
      _value -> invalid_request()
    end
  end

  defp invalid_request,
    do: {:error, {400, "invalid_request", "request body does not match the SIWA contract"}}
end
