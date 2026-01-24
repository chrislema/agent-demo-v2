defmodule InterviewStudio.DomainLoader do
  @moduledoc """
  Central module for loading and managing domain configurations.

  Phase 4: True Domain-Agnostic Architecture

  This module:
  - Loads and validates complete domain configuration from YAML files
  - Caches config in :persistent_term for performance
  - Provides accessors: get_agent/2, get_action/2, get_signal_type/2, get_consensus_weights/2

  Domain configurations are stored in: priv/domains/{domain_name}/

  A domain consists of:
  - domain.yaml: Master config that references all other files
  - agents.yaml: Agent definitions and subscriptions
  - phases.yaml: Phase definitions and flow (already exists from Phase 3)
  - actions.yaml: Action types and fallbacks
  - consensus.yaml: Voting weights and rules
  - signals.yaml: Signal type definitions
  - heuristics/: Per-agent heuristic configurations
  """

  require Logger

  defstruct [
    :name,
    :display_name,
    :agents,
    :phases,
    :signals,
    :actions,
    :consensus,
    :heuristics,
    :llm_defaults,
    :settings
  ]

  @type t :: %__MODULE__{
    name: String.t(),
    display_name: String.t(),
    agents: map(),
    phases: map(),
    signals: map(),
    actions: map(),
    consensus: map(),
    heuristics: map(),
    llm_defaults: map(),
    settings: map()
  }

  # Persistent term key prefix for domain configs
  @domain_key_prefix :interview_studio_domain

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Load a complete domain configuration.

  Returns {:ok, %DomainLoader{}} or {:error, reason}

  ## Examples

      iex> DomainLoader.load("interview")
      {:ok, %DomainLoader{name: "interview", ...}}

      iex> DomainLoader.load("tutoring")
      {:ok, %DomainLoader{name: "tutoring", ...}}
  """
  @spec load(String.t()) :: {:ok, t()} | {:error, term()}
  def load(domain_name) when is_binary(domain_name) do
    # Check cache first
    case get_cached(domain_name) do
      {:ok, domain} ->
        {:ok, domain}

      :not_found ->
        # Load from YAML files
        case load_from_yaml(domain_name) do
          {:ok, domain} ->
            cache_domain(domain_name, domain)
            {:ok, domain}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  def load(domain_name) when is_atom(domain_name) do
    load(Atom.to_string(domain_name))
  end

  @doc """
  Load a domain configuration, raising on error.
  """
  @spec load!(String.t()) :: t()
  def load!(domain_name) do
    case load(domain_name) do
      {:ok, domain} -> domain
      {:error, reason} -> raise "Failed to load domain #{domain_name}: #{inspect(reason)}"
    end
  end

  @doc """
  Reload a domain configuration, bypassing cache.
  """
  @spec reload(String.t()) :: {:ok, t()} | {:error, term()}
  def reload(domain_name) do
    clear_cache(domain_name)
    load(domain_name)
  end

  @doc """
  Get an agent configuration from the domain.

  Returns the agent config map or nil if not found.
  """
  @spec get_agent(t() | String.t(), atom() | String.t()) :: map() | nil
  def get_agent(%__MODULE__{} = domain, agent_id) when is_atom(agent_id) do
    get_agent(domain, Atom.to_string(agent_id))
  end

  def get_agent(%__MODULE__{agents: agents}, agent_id) when is_binary(agent_id) do
    all_agents = (agents[:critical] || []) ++ (agents[:observers] || [])
    Enum.find(all_agents, fn a -> a[:id] == agent_id end)
  end

  def get_agent(domain_name, agent_id) when is_binary(domain_name) do
    case load(domain_name) do
      {:ok, domain} -> get_agent(domain, agent_id)
      {:error, _} -> nil
    end
  end

  @doc """
  Get all agents from the domain.

  Returns a list of all agent configs (critical + observers).
  """
  @spec get_all_agents(t() | String.t()) :: [map()]
  def get_all_agents(%__MODULE__{agents: agents}) do
    (agents[:critical] || []) ++ (agents[:observers] || [])
  end

  def get_all_agents(domain_name) when is_binary(domain_name) do
    case load(domain_name) do
      {:ok, domain} -> get_all_agents(domain)
      {:error, _} -> []
    end
  end

  @doc """
  Get subscriptions for a specific agent.
  """
  @spec get_subscriptions(t() | String.t(), atom() | String.t()) :: [String.t()]
  def get_subscriptions(%__MODULE__{agents: agents}, agent_id) do
    agent_id_str = to_string(agent_id)
    agent_id_atom = if is_binary(agent_id), do: String.to_atom(agent_id), else: agent_id

    subscriptions = agents[:subscriptions] || %{}
    Map.get(subscriptions, agent_id_atom, []) ||
      Map.get(subscriptions, agent_id_str, [])
  end

  def get_subscriptions(domain_name, agent_id) when is_binary(domain_name) do
    case load(domain_name) do
      {:ok, domain} -> get_subscriptions(domain, agent_id)
      {:error, _} -> []
    end
  end

  @doc """
  Get an action configuration from the domain.

  Returns the action config map or nil if not found.
  """
  @spec get_action(t() | String.t(), atom() | String.t()) :: map() | nil
  def get_action(%__MODULE__{actions: actions}, action_type) when is_atom(action_type) do
    action_types = actions[:action_types] || %{}
    Map.get(action_types, action_type)
  end

  def get_action(%__MODULE__{} = domain, action_type) when is_binary(action_type) do
    get_action(domain, String.to_atom(action_type))
  end

  def get_action(domain_name, action_type) when is_binary(domain_name) do
    case load(domain_name) do
      {:ok, domain} -> get_action(domain, action_type)
      {:error, _} -> nil
    end
  end

  @doc """
  Get a signal type configuration from the domain.

  Returns the signal config map or nil if not found.
  """
  @spec get_signal_type(t() | String.t(), atom() | String.t()) :: map() | nil
  def get_signal_type(%__MODULE__{signals: signals}, signal_name) when is_atom(signal_name) do
    signal_types = signals[:signal_types] || %{}
    Map.get(signal_types, signal_name)
  end

  def get_signal_type(%__MODULE__{} = domain, signal_name) when is_binary(signal_name) do
    get_signal_type(domain, String.to_atom(signal_name))
  end

  def get_signal_type(domain_name, signal_name) when is_binary(domain_name) do
    case load(domain_name) do
      {:ok, domain} -> get_signal_type(domain, signal_name)
      {:error, _} -> nil
    end
  end

  @doc """
  Get consensus weights for a specific phase transition.

  Returns a map of agent weights and threshold configuration.
  """
  @spec get_consensus_weights(t() | String.t(), atom()) :: map()
  def get_consensus_weights(%__MODULE__{consensus: consensus}, target_phase) do
    weights = consensus[:weights] || %{}
    thresholds = consensus[:thresholds] || %{}

    # Get phase-specific weights or default
    phase_weights = Map.get(weights, target_phase) || weights[:default] || %{}

    %{
      weights: phase_weights,
      threshold: thresholds[:weighted_threshold] || 0.6,
      strong_consensus: thresholds[:strong_consensus] || 2
    }
  end

  def get_consensus_weights(domain_name, target_phase) when is_binary(domain_name) do
    case load(domain_name) do
      {:ok, domain} -> get_consensus_weights(domain, target_phase)
      {:error, _} -> %{weights: %{}, threshold: 0.6, strong_consensus: 2}
    end
  end

  @doc """
  Get consensus overrides - conditions that bypass normal voting.
  """
  @spec get_consensus_overrides(t() | String.t()) :: [map()]
  def get_consensus_overrides(%__MODULE__{consensus: consensus}) do
    consensus[:overrides] || []
  end

  def get_consensus_overrides(domain_name) when is_binary(domain_name) do
    case load(domain_name) do
      {:ok, domain} -> get_consensus_overrides(domain)
      {:error, _} -> []
    end
  end

  @doc """
  Get heuristics configuration for a specific agent.

  Returns the heuristics config map or empty map if not found.
  """
  @spec get_heuristics(t() | String.t(), atom() | String.t()) :: map()
  def get_heuristics(%__MODULE__{heuristics: heuristics}, agent_name) when is_atom(agent_name) do
    Map.get(heuristics, agent_name, %{})
  end

  def get_heuristics(%__MODULE__{} = domain, agent_name) when is_binary(agent_name) do
    get_heuristics(domain, String.to_atom(agent_name))
  end

  def get_heuristics(domain_name, agent_name) when is_binary(domain_name) do
    case load(domain_name) do
      {:ok, domain} -> get_heuristics(domain, agent_name)
      {:error, _} -> %{}
    end
  end

  @doc """
  Get LLM defaults for the domain.
  """
  @spec get_llm_defaults(t() | String.t()) :: map()
  def get_llm_defaults(%__MODULE__{llm_defaults: llm_defaults}) do
    llm_defaults || %{}
  end

  def get_llm_defaults(domain_name) when is_binary(domain_name) do
    case load(domain_name) do
      {:ok, domain} -> get_llm_defaults(domain)
      {:error, _} -> %{}
    end
  end

  @doc """
  Get phases configuration (passthrough to existing Phases module).
  """
  @spec get_phases(t() | String.t()) :: map()
  def get_phases(%__MODULE__{phases: phases}), do: phases

  def get_phases(domain_name) when is_binary(domain_name) do
    case load(domain_name) do
      {:ok, domain} -> get_phases(domain)
      {:error, _} -> %{}
    end
  end

  @doc """
  Store domain config for a session in :persistent_term.
  This allows agents to access domain config by session_id.
  """
  @spec store_session_domain(String.t(), t()) :: :ok
  def store_session_domain(session_id, %__MODULE__{} = domain) do
    :persistent_term.put({:session_domain, session_id}, domain)
    :ok
  end

  @doc """
  Get domain config for a session from :persistent_term.
  """
  @spec get_session_domain(String.t()) :: t() | nil
  def get_session_domain(session_id) do
    try do
      :persistent_term.get({:session_domain, session_id})
    rescue
      ArgumentError -> nil
    end
  end

  @doc """
  Clear session domain config from :persistent_term.
  """
  @spec clear_session_domain(String.t()) :: :ok
  def clear_session_domain(session_id) do
    try do
      :persistent_term.erase({:session_domain, session_id})
    rescue
      ArgumentError -> :ok
    end
    :ok
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp load_from_yaml(domain_name) do
    base_path = domain_path(domain_name)

    with {:ok, domain_yaml} <- load_yaml_file(base_path, "domain.yaml"),
         {:ok, agents_config} <- load_referenced_config(base_path, domain_yaml, :agents_config, "agents.yaml"),
         {:ok, phases} <- load_referenced_config(base_path, domain_yaml, :phases_config, "phases.yaml"),
         {:ok, signals_config} <- load_referenced_config(base_path, domain_yaml, :signals_config, "signals.yaml"),
         {:ok, actions_config} <- load_referenced_config(base_path, domain_yaml, :actions_config, "actions.yaml"),
         {:ok, consensus_config} <- load_referenced_config(base_path, domain_yaml, :consensus_config, "consensus.yaml") do

      # Extract nested structures from YAML files
      # agents.yaml has: agents: {critical: [...], observers: [...]} and subscriptions: {...}
      agents = %{
        critical: get_in(agents_config, [:agents, :critical]) || [],
        observers: get_in(agents_config, [:agents, :observers]) || [],
        subscriptions: agents_config[:subscriptions] || %{}
      }

      # signals.yaml has: signal_types: {...}
      signals = %{
        signal_types: signals_config[:signal_types] || %{}
      }

      # actions.yaml has: action_types: {...}, timeouts: {...}
      actions = %{
        action_types: actions_config[:action_types] || %{},
        timeouts: actions_config[:timeouts] || %{}
      }

      # consensus.yaml has: consensus: {thresholds: {...}, weights: {...}, overrides: [...]}
      consensus = consensus_config[:consensus] || %{}

      # Load heuristics based on agent configs
      {:ok, heuristics} = load_heuristics(base_path, agents)

      domain = %__MODULE__{
        name: domain_yaml[:domain][:name] || domain_name,
        display_name: domain_yaml[:domain][:display_name] || domain_name,
        agents: agents,
        phases: phases,
        signals: signals,
        actions: actions,
        consensus: consensus,
        heuristics: heuristics,
        llm_defaults: domain_yaml[:llm_defaults] || %{},
        settings: domain_yaml[:settings] || %{}
      }

      Logger.info("[DomainLoader] Loaded domain: #{domain_name}")
      {:ok, domain}
    else
      {:error, reason} ->
        Logger.warning("[DomainLoader] Failed to load domain #{domain_name}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp load_referenced_config(base_path, domain_yaml, config_key, default_filename) do
    filename = domain_yaml[config_key] || default_filename
    load_yaml_file(base_path, filename)
  end

  defp load_heuristics(base_path, agents) do
    # Load heuristics for each agent that has a heuristics_config
    all_agents = (agents[:critical] || []) ++ (agents[:observers] || [])

    heuristics = Enum.reduce(all_agents, %{}, fn agent, acc ->
      case agent[:heuristics_config] do
        nil ->
          acc

        config_path ->
          agent_id = String.to_atom(agent[:id])
          case load_yaml_file(base_path, config_path) do
            {:ok, config} ->
              Map.put(acc, agent_id, config)

            {:error, reason} ->
              Logger.warning("[DomainLoader] Failed to load heuristics for #{agent_id}: #{inspect(reason)}")
              acc
          end
      end
    end)

    {:ok, heuristics}
  end

  defp load_yaml_file(base_path, filename) do
    path = Path.join(base_path, filename)

    if File.exists?(path) do
      case YamlElixir.read_from_file(path) do
        {:ok, content} ->
          {:ok, atomize_keys(content)}

        {:error, reason} ->
          {:error, {:parse_error, path, reason}}
      end
    else
      # Return empty config for optional files
      if filename in ["signals.yaml", "consensus.yaml", "actions.yaml"] do
        Logger.debug("[DomainLoader] Optional file not found: #{path}, using defaults")
        {:ok, %{}}
      else
        {:error, {:file_not_found, path}}
      end
    end
  end

  defp domain_path(domain_name) do
    Application.app_dir(:interview_studio, "priv/domains/#{domain_name}")
  end

  # Convert string keys to atoms recursively
  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) -> {String.to_atom(k), atomize_keys(v)}
      {k, v} -> {k, atomize_keys(v)}
    end)
  end
  defp atomize_keys(list) when is_list(list) do
    Enum.map(list, &atomize_keys/1)
  end
  defp atomize_keys(value), do: value

  # Cache management using :persistent_term

  defp get_cached(domain_name) do
    try do
      domain = :persistent_term.get({@domain_key_prefix, domain_name})
      {:ok, domain}
    rescue
      ArgumentError -> :not_found
    end
  end

  defp cache_domain(domain_name, domain) do
    :persistent_term.put({@domain_key_prefix, domain_name}, domain)
    Logger.debug("[DomainLoader] Cached domain: #{domain_name}")
  end

  defp clear_cache(domain_name) do
    try do
      :persistent_term.erase({@domain_key_prefix, domain_name})
    rescue
      ArgumentError -> :ok
    end
  end
end
