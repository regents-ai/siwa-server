defmodule SiwaDemo.StubClient do
  @moduledoc """
  Stands in for the SIWA service in tests. A test sets what the service answers with
  `answer/1`; each check the site asks for is sent to the test as
  `{:checked, payload, opts}`.
  """

  @behaviour Siwa.AgentAuthPlug.Client

  def answer(result), do: Process.put(__MODULE__, result)

  @impl true
  def verify_http_request(payload, opts) do
    send(self(), {:checked, payload, opts})
    Process.get(__MODULE__)
  end
end
