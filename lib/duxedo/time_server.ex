defmodule Duxedo.TimeServer do
  @moduledoc false

  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: name(args[:instance]))
  end

  @spec register(atom(), pid()) :: :ok
  def register(instance \\ :duxedo, process) do
    GenServer.call(name(instance), {:register, process})
  end

  @spec synchronized?(atom()) :: boolean()
  def synchronized?(instance \\ :duxedo) do
    GenServer.call(name(instance), :synchronized?)
  end

  defp name(instance), do: Module.concat(__MODULE__, instance)

  @impl GenServer
  def init(args) do
    state = %{
      started_sys_time: System.system_time(:second),
      clock: nil,
      synced?: true,
      registered: []
    }

    case args[:clock] do
      nil ->
        {:ok, state}

      clock ->
        Process.send_after(self(), :check_clock, 1_000)
        {:ok, %{state | clock: clock, synced?: false}}
    end
  end

  @impl GenServer
  def handle_call({:register, pid}, _from, %{clock: nil} = state) do
    notify(0, [pid])
    {:reply, :ok, state}
  end

  def handle_call({:register, pid}, _from, state) do
    if pid in state.registered do
      {:reply, :ok, state}
    else
      {:reply, :ok, %{state | registered: [pid | state.registered]}}
    end
  end

  def handle_call(:synchronized?, _from, state) do
    {:reply, state.synced?, state}
  end

  @impl GenServer
  def handle_info(:check_clock, %{synced?: false} = state) do
    if state.clock.synchronized?() do
      now = System.system_time(:second)
      adjustment = now - state.started_sys_time
      notify(adjustment, state.registered)
      {:noreply, %{state | synced?: true}}
    else
      Process.send_after(self(), :check_clock, 1_000)
      {:noreply, state}
    end
  end

  defp notify(adjustment, registered) do
    for pid <- registered do
      send(pid, {__MODULE__, adjustment})
    end

    :ok
  end
end
