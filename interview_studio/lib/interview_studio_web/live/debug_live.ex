defmodule InterviewStudioWeb.DebugLive do
  @moduledoc """
  Debug interface showing agent activity, signals, and phase diagram.

  Phase 5 UI Visibility Features:
  - Agent communication log (agent-to-agent messages)
  - Synthesis visualization (Director's decision inputs)
  - Real-time collaboration indicators (pulsing when active)
  - Agent influence attribution (which agents influenced each question)
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
      current_phase: get_current_phase(history),
      # Phase 5: New assigns for collaboration visibility
      agent_communications: extract_agent_communications(history),
      active_agents: %{},  # Agents currently analyzing
      last_synthesis: nil, # Last Director synthesis
      question_attributions: [], # Which agents influenced each question
      consensus_events: extract_consensus_events(history),
      view_mode: "signals"  # signals | collaboration | synthesis
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

    # Phase 5: Track agent-to-agent communications
    agent_communications = track_agent_communication(signal, socket.assigns.agent_communications)

    # Phase 5: Track active agents (pulsing indicators)
    active_agents = update_active_agents(signal, socket.assigns.active_agents)

    # Phase 5: Track synthesis events
    last_synthesis = track_synthesis(signal, socket.assigns.last_synthesis)

    # Phase 5: Track question attributions
    question_attributions = track_attributions(signal, socket.assigns.question_attributions)

    # Phase 5: Track consensus events
    consensus_events = track_consensus(signal, socket.assigns.consensus_events)

    {:noreply, assign(socket,
      signals: signals,
      phase_history: phase_history,
      current_phase: current_phase,
      agent_communications: agent_communications,
      active_agents: active_agents,
      last_synthesis: last_synthesis,
      question_attributions: question_attributions,
      consensus_events: consensus_events
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

  @impl true
  def handle_event("set_view", %{"view" => view}, socket) do
    {:noreply, assign(socket, view_mode: view)}
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

  # Phase 5: Extract agent-to-agent communications from history
  defp extract_agent_communications(history) do
    history
    |> Enum.filter(fn s -> is_agent_communication?(s) end)
    |> Enum.map(&format_communication/1)
    |> Enum.take(50)
  end

  defp is_agent_communication?(signal) do
    # Agent-to-agent signals have a target or are theme/probe notifications
    has_target = get_in(signal, [Access.key(:data, %{}), :target]) != nil
    is_theme_notification = signal.type == "analyst.theme.discovered"
    is_engagement_alert = signal.type == "engagement.alert.broadcast"
    is_consensus = String.starts_with?(signal.type, "director.consensus")

    has_target or is_theme_notification or is_engagement_alert or is_consensus
  end

  defp format_communication(signal) do
    target = get_in(signal, [Access.key(:data, %{}), :target]) || "all"
    timestamp = get_in(signal, [Access.key(:data, %{}), :timestamp]) || DateTime.utc_now()

    message = cond do
      signal.type == "analyst.theme.discovered" ->
        "Theme: #{signal.data[:theme] || "unknown"}"
      signal.type == "engagement.alert.broadcast" ->
        "Engagement: #{signal.data[:level] || "unknown"} - #{signal.data[:message] || ""}"
      signal.type == "director.consensus.disagreement" ->
        "Disagreement on #{signal.data[:target_phase] || "unknown"}"
      true ->
        preview_data(signal.data)
    end

    %{
      timestamp: timestamp,
      source: signal.source,
      target: target,
      type: signal.type,
      message: message,
      signal: signal
    }
  end

  # Track new agent communications
  defp track_agent_communication(signal, existing) do
    if is_agent_communication?(signal) do
      [format_communication(signal) | existing] |> Enum.take(50)
    else
      existing
    end
  end

  # Phase 5: Track active agents for pulsing indicators
  defp update_active_agents(signal, active) do
    now = System.system_time(:second)

    cond do
      # Agent started analyzing
      signal.type == "observer.status.analyzing" ->
        Map.put(active, signal.source, %{status: :analyzing, since: now})

      # Agent completed
      signal.type == "observer.status.complete" ->
        Map.put(active, signal.source, %{status: :idle, since: now})

      # Agent error
      signal.type == "observer.status.error" ->
        Map.put(active, signal.source, %{status: :error, since: now})

      true ->
        # Clear stale entries (older than 10 seconds)
        active
        |> Enum.filter(fn {_k, v} -> now - v.since < 10 end)
        |> Enum.into(%{})
    end
  end

  # Phase 5: Track synthesis events
  defp track_synthesis(signal, _existing) do
    if signal.type == "interview.utterance.host" do
      # Extract attribution from the action that generated this response
      %{
        timestamp: get_in(signal, [Access.key(:data, %{}), :timestamp]) || DateTime.utc_now(),
        response: signal.data[:content] || "",
        source: get_in(signal, [Access.key(:data, %{}), :action_source]) || :unknown,
        themes_used: get_in(signal, [Access.key(:data, %{}), :themes_used]) || [],
        probes_used: get_in(signal, [Access.key(:data, %{}), :probes_used]) || [],
        engagement: get_in(signal, [Access.key(:data, %{}), :engagement]) || :unknown
      }
    else
      nil
    end
  end

  # Phase 5: Track question attributions
  defp track_attributions(signal, existing) do
    if signal.type == "interview.utterance.host" do
      attribution = %{
        timestamp: get_in(signal, [Access.key(:data, %{}), :timestamp]) || DateTime.utc_now(),
        question: String.slice(signal.data[:content] || "", 0, 100),
        source: get_in(signal, [Access.key(:data, %{}), :action_source]) || :director,
        contributors: extract_contributors(signal)
      }
      [attribution | existing] |> Enum.take(20)
    else
      existing
    end
  end

  defp extract_contributors(signal) do
    contributors = []
    data = signal.data || %{}

    contributors = if data[:action_source] == :probe_coach, do: ["Probe Coach" | contributors], else: contributors
    contributors = if data[:action_source] == :collective_intelligence, do: ["Story Analyst", "Probe Coach", "Engagement Monitor" | contributors], else: contributors
    contributors = if data[:themes_used] && data[:themes_used] != [], do: ["Story Analyst" | contributors], else: contributors

    Enum.uniq(contributors)
  end

  # Phase 5: Extract consensus events from history
  defp extract_consensus_events(history) do
    history
    |> Enum.filter(fn s -> String.starts_with?(s.type, "director.consensus") end)
    |> Enum.map(fn s ->
      %{
        timestamp: get_in(s, [Access.key(:data, %{}), :timestamp]) || DateTime.utc_now(),
        target_phase: s.data[:target_phase],
        votes: s.data[:votes] || [],
        resolution: s.data[:resolution] || :unknown
      }
    end)
    |> Enum.take(20)
  end

  defp track_consensus(signal, existing) do
    if String.starts_with?(signal.type, "director.consensus") do
      event = %{
        timestamp: get_in(signal, [Access.key(:data, %{}), :timestamp]) || DateTime.utc_now(),
        target_phase: signal.data[:target_phase],
        votes: signal.data[:votes] || [],
        resolution: signal.data[:resolution] || :unknown
      }
      [event | existing] |> Enum.take(20)
    else
      existing
    end
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
            <p class="text-slate-400">Real-time agent collaboration visibility</p>
          </div>
          <div class="flex items-center gap-4">
            <!-- View Mode Tabs -->
            <div class="flex bg-slate-800 rounded-lg p-1">
              <button
                phx-click="set_view"
                phx-value-view="signals"
                class={["px-3 py-1 rounded text-sm", if(@view_mode == "signals", do: "bg-blue-600", else: "hover:bg-slate-700")]}
              >
                Signals
              </button>
              <button
                phx-click="set_view"
                phx-value-view="collaboration"
                class={["px-3 py-1 rounded text-sm", if(@view_mode == "collaboration", do: "bg-blue-600", else: "hover:bg-slate-700")]}
              >
                Collaboration
              </button>
              <button
                phx-click="set_view"
                phx-value-view="synthesis"
                class={["px-3 py-1 rounded text-sm", if(@view_mode == "synthesis", do: "bg-blue-600", else: "hover:bg-slate-700")]}
              >
                Synthesis
              </button>
            </div>
            <a href="/interview" class="text-blue-400 hover:text-blue-300">
              Back to Interview
            </a>
          </div>
        </header>

        <div class="grid grid-cols-3 gap-6">
          <!-- Left Column: Phase + Agent Status -->
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

            <!-- Agent Status with Real-Time Indicators -->
            <div class="bg-slate-800 rounded-xl p-4 mt-4">
              <h2 class="text-lg font-semibold mb-4">Agent Activity</h2>
              <div class="space-y-3 text-sm">
                <%= for {agent, agent_key, color} <- [
                  {"Director", "director", "blue"},
                  {"Story Analyst", "story_analyst", "purple"},
                  {"Probe Coach", "probe_coach", "yellow"},
                  {"Engagement Monitor", "engagement_monitor", "red"}
                ] do %>
                  <div class="flex items-center gap-2">
                    <!-- Pulsing indicator when agent is active -->
                    <div class={[
                      "w-3 h-3 rounded-full",
                      agent_status_class(@active_agents, agent_key, color)
                    ]}></div>
                    <span class="text-slate-300"><%= agent %></span>
                    <span class="text-slate-500 ml-auto text-xs">
                      <%= agent_status_text(@active_agents, agent_key) %>
                    </span>
                  </div>
                <% end %>
              </div>
            </div>

            <!-- Consensus Events -->
            <%= if @consensus_events != [] do %>
              <div class="bg-slate-800 rounded-xl p-4 mt-4">
                <h2 class="text-lg font-semibold mb-4">Consensus Events</h2>
                <div class="space-y-2 text-sm max-h-48 overflow-y-auto">
                  <%= for event <- Enum.take(@consensus_events, 5) do %>
                    <div class="p-2 bg-slate-700 rounded">
                      <div class="flex justify-between">
                        <span class="text-cyan-400">→ <%= event.target_phase %></span>
                        <span class={[
                          "text-xs px-2 py-0.5 rounded",
                          if(event.resolution == :director_override, do: "bg-yellow-600", else: "bg-green-600")
                        ]}>
                          <%= event.resolution %>
                        </span>
                      </div>
                      <%= if event.votes != [] do %>
                        <div class="mt-1 text-xs text-slate-400">
                          <%= for vote <- event.votes do %>
                            <span class={vote_color(vote.vote)}><%= vote.agent %>: <%= vote.vote %></span>
                          <% end %>
                        </div>
                      <% end %>
                    </div>
                  <% end %>
                </div>
              </div>
            <% end %>
          </div>

          <!-- Main Content Area -->
          <div class="col-span-2">
            <%= case @view_mode do %>
              <% "signals" -> %>
                <!-- Signal Stream (Original View) -->
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

              <% "collaboration" -> %>
                <!-- Agent-to-Agent Communication Log -->
                <div class="bg-slate-800 rounded-xl p-4">
                  <h2 class="text-lg font-semibold mb-4">Agent Communication Log</h2>
                  <p class="text-slate-400 text-sm mb-4">Direct messages between agents showing real-time collaboration</p>

                  <div class="space-y-2 max-h-[600px] overflow-y-auto">
                    <%= if @agent_communications == [] do %>
                      <div class="text-slate-500 text-center py-8">
                        No agent-to-agent communications yet
                      </div>
                    <% else %>
                      <%= for comm <- @agent_communications do %>
                        <div class="p-3 bg-slate-700 rounded-lg">
                          <div class="flex items-center gap-2 mb-1">
                            <span class="text-xs text-slate-500"><%= format_time_from_dt(comm.timestamp) %></span>
                            <span class={"font-semibold #{source_color(comm.source)}"}><%= format_agent_name(comm.source) %></span>
                            <span class="text-slate-500">→</span>
                            <span class={"font-semibold #{target_color(comm.target)}"}><%= format_agent_name(comm.target) %></span>
                          </div>
                          <div class="text-slate-300 text-sm">
                            <%= comm.message %>
                          </div>
                          <div class="text-xs text-slate-500 mt-1">
                            <%= comm.type %>
                          </div>
                        </div>
                      <% end %>
                    <% end %>
                  </div>
                </div>

              <% "synthesis" -> %>
                <!-- Synthesis Visualization -->
                <div class="bg-slate-800 rounded-xl p-4">
                  <h2 class="text-lg font-semibold mb-4">Director Synthesis</h2>
                  <p class="text-slate-400 text-sm mb-4">How Director combines agent inputs to generate questions</p>

                  <!-- Current Synthesis -->
                  <div class="bg-slate-700 rounded-lg p-4 mb-4">
                    <h3 class="text-sm font-semibold text-slate-300 mb-3">Decision Inputs</h3>
                    <div class="grid grid-cols-3 gap-4">
                      <!-- Themes from Story Analyst -->
                      <div class="bg-slate-800 rounded p-3">
                        <div class="flex items-center gap-2 mb-2">
                          <div class="w-2 h-2 rounded-full bg-purple-500"></div>
                          <span class="text-xs font-semibold text-purple-400">Story Analyst</span>
                        </div>
                        <div class="text-xs text-slate-400">
                          Themes: <%= count_recent_themes(@signals) %>
                        </div>
                      </div>

                      <!-- Probes from Probe Coach -->
                      <div class="bg-slate-800 rounded p-3">
                        <div class="flex items-center gap-2 mb-2">
                          <div class="w-2 h-2 rounded-full bg-yellow-500"></div>
                          <span class="text-xs font-semibold text-yellow-400">Probe Coach</span>
                        </div>
                        <div class="text-xs text-slate-400">
                          Probes: <%= count_recent_probes(@signals) %>
                        </div>
                      </div>

                      <!-- Engagement from Monitor -->
                      <div class="bg-slate-800 rounded p-3">
                        <div class="flex items-center gap-2 mb-2">
                          <div class="w-2 h-2 rounded-full bg-red-500"></div>
                          <span class="text-xs font-semibold text-red-400">Engagement</span>
                        </div>
                        <div class="text-xs text-slate-400">
                          Level: <%= get_current_engagement(@signals) %>
                        </div>
                      </div>
                    </div>

                    <div class="mt-4 pt-4 border-t border-slate-600">
                      <div class="flex items-center gap-2 mb-2">
                        <div class="w-2 h-2 rounded-full bg-blue-500"></div>
                        <span class="text-xs font-semibold text-blue-400">Director Output</span>
                      </div>
                      <div class="text-sm text-slate-300">
                        Synthesizes all inputs → Generates contextual question
                      </div>
                    </div>
                  </div>

                  <!-- Question Attribution History -->
                  <h3 class="text-sm font-semibold text-slate-300 mb-3">Question Attributions</h3>
                  <div class="space-y-2 max-h-80 overflow-y-auto">
                    <%= if @question_attributions == [] do %>
                      <div class="text-slate-500 text-center py-4">
                        No questions generated yet
                      </div>
                    <% else %>
                      <%= for attr <- @question_attributions do %>
                        <div class="p-3 bg-slate-700 rounded-lg">
                          <div class="text-sm text-slate-300 mb-2">
                            "<%= attr.question %>..."
                          </div>
                          <div class="flex items-center gap-2 flex-wrap">
                            <span class="text-xs text-slate-500">Influenced by:</span>
                            <%= if attr.contributors == [] do %>
                              <span class="text-xs px-2 py-0.5 bg-blue-600 rounded">Director</span>
                            <% else %>
                              <%= for contributor <- attr.contributors do %>
                                <span class={"text-xs px-2 py-0.5 rounded #{contributor_color(contributor)}"}>
                                  <%= contributor %>
                                </span>
                              <% end %>
                            <% end %>
                          </div>
                        </div>
                      <% end %>
                    <% end %>
                  </div>
                </div>
            <% end %>

            <!-- Selected Signal Detail -->
            <%= if @selected_signal && @view_mode == "signals" do %>
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

  # Phase 5: Agent status indicator helpers
  defp agent_status_class(active_agents, agent_key, color) do
    case Map.get(active_agents, agent_key) do
      %{status: :analyzing} -> "bg-#{color}-500 animate-pulse"
      %{status: :error} -> "bg-red-500"
      _ -> "bg-#{color}-500 opacity-50"
    end
  end

  defp agent_status_text(active_agents, agent_key) do
    case Map.get(active_agents, agent_key) do
      %{status: :analyzing} -> "analyzing..."
      %{status: :error} -> "error"
      %{status: :idle} -> "idle"
      _ -> "ready"
    end
  end

  # Phase 5: Format helpers for collaboration view
  defp format_time_from_dt(%DateTime{} = dt) do
    Calendar.strftime(dt, "%H:%M:%S")
  rescue
    _ -> "--:--:--"
  end
  defp format_time_from_dt(_), do: "--:--:--"

  defp format_agent_name("story_analyst"), do: "Story Analyst"
  defp format_agent_name("probe_coach"), do: "Probe Coach"
  defp format_agent_name("engagement_monitor"), do: "Engagement Monitor"
  defp format_agent_name("director"), do: "Director"
  defp format_agent_name("all"), do: "All Agents"
  defp format_agent_name(name) when is_binary(name), do: name |> String.replace("_", " ") |> String.capitalize()
  defp format_agent_name(name), do: to_string(name)

  defp source_color("story_analyst"), do: "text-purple-400"
  defp source_color("probe_coach"), do: "text-yellow-400"
  defp source_color("engagement_monitor"), do: "text-red-400"
  defp source_color("director"), do: "text-blue-400"
  defp source_color(_), do: "text-slate-400"

  defp target_color("story_analyst"), do: "text-purple-400"
  defp target_color("probe_coach"), do: "text-yellow-400"
  defp target_color("engagement_monitor"), do: "text-red-400"
  defp target_color("director"), do: "text-blue-400"
  defp target_color("all"), do: "text-cyan-400"
  defp target_color(_), do: "text-slate-400"

  defp vote_color(:ready), do: "text-green-400"
  defp vote_color(:not_ready), do: "text-red-400"
  defp vote_color(:abstain), do: "text-slate-400"
  defp vote_color(_), do: "text-slate-400"

  defp contributor_color("Story Analyst"), do: "bg-purple-600"
  defp contributor_color("Probe Coach"), do: "bg-yellow-600"
  defp contributor_color("Engagement Monitor"), do: "bg-red-600"
  defp contributor_color(_), do: "bg-slate-600"

  # Phase 5: Synthesis view helpers
  defp count_recent_themes(signals) do
    signals
    |> Enum.filter(fn s -> s.type == "observer.insight.theme" end)
    |> Enum.take(10)
    |> length()
  end

  defp count_recent_probes(signals) do
    signals
    |> Enum.filter(fn s -> s.type == "observer.suggestion.probe" end)
    |> Enum.take(10)
    |> length()
  end

  defp get_current_engagement(signals) do
    engagement_signal = Enum.find(signals, fn s ->
      s.type == "observer.status.engagement"
    end)

    if engagement_signal, do: engagement_signal.data[:level] || :unknown, else: :unknown
  end
end
