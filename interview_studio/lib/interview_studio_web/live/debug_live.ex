defmodule InterviewStudioWeb.DebugLive do
  @moduledoc """
  Debug interface showing agent activity, signals, and phase diagram.
  """

  use InterviewStudioWeb, :live_view

  alias InterviewStudio.InterviewBus

  @impl true
  def mount(_params, _session, socket) do
    # Subscribe to all signals
    if connected?(socket) do
      InterviewBus.subscribe("**")
    end

    # Get signal history
    history = InterviewBus.history(limit: 100)

    {:ok, assign(socket,
      signals: history,
      filter: "",
      selected_signal: nil,
      phase_history: extract_phases(history),
      current_phase: get_current_phase(history)
    )}
  end

  @impl true
  def handle_info({:signal, signal}, socket) do
    # Add to signals list (most recent first)
    signals = [signal | socket.assigns.signals] |> Enum.take(100)

    # Update phase if it's a phase signal
    {phase_history, current_phase} =
      if String.starts_with?(signal.type, "interview.phase.entered") do
        new_phase = signal.data.phase_name
        {[new_phase | socket.assigns.phase_history], new_phase}
      else
        {socket.assigns.phase_history, socket.assigns.current_phase}
      end

    {:noreply, assign(socket,
      signals: signals,
      phase_history: phase_history,
      current_phase: current_phase
    )}
  end

  @impl true
  def handle_event("filter", %{"filter" => filter}, socket) do
    {:noreply, assign(socket, filter: filter)}
  end

  @impl true
  def handle_event("select_signal", %{"id" => id}, socket) do
    signal = Enum.find(socket.assigns.signals, fn s -> s.id == id end)
    {:noreply, assign(socket, selected_signal: signal)}
  end

  @impl true
  def handle_event("clear_selection", _params, socket) do
    {:noreply, assign(socket, selected_signal: nil)}
  end

  defp extract_phases(signals) do
    signals
    |> Enum.filter(fn s -> String.starts_with?(s.type, "interview.phase.entered") end)
    |> Enum.map(fn s -> s.data.phase_name end)
    |> Enum.reverse()
  end

  defp get_current_phase(history) do
    phase_signal = Enum.find(history, fn s ->
      String.starts_with?(s.type, "interview.phase.entered")
    end)

    if phase_signal, do: phase_signal.data.phase_name, else: :preparation
  end

  defp filtered_signals(signals, "") do
    signals
  end

  defp filtered_signals(signals, filter) do
    Enum.filter(signals, fn s ->
      String.contains?(s.type, filter) or
      String.contains?(s.source, filter)
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-slate-900 text-white p-6">
      <div class="max-w-7xl mx-auto">
        <!-- Header -->
        <header class="mb-8 flex justify-between items-center">
          <div>
            <h1 class="text-2xl font-bold">Debug Interface</h1>
            <p class="text-slate-400">Real-time agent activity and signals</p>
          </div>
          <a href="/interview" class="text-blue-400 hover:text-blue-300">
            Back to Interview
          </a>
        </header>

        <div class="grid grid-cols-3 gap-6">
          <!-- Phase Diagram -->
          <div class="col-span-1">
            <div class="bg-slate-800 rounded-xl p-4">
              <h2 class="text-lg font-semibold mb-4">Phase Diagram</h2>
              <div class="space-y-2">
                <%= for phase <- [:preparation, :opening, :core_questions, :probing, :synthesis, :closing] do %>
                  <div class={[
                    "flex items-center gap-3 p-3 rounded-lg transition-colors",
                    if(phase == @current_phase,
                      do: "bg-blue-600",
                      else: if(phase in @phase_history, do: "bg-slate-700", else: "bg-slate-800 border border-slate-700"))
                  ]}>
                    <div class={[
                      "w-3 h-3 rounded-full",
                      if(phase == @current_phase,
                        do: "bg-white",
                        else: if(phase in @phase_history, do: "bg-green-500", else: "bg-slate-600"))
                    ]}></div>
                    <span class={[
                      if(phase == @current_phase, do: "font-semibold", else: "")
                    ]}>
                      <%= format_phase(phase) %>
                    </span>
                  </div>
                <% end %>
              </div>
            </div>

            <!-- Agent Status Summary -->
            <div class="bg-slate-800 rounded-xl p-4 mt-4">
              <h2 class="text-lg font-semibold mb-4">Agent Activity</h2>
              <div class="space-y-2 text-sm">
                <%= for {agent, color} <- [{"Director", "blue"}, {"Scribe", "green"}, {"Story Analyst", "purple"}, {"Probe Coach", "yellow"}, {"Engagement Monitor", "red"}] do %>
                  <div class="flex items-center gap-2">
                    <div class={"w-2 h-2 rounded-full bg-#{color}-500"}></div>
                    <span class="text-slate-300"><%= agent %></span>
                    <span class="text-slate-500 ml-auto">
                      <%= count_signals_from(@signals, String.downcase(agent) |> String.replace(" ", "_")) %>
                    </span>
                  </div>
                <% end %>
              </div>
            </div>
          </div>

          <!-- Signal Stream -->
          <div class="col-span-2">
            <div class="bg-slate-800 rounded-xl p-4">
              <div class="flex justify-between items-center mb-4">
                <h2 class="text-lg font-semibold">Signal Stream</h2>
                <input
                  type="text"
                  placeholder="Filter signals..."
                  phx-change="filter"
                  phx-debounce="200"
                  name="filter"
                  value={@filter}
                  class="bg-slate-700 border-0 rounded-lg px-3 py-1 text-sm focus:ring-1 focus:ring-blue-500"
                />
              </div>

              <div class="space-y-2 max-h-[600px] overflow-y-auto">
                <%= for signal <- filtered_signals(@signals, @filter) do %>
                  <div
                    phx-click="select_signal"
                    phx-value-id={signal.id}
                    class={[
                      "p-3 rounded-lg cursor-pointer transition-colors",
                      if(@selected_signal && @selected_signal.id == signal.id,
                        do: "bg-blue-600",
                        else: "bg-slate-700 hover:bg-slate-600")
                    ]}
                  >
                    <div class="flex justify-between items-start">
                      <div>
                        <span class={"text-sm font-mono #{signal_color(signal.type)}"}>
                          <%= signal.type %>
                        </span>
                        <span class="text-slate-500 text-xs ml-2">
                          from <%= signal.source %>
                        </span>
                      </div>
                      <span class="text-slate-500 text-xs">
                        <%= format_time(signal) %>
                      </span>
                    </div>
                    <div class="text-slate-400 text-sm mt-1 truncate">
                      <%= preview_data(signal.data) %>
                    </div>
                  </div>
                <% end %>
              </div>
            </div>

            <!-- Selected Signal Detail -->
            <%= if @selected_signal do %>
              <div class="bg-slate-800 rounded-xl p-4 mt-4">
                <div class="flex justify-between items-center mb-4">
                  <h2 class="text-lg font-semibold">Signal Detail</h2>
                  <button phx-click="clear_selection" class="text-slate-400 hover:text-white">
                    Close
                  </button>
                </div>
                <pre class="bg-slate-900 rounded-lg p-4 text-sm overflow-x-auto"><%= format_signal(@selected_signal) %></pre>
              </div>
            <% end %>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp format_phase(:preparation), do: "Preparation"
  defp format_phase(:opening), do: "Opening"
  defp format_phase(:core_questions), do: "Core Questions"
  defp format_phase(:probing), do: "Probing"
  defp format_phase(:synthesis), do: "Synthesis"
  defp format_phase(:closing), do: "Closing"
  defp format_phase(phase), do: to_string(phase)

  defp signal_color(type) do
    cond do
      String.starts_with?(type, "interview.utterance") -> "text-green-400"
      String.starts_with?(type, "interview.phase") -> "text-blue-400"
      String.starts_with?(type, "observer.insight") -> "text-purple-400"
      String.starts_with?(type, "observer.suggestion") -> "text-yellow-400"
      String.starts_with?(type, "observer.status") -> "text-red-400"
      String.starts_with?(type, "observer.record") -> "text-slate-400"
      String.starts_with?(type, "director") -> "text-cyan-400"
      true -> "text-slate-300"
    end
  end

  defp preview_data(data) when is_map(data) do
    cond do
      Map.has_key?(data, :content) -> String.slice(data.content || "", 0, 80)
      Map.has_key?(data, :theme) -> "Theme: #{data.theme}"
      Map.has_key?(data, :topic) -> "Topic: #{data.topic}"
      Map.has_key?(data, :level) -> "Level: #{data.level}"
      Map.has_key?(data, :phase_name) -> "Phase: #{data.phase_name}"
      true -> inspect(data) |> String.slice(0, 80)
    end
  end

  defp preview_data(data), do: inspect(data) |> String.slice(0, 80)

  defp format_time(%{data: %{timestamp: ts}}) when not is_nil(ts) do
    case ts do
      %DateTime{} -> Calendar.strftime(ts, "%H:%M:%S")
      _ -> "--:--:--"
    end
  rescue
    _ -> "--:--:--"
  end

  defp format_time(_), do: "--:--:--"

  defp format_signal(signal) do
    signal
    |> Map.from_struct()
    |> Jason.encode!(pretty: true)
  end

  defp count_signals_from(signals, source) do
    Enum.count(signals, fn s ->
      String.contains?(String.downcase(s.source), source)
    end)
  end
end
