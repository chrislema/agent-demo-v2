defmodule InterviewStudioWeb.InterviewLive do
  @moduledoc """
  Main interview chat interface.
  Clean, minimal UI for conducting interviews.
  """

  use InterviewStudioWeb, :live_view

  alias InterviewStudio.Session
  alias InterviewStudio.InterviewBus

  @impl true
  def mount(_params, _session, socket) do
    # Start a new session
    {:ok, session_id} = Session.start_session()

    # Subscribe to signals for this session
    if connected?(socket) do
      InterviewBus.subscribe("interview.utterance.host")
      InterviewBus.subscribe("interview.phase.**")
      InterviewBus.subscribe("observer.**")
    end

    # Auto-start the interview
    send(self(), :start_interview)

    {:ok, assign(socket,
      session_id: session_id,
      messages: [],
      input_value: "",
      loading: true,
      phase: :preparation,
      interview_complete: false,
      agent_signals: []
    )}
  end

  @impl true
  def handle_info(:start_interview, socket) do
    # Transition to opening phase and get first message
    case Session.transition_to(socket.assigns.session_id, :opening, "Interview started") do
      {:ok, :opening} ->
        case Session.process_message(socket.assigns.session_id, "") do
          {:ok, response} when is_binary(response) ->
            messages = [%{role: :host, content: response, timestamp: DateTime.utc_now()}]
            {:noreply, assign(socket, messages: messages, loading: false, phase: :opening)}

          _ ->
            {:noreply, assign(socket, loading: false, phase: :opening)}
        end

      _ ->
        {:noreply, assign(socket, loading: false)}
    end
  end

  @impl true
  def handle_info({:signal, %{type: "interview.phase.entered"} = signal}, socket) do
    phase = signal.data.phase_name
    interview_complete = phase == :closing

    {:noreply, assign(socket, phase: phase, interview_complete: interview_complete)}
  end

  @impl true
  def handle_info({:signal, %{type: "observer." <> _} = signal}, socket) do
    # Add observer signals to the agent panel
    signals = [signal | socket.assigns.agent_signals] |> Enum.take(50)
    {:noreply, assign(socket, agent_signals: signals)}
  end

  @impl true
  def handle_info({:signal, _signal}, socket) do
    # Ignore other signals
    {:noreply, socket}
  end

  @impl true
  def handle_info({:response, nil}, socket) do
    {:noreply, assign(socket, loading: false)}
  end

  @impl true
  def handle_info({:response, response}, socket) do
    host_msg = %{role: :host, content: response, timestamp: DateTime.utc_now()}
    messages = socket.assigns.messages ++ [host_msg]

    {:noreply, assign(socket, messages: messages, loading: false)}
  end

  @impl true
  def handle_info({:error, _reason}, socket) do
    {:noreply, assign(socket, loading: false)}
  end

  @impl true
  def handle_event("send_message", %{"message" => message}, socket) when message != "" do
    # Add user message to display
    user_msg = %{role: :user, content: message, timestamp: DateTime.utc_now()}
    messages = socket.assigns.messages ++ [user_msg]

    # Show loading state
    socket = assign(socket, messages: messages, input_value: "", loading: true)

    # Process async to not block
    session_id = socket.assigns.session_id
    lv_pid = self()

    Task.start(fn ->
      case Session.process_message(session_id, message) do
        {:ok, response} when is_binary(response) ->
          send(lv_pid, {:response, response})

        {:ok, nil} ->
          send(lv_pid, {:response, nil})

        {:error, reason} ->
          send(lv_pid, {:error, reason})
      end
    end)

    {:noreply, socket}
  end

  @impl true
  def handle_event("send_message", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("update_input", %{"message" => value}, socket) do
    {:noreply, assign(socket, input_value: value)}
  end

  @impl true
  def handle_event("update_input", _params, socket) do
    # Fallback for other param structures
    {:noreply, socket}
  end

  @impl true
  def handle_event("new_interview", _params, socket) do
    # Stop current session
    Session.stop_session(socket.assigns.session_id)

    # Start fresh
    {:ok, session_id} = Session.start_session()

    if connected?(socket) do
      InterviewBus.subscribe("interview.utterance.host")
      InterviewBus.subscribe("interview.phase.**")
      InterviewBus.subscribe("observer.**")
    end

    send(self(), :start_interview)

    {:noreply, assign(socket,
      session_id: session_id,
      messages: [],
      input_value: "",
      loading: true,
      phase: :preparation,
      interview_complete: false,
      agent_signals: []
    )}
  end

  @impl true
  def terminate(_reason, socket) do
    Session.stop_session(socket.assigns.session_id)
    :ok
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-gradient-to-b from-slate-900 to-slate-800 text-white">
      <div class="max-w-6xl mx-auto px-4 py-8">
        <!-- Header -->
        <header class="text-center mb-8">
          <h1 class="text-3xl font-bold text-white mb-2">The Story of You</h1>
          <p class="text-slate-400">Let's discover what makes you unique</p>
          <div class="mt-2 text-sm text-slate-500">
            Phase: <span class="text-blue-400"><%= format_phase(@phase) %></span>
          </div>
        </header>

        <!-- Two Column Layout -->
        <div class="grid grid-cols-3 gap-6">
          <!-- Chat Section (2/3) -->
          <div class="col-span-2">
            <!-- Chat Messages -->
            <div class="bg-slate-800/50 rounded-2xl p-6 mb-6 min-h-[400px] max-h-[500px] overflow-y-auto" id="chat-messages" phx-hook="ScrollToBottom">
              <%= if @messages == [] and @loading do %>
                <div class="flex items-center justify-center h-full">
                  <div class="animate-pulse text-slate-400">Starting interview...</div>
                </div>
              <% else %>
                <div class="space-y-4">
                  <%= for message <- @messages do %>
                    <div class={[
                      "flex",
                      if(message.role == :user, do: "justify-end", else: "justify-start")
                    ]}>
                      <div class={[
                        "max-w-[80%] rounded-2xl px-4 py-3",
                        if(message.role == :user,
                          do: "bg-blue-600 text-white",
                          else: "bg-slate-700 text-slate-100")
                      ]}>
                        <p class="whitespace-pre-wrap"><%= message.content %></p>
                      </div>
                    </div>
                  <% end %>

                  <%= if @loading do %>
                    <div class="flex justify-start">
                      <div class="bg-slate-700 rounded-2xl px-4 py-3">
                        <div class="flex space-x-1">
                          <div class="w-2 h-2 bg-slate-400 rounded-full animate-bounce"></div>
                          <div class="w-2 h-2 bg-slate-400 rounded-full animate-bounce" style="animation-delay: 0.1s"></div>
                          <div class="w-2 h-2 bg-slate-400 rounded-full animate-bounce" style="animation-delay: 0.2s"></div>
                        </div>
                      </div>
                    </div>
                  <% end %>
                </div>
              <% end %>
            </div>

            <!-- Input Form -->
            <%= if @interview_complete do %>
              <div class="text-center">
                <p class="text-slate-400 mb-4">Interview complete! Thank you for sharing your story.</p>
                <button
                  phx-click="new_interview"
                  class="bg-blue-600 hover:bg-blue-700 text-white font-semibold py-3 px-6 rounded-xl transition-colors"
                >
                  Start New Interview
                </button>
              </div>
            <% else %>
              <form phx-submit="send_message" phx-change="update_input" class="flex gap-3">
                <input
                  type="text"
                  name="message"
                  value={@input_value}
                  phx-debounce="100"
                  placeholder="Type your response..."
                  autocomplete="off"
                  disabled={@loading}
                  class="flex-1 bg-slate-700 border-0 rounded-xl px-4 py-3 text-white placeholder-slate-400 focus:ring-2 focus:ring-blue-500 focus:outline-none disabled:opacity-50"
                />
                <button
                  type="submit"
                  disabled={@loading or @input_value == ""}
                  class="bg-blue-600 hover:bg-blue-700 disabled:bg-slate-600 disabled:cursor-not-allowed text-white font-semibold py-3 px-6 rounded-xl transition-colors"
                >
                  Send
                </button>
              </form>
            <% end %>
          </div>

          <!-- Agent Activity Panel (1/3) -->
          <div class="col-span-1">
            <div class="bg-slate-800/50 rounded-2xl p-4 min-h-[400px] max-h-[560px] overflow-y-auto">
              <h3 class="text-sm font-semibold text-slate-400 mb-3 uppercase tracking-wide">Agent Activity</h3>

              <%= if @agent_signals == [] do %>
                <div class="text-slate-500 text-sm text-center py-8">
                  Waiting for agent activity...
                </div>
              <% else %>
                <div class="space-y-2">
                  <%= for signal <- @agent_signals do %>
                    <div class="bg-slate-700/50 rounded-lg p-2 text-xs">
                      <div class={"font-mono truncate #{signal_color(signal.type)}"}>
                        <%= format_signal_type(signal.type) %>
                      </div>
                      <div class="text-slate-400 mt-1 truncate">
                        <%= signal_preview(signal) %>
                      </div>
                    </div>
                  <% end %>
                </div>
              <% end %>
            </div>

            <!-- Debug Link -->
            <div class="mt-4 text-center">
              <a href="/debug" class="text-slate-500 hover:text-slate-400 text-sm">
                Full Debug View
              </a>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp format_phase(:preparation), do: "Preparing"
  defp format_phase(:opening), do: "Opening"
  defp format_phase(:core_questions), do: "Core Questions"
  defp format_phase(:probing), do: "Probing Deeper"
  defp format_phase(:synthesis), do: "Synthesis"
  defp format_phase(:closing), do: "Closing"
  defp format_phase(phase), do: to_string(phase)

  # Signal formatting helpers for agent panel - human readable messages
  defp signal_color(type) do
    cond do
      String.contains?(type, "insight.theme") -> "text-purple-400"
      String.contains?(type, "insight.pattern") -> "text-purple-300"
      String.contains?(type, "suggestion.probe") -> "text-yellow-400"
      String.contains?(type, "status.engagement") -> "text-orange-400"
      String.contains?(type, "record.quote") -> "text-green-400"
      String.contains?(type, "record.summary") -> "text-green-300"
      String.contains?(type, "phase.entered") -> "text-blue-400"
      String.contains?(type, "phase.completed") -> "text-blue-300"
      true -> "text-slate-400"
    end
  end

  defp format_signal_type(type) do
    cond do
      String.contains?(type, "insight.theme") -> "Story Analyst"
      String.contains?(type, "insight.pattern") -> "Story Analyst"
      String.contains?(type, "suggestion.probe") -> "Probe Coach"
      String.contains?(type, "status.engagement") -> "Engagement Monitor"
      String.contains?(type, "record.quote") -> "Scribe"
      String.contains?(type, "record.summary") -> "Scribe"
      String.contains?(type, "phase.entered") -> "Director"
      String.contains?(type, "phase.completed") -> "Director"
      true -> "System"
    end
  end

  defp signal_preview(signal) do
    type = signal.type
    data = signal.data

    cond do
      # Theme discovered
      String.contains?(type, "insight.theme") ->
        theme = Map.get(data, :theme, "something interesting")
        "I'm noticing a theme around #{theme}"

      # Pattern found
      String.contains?(type, "insight.pattern") ->
        pattern = Map.get(data, :pattern_type, "recurring element")
        "Spotted a pattern: #{pattern}"

      # Probe suggestion
      String.contains?(type, "suggestion.probe") ->
        topic = Map.get(data, :topic, "this")
        priority = Map.get(data, :priority, :medium)
        priority_text = if priority == :high, do: "We should definitely", else: "We could"
        "#{priority_text} dig deeper on #{topic}"

      # Engagement status
      String.contains?(type, "status.engagement") ->
        level = Map.get(data, :level, :medium)
        case level do
          :high -> "They're really engaged right now!"
          :medium -> "Engagement looking good"
          :low -> "Energy seems to be dropping..."
          :critical -> "We might be losing them"
          _ -> "Watching engagement levels"
        end

      # Notable quote
      String.contains?(type, "record.quote") ->
        quote = Map.get(data, :quote, "")
        "Great quote: \"#{String.slice(quote, 0, 35)}...\""

      # Phase summary
      String.contains?(type, "record.summary") ->
        "Wrapping up notes for this section"

      # Phase entered
      String.contains?(type, "phase.entered") ->
        phase = Map.get(data, :phase_name, :unknown)
        case phase do
          :preparation -> "Getting everything ready..."
          :opening -> "Starting the conversation"
          :core_questions -> "Moving into the main questions"
          :probing -> "Let's explore some things deeper"
          :synthesis -> "Time to bring it all together"
          :closing -> "Wrapping up the interview"
          _ -> "Transitioning to #{phase}"
        end

      # Phase completed
      String.contains?(type, "phase.completed") ->
        phase = Map.get(data, :phase_name, :unknown)
        "Finished #{format_phase_name(phase)}"

      # Fallback
      true ->
        "Processing..."
    end
  end

  defp format_phase_name(phase) do
    case phase do
      :preparation -> "preparation"
      :opening -> "the opening"
      :core_questions -> "core questions"
      :probing -> "deep dive"
      :synthesis -> "synthesis"
      :closing -> "closing"
      _ -> to_string(phase)
    end
  end
end
