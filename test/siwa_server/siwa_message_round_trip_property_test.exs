defmodule SiwaServer.SiwaMessageRoundTripPropertyTest do
  use SiwaServer.DataCase, async: false
  use ExUnitProperties

  alias SiwaServer.{Ethereum, RuntimeConfig}
  alias SiwaServer.Siwa.Wallet

  @alphanumeric Enum.concat(?a..?z, ?0..?9)

  setup do
    previous = Application.get_env(:siwa_server, :siwa)
    on_exit(fn -> Application.put_env(:siwa_server, :siwa, previous) end)
    %{previous: previous}
  end

  # The sign-in message is written from the challenge's fields and read back by the
  # server: it names exactly those fields, the server accepts exactly that text once,
  # refuses any other text even when the wallet signed it, and the receipt it gives
  # carries the same fields.
  property "the wallet sign-in message round-trips through issue and verify",
           %{previous: previous} do
    check all audience <- audience(),
              host <- host(),
              chain_id <- member_of(Ethereum.wallet_chain_ids()),
              upcase <- list_of(boolean(), length: 40),
              edit_at <- non_negative_integer(),
              edit <- member_of(["x", "0", " ", "\n", "Z"]),
              max_runs: 60 do
      origin = "https://" <> host

      Application.put_env(
        :siwa_server,
        :siwa,
        Keyword.put(previous, :wallet_origins, %{audience => [origin]})
      )

      {:ok, signer} = Siwa.LocalSigner.new()
      wallet = String.downcase(signer.address)

      params = %{
        "wallet_address" => mixed_case(wallet, upcase),
        "chain_id" => chain_id,
        "audience" => audience
      }

      assert {:ok, %{"code" => "nonce_issued", "data" => data}} = Wallet.issue_nonce(params)
      message = data["message"]

      assert %{
               authority: ^host,
               address: address,
               uri: ^origin,
               chain_id: chain,
               nonce: nonce,
               issued_at: issued_at,
               expires_at: expires_at,
               resource: resource
             } = read_message(message)

      assert String.downcase(address) == wallet
      assert {chain, nonce} == {Integer.to_string(chain_id), data["nonce"]}
      assert {issued_at, expires_at} == {data["issuedAt"], data["expiresAt"]}
      assert resource == "urn:regent:audience:" <> audience

      at = rem(edit_at, String.length(message) + 1)
      edited = String.slice(message, 0, at) <> edit <> String.slice(message, at..-1//1)

      assert {:error, {401, "message_invalid", _}} =
               Wallet.verify(proof(params, signer, data["nonce"], edited))

      assert {:ok, %{"code" => "wallet_verified", "data" => verified}} =
               Wallet.verify(proof(params, signer, data["nonce"], message))

      assert {verified["walletAddress"], verified["chainId"], verified["audience"]} ==
               {wallet, chain_id, audience}

      {:ok, secret} = RuntimeConfig.siwa_receipt_secret()

      assert {:ok, claims} =
               Siwa.verify_receipt(verified["receipt"],
                 receipt_secret: secret,
                 audience: audience
               )

      assert Map.take(claims, ["typ", "sub", "key_id", "aud", "chain_id", "nonce"]) == %{
               "typ" => "siwa_wallet_receipt",
               "sub" => wallet,
               "key_id" => wallet,
               "aud" => audience,
               "chain_id" => chain_id,
               "nonce" => data["nonce"]
             }

      assert {:error, {404, "nonce_not_found", _}} =
               Wallet.verify(proof(params, signer, data["nonce"], message))
    end
  end

  defp proof(params, signer, nonce, message) do
    {:ok, signature} = Siwa.LocalSigner.sign_message(signer, message)
    Map.merge(params, %{"nonce" => nonce, "message" => message, "signature" => signature})
  end

  # Reads the lines a person sees in their wallet, in the order they appear.
  defp read_message(message) do
    [header, address, "", _statement, "" | lines] = String.split(message, "\n")

    [authority] =
      Regex.run(~r/^(.+) wants you to sign in with your Ethereum account:$/, header,
        capture: :all_but_first
      )

    [
      "URI: " <> uri,
      "Version: 1",
      "Chain ID: " <> chain_id,
      "Nonce: " <> nonce,
      "Issued At: " <> issued_at,
      "Expiration Time: " <> expires_at,
      "Resources:",
      "- " <> resource
    ] = lines

    %{
      authority: authority,
      address: address,
      uri: uri,
      chain_id: chain_id,
      nonce: nonce,
      issued_at: issued_at,
      expires_at: expires_at,
      resource: resource
    }
  end

  defp mixed_case("0x" <> hex, upcase) do
    "0x" <>
      (hex
       |> String.graphemes()
       |> Enum.zip(upcase)
       |> Enum.map_join(fn {char, up?} -> if up?, do: String.upcase(char), else: char end))
  end

  defp audience do
    gen all first <- member_of(@alphanumeric),
            rest <- string(Enum.concat(@alphanumeric, [?_, ?-]), max_length: 20) do
      <<first>> <> rest
    end
  end

  defp host do
    label = string(@alphanumeric, min_length: 1, max_length: 12)

    gen all labels <- list_of(label, min_length: 1, max_length: 3),
            tld <- string(?a..?z, min_length: 2, max_length: 6) do
      Enum.join(labels ++ [tld], ".")
    end
  end
end
