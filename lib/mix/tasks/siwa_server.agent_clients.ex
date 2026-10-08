defmodule Mix.Tasks.SiwaServer.AgentClients do
  @moduledoc """
  Writes the siwa library's signing contract into the served agent clients and
  serves the contract itself at `/agent/siwa-contract.json`.

  The clients sign from the block between their `BEGIN SIWA CONTRACT` and
  `END SIWA CONTRACT` lines, which names the contract id, and hold no signing
  rules of their own. With `--check`, nothing is written and the task fails if
  any file differs from what the library generates.
  """

  use Mix.Task

  @shortdoc "Writes the signing contract into the served agent clients"
  @contract "priv/static/agent/siwa-contract.json"
  @python "priv/static/agent/siwa_agent.py"
  @node "priv/static/agent/siwa-agent.mjs"
  @block ~r/^(# |\/\/ )BEGIN SIWA CONTRACT\n.*?^(# |\/\/ )END SIWA CONTRACT\n/ms

  @impl Mix.Task
  def run(args) do
    {opts, []} = OptionParser.parse!(args, strict: [check: :boolean])
    Mix.Task.run("compile")

    stale = for {path, text} <- files(), File.read(path) != {:ok, text}, do: {path, text}

    cond do
      stale == [] ->
        :ok

      opts[:check] ->
        Mix.raise(
          "Served agent clients differ from the siwa library's contract " <>
            "#{Siwa.Contract.id()}: #{Enum.map_join(stale, ", ", &elem(&1, 0))}. " <>
            "Run `mix siwa_server.agent_clients`."
        )

      true ->
        Enum.each(stale, fn {path, text} -> File.write!(path, text) end)

        Mix.shell().info(
          "Wrote contract #{Siwa.Contract.id()} into #{Enum.map_join(stale, ", ", &elem(&1, 0))}"
        )
    end
  end

  defp files do
    json = Siwa.Contract.json()
    id = Siwa.Contract.id()

    [
      {@contract, json},
      {@python, with_block(@python, python_block(json, id))},
      {@node, with_block(@node, node_block(json, id))}
    ]
  end

  defp with_block(path, block) do
    text = File.read!(path)
    Regex.match?(@block, text) || Mix.raise("#{path} has no SIWA CONTRACT block")
    Regex.replace(@block, text, fn _ -> block end, global: false)
  end

  defp python_block(json, id) do
    """
    # BEGIN SIWA CONTRACT
    # Contract #{id}, written by `mix siwa_server.agent_clients` from the siwa library; do not edit.
    SIWA_CONTRACT = json.loads(
        r\"\"\"
    #{json}\"\"\"
    )
    # END SIWA CONTRACT
    """
  end

  defp node_block(json, id) do
    """
    // BEGIN SIWA CONTRACT
    // Contract #{id}, written by `mix siwa_server.agent_clients` from the siwa library; do not edit.
    const SIWA_CONTRACT = #{String.trim_trailing(json)};
    // END SIWA CONTRACT
    """
  end
end
