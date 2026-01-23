defmodule InterviewStudio.ConfigLoader do
  @moduledoc """
  Loads YAML configuration files for agents.

  Provides a centralized way to load config from priv/config/ directory,
  with caching for performance.
  """

  require Logger

  @config_dir "priv/config"

  @doc """
  Load a YAML config file by name.

  ## Examples

      iex> ConfigLoader.load(:timer)
      %{milestones: [5, 10], tick_interval_ms: 60000, ...}

      iex> ConfigLoader.load(:engagement)
      %{wrap_up_markers: ["wrap up", ...], scoring: %{...}, ...}
  """
  def load(config_name) when is_atom(config_name) do
    path = config_path(config_name)

    case load_yaml(path) do
      {:ok, config} ->
        Logger.debug("[ConfigLoader] Loaded #{config_name} config from #{path}")
        {:ok, atomize_keys(config)}

      {:error, reason} ->
        Logger.warning("[ConfigLoader] Failed to load #{config_name}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Load a YAML config file, returning default if not found.
  """
  def load(config_name, default) when is_atom(config_name) do
    case load(config_name) do
      {:ok, config} -> config
      {:error, _} -> default
    end
  end

  @doc """
  Load and merge with defaults - config values override defaults.
  """
  def load_with_defaults(config_name, defaults) when is_atom(config_name) and is_map(defaults) do
    case load(config_name) do
      {:ok, config} -> deep_merge(defaults, config)
      {:error, _} -> defaults
    end
  end

  @doc """
  Get a specific key from a config file.
  """
  def get(config_name, key, default \\ nil) do
    case load(config_name) do
      {:ok, config} -> Map.get(config, key, default)
      {:error, _} -> default
    end
  end

  @doc """
  Load a domain-specific config file.

  Domain configs are stored in: priv/domains/{domain}/{config_name}.yaml

  ## Examples

      iex> ConfigLoader.load_domain_config("interview", :phases)
      {:ok, %{phases: %{...}, core_categories: [...], ...}}

      iex> ConfigLoader.load_domain_config("tutoring", :phases)
      {:ok, %{phases: %{...}, ...}}
  """
  def load_domain_config(domain, config_name) when is_binary(domain) and is_atom(config_name) do
    path = domain_config_path(domain, config_name)

    case load_yaml(path) do
      {:ok, config} ->
        Logger.debug("[ConfigLoader] Loaded #{domain}/#{config_name} config from #{path}")
        {:ok, atomize_keys(config)}

      {:error, reason} ->
        Logger.warning("[ConfigLoader] Failed to load #{domain}/#{config_name}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def load_domain_config(domain, config_name) when is_atom(domain) do
    load_domain_config(Atom.to_string(domain), config_name)
  end

  @doc """
  Load a domain-specific config with defaults.
  """
  def load_domain_config_with_defaults(domain, config_name, defaults) when is_map(defaults) do
    case load_domain_config(domain, config_name) do
      {:ok, config} -> deep_merge(defaults, config)
      {:error, _} -> defaults
    end
  end

  # Private helpers

  defp config_path(config_name) do
    Application.app_dir(:interview_studio, "#{@config_dir}/#{config_name}.yaml")
  end

  defp domain_config_path(domain, config_name) do
    Application.app_dir(:interview_studio, "priv/domains/#{domain}/#{config_name}.yaml")
  end

  defp load_yaml(path) do
    if File.exists?(path) do
      case YamlElixir.read_from_file(path) do
        {:ok, content} -> {:ok, content}
        {:error, reason} -> {:error, {:parse_error, reason}}
      end
    else
      {:error, {:file_not_found, path}}
    end
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

  # Deep merge two maps
  defp deep_merge(left, right) do
    Map.merge(left, right, fn
      _k, left_val, right_val when is_map(left_val) and is_map(right_val) ->
        deep_merge(left_val, right_val)
      _k, _left_val, right_val ->
        right_val
    end)
  end
end
