defmodule SiwaServer.Customers.SiteFile do
  @moduledoc """
  Reads the file a company publishes at each of its production site's origins
  to prove the origin is its own, `https://<origin>/.well-known/siwa-site.txt`,
  which holds the site's token (`SiwaServer.Customers.check_site_proof/2`).

  The origin is one a customer named, so the read is safe wherever it points:

    * only an origin in its one `https://` spelling
      (`SiwaServer.Config.https_origin?/1`): https on the default port, to a
      host name, never a number;
    * every address the name resolves to, IPv4 and IPv6, must be public, by the
      shared rule (`RegentHttp.Public.public_ip?/1`): loopback, private,
      link-local, unique-local, shared (CGNAT), multicast, unspecified,
      IPv4-mapped and other special addresses are refused;
    * the connection goes to an address that was checked, with the host name
      kept for TLS and the `host` header, so the name is never resolved again;
    * one GET on a new connection, closed after it: a redirect is an answer and
      is never followed, and nothing is retried;
    * 5 seconds for all of it, from the name lookup to the last byte, and at
      most 1 KB (1,024 bytes) of body.
  """

  alias RegentHttp.Public
  alias SiwaServer.Config

  @path "/.well-known/siwa-site.txt"
  @timeout_ms 5_000
  @max_body_bytes 1_024
  @max_header_bytes 16_384

  @type reason ::
          :not_https | :address_not_allowed | :unreachable | :redirected | :not_found | :too_large

  @doc "The address of `origin`'s site file."
  @spec url(String.t()) :: String.t()
  def url(origin), do: origin <> @path

  @doc "What `origin` serves as its site file, or why it could not be read."
  @spec fetch(String.t()) :: {:ok, binary()} | {:error, reason()}
  def fetch(origin) do
    deadline = System.monotonic_time(:millisecond) + @timeout_ms

    if Config.https_origin?(origin) do
      uri = origin |> url() |> URI.parse()
      with {:ok, address} <- resolve(uri.host, deadline), do: get(uri, address, deadline)
    else
      {:error, :not_https}
    end
  end

  @doc """
  Reads `uri` over a new connection to `address`, an address already checked
  for its host, until `deadline` (monotonic milliseconds). The answer must be
  200 with a body of at most 1,024 bytes; any 3xx is `:redirected`, any other
  status `:not_found`, and a body that runs past the limit `:too_large`.
  """
  @spec get(URI.t(), :inet.ip_address(), integer()) :: {:ok, binary()} | {:error, reason()}
  def get(%URI{} = uri, address, deadline) do
    with {:ok, conn} <- connect(uri, address, deadline) do
      try do
        request(conn, uri, deadline)
      after
        Mint.HTTP.close(conn)
      end
    end
  end

  # Every answer for the name must be public, not only the one connected to, so
  # a family whose answer did not come in time leaves the name unread.
  defp resolve(host, deadline) do
    name = String.to_charlist(host)
    answers = for family <- [:inet, :inet6], do: :inet.getaddrs(name, family, remaining(deadline))
    addresses = for {:ok, found} <- answers, address <- found, do: address

    cond do
      {:error, :timeout} in answers or addresses == [] -> {:error, :unreachable}
      Enum.all?(addresses, &Public.public_ip?/1) -> {:ok, hd(addresses)}
      true -> {:error, :address_not_allowed}
    end
  end

  defp connect(uri, address, deadline) do
    ipv6? = tuple_size(address) == 8

    case Mint.HTTP.connect(scheme(uri), address, uri.port,
           hostname: uri.host,
           protocols: [:http1],
           mode: :passive,
           max_header_list_size: @max_header_bytes,
           transport_opts: [
             timeout: remaining(deadline),
             send_timeout: remaining(deadline),
             send_timeout_close: true,
             inet4: not ipv6?,
             inet6: ipv6?
           ]
         ) do
      {:ok, conn} -> {:ok, conn}
      {:error, _reason} -> {:error, :unreachable}
    end
  end

  defp scheme(%URI{scheme: "https"}), do: :https
  defp scheme(%URI{scheme: "http"}), do: :http

  defp request(conn, uri, deadline) do
    case Mint.HTTP.request(conn, "GET", uri.path, [], nil) do
      {:ok, conn, ref} -> receive_body(conn, ref, deadline, "")
      {:error, _conn, _reason} -> {:error, :unreachable}
    end
  end

  defp receive_body(conn, ref, deadline, body) do
    with true <- remaining(deadline) > 0,
         {:ok, conn, responses} <- Mint.HTTP.recv(conn, 0, remaining(deadline)) do
      read(responses, conn, ref, deadline, body)
    else
      _late_or_failed -> {:error, :unreachable}
    end
  end

  defp read([], conn, ref, deadline, body), do: receive_body(conn, ref, deadline, body)

  defp read([{:status, ref, status} | rest], conn, ref, deadline, body) do
    cond do
      status == 200 or status in 100..199 -> read(rest, conn, ref, deadline, body)
      status in 300..399 -> {:error, :redirected}
      true -> {:error, :not_found}
    end
  end

  defp read([{:data, ref, data} | rest], conn, ref, deadline, body) do
    if byte_size(body) + byte_size(data) > @max_body_bytes,
      do: {:error, :too_large},
      else: read(rest, conn, ref, deadline, body <> data)
  end

  defp read([{:done, ref} | _rest], _conn, ref, _deadline, body), do: {:ok, body}

  defp read([{:error, ref, _reason} | _rest], _conn, ref, _deadline, _body),
    do: {:error, :unreachable}

  defp read([_headers | rest], conn, ref, deadline, body),
    do: read(rest, conn, ref, deadline, body)

  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)
end
