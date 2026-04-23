defmodule SiwaServer.Siwa.Message do
  @moduledoc false

  alias SiwaServer.Siwa.Error

  @domain "regent.cx"
  @verify_uri "https://regent.cx/v1/agent/siwa/verify"
  @positive_int_regex ~r/^[1-9][0-9]*$/
  @field_names ["URI", "Version", "Chain ID", "Nonce", "Issued At"]

  @spec validate(String.t(), String.t(), pos_integer(), String.t()) ::
          :ok | {:error, {401, String.t(), String.t()}}
  def validate(message, wallet_address, chain_id, nonce) do
    with {:ok, parsed} <- parse(message),
         true <- parsed.wallet_address == wallet_address,
         true <- parsed.chain_id == chain_id,
         true <- parsed.nonce == nonce do
      :ok
    else
      {:error, reason} ->
        Error.error(Error.unauthorized("signature_invalid", reason))

      false ->
        Error.error(
          Error.unauthorized(
            "signature_invalid",
            "message does not match the requested SIWA claims"
          )
        )
    end
  end

  defp parse(message) when is_binary(message) do
    normalized_message = String.trim(message)
    lines = String.split(normalized_message, "\n", trim: false)

    with [header, wallet_address, "" | rest] <- lines,
         true <- header == "#{@domain} wants you to sign in with your Ethereum account:",
         {:ok, statement_lines, field_lines} <- split_statement_and_fields(rest),
         {:ok, fields} <- parse_fields(field_lines),
         :ok <- validate_fields(fields),
         true <- Enum.all?(statement_lines, &(String.trim(&1) != "")) do
      {:ok,
       %{
         wallet_address: String.downcase(String.trim(wallet_address)),
         chain_id: parse_positive_integer!(fields["Chain ID"]),
         nonce: fields["Nonce"],
         issued_at: fields["Issued At"],
         statement: Enum.join(statement_lines, "\n")
       }}
    else
      false -> {:error, "message does not match the canonical SIWA format"}
      _ -> {:error, "message does not match the canonical SIWA format"}
    end
  end

  defp parse(_message), do: {:error, "message does not match the canonical SIWA format"}

  defp split_statement_and_fields(lines) do
    {statement_lines, remainder} = Enum.split_while(lines, &(&1 != ""))

    case remainder do
      [] -> {:ok, statement_lines, lines}
      [_blank | field_lines] -> {:ok, statement_lines, field_lines}
    end
  end

  defp parse_fields(field_lines) do
    Enum.reduce_while(field_lines, {:ok, %{}}, fn line, {:ok, fields} ->
      case parse_field(line, fields) do
        {:ok, updated_fields} -> {:cont, {:ok, updated_fields}}
        {:error, _reason} -> {:halt, {:error, :invalid}}
      end
    end)
  end

  defp validate_fields(fields) do
    with true <- Enum.sort(Map.keys(fields)) == Enum.sort(@field_names),
         "1" <- Map.get(fields, "Version"),
         @verify_uri <- Map.get(fields, "URI"),
         {:ok, _chain_id} <- parse_positive_integer(Map.get(fields, "Chain ID")),
         {:ok, _nonce} <- required_value(Map.get(fields, "Nonce")),
         {:ok, issued_at} <- required_value(Map.get(fields, "Issued At")),
         {:ok, _datetime, 0} <- DateTime.from_iso8601(issued_at) do
      :ok
    else
      _ -> {:error, "message does not match the canonical SIWA format"}
    end
  end

  defp parse_field(line, fields) do
    case String.split(line, ": ", parts: 2) do
      [key, value] ->
        cond do
          key not in @field_names -> {:error, :invalid}
          value == "" -> {:error, :invalid}
          Map.has_key?(fields, key) -> {:error, :invalid}
          true -> {:ok, Map.put(fields, key, value)}
        end

      _ ->
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
  defp parse_positive_integer!(value), do: value |> parse_positive_integer() |> elem(1)

  defp required_value(nil), do: {:error, :missing}
  defp required_value(""), do: {:error, :missing}
  defp required_value(value), do: {:ok, value}
end
