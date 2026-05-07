defmodule Mix.Tasks.SiwaServer.ReleasePackagingCheck do
  use Mix.Task

  @shortdoc "Checks release packaging covers local production dependencies"
  @dockerfile "Dockerfile"

  @impl Mix.Task
  def run(_args) do
    dockerfile = File.read!(@dockerfile)
    repo_root = File.cwd!()
    build_context = Path.dirname(repo_root)
    local_path_deps = local_production_path_deps(repo_root)

    missing =
      local_path_deps
      |> Enum.reject(&dockerfile_copies_path?(dockerfile, build_context, &1))

    non_runtime = Enum.filter(local_path_deps, &runtime_disabled?/1)

    if missing == [] and non_runtime == [] do
      Mix.shell().info("release packaging covers local production dependencies")
    else
      Enum.each(missing, fn {app, path, _opts} ->
        Mix.shell().error(
          "local production dependency not copied into release image: #{app} #{path}"
        )
      end)

      Enum.each(non_runtime, fn {app, _path, _opts} ->
        Mix.shell().error("local production dependency must be packaged at runtime: #{app}")
      end)

      Mix.raise("release packaging is missing local production dependency inputs")
    end
  end

  defp local_production_path_deps(repo_root) do
    Mix.Project.config()
    |> Keyword.fetch!(:deps)
    |> Enum.flat_map(fn
      {app, opts} when is_list(opts) ->
        path_dep(app, opts, repo_root)

      {app, _requirement, opts} when is_list(opts) ->
        path_dep(app, opts, repo_root)

      _dep ->
        []
    end)
  end

  defp path_dep(app, opts, repo_root) do
    if Keyword.has_key?(opts, :path) and production_dep?(opts) do
      [{app, opts |> Keyword.fetch!(:path) |> Path.expand(repo_root), opts}]
    else
      []
    end
  end

  defp production_dep?(opts) do
    case Keyword.get(opts, :only) do
      nil -> true
      env when is_atom(env) -> env == :prod
      envs when is_list(envs) -> :prod in envs
    end
  end

  defp runtime_disabled?({_app, _path, opts}), do: Keyword.get(opts, :runtime) == false

  defp dockerfile_copies_path?(dockerfile, build_context, {_app, path, _opts}) do
    copied_paths =
      dockerfile
      |> String.split("\n")
      |> Enum.flat_map(&copy_sources/1)
      |> Enum.map(&Path.expand(&1, build_context))

    Enum.any?(copied_paths, fn copied_path ->
      path == copied_path or String.starts_with?(path, copied_path <> "/")
    end)
  end

  defp copy_sources("COPY " <> rest) do
    rest
    |> String.split()
    |> Enum.drop_while(&String.starts_with?(&1, "--"))
    |> Enum.drop(-1)
  end

  defp copy_sources(_line), do: []
end
