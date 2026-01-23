defmodule InterviewStudio.Pipeline.Phases do
  @moduledoc """
  Phase definitions and question banks for conversations.

  Phases are loaded from external YAML config files, allowing different domains
  (interview, tutoring, assessment, etc.) to define their own phase structures.

  Each phase has:
  - Entry conditions
  - Core questions (for core_questions phase)
  - Exit criteria
  - Timing guidelines

  Configuration is loaded from: priv/domains/{domain}/phases.yaml
  """

  require Logger

  alias InterviewStudio.ConfigLoader

  # Default domain
  @default_domain "interview"

  # Default phases (fallback if YAML not found)
  @default_phases %{
    preparation: %{
      name: "Preparation",
      description: "Initialize agents, load context",
      entry_conditions: ["Session created"],
      exit_criteria: ["All agents ready", "Context loaded"],
      duration: :automatic,
      questions: []
    },
    opening: %{
      name: "Opening",
      description: "Greeting, establish rapport, set expectations",
      entry_conditions: ["Preparation complete"],
      exit_criteria: ["User has responded", "Rapport established"],
      duration: "1-2 exchanges",
      questions: [
        %{
          id: "opening_1",
          text: "Hi! I'm excited to learn more about you and your story. This conversation will help create a compelling article that captures what makes you unique. Ready to dive in?",
          purpose: "Set expectations and get consent"
        }
      ]
    },
    core_questions: %{
      name: "Core Questions",
      description: "Primary interview questions exploring their story",
      entry_conditions: ["Opening complete"],
      exit_criteria: ["All core questions asked", "Or time threshold reached"],
      duration: "Main portion",
      questions: [
        %{id: "origin_1", text: "Let's start at the beginning. What's your background, and how did you get to where you are today?", purpose: "Understand origin story", category: :origin},
        %{id: "passion_1", text: "What drives you? What are you most passionate about in your work?", purpose: "Uncover motivations", category: :passion},
        %{id: "unique_1", text: "What would you say makes your approach or perspective unique? What do you do differently?", purpose: "Identify differentiation", category: :differentiation},
        %{id: "moment_1", text: "Was there a pivotal moment or turning point that really shaped who you've become?", purpose: "Find defining moments", category: :moments},
        %{id: "vision_1", text: "Where are you headed? What's the vision or goal you're working toward?", purpose: "Understand future direction", category: :vision}
      ]
    },
    probing: %{
      name: "Probing",
      description: "Follow up on themes, dig deeper",
      entry_conditions: ["Core questions complete", "Or high-value probe opportunity"],
      exit_criteria: ["Probing depth satisfied", "Or diminishing returns"],
      duration: "Variable",
      questions: []
    },
    synthesis: %{
      name: "Synthesis",
      description: "Summarize key themes, confirm understanding",
      entry_conditions: ["Probing complete"],
      exit_criteria: ["User confirms or corrects synthesis"],
      duration: "1-2 exchanges",
      questions: [
        %{id: "synthesis_1", text: "Based on our conversation, here's what I'm hearing as the core of your story: [THEMES]. Does that resonate with you? Is there anything you'd add or change?", purpose: "Confirm understanding"}
      ]
    },
    closing: %{
      name: "Closing",
      description: "Thank user, explain next steps",
      entry_conditions: ["Synthesis confirmed"],
      exit_criteria: ["Session complete"],
      duration: "1 exchange",
      questions: [
        %{id: "closing_1", text: "Thank you so much for sharing your story with me. I have everything I need to write a compelling piece about you. Is there anything else you'd like to add before we wrap up?", purpose: "Final opportunity and gratitude"}
      ]
    }
  }

  @default_core_categories [:origin, :passion, :differentiation, :moments, :vision]
  @default_phase_order [:preparation, :opening, :core_questions, :probing, :synthesis, :closing]

  @doc """
  Get all phase definitions for the default domain.
  """
  def all, do: all(@default_domain)

  @doc """
  Get all phase definitions for a specific domain.
  """
  def all(domain) do
    load_phases(domain)
  end

  @doc """
  Get a specific phase definition from the default domain.
  """
  def get(phase_name) when is_atom(phase_name) do
    get(@default_domain, phase_name)
  end

  @doc """
  Get a specific phase definition from a specific domain.
  """
  def get(domain, phase_name) when is_atom(phase_name) do
    phases = load_phases(domain)
    Map.get(phases, phase_name)
  end

  @doc """
  Get questions for a specific phase from the default domain.
  """
  def questions(phase_name) do
    questions(@default_domain, phase_name)
  end

  @doc """
  Get questions for a specific phase from a specific domain.
  """
  def questions(domain, phase_name) do
    case get(domain, phase_name) do
      %{questions: questions} -> questions
      _ -> []
    end
  end

  @doc """
  Get question by ID from the default domain.
  """
  def get_question(question_id) do
    get_question(@default_domain, question_id)
  end

  @doc """
  Get question by ID from a specific domain.
  """
  def get_question(domain, question_id) do
    domain
    |> load_phases()
    |> Map.values()
    |> Enum.flat_map(fn phase -> phase.questions end)
    |> Enum.find(fn q -> q.id == question_id end)
  end

  @doc """
  Get the core question categories for the default domain.
  """
  def core_categories do
    core_categories(@default_domain)
  end

  @doc """
  Get the core question categories for a specific domain.
  """
  def core_categories(domain) do
    config = load_config(domain)
    Map.get(config, :core_categories, @default_core_categories)
  end

  @doc """
  Get the phase order for the default domain.
  """
  def phase_order do
    phase_order(@default_domain)
  end

  @doc """
  Get the phase order for a specific domain.
  """
  def phase_order(domain) do
    config = load_config(domain)
    Map.get(config, :phase_order, @default_phase_order)
  end

  @doc """
  Get the next phase in sequence for the default domain.
  """
  def next_phase(current_phase) do
    next_phase(@default_domain, current_phase)
  end

  @doc """
  Get the next phase in sequence for a specific domain.
  """
  def next_phase(domain, current_phase) do
    order = phase_order(domain)
    current_index = Enum.find_index(order, &(&1 == current_phase))

    if current_index && current_index < length(order) - 1 do
      Enum.at(order, current_index + 1)
    else
      nil
    end
  end

  @doc """
  Check if a phase transition is valid for the default domain.
  """
  def valid_transition?(from_phase, to_phase) do
    valid_transition?(@default_domain, from_phase, to_phase)
  end

  @doc """
  Check if a phase transition is valid for a specific domain.
  """
  def valid_transition?(domain, from_phase, to_phase) do
    order = phase_order(domain)
    from_index = Enum.find_index(order, &(&1 == from_phase))
    to_index = Enum.find_index(order, &(&1 == to_phase))

    cond do
      # Both phases must exist in the order
      is_nil(from_index) or is_nil(to_index) -> false
      # Can always move forward
      to_index > from_index -> true
      # Can move backward in special cases (e.g., from closing back to synthesis)
      to_index == from_index - 1 -> true
      # Same phase is valid (no-op)
      to_index == from_index -> true
      # Otherwise invalid
      true -> false
    end
  end

  @doc """
  Check if a phase is complete based on criteria.
  """
  def phase_complete?(:preparation, _context), do: true

  def phase_complete?(:opening, context) do
    Map.get(context, :user_responded, false)
  end

  def phase_complete?(:core_questions, context) do
    asked = Map.get(context, :questions_asked, [])
    total = length(questions(:core_questions))
    length(asked) >= total
  end

  def phase_complete?(:probing, context) do
    Map.get(context, :probing_satisfied, false) or
    Map.get(context, :diminishing_returns, false)
  end

  def phase_complete?(:synthesis, context) do
    Map.get(context, :synthesis_confirmed, false)
  end

  def phase_complete?(:closing, _context), do: true

  # Generic fallback for custom phases
  def phase_complete?(_phase, _context), do: false

  # Private functions for loading config

  defp load_config(domain) do
    case ConfigLoader.load_domain_config(domain, :phases) do
      {:ok, config} ->
        normalize_config(config)

      {:error, reason} ->
        Logger.debug("[Phases] Failed to load config for domain #{domain}: #{inspect(reason)}, using defaults")
        %{
          phases: @default_phases,
          core_categories: @default_core_categories,
          phase_order: @default_phase_order
        }
    end
  end

  defp load_phases(domain) do
    config = load_config(domain)
    Map.get(config, :phases, @default_phases)
  end

  defp normalize_config(config) when is_map(config) do
    %{
      phases: normalize_phases(config[:phases] || config["phases"] || %{}),
      core_categories: normalize_categories(config[:core_categories] || config["core_categories"] || @default_core_categories),
      phase_order: normalize_phase_order(config[:phase_order] || config["phase_order"] || @default_phase_order)
    }
  end

  defp normalize_phases(phases) when is_map(phases) do
    phases
    |> Enum.map(fn {key, value} ->
      phase_key = to_atom(key)
      phase_value = normalize_phase(value)
      {phase_key, phase_value}
    end)
    |> Enum.into(%{})
  end

  defp normalize_phases(phases) when is_list(phases) do
    # Handle list format from YAML
    phases
    |> Enum.map(fn phase ->
      name = phase[:name] || phase["name"]
      phase_key = if name, do: name |> String.downcase() |> String.replace(" ", "_") |> String.to_atom(), else: :unknown
      {phase_key, normalize_phase(phase)}
    end)
    |> Enum.into(%{})
  end

  defp normalize_phases(_), do: @default_phases

  defp normalize_phase(phase) when is_map(phase) do
    %{
      name: phase[:name] || phase["name"] || "Unknown",
      description: phase[:description] || phase["description"] || "",
      entry_conditions: phase[:entry_conditions] || phase["entry_conditions"] || [],
      exit_criteria: phase[:exit_criteria] || phase["exit_criteria"] || [],
      duration: normalize_duration(phase[:duration] || phase["duration"]),
      questions: normalize_questions(phase[:questions] || phase["questions"] || [])
    }
  end

  defp normalize_duration("automatic"), do: :automatic
  defp normalize_duration(:automatic), do: :automatic
  defp normalize_duration(other), do: other

  defp normalize_questions(questions) when is_list(questions) do
    Enum.map(questions, &normalize_question/1)
  end

  defp normalize_questions(_), do: []

  defp normalize_question(q) when is_map(q) do
    base = %{
      id: q[:id] || q["id"] || "unknown",
      text: q[:text] || q["text"] || "",
      purpose: q[:purpose] || q["purpose"] || ""
    }

    # Add category if present
    category = q[:category] || q["category"]
    if category do
      Map.put(base, :category, to_atom(category))
    else
      base
    end
  end

  defp normalize_categories(categories) when is_list(categories) do
    Enum.map(categories, &to_atom/1)
  end

  defp normalize_categories(_), do: @default_core_categories

  defp normalize_phase_order(order) when is_list(order) do
    Enum.map(order, &to_atom/1)
  end

  defp normalize_phase_order(_), do: @default_phase_order

  defp to_atom(value) when is_atom(value), do: value
  defp to_atom(value) when is_binary(value), do: String.to_atom(value)
  defp to_atom(_), do: :unknown
end
