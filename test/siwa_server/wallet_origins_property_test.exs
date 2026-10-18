defmodule SiwaServer.WalletOriginsPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias SiwaServer.WalletOrigins

  @alphanumeric Enum.concat(?a..?z, ?0..?9)

  # Only a bare HTTPS origin on port 443 is approved for wallet sign-in, and it is
  # kept in its one spelling: a trailing slash or spaces around it are dropped.
  property "a bare HTTPS origin is accepted and kept as https://host" do
    check all audience <- audience(),
              host <- host(),
              slash <- member_of(["", "/"]),
              space <- member_of(["", " "]) do
      entry = "#{space}#{audience}=#{space}https://#{host}#{slash}#{space}"
      assert WalletOrigins.parse!(entry) == %{audience => ["https://#{host}"]}
    end
  end

  # A lookalike of an approved origin (another scheme or port, another spelling of the
  # same origin, credentials, a path, query or fragment, a missing slash, a character
  # outside ASCII) is never approved, so no origin can be listed twice under two spellings.
  property "a lookalike of a bare HTTPS origin is refused" do
    check all host <- host(),
              other <- label(),
              lookalike <- lookalike(host, other) do
      assert_raise ArgumentError, fn -> WalletOrigins.parse!("site=" <> lookalike) end
    end
  end

  # A neighbouring host (an extra subdomain, a suffix or a prefix) is an origin of its
  # own, kept under the audience that lists it and never merged with its lookalike.
  property "a neighbouring host stays its own origin under its own audience" do
    check all host <- host(),
              other <- label(),
              neighbour <-
                member_of(["#{other}.#{host}", "#{host}.#{other}.com", "#{other}#{host}"]) do
      assert WalletOrigins.parse!("site=https://#{host},other=https://#{neighbour}") == %{
               "site" => ["https://#{host}"],
               "other" => ["https://#{neighbour}"]
             }
    end
  end

  # One origin listed twice, with or without its trailing slash, belongs to one
  # audience only.
  property "the same origin under two audiences is refused" do
    check all host <- host(),
              slash <- member_of(["", "/"]) do
      assert_raise ArgumentError, fn ->
        WalletOrigins.parse!("site=https://#{host},other=https://#{host}#{slash}")
      end
    end
  end

  defp lookalike(host, other) do
    one_of([
      member_of([
        "http://#{host}",
        "wss://#{host}",
        "ftp://#{host}",
        "https:#{host}",
        "https:/#{host}",
        "https:///#{host}",
        "//#{host}",
        host,
        "https://#{other}@#{host}",
        "https://@#{host}",
        "https://#{other}:pw@#{host}",
        "https://#{host}@#{other}.com",
        "https://#{host}\\@#{other}.com",
        "https://#{host}/#{other}",
        "https://#{host}//",
        "https://#{host}/?",
        "https://#{host}?",
        "https://#{host}?#{other}=1",
        "https://#{host}#",
        "https://#{host}##{other}",
        "https://#{other} #{host}",
        "HTTPS://#{host}",
        "https://#{String.upcase(host)}",
        "https://#{host}:443",
        "https://#{host}:",
        "https://#{host}.",
        "https://*.#{host}",
        "https://*",
        "https://.#{host}",
        "https://#{host}..#{other}",
        "https://-#{host}",
        "https://\u00E9#{host}",
        # A Cyrillic letter that looks like a Latin "a".
        "https://\u0430#{host}"
      ]),
      map(filter(integer(1..65_535), &(&1 != 443)), &"https://#{host}:#{&1}")
    ])
  end

  defp audience do
    gen all first <- member_of(@alphanumeric),
            rest <- string(Enum.concat(@alphanumeric, [?_, ?-]), max_length: 20) do
      <<first>> <> rest
    end
  end

  defp label do
    gen all start <- string(@alphanumeric, min_length: 1, max_length: 8),
            finish <- string(@alphanumeric, max_length: 8),
            hyphen <- member_of(["", "-", "--"]) do
      if finish == "", do: start, else: start <> hyphen <> finish
    end
  end

  defp host do
    gen all labels <- list_of(label(), min_length: 1, max_length: 3),
            punycode <- boolean(),
            tld <- string(?a..?z, min_length: 2, max_length: 6) do
      labels = if punycode, do: ["xn--" <> hd(labels) | tl(labels)], else: labels
      Enum.join(labels ++ [tld], ".")
    end
  end
end
