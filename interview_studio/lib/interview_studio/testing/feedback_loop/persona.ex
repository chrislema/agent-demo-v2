defmodule InterviewStudio.Testing.FeedbackLoop.Persona do
  @moduledoc """
  Persona configuration struct for simulated interviewees.

  Personas define how a simulated interviewee behaves during automated testing.
  They're loaded from YAML files in priv/testing/personas/.
  """

  @enforce_keys [:name]
  defstruct [
    :name,
    :description,
    behavior: %{},
    background: %{},
    personality_traits: [],
    llm_instructions: "",
    frustration_triggers: [],
    tangent_topics: [],
    comfort_indicators: [],
    frustration_progression: %{},
    comfort_progression: %{}
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t() | nil,
          behavior: map(),
          background: map(),
          personality_traits: [String.t()],
          llm_instructions: String.t(),
          frustration_triggers: [String.t()],
          tangent_topics: [String.t()],
          comfort_indicators: [String.t()],
          frustration_progression: map(),
          comfort_progression: map()
        }

  @personas_dir "priv/testing/personas"

  @doc """
  Loads a persona from a YAML file.

  ## Examples

      iex> Persona.load(:cooperative)
      {:ok, %Persona{name: "cooperative", ...}}

      iex> Persona.load("frustrated")
      {:ok, %Persona{name: "frustrated", ...}}
  """
  @spec load(atom() | String.t()) :: {:ok, t()} | {:error, term()}
  def load(persona_name) when is_atom(persona_name) do
    load(Atom.to_string(persona_name))
  end

  def load(persona_name) when is_binary(persona_name) do
    path = Path.join([Application.app_dir(:interview_studio), @personas_dir, "#{persona_name}.yaml"])

    case YamlElixir.read_from_file(path) do
      {:ok, data} ->
        {:ok, from_yaml(data)}

      {:error, reason} ->
        {:error, {:yaml_parse_error, reason}}
    end
  rescue
    e -> {:error, {:file_error, e}}
  end

  @doc """
  Loads a persona, raising on error.
  """
  @spec load!(atom() | String.t()) :: t()
  def load!(persona_name) do
    case load(persona_name) do
      {:ok, persona} -> persona
      {:error, reason} -> raise "Failed to load persona #{persona_name}: #{inspect(reason)}"
    end
  end

  @doc """
  Lists all available persona names.
  """
  @spec list_available() :: [String.t()]
  def list_available do
    path = Path.join(Application.app_dir(:interview_studio), @personas_dir)

    case File.ls(path) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".yaml"))
        |> Enum.map(&String.replace(&1, ".yaml", ""))

      {:error, _} ->
        []
    end
  end

  @doc """
  Loads all available personas.
  """
  @spec load_all() :: {:ok, [t()]} | {:error, term()}
  def load_all do
    results =
      list_available()
      |> Enum.map(&load/1)

    errors = Enum.filter(results, &match?({:error, _}, &1))

    if Enum.empty?(errors) do
      {:ok, Enum.map(results, fn {:ok, p} -> p end)}
    else
      {:error, {:load_errors, errors}}
    end
  end

  @doc """
  Converts a YAML map to a Persona struct.
  """
  @spec from_yaml(map()) :: t()
  def from_yaml(data) do
    persona_data = data["persona"] || %{}
    behavior_data = data["behavior"] || %{}
    background_data = data["background"] || %{}

    %__MODULE__{
      name: persona_data["name"] || "unknown",
      description: persona_data["description"],
      behavior: %{
        response_length: String.to_atom(behavior_data["response_length"] || "medium"),
        enthusiasm_level: String.to_atom(behavior_data["enthusiasm_level"] || "medium"),
        tangent_probability: behavior_data["tangent_probability"] || 0.0,
        frustration_threshold: behavior_data["frustration_threshold"] || 10,
        detail_level: String.to_atom(behavior_data["detail_level"] || "medium"),
        emotional_openness: String.to_atom(behavior_data["emotional_openness"] || "medium")
      },
      background: %{
        profession: background_data["profession"],
        years_experience: background_data["years_experience"],
        origin_story: background_data["origin_story"],
        passion: background_data["passion"],
        turning_point: background_data["turning_point"],
        key_moments: background_data["key_moments"] || []
      },
      personality_traits: data["personality_traits"] || [],
      llm_instructions: data["llm_instructions"] || "",
      frustration_triggers: data["frustration_triggers"] || [],
      tangent_topics: data["tangent_topics"] || [],
      comfort_indicators: data["comfort_indicators"] || [],
      frustration_progression: parse_progression(data["frustration_progression"]),
      comfort_progression: parse_progression(data["comfort_progression"])
    }
  end

  @doc """
  Generates the system prompt for the LLM based on persona configuration.
  """
  @spec to_system_prompt(t(), map()) :: String.t()
  def to_system_prompt(%__MODULE__{} = persona, context \\ %{}) do
    exchange_count = context[:exchange_count] || 0
    frustration_level = context[:frustration_level] || 0
    comfort_level = context[:comfort_level] || 0

    """
    #{persona.llm_instructions}

    YOUR BACKGROUND:
    - Profession: #{persona.background.profession || "Not specified"}
    - Years of experience: #{persona.background.years_experience || "Not specified"}
    - Origin story: #{persona.background.origin_story || "Not specified"}
    - What you're passionate about: #{persona.background.passion || "Not specified"}
    - A turning point in your career/life: #{persona.background.turning_point || "Not specified"}
    #{format_key_moments(persona.background.key_moments)}

    PERSONALITY TRAITS: #{Enum.join(persona.personality_traits, ", ")}

    CURRENT STATE:
    - Exchange number: #{exchange_count}
    - Frustration level: #{frustration_level} (threshold: #{persona.behavior.frustration_threshold})
    - Comfort level: #{comfort_level}

    BEHAVIORAL PARAMETERS:
    - Response length preference: #{persona.behavior.response_length}
    - Enthusiasm level: #{persona.behavior.enthusiasm_level}
    - Likelihood of going off-topic: #{Float.round(persona.behavior.tangent_probability * 100, 1)}%
    - Detail level: #{persona.behavior.detail_level}
    - Emotional openness: #{persona.behavior.emotional_openness}

    Remember: You are the interviewee. Respond only as the interview subject would respond.
    Do NOT break character or provide meta-commentary about the interview process.
    """
  end

  # Private helpers

  defp parse_progression(nil), do: %{}

  defp parse_progression(levels) when is_list(levels) do
    Enum.into(levels, %{}, fn level ->
      key = level["level"] || level["description"]
      {key, level}
    end)
  end

  defp parse_progression(levels) when is_map(levels), do: levels

  defp format_key_moments([]), do: ""

  defp format_key_moments(moments) do
    formatted = moments |> Enum.map(&"  - #{&1}") |> Enum.join("\n")
    "- Key moments:\n#{formatted}"
  end
end
