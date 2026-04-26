defmodule SiwaServer.Siwa.SignatureInput do
  @moduledoc false

  @signature_input_regex ~r/^sig1=\((?<components>.+)\)(?<params>(?:;.+)*)$/
  @positive_int_regex ~r/^[1-9][0-9]*$/
  @signature_components ~w(
    @method
    @path
    x-siwa-receipt
    x-key-id
    x-timestamp
    x-agent-wallet-address
    x-agent-chain-id
    x-agent-registry-address
    x-agent-token-id
    content-digest
  )

  def parse(signature_input) when is_binary(signature_input) do
    with %{"components" => components_blob, "params" => params_blob} <-
           Regex.named_captures(@signature_input_regex, String.trim(signature_input)),
         {:ok, components} <- parse_components(components_blob),
         {:ok, params} <- parse_signature_params(params_blob) do
      {:ok,
       %{
         components: components,
         created: params.created,
         expires: params.expires,
         nonce: params.nonce,
         key_id: params.key_id,
         signature_params:
           "(#{Enum.map_join(components, " ", &~s("#{&1}"))})" <>
             ";created=#{params.created}" <>
             ";expires=#{params.expires}" <>
             ~s(;nonce="#{params.nonce}") <>
             if(params.key_id, do: ~s(;keyid="#{params.key_id}"), else: "")
       }}
    else
      _ -> {:error, {401, "http_signature_input_invalid", "invalid signature-input header"}}
    end
  end

  def parse(_value),
    do: {:error, {401, "http_signature_input_invalid", "invalid signature-input header"}}

  defp parse_components(blob) when is_binary(blob) do
    case(
      blob
      |> String.split(~r/\s+/, trim: true)
      |> Enum.reduce_while([], &reduce_signature_component/2)
    ) do
      {:error, reason} -> {:error, reason}
      components -> {:ok, Enum.reverse(components)}
    end
  end

  defp parse_signature_params(blob) do
    case(
      blob
      |> String.split(";", trim: true)
      |> Enum.reduce_while(%{}, &reduce_signature_param/2)
    ) do
      {:error, reason} ->
        {:error, reason}

      entries ->
        with {:ok, created} <- parse_positive_integer(entries["created"]),
             {:ok, expires} <- parse_positive_integer(entries["expires"]),
             {:ok, nonce} <- required_value(entries["nonce"]),
             {:ok, key_id} <- required_value(entries["keyid"]),
             true <- expires > created do
          {:ok,
           %{
             created: created,
             expires: expires,
             nonce: nonce,
             key_id: key_id
           }}
        else
          _ -> {:error, :invalid}
        end
    end
  end

  defp reduce_signature_component(token, components) do
    case parse_component(token) do
      {:ok, component} ->
        if component in components do
          {:halt, {:error, :invalid}}
        else
          {:cont, [component | components]}
        end

      {:error, _reason} ->
        {:halt, {:error, :invalid}}
    end
  end

  defp reduce_signature_param(entry, acc) do
    case parse_signature_param_entry(entry, acc) do
      {:ok, updated_acc} -> {:cont, updated_acc}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp parse_signature_param_entry(entry, acc) do
    case String.split(entry, "=", parts: 2) do
      [key, value] ->
        if Map.has_key?(acc, key) do
          {:error, :duplicate}
        else
          {:ok, Map.put(acc, key, String.trim(value, "\""))}
        end

      _ ->
        {:error, :invalid}
    end
  end

  defp parse_component(token) when is_binary(token) do
    if String.starts_with?(token, "\"") and String.ends_with?(token, "\"") do
      normalized = token |> String.trim_leading("\"") |> String.trim_trailing("\"")

      if normalized in @signature_components do
        {:ok, normalized}
      else
        {:error, :invalid}
      end
    else
      {:error, :invalid}
    end
  end

  defp parse_positive_integer(value) when is_binary(value) do
    if Regex.match?(@positive_int_regex, String.trim(value)) do
      {:ok, String.to_integer(String.trim(value))}
    else
      {:error, :invalid}
    end
  end

  defp parse_positive_integer(_value), do: {:error, :invalid}

  defp required_value(nil), do: {:error, :missing}
  defp required_value(""), do: {:error, :missing}
  defp required_value(value), do: {:ok, value}
end
