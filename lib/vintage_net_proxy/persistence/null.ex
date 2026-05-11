defmodule VintageNetProxy.Persistence.Null do
  @moduledoc "No-op persistence. For tests or environments where a writable disk isn't available."

  @behaviour VintageNetProxy.Persistence

  @impl true
  def save(_state), do: :ok

  @impl true
  def load, do: {:ok, %{}}

  @impl true
  def clear, do: :ok
end
