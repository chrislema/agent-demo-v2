defmodule InterviewStudio.Testing.FeedbackLoop.BatchRunner do
  @moduledoc """
  Orchestrates multiple automated conversations for batch testing.

  Supports parallel execution, multiple personas, and aggregate metrics.
  """

  require Logger

  alias InterviewStudio.Testing.FeedbackLoop.ConversationRunner
  alias InterviewStudio.Testing.FeedbackLoop.ConfigManager
  alias InterviewStudio.Testing.FeedbackLoop.Persona

  @default_count 10
  @default_parallel 1

  @doc """
  Runs a batch of automated conversations.

  ## Options
    * `:count` - Number of conversations to run (default: 10)
    * `:personas` - List of persona names or `:all` (default: [:cooperative])
    * `:parallel` - Number of parallel conversations (default: 1)
    * `:domain` - Domain name (default: "interview")
    * `:max_exchanges` - Max exchanges per conversation (default: 20)
    * `:config_reload` - Whether to reload config before running (default: false)
    * `:progress_callback` - Function to call with progress updates

  ## Returns
    A map containing:
    * `:batch_id` - Unique identifier for this batch
    * `:results` - List of individual conversation results
    * `:aggregate_metrics` - Aggregated metrics across all conversations
    * `:config_snapshot` - Configuration snapshot for reproducibility
    * `:by_persona` - Results grouped by persona
    * `:duration_ms` - Total batch duration
  """
  @spec run(keyword()) :: map()
  def run(opts \\ []) do
    start_time = System.monotonic_time(:millisecond)

    count = Keyword.get(opts, :count, @default_count)
    personas_opt = Keyword.get(opts, :personas, [:cooperative])
    parallel = Keyword.get(opts, :parallel, @default_parallel)
    domain = Keyword.get(opts, :domain, "interview")
    max_exchanges = Keyword.get(opts, :max_exchanges, 20)
    config_reload = Keyword.get(opts, :config_reload, false)
    progress_callback = Keyword.get(opts, :progress_callback)

    batch_id = generate_batch_id()
    Logger.info("[BatchRunner] Starting batch #{batch_id}: #{count} conversations")

    # Reload config if requested
    if config_reload do
      Logger.info("[BatchRunner] Reloading domain configuration: #{domain}")
      ConfigManager.reload_domain(domain)
    end

    # Snapshot config for reproducibility
    config_snapshot = ConfigManager.snapshot!(domain)

    # Resolve personas
    personas = resolve_personas(personas_opt)
    Logger.info("[BatchRunner] Using personas: #{inspect(Enum.map(personas, & &1.name))}")

    # Generate conversation specs (distribute count across personas)
    specs = generate_specs(count, personas, domain, max_exchanges)

    # Run conversations
    results =
      if parallel > 1 do
        run_parallel(specs, parallel, progress_callback)
      else
        run_sequential(specs, progress_callback)
      end

    end_time = System.monotonic_time(:millisecond)

    # Aggregate results
    aggregate = aggregate_results(results)
    by_persona = group_by_persona(results)

    %{
      batch_id: batch_id,
      results: results,
      aggregate_metrics: aggregate,
      config_snapshot: config_snapshot,
      by_persona: by_persona,
      duration_ms: end_time - start_time,
      count: count,
      personas_used: Enum.map(personas, & &1.name),
      parallel: parallel,
      started_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  @doc """
  Runs a quick test with a single persona.
  """
  @spec quick_test(atom() | String.t(), keyword()) :: map()
  def quick_test(persona_name, opts \\ []) do
    run([{:personas, [persona_name]}, {:count, 1} | opts])
  end

  @doc """
  Saves batch results to a JSON file.
  """
  @spec save_results(map(), String.t()) :: :ok | {:error, term()}
  def save_results(batch_results, path) do
    # Serialize results (handle non-serializable data)
    serializable = make_serializable(batch_results)
    json = Jason.encode!(serializable, pretty: true)
    File.write(path, json)
  end

  @doc """
  Loads batch results from a JSON file.
  """
  @spec load_results(String.t()) :: {:ok, map()} | {:error, term()}
  def load_results(path) do
    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, data} -> {:ok, data}
          {:error, reason} -> {:error, {:json_decode_error, reason}}
        end

      {:error, reason} ->
        {:error, {:file_read_error, reason}}
    end
  end

  # Private functions

  defp generate_batch_id do
    timestamp = DateTime.utc_now() |> DateTime.to_unix()
    random = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    "batch_#{timestamp}_#{random}"
  end

  defp resolve_personas(:all) do
    case Persona.load_all() do
      {:ok, personas} -> personas
      {:error, _} -> [Persona.load!(:cooperative)]
    end
  end

  defp resolve_personas(persona_names) when is_list(persona_names) do
    Enum.map(persona_names, fn name ->
      case name do
        %Persona{} = p -> p
        name -> Persona.load!(name)
      end
    end)
  end

  defp resolve_personas(single) do
    resolve_personas([single])
  end

  defp generate_specs(count, personas, domain, max_exchanges) do
    # Distribute count evenly across personas
    persona_count = length(personas)
    per_persona = div(count, persona_count)
    remainder = rem(count, persona_count)

    personas
    |> Enum.with_index()
    |> Enum.flat_map(fn {persona, idx} ->
      # Add one extra to first 'remainder' personas
      n = if idx < remainder, do: per_persona + 1, else: per_persona

      Enum.map(1..n, fn i ->
        %{
          persona: persona,
          domain: domain,
          max_exchanges: max_exchanges,
          spec_id: "#{persona.name}_#{idx}_#{i}"
        }
      end)
    end)
  end

  defp run_sequential(specs, progress_callback) do
    total = length(specs)

    specs
    |> Enum.with_index(1)
    |> Enum.map(fn {spec, idx} ->
      if progress_callback, do: progress_callback.({:progress, idx, total, spec.persona.name})

      result = run_single(spec)

      if progress_callback, do: progress_callback.({:completed, idx, total, result})

      result
    end)
  end

  defp run_parallel(specs, parallel_count, progress_callback) do
    total = length(specs)

    # Track progress with a simple agent
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    results =
      specs
      |> Task.async_stream(
        fn spec ->
          result = run_single(spec)

          if progress_callback do
            count = Agent.get_and_update(counter, fn c -> {c + 1, c + 1} end)
            progress_callback.({:completed, count, total, result})
          end

          result
        end,
        max_concurrency: parallel_count,
        timeout: :infinity,
        ordered: false
      )
      |> Enum.map(fn
        {:ok, result} -> result
        {:exit, reason} -> %{error: {:task_exit, reason}, spec_id: "unknown"}
      end)

    Agent.stop(counter)
    results
  end

  defp run_single(spec) do
    result =
      ConversationRunner.run(
        persona: spec.persona,
        domain: spec.domain,
        max_exchanges: spec.max_exchanges
      )

    Map.put(result, :spec_id, spec.spec_id)
  end

  defp aggregate_results(results) do
    successful = Enum.filter(results, fn r -> is_nil(r.error) end)
    failed = Enum.filter(results, fn r -> not is_nil(r.error) end)

    evaluations = Enum.map(successful, & &1.evaluation) |> Enum.filter(&(not is_nil(&1)))

    scores = Enum.map(evaluations, & &1.score.final_score)

    all_issues =
      evaluations
      |> Enum.flat_map(& &1.issues)

    issue_counts =
      all_issues
      |> Enum.group_by(& &1.category)
      |> Enum.map(fn {cat, issues} -> {cat, length(issues)} end)
      |> Enum.into(%{})

    %{
      total_runs: length(results),
      successful_runs: length(successful),
      failed_runs: length(failed),
      avg_score: if(Enum.empty?(scores), do: 0, else: Enum.sum(scores) / length(scores)),
      min_score: if(Enum.empty?(scores), do: 0, else: Enum.min(scores)),
      max_score: if(Enum.empty?(scores), do: 0, else: Enum.max(scores)),
      avg_exchanges: calculate_avg(results, :exchange_count),
      avg_duration_ms: calculate_avg(results, :duration_ms),
      issue_counts: issue_counts,
      total_issues: length(all_issues),
      rating_distribution: calculate_rating_distribution(evaluations),
      error_types: group_errors(failed),
      phase_distribution: calculate_phase_distribution(results)
    }
  end

  defp group_by_persona(results) do
    results
    |> Enum.group_by(& &1.persona)
    |> Enum.map(fn {persona, persona_results} ->
      {persona,
       %{
         count: length(persona_results),
         aggregate: aggregate_results(persona_results)
       }}
    end)
    |> Enum.into(%{})
  end

  defp calculate_avg(results, key) do
    values =
      results
      |> Enum.map(&Map.get(&1, key))
      |> Enum.filter(&(not is_nil(&1)))

    if Enum.empty?(values), do: 0, else: Enum.sum(values) / length(values)
  end

  defp calculate_rating_distribution(evaluations) do
    evaluations
    |> Enum.map(& &1.score.rating)
    |> Enum.group_by(& &1)
    |> Enum.map(fn {rating, items} -> {rating, length(items)} end)
    |> Enum.into(%{})
  end

  defp group_errors(failed_results) do
    failed_results
    |> Enum.map(& &1.error)
    |> Enum.group_by(&error_type/1)
    |> Enum.map(fn {type, errors} -> {type, length(errors)} end)
    |> Enum.into(%{})
  end

  defp error_type({type, _}), do: type
  defp error_type(type) when is_atom(type), do: type
  defp error_type(_), do: :unknown

  defp calculate_phase_distribution(results) do
    results
    |> Enum.map(& &1.final_phase)
    |> Enum.filter(&(not is_nil(&1)))
    |> Enum.group_by(& &1)
    |> Enum.map(fn {phase, items} -> {phase, length(items)} end)
    |> Enum.into(%{})
  end

  defp make_serializable(data) when is_map(data) do
    data
    |> Enum.map(fn {k, v} -> {to_string(k), make_serializable(v)} end)
    |> Enum.into(%{})
  end

  defp make_serializable(data) when is_list(data) do
    Enum.map(data, &make_serializable/1)
  end

  defp make_serializable(data) when is_atom(data), do: to_string(data)
  defp make_serializable(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp make_serializable(data), do: data
end
