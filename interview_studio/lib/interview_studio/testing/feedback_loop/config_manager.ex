defmodule InterviewStudio.Testing.FeedbackLoop.ConfigManager do
  @moduledoc """
  Manages configuration loading, hot-reloading, and snapshotting for the feedback loop.

  Provides functionality to:
  - Reload domain configurations without restart
  - Snapshot current configuration for reproducibility
  - Diff configurations between runs
  """

  alias InterviewStudio.DomainLoader
  alias InterviewStudio.PromptLoader

  @doc """
  Reloads all configuration for a domain from disk.

  This clears caches and re-reads YAML files, allowing live configuration changes.
  """
  @spec reload_domain(String.t()) :: {:ok, DomainLoader.t()} | {:error, term()}
  def reload_domain(domain_name) do
    # Clear prompt cache
    PromptLoader.clear_cache()

    # Reload domain configuration
    DomainLoader.reload(domain_name)
  end

  @doc """
  Creates a snapshot of the current domain configuration.

  Returns a map containing all configuration values at the time of the snapshot,
  useful for comparing runs or reproducing results.
  """
  @spec snapshot(String.t()) :: {:ok, map()} | {:error, term()}
  def snapshot(domain_name) do
    case DomainLoader.load(domain_name) do
      {:ok, domain} ->
        snapshot = %{
          timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
          domain_name: domain_name,
          agents: domain.agents,
          phases: domain.phases,
          actions: domain.actions,
          consensus: domain.consensus,
          heuristics: domain.heuristics,
          signals: domain.signals,
          llm_defaults: domain.llm_defaults,
          settings: domain.settings,
          # Hash for quick comparison
          config_hash: compute_hash(domain)
        }

        {:ok, snapshot}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Creates a snapshot, raising on error.
  """
  @spec snapshot!(String.t()) :: map()
  def snapshot!(domain_name) do
    case snapshot(domain_name) do
      {:ok, snapshot} -> snapshot
      {:error, reason} -> raise "Failed to snapshot config: #{inspect(reason)}"
    end
  end

  @doc """
  Compares two configuration snapshots and returns the differences.
  """
  @spec diff_configs(map(), map()) :: map()
  def diff_configs(baseline, current) do
    %{
      hash_changed: baseline[:config_hash] != current[:config_hash],
      changes: diff_maps(baseline, current, []),
      baseline_timestamp: baseline[:timestamp],
      current_timestamp: current[:timestamp]
    }
  end

  @doc """
  Loads evaluation metrics configuration.
  """
  @spec load_metrics() :: {:ok, map()} | {:error, term()}
  def load_metrics do
    path = Path.join([Application.app_dir(:interview_studio), "priv/testing/evaluation/metrics.yaml"])

    case YamlElixir.read_from_file(path) do
      {:ok, data} -> {:ok, data}
      {:error, reason} -> {:error, {:yaml_parse_error, reason}}
    end
  rescue
    e -> {:error, {:file_error, e}}
  end

  @doc """
  Saves a configuration snapshot to a JSON file.
  """
  @spec save_snapshot(map(), String.t()) :: :ok | {:error, term()}
  def save_snapshot(snapshot, path) do
    json = Jason.encode!(snapshot, pretty: true)
    File.write(path, json)
  end

  @doc """
  Loads a configuration snapshot from a JSON file.
  """
  @spec load_snapshot(String.t()) :: {:ok, map()} | {:error, term()}
  def load_snapshot(path) do
    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, data} -> {:ok, data}
          {:error, reason} -> {:error, {:json_parse_error, reason}}
        end

      {:error, reason} ->
        {:error, {:file_read_error, reason}}
    end
  end

  @doc """
  Gets the current LLM configuration for testing.

  Returns configuration suitable for the IntervieweeAgent to use the same
  model as the interview system.
  """
  @spec get_llm_config(String.t()) :: map()
  def get_llm_config(domain_name) do
    case DomainLoader.load(domain_name) do
      {:ok, domain} ->
        %{
          provider: domain.llm_defaults["provider"] || "openrouter",
          model: domain.llm_defaults["model"] || "meta-llama/llama-4-scout-17b-16e-instruct",
          temperature: domain.llm_defaults["temperature"] || 0.7,
          max_tokens: domain.llm_defaults["max_tokens"] || 1000
        }

      {:error, _} ->
        # Fallback defaults
        %{
          provider: "openrouter",
          model: "meta-llama/llama-4-scout-17b-16e-instruct",
          temperature: 0.7,
          max_tokens: 1000
        }
    end
  end

  # Private helpers

  defp compute_hash(domain) do
    content =
      :erlang.term_to_binary(%{
        agents: domain.agents,
        phases: domain.phases,
        actions: domain.actions,
        consensus: domain.consensus,
        heuristics: domain.heuristics
      })

    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end

  defp diff_maps(baseline, current, path) do
    all_keys = MapSet.union(MapSet.new(Map.keys(baseline)), MapSet.new(Map.keys(current)))

    Enum.reduce(all_keys, [], fn key, changes ->
      baseline_val = Map.get(baseline, key)
      current_val = Map.get(current, key)
      key_path = path ++ [key]

      cond do
        is_nil(baseline_val) and not is_nil(current_val) ->
          [{key_path, :added, nil, current_val} | changes]

        not is_nil(baseline_val) and is_nil(current_val) ->
          [{key_path, :removed, baseline_val, nil} | changes]

        is_map(baseline_val) and is_map(current_val) ->
          nested = diff_maps(baseline_val, current_val, key_path)
          nested ++ changes

        baseline_val != current_val ->
          [{key_path, :changed, baseline_val, current_val} | changes]

        true ->
          changes
      end
    end)
  end
end
