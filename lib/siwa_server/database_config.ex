defmodule SiwaServer.DatabaseConfig do
  @moduledoc false

  @fly_mpg_suffix ".flympg.net"

  def runtime_config!(database_url, socket_options) do
    database_url
    |> parse_url!()
    |> runtime_options(socket_options)
  end

  def release_config!(database_url, socket_options) do
    database_url
    |> parse_url!()
    |> release_options(socket_options)
  end

  defp runtime_options({database_url, %URI{host: host}}, socket_options) do
    if fly_mpg_host?(host) do
      unless String.starts_with?(host, "pgbouncer.") do
        raise "DATABASE_URL must use the Fly Managed Postgres pooled endpoint"
      end

      fly_mpg_options(database_url, host, socket_options)
      |> Keyword.put(:prepare, :unnamed)
    else
      [url: database_url, socket_options: socket_options]
    end
  end

  defp release_options({database_url, %URI{host: host} = uri}, socket_options) do
    if fly_mpg_host?(host) do
      direct_host = direct_host!(host)
      direct_url = URI.to_string(%{uri | host: direct_host})
      fly_mpg_options(direct_url, direct_host, socket_options)
    else
      [url: database_url, socket_options: socket_options]
    end
  end

  defp parse_url!(database_url) when is_binary(database_url) do
    with {:ok, %URI{scheme: scheme, host: host, path: "/" <> database, userinfo: userinfo} = uri} <-
           URI.new(database_url),
         true <- scheme in ["postgres", "postgresql"],
         true <- present?(host),
         false <- fly_mpg_root?(host),
         true <- present?(database),
         true <- valid_credentials?(uri, userinfo),
         true <- safe_fly_mpg_query?(uri),
         true <- safe_fly_mpg_port?(uri),
         true <- valid_ecto_url?(database_url) do
      canonical_fly_mpg_url(database_url, %{uri | host: String.downcase(host)})
    else
      _ -> raise "DATABASE_URL must be a valid PostgreSQL URL"
    end
  end

  defp parse_url!(_database_url), do: raise("DATABASE_URL must be a valid PostgreSQL URL")

  defp fly_mpg_options(database_url, host, socket_options) do
    [
      url: database_url,
      port: 5432,
      socket_options: ensure_ipv6(socket_options),
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        server_name_indication: String.to_charlist(host),
        customize_hostname_check: [
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        ]
      ]
    ]
  end

  defp direct_host!("pgbouncer." <> rest), do: "direct." <> rest
  defp direct_host!("direct." <> _rest = host), do: host

  defp direct_host!(_host) do
    raise "DATABASE_URL must use a Fly Managed Postgres pooled or direct endpoint"
  end

  defp ensure_ipv6(socket_options) do
    if :inet6 in socket_options, do: socket_options, else: [:inet6 | socket_options]
  end

  defp safe_fly_mpg_query?(%URI{host: host, query: query}) do
    not fly_mpg_host?(host) or query in [nil, ""]
  end

  defp safe_fly_mpg_port?(%URI{host: host, port: port}) do
    not fly_mpg_host?(host) or port in [nil, 5432]
  end

  defp fly_mpg_host?(host) when is_binary(host) do
    host = normalize_host(host)
    host != "flympg.net" and String.ends_with?(host, @fly_mpg_suffix)
  end

  defp fly_mpg_host?(_host), do: false

  defp fly_mpg_root?(host) when is_binary(host), do: normalize_host(host) == "flympg.net"
  defp fly_mpg_root?(_host), do: false

  defp canonical_fly_mpg_url(database_url, %URI{host: host} = uri) do
    if fly_mpg_host?(host) do
      canonical_uri = %{uri | host: normalize_host(host)}
      {URI.to_string(canonical_uri), canonical_uri}
    else
      {database_url, uri}
    end
  end

  defp normalize_host(host) do
    host |> String.downcase() |> String.trim_trailing(".")
  end

  defp valid_credentials?(%URI{host: host}, userinfo) do
    not fly_mpg_host?(host) or valid_userinfo?(userinfo)
  end

  defp valid_userinfo?(userinfo) when is_binary(userinfo) do
    case String.split(userinfo, ":", parts: 2) do
      [username, password] -> present?(username) and present?(password)
      _ -> false
    end
  end

  defp valid_userinfo?(_userinfo), do: false

  defp valid_ecto_url?(database_url) do
    Ecto.Repo.Supervisor.parse_url(database_url)
    true
  rescue
    _error -> false
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
