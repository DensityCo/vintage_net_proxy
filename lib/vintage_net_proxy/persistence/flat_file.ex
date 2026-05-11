defmodule VintageNetProxy.Persistence.FlatFile do
  @moduledoc """
  File-backed persistence. Writes an Erlang term to `<dir>/state` atomically
  (write-temp + rename).

  Configure the directory via app env:

      config :vintage_net_proxy, persistence_dir: "/root/vintage_net_proxy"

  Default is `/root/vintage_net_proxy/`.
  """

  @behaviour VintageNetProxy.Persistence

  @default_dir "/root/vintage_net_proxy"
  @file_name "state"

  @impl true
  def save(state) when is_map(state) do
    path = path()
    tmp = path <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(tmp, :erlang.term_to_binary(state)),
         :ok <- File.rename(tmp, path) do
      :ok
    end
  end

  @impl true
  def load do
    case File.read(path()) do
      {:ok, binary} ->
        try do
          {:ok, :erlang.binary_to_term(binary, [:safe])}
        rescue
          _ -> {:error, :corrupt}
        end

      {:error, :enoent} ->
        {:ok, %{}}

      {:error, _} = err ->
        err
    end
  end

  @impl true
  def clear do
    case File.rm(path()) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      err -> err
    end
  end

  defp path do
    dir = Application.get_env(:vintage_net_proxy, :persistence_dir, @default_dir)
    Path.join(dir, @file_name)
  end
end
