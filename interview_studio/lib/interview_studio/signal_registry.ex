defmodule InterviewStudio.SignalRegistry do
  @moduledoc """
  Signal Registry - provides type-safe signal creation from domain configuration.

  Phase 4: Domain-Agnostic Architecture

  This module:
  - Creates signals based on domain signal type definitions
  - Ensures consistent signal structure across all agents
  - Provides centralized signal type validation

  Usage:
      # Create a signal using domain config
      signal = SignalRegistry.create_signal(domain, :user_utterance, %{content: "Hello"})

      # Or with domain name string
      signal = SignalRegistry.create_signal("interview", :insight_theme, %{theme: "resilience"})
  """

  require Logger

  alias InterviewStudio.DomainLoader

  @doc """
  Create a signal based on domain signal type configuration.

  Returns a %Jido.Signal{} struct with:
  - type: From domain config signal_types
  - source: From domain config or override
  - id: Auto-generated UUID
  - data: Provided data merged with timestamp

  ## Examples

      iex> SignalRegistry.create_signal(domain, :user_utterance, %{content: "Hello"})
      %Jido.Signal{type: "interview.utterance.user", source: "director", ...}

      iex> SignalRegistry.create_signal("interview", :insight_theme, %{theme: "resilience"})
      %Jido.Signal{type: "observer.insight.theme", source: "story_analyst", ...}
  """
  @spec create_signal(DomainLoader.t() | String.t(), atom(), map(), keyword()) :: Jido.Signal.t()
  def create_signal(domain, signal_name, data, opts \\ [])

  def create_signal(%DomainLoader{} = domain, signal_name, data, opts) do
    signal_config = DomainLoader.get_signal_type(domain, signal_name)

    if signal_config do
      create_from_config(signal_config, data, opts)
    else
      # Fallback: create signal with name-based type
      Logger.warning("[SignalRegistry] Signal type #{signal_name} not found in config, using fallback")
      create_fallback_signal(signal_name, data, opts)
    end
  end

  def create_signal(domain_name, signal_name, data, opts) when is_binary(domain_name) do
    case DomainLoader.load(domain_name) do
      {:ok, domain} ->
        create_signal(domain, signal_name, data, opts)

      {:error, _reason} ->
        # Fallback if domain can't be loaded
        create_fallback_signal(signal_name, data, opts)
    end
  end

  @doc """
  Create a signal with explicit type (bypassing domain config).

  Useful for signals that don't need config lookup or for backward compatibility.

  ## Examples

      iex> SignalRegistry.create_direct("observer.status.analyzing", "probe_coach", %{status: :analyzing})
      %Jido.Signal{type: "observer.status.analyzing", source: "probe_coach", ...}
  """
  @spec create_direct(String.t(), String.t(), map()) :: Jido.Signal.t()
  def create_direct(type, source, data) do
    %Jido.Signal{
      type: type,
      source: source,
      id: Jido.Util.generate_id(),
      data: Map.merge(data, %{timestamp: DateTime.utc_now()})
    }
  end

  @doc """
  Get all signal types for a domain.

  Returns a map of signal_name => signal_config.
  """
  @spec get_all_types(DomainLoader.t() | String.t()) :: map()
  def get_all_types(%DomainLoader{signals: signals}) do
    signals[:signal_types] || %{}
  end

  def get_all_types(domain_name) when is_binary(domain_name) do
    case DomainLoader.load(domain_name) do
      {:ok, domain} -> get_all_types(domain)
      {:error, _} -> %{}
    end
  end

  @doc """
  Validate that a signal type exists in the domain config.

  Returns true if the signal type is defined, false otherwise.
  """
  @spec valid_type?(DomainLoader.t() | String.t(), atom()) :: boolean()
  def valid_type?(domain, signal_name) do
    case DomainLoader.get_signal_type(domain, signal_name) do
      nil -> false
      _ -> true
    end
  end

  @doc """
  Get the type string for a signal name.

  Returns the type string or nil if not found.
  """
  @spec type_for(DomainLoader.t() | String.t(), atom()) :: String.t() | nil
  def type_for(domain, signal_name) do
    case DomainLoader.get_signal_type(domain, signal_name) do
      nil -> nil
      config -> config[:type]
    end
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp create_from_config(config, data, opts) do
    # Allow source override via opts
    source = Keyword.get(opts, :source, config[:source] || "unknown")

    %Jido.Signal{
      type: config[:type],
      source: source,
      id: Jido.Util.generate_id(),
      data: Map.merge(data, %{timestamp: DateTime.utc_now()})
    }
  end

  defp create_fallback_signal(signal_name, data, opts) do
    # Convert atom to dot-separated type string
    type = signal_name
           |> Atom.to_string()
           |> String.replace("_", ".")

    source = Keyword.get(opts, :source, "unknown")

    %Jido.Signal{
      type: type,
      source: source,
      id: Jido.Util.generate_id(),
      data: Map.merge(data, %{timestamp: DateTime.utc_now()})
    }
  end
end
