defmodule SiwaServer.TestStripe do
  @moduledoc """
  Stands in for Stripe's API in tests (config/test.exs): each call is sent to
  the calling process as `{:stripe, method, path, params}` and answered by the
  function the test set with `answer/1`, called with the method, path and
  params. A call with no answer set fails the test.
  """

  @doc "Sets how this process's Stripe calls are answered."
  @spec answer((atom(), String.t(), map() -> term())) :: :ok
  def answer(fun) when is_function(fun, 3) do
    Process.put(__MODULE__, fun)
    :ok
  end

  def request(method, path, params, _opts) do
    send(self(), {:stripe, method, path, params})

    case Process.get(__MODULE__) do
      nil -> raise "Stripe was called with #{method} #{path} and the test set no answer"
      fun -> fun.(method, path, params)
    end
  end
end
