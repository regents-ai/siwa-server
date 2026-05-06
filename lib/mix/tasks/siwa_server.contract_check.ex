defmodule Mix.Tasks.SiwaServer.ContractCheck do
  use Mix.Task

  @shortdoc "Checks SIWA routes and responses in the shared-services contract"
  @contract_path "priv/static/regent-services-contract.openapiv3.yaml"
  @openapi_methods ~w(get post put patch delete options head trace)
  @expected_response_codes %{
    {"POST", "/v1/agent/siwa/nonce"} => MapSet.new(~w(200 400 413)),
    {"POST", "/v1/agent/siwa/verify"} => MapSet.new(~w(200 400 401 404 413 500 502)),
    {"POST", "/v1/agent/siwa/http-verify"} => MapSet.new(~w(200 400 401 409 413 500))
  }
  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("compile")

    contract = File.read!(@contract_path)

    contract_routes =
      contract_routes(contract)

    contract_response_codes =
      contract_response_codes(contract)

    router_routes =
      SiwaServerWeb.Router
      |> Phoenix.Router.routes()
      |> Enum.map(&{&1.verb |> to_string() |> String.upcase(), &1.path})
      |> Enum.reject(fn {_verb, path} -> String.starts_with?(path, "/internal/keyring") end)
      |> MapSet.new()
      |> MapSet.union(keyring_routes())

    missing_from_contract = MapSet.difference(router_routes, contract_routes)

    unexpected_contract_routes =
      contract_routes
      |> MapSet.difference(router_routes)

    response_code_drift = response_code_drift(contract_response_codes)

    if MapSet.size(missing_from_contract) == 0 and
         MapSet.size(unexpected_contract_routes) == 0 and response_code_drift == [] do
      Mix.shell().info("shared services contract covers SIWA routes and expected responses")
    else
      report_drift(missing_from_contract, unexpected_contract_routes)
      report_response_code_drift(response_code_drift)
      Mix.raise("shared services contract does not cover SIWA routes or expected responses")
    end
  end

  defp contract_routes(contract) do
    contract
    |> String.split("\n")
    |> Enum.reduce({nil, []}, &collect_contract_route/2)
    |> elem(1)
    |> MapSet.new()
  end

  defp collect_contract_route("  /" <> rest, {_path, routes}) do
    path =
      rest
      |> String.trim_trailing()
      |> String.trim_trailing(":")
      |> then(&("/" <> &1))

    {path, routes}
  end

  defp collect_contract_route("    " <> rest, {path, routes}) when is_binary(path) do
    method =
      rest
      |> String.trim()
      |> String.trim_trailing(":")

    if method in @openapi_methods do
      {path, [{String.upcase(method), path} | routes]}
    else
      {path, routes}
    end
  end

  defp collect_contract_route(_line, acc), do: acc

  defp contract_response_codes(contract) do
    contract
    |> String.split("\n")
    |> Enum.reduce({nil, nil, false, %{}}, &collect_contract_response_code/2)
    |> elem(3)
  end

  defp collect_contract_response_code(line, {path, method, in_responses?, response_codes}) do
    cond do
      path = path_from_line(line) ->
        {path, nil, false, response_codes}

      method = method_from_line(line) ->
        {path, method, false, response_codes}

      path && method && String.trim(line) == "responses:" ->
        {path, method, true, response_codes}

      in_responses? ->
        response_codes =
          case response_code_from_line(line) do
            nil ->
              response_codes

            code ->
              Map.update(
                response_codes,
                {method, path},
                MapSet.new([code]),
                &MapSet.put(&1, code)
              )
          end

        {path, method, true, response_codes}

      true ->
        {path, method, in_responses?, response_codes}
    end
  end

  defp path_from_line(line) do
    case Regex.run(~r/^  (\/[^:\n]+):$/, line) do
      [_, path] -> path
      _ -> nil
    end
  end

  defp method_from_line(line) do
    case Regex.run(~r/^    ([a-z]+):$/, line) do
      [_, method] when method in @openapi_methods -> String.upcase(method)
      _ -> nil
    end
  end

  defp response_code_from_line(line) do
    case Regex.run(~r/^        "(\d{3})":$/, line) do
      [_, code] -> code
      _ -> nil
    end
  end

  defp keyring_routes do
    router_path =
      :siwa_keyring
      |> path_dep!()
      |> Path.join("lib/siwa_keyring/router.ex")

    router_path
    |> File.read!()
    |> String.split("\n")
    |> Enum.flat_map(&keyring_route_from_line/1)
    |> MapSet.new()
  end

  defp keyring_route_from_line(line) do
    case Regex.run(~r/^\s*(get|post)\s+@prefix <> "([^"]+)"/, line) do
      [_, verb, path] -> [{String.upcase(verb), "/internal/keyring" <> path}]
      _ -> []
    end
  end

  defp path_dep!(app) do
    Mix.Project.config()
    |> Keyword.fetch!(:deps)
    |> Enum.find_value(fn
      {^app, opts} when is_list(opts) ->
        Keyword.get(opts, :path)

      {^app, _requirement, opts} when is_list(opts) ->
        Keyword.get(opts, :path)

      _dep ->
        nil
    end)
    |> case do
      nil -> Mix.raise("missing local path dependency for #{app}")
      path -> Path.expand(path, File.cwd!())
    end
  end

  defp response_code_drift(contract_response_codes) do
    Enum.flat_map(@expected_response_codes, fn {route, expected_codes} ->
      actual_codes = Map.get(contract_response_codes, route, MapSet.new())
      missing_codes = MapSet.difference(expected_codes, actual_codes)

      if MapSet.size(missing_codes) == 0 do
        []
      else
        [{route, missing_codes}]
      end
    end)
  end

  defp report_drift(missing_from_contract, unexpected_contract_routes) do
    if MapSet.size(missing_from_contract) > 0 do
      Mix.shell().error("routes missing from contract:")
      Enum.each(missing_from_contract, &Mix.shell().error("  #{format_route(&1)}"))
    end

    if MapSet.size(unexpected_contract_routes) > 0 do
      Mix.shell().error("unexpected contract routes:")
      Enum.each(unexpected_contract_routes, &Mix.shell().error("  #{format_route(&1)}"))
    end
  end

  defp report_response_code_drift(response_code_drift) do
    if response_code_drift != [] do
      Mix.shell().error("expected responses missing from contract:")

      Enum.each(response_code_drift, fn {route, codes} ->
        Mix.shell().error(
          "  #{format_route(route)} missing #{codes |> Enum.sort() |> Enum.join(", ")}"
        )
      end)
    end
  end

  defp format_route({verb, path}), do: "#{verb} #{path}"
end
