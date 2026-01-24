defmodule InterviewStudio.Testing.FeedbackLoop.IntervieweeAgent do
  @moduledoc """
  GenServer that simulates interviewee responses using LLM.

  Uses persona configuration to generate contextual, behavior-appropriate
  responses during automated testing.
  """

  use GenServer
  require Logger

  alias InterviewStudio.Testing.FeedbackLoop.Persona
  alias InterviewStudio.Testing.FeedbackLoop.ConfigManager

  @timeout 30_000

  defstruct [
    :session_id,
    :persona,
    :llm_config,
    :conversation_history,
    :exchange_count,
    :frustration_level,
    :comfort_level,
    :started_at
  ]

  @type t :: %__MODULE__{
          session_id: String.t(),
          persona: Persona.t(),
          llm_config: map(),
          conversation_history: [map()],
          exchange_count: non_neg_integer(),
          frustration_level: non_neg_integer(),
          comfort_level: non_neg_integer(),
          started_at: DateTime.t()
        }

  # Client API

  @doc """
  Starts an IntervieweeAgent for a session.

  ## Options
    * `:session_id` - Required. The interview session ID.
    * `:persona` - Required. Persona name (atom/string) or Persona struct.
    * `:domain` - Optional. Domain name for LLM config (default: "interview").
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    GenServer.start_link(__MODULE__, opts, name: via_tuple(session_id))
  end

  @doc """
  Generates a response to the host's question.
  """
  @spec generate_response(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def generate_response(session_id, host_question) do
    GenServer.call(via_tuple(session_id), {:generate_response, host_question}, @timeout)
  end

  @doc """
  Gets the current state of the interviewee agent.
  """
  @spec get_state(String.t()) :: {:ok, t()} | {:error, term()}
  def get_state(session_id) do
    GenServer.call(via_tuple(session_id), :get_state)
  end

  @doc """
  Gets the conversation history.
  """
  @spec get_history(String.t()) :: {:ok, [map()]} | {:error, term()}
  def get_history(session_id) do
    GenServer.call(via_tuple(session_id), :get_history)
  end

  @doc """
  Stops the interviewee agent.
  """
  @spec stop(String.t()) :: :ok
  def stop(session_id) do
    GenServer.stop(via_tuple(session_id))
  catch
    :exit, _ -> :ok
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    persona_input = Keyword.fetch!(opts, :persona)
    domain = Keyword.get(opts, :domain, "interview")

    # Load persona if it's a name
    persona =
      case persona_input do
        %Persona{} = p -> p
        name -> Persona.load!(name)
      end

    llm_config = ConfigManager.get_llm_config(domain)

    state = %__MODULE__{
      session_id: session_id,
      persona: persona,
      llm_config: llm_config,
      conversation_history: [],
      exchange_count: 0,
      frustration_level: 0,
      comfort_level: 0,
      started_at: DateTime.utc_now()
    }

    Logger.info("[IntervieweeAgent] Started for session #{session_id} with persona: #{persona.name}")

    {:ok, state}
  end

  @impl true
  def handle_call({:generate_response, host_question}, _from, state) do
    case do_generate_response(state, host_question) do
      {:ok, response, new_state} ->
        {:reply, {:ok, response}, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, {:ok, state}, state}
  end

  @impl true
  def handle_call(:get_history, _from, state) do
    {:reply, {:ok, state.conversation_history}, state}
  end

  # Private functions

  defp via_tuple(session_id) do
    {:via, Registry, {InterviewStudio.SessionRegistry, {:interviewee_agent, session_id}}}
  end

  defp do_generate_response(state, host_question) do
    # Update history with host message
    history_with_question =
      state.conversation_history ++
        [%{role: "host", content: host_question, timestamp: DateTime.utc_now()}]

    # Build context for prompt generation
    context = %{
      exchange_count: state.exchange_count + 1,
      frustration_level: state.frustration_level,
      comfort_level: state.comfort_level
    }

    # Generate system prompt
    system_prompt = Persona.to_system_prompt(state.persona, context)

    # Build conversation for LLM
    messages = build_llm_messages(history_with_question, system_prompt)

    # Call LLM
    case call_llm(messages, state.llm_config) do
      {:ok, response} ->
        # Update state based on persona behavior
        new_state = update_behavioral_state(state, host_question, response)

        # Add response to history
        final_history =
          history_with_question ++
            [%{role: "interviewee", content: response, timestamp: DateTime.utc_now()}]

        new_state = %{new_state | conversation_history: final_history, exchange_count: state.exchange_count + 1}

        {:ok, response, new_state}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_llm_messages(history, system_prompt) do
    # Convert conversation history to LLM message format
    conversation_messages =
      Enum.map(history, fn
        %{role: "host", content: content} ->
          %{role: "user", content: "INTERVIEWER: #{content}"}

        %{role: "interviewee", content: content} ->
          %{role: "assistant", content: content}
      end)

    [%{role: "system", content: system_prompt}] ++ conversation_messages
  end

  defp call_llm(messages, llm_config) do
    # Use the same Jido.AI infrastructure as the interview agents
    try do
      # Build Model struct with API key from environment (Groq via OpenAI-compatible API)
      api_key = System.get_env("AgentDemo_Groq_API_Key") || ""

      model = %Jido.AI.Model{
        provider: :openrouter,
        base_url: "https://api.groq.com/openai/v1/chat/completions",
        model: llm_config.model || "meta-llama/llama-4-scout-17b-16e-instruct",
        api_key: api_key,
        temperature: llm_config.temperature || 0.7,
        max_tokens: llm_config.max_tokens || 1000
      }

      # Convert messages to Jido format
      jido_messages =
        Enum.map(messages, fn msg ->
          role =
            case msg.role || msg["role"] do
              "system" -> :system
              "user" -> :user
              "assistant" -> :assistant
              r when is_atom(r) -> r
              r -> String.to_atom(r)
            end

          content = msg.content || msg["content"]
          %{role: role, content: content}
        end)

      # Build Prompt with messages
      prompt = Jido.AI.Prompt.new(%{messages: jido_messages})

      # Call Langchain action
      case Jido.AI.Actions.Langchain.run(%{model: model, prompt: prompt}, %{}) do
        {:ok, %{content: content}} -> {:ok, content}
        {:ok, result} when is_map(result) -> {:ok, Map.get(result, :content, inspect(result))}
        {:error, reason} -> {:error, reason}
      end
    rescue
      e -> {:error, {:exception, Exception.message(e)}}
    end
  end

  defp update_behavioral_state(state, host_question, _response) do
    persona = state.persona

    # Update frustration based on persona type
    new_frustration =
      case persona.name do
        "frustrated" ->
          # Frustration increases with each exchange
          base_increase = 1
          # Check for frustration triggers
          trigger_increase =
            if has_frustration_trigger?(host_question, persona.frustration_triggers), do: 2, else: 0

          state.frustration_level + base_increase + trigger_increase

        _ ->
          # Other personas have low frustration buildup
          if state.exchange_count > persona.behavior.frustration_threshold do
            state.frustration_level + 1
          else
            state.frustration_level
          end
      end

    # Update comfort for nervous persona
    new_comfort =
      case persona.name do
        "nervous" ->
          # Comfort increases with positive interactions
          state.comfort_level + 1

        _ ->
          state.comfort_level
      end

    %{state | frustration_level: new_frustration, comfort_level: new_comfort}
  end

  defp has_frustration_trigger?(question, triggers) when is_list(triggers) do
    question_lower = String.downcase(question)
    Enum.any?(triggers, fn trigger ->
      String.contains?(question_lower, String.downcase(trigger))
    end)
  end

  defp has_frustration_trigger?(_question, _triggers), do: false
end
