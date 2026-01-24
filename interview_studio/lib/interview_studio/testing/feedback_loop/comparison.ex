defmodule InterviewStudio.Testing.FeedbackLoop.Comparison do
  @moduledoc """
  Detects regressions and improvements between batch runs.

  Compares two batch results to identify:
  - Score changes
  - New issues
  - Resolved issues
  - Configuration changes
  """

  alias InterviewStudio.Testing.FeedbackLoop.ConfigManager

  @doc """
  Compares two batch results and returns a detailed comparison.

  ## Returns
    A map containing:
    * `:metric_deltas` - Changes in key metrics
    * `:new_issues` - Issues that appeared in new batch
    * `:resolved_issues` - Issues that were fixed
    * `:verdict` - :regression | :improvement | :no_change
    * `:config_changes` - Differences in configuration
  """
  @spec compare(map(), map()) :: map()
  def compare(baseline, new_batch) do
    metric_deltas = calculate_deltas(baseline, new_batch)
    {new_issues, resolved_issues} = analyze_issues(baseline, new_batch)
    config_changes = compare_configs(baseline, new_batch)
    verdict = determine_verdict(metric_deltas, new_issues, resolved_issues)

    %{
      baseline_id: baseline.batch_id,
      new_batch_id: new_batch.batch_id,
      metric_deltas: metric_deltas,
      new_issues: new_issues,
      resolved_issues: resolved_issues,
      verdict: verdict,
      config_changes: config_changes,
      summary: generate_summary(metric_deltas, new_issues, resolved_issues, verdict),
      compared_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  @doc """
  Compares a new batch against a saved baseline file.
  """
  @spec compare_with_baseline(map(), String.t()) :: {:ok, map()} | {:error, term()}
  def compare_with_baseline(new_batch, baseline_path) do
    case File.read(baseline_path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, baseline} ->
            # Convert string keys to atoms for consistency
            baseline = atomize_keys(baseline)
            {:ok, compare(baseline, new_batch)}

          {:error, reason} ->
            {:error, {:json_decode_error, reason}}
        end

      {:error, reason} ->
        {:error, {:file_read_error, reason}}
    end
  end

  @doc """
  Generates a CLI-formatted comparison report.
  """
  @spec format_comparison(map()) :: String.t()
  def format_comparison(comparison) do
    verdict_emoji =
      case comparison.verdict do
        :improvement -> "✅"
        :regression -> "❌"
        :no_change -> "➖"
      end

    """
    ════════════════════════════════════════════════════════════
      Comparison Report #{verdict_emoji} #{humanize(comparison.verdict)}
    ════════════════════════════════════════════════════════════

    Baseline: #{comparison.baseline_id}
    New Batch: #{comparison.new_batch_id}

    --- Metric Changes ─────────────────────────────────────────
    #{format_deltas(comparison.metric_deltas)}

    --- New Issues ─────────────────────────────────────────────
    #{format_issue_list(comparison.new_issues, "No new issues!")}

    --- Resolved Issues ────────────────────────────────────────
    #{format_issue_list(comparison.resolved_issues, "No issues resolved.")}

    --- Config Changes ─────────────────────────────────────────
    #{format_config_changes(comparison.config_changes)}

    ────────────────────────────────────────────────────────────
    #{comparison.summary}
    ════════════════════════════════════════════════════════════
    """
  end

  # Private functions

  defp calculate_deltas(baseline, new_batch) do
    baseline_agg = baseline.aggregate_metrics || baseline["aggregate_metrics"] || %{}
    new_agg = new_batch.aggregate_metrics || %{}

    %{
      avg_score: %{
        baseline: get_metric(baseline_agg, :avg_score),
        new: get_metric(new_agg, :avg_score),
        delta: get_metric(new_agg, :avg_score) - get_metric(baseline_agg, :avg_score),
        direction: delta_direction(get_metric(new_agg, :avg_score), get_metric(baseline_agg, :avg_score))
      },
      total_issues: %{
        baseline: get_metric(baseline_agg, :total_issues),
        new: get_metric(new_agg, :total_issues),
        delta: get_metric(new_agg, :total_issues) - get_metric(baseline_agg, :total_issues),
        # Lower is better for issues
        direction: delta_direction(get_metric(baseline_agg, :total_issues), get_metric(new_agg, :total_issues))
      },
      success_rate: %{
        baseline: calculate_success_rate(baseline_agg),
        new: calculate_success_rate(new_agg),
        delta: calculate_success_rate(new_agg) - calculate_success_rate(baseline_agg),
        direction: delta_direction(calculate_success_rate(new_agg), calculate_success_rate(baseline_agg))
      },
      avg_exchanges: %{
        baseline: get_metric(baseline_agg, :avg_exchanges),
        new: get_metric(new_agg, :avg_exchanges),
        delta: get_metric(new_agg, :avg_exchanges) - get_metric(baseline_agg, :avg_exchanges),
        direction: :neutral
      }
    }
  end

  defp get_metric(agg, key) do
    value = Map.get(agg, key) || Map.get(agg, to_string(key)) || 0
    if is_number(value), do: value, else: 0
  end

  defp calculate_success_rate(agg) do
    total = get_metric(agg, :total_runs)
    successful = get_metric(agg, :successful_runs)
    if total > 0, do: successful / total * 100, else: 0.0
  end

  defp delta_direction(new_val, baseline_val) when new_val > baseline_val, do: :better
  defp delta_direction(new_val, baseline_val) when new_val < baseline_val, do: :worse
  defp delta_direction(_, _), do: :same

  defp analyze_issues(baseline, new_batch) do
    baseline_issues = extract_issue_categories(baseline)
    new_issues = extract_issue_categories(new_batch)

    # Issues that are in new but not in baseline (or increased)
    appeared =
      new_issues
      |> Enum.filter(fn {cat, count} ->
        baseline_count = Map.get(baseline_issues, cat, 0)
        count > baseline_count
      end)
      |> Enum.map(fn {cat, count} ->
        baseline_count = Map.get(baseline_issues, cat, 0)
        %{category: cat, new_count: count, baseline_count: baseline_count, increase: count - baseline_count}
      end)

    # Issues that decreased or disappeared
    resolved =
      baseline_issues
      |> Enum.filter(fn {cat, count} ->
        new_count = Map.get(new_issues, cat, 0)
        new_count < count
      end)
      |> Enum.map(fn {cat, count} ->
        new_count = Map.get(new_issues, cat, 0)
        %{category: cat, baseline_count: count, new_count: new_count, decrease: count - new_count}
      end)

    {appeared, resolved}
  end

  defp extract_issue_categories(batch) do
    agg = batch.aggregate_metrics || batch["aggregate_metrics"] || %{}
    counts = agg[:issue_counts] || agg["issue_counts"] || %{}

    counts
    |> Enum.map(fn {k, v} -> {to_string(k), v} end)
    |> Enum.into(%{})
  end

  defp compare_configs(baseline, new_batch) do
    baseline_snapshot = baseline.config_snapshot || baseline["config_snapshot"] || %{}
    new_snapshot = new_batch.config_snapshot || %{}

    baseline_hash = baseline_snapshot[:config_hash] || baseline_snapshot["config_hash"]
    new_hash = new_snapshot[:config_hash] || new_snapshot["config_hash"]

    if baseline_hash == new_hash do
      %{changed: false, diff: []}
    else
      diff = ConfigManager.diff_configs(baseline_snapshot, new_snapshot)
      %{changed: true, diff: diff.changes}
    end
  end

  defp determine_verdict(deltas, new_issues, resolved_issues) do
    score_delta = deltas.avg_score.delta
    issues_delta = deltas.total_issues.delta

    new_issue_count = length(new_issues)
    resolved_count = length(resolved_issues)

    cond do
      # Clear regression: score dropped significantly or many new issues
      score_delta < -5 or issues_delta > 5 or new_issue_count > 3 ->
        :regression

      # Clear improvement: score improved significantly or many issues resolved
      score_delta > 5 or issues_delta < -5 or resolved_count > 3 ->
        :improvement

      # Mixed or minimal change
      true ->
        improvement_signals = [
          score_delta > 0,
          issues_delta < 0,
          resolved_count > new_issue_count
        ]

        regression_signals = [
          score_delta < 0,
          issues_delta > 0,
          new_issue_count > resolved_count
        ]

        improvements = Enum.count(improvement_signals, & &1)
        regressions = Enum.count(regression_signals, & &1)

        cond do
          improvements > regressions -> :improvement
          regressions > improvements -> :regression
          true -> :no_change
        end
    end
  end

  defp generate_summary(deltas, new_issues, resolved_issues, verdict) do
    parts = []

    parts =
      case verdict do
        :regression ->
          ["⚠️  REGRESSION DETECTED" | parts]

        :improvement ->
          ["✨ IMPROVEMENT DETECTED" | parts]

        :no_change ->
          ["No significant change detected." | parts]
      end

    score_change = deltas.avg_score.delta

    parts =
      if abs(score_change) >= 1 do
        direction = if score_change > 0, do: "improved", else: "dropped"
        ["Score #{direction} by #{abs(Float.round(score_change, 1))} points." | parts]
      else
        parts
      end

    parts =
      if length(new_issues) > 0 do
        cats = new_issues |> Enum.map(& &1.category) |> Enum.join(", ")
        ["New issues in: #{cats}" | parts]
      else
        parts
      end

    parts =
      if length(resolved_issues) > 0 do
        cats = resolved_issues |> Enum.map(& &1.category) |> Enum.join(", ")
        ["Resolved issues in: #{cats}" | parts]
      else
        parts
      end

    parts |> Enum.reverse() |> Enum.join(" ")
  end

  defp format_deltas(deltas) do
    [
      format_delta_line("Average Score", deltas.avg_score),
      format_delta_line("Total Issues", deltas.total_issues),
      format_delta_line("Success Rate", deltas.success_rate),
      format_delta_line("Avg Exchanges", deltas.avg_exchanges)
    ]
    |> Enum.join("\n")
  end

  defp format_delta_line(name, delta) do
    arrow =
      case delta.direction do
        :better -> "↑"
        :worse -> "↓"
        _ -> "→"
      end

    delta_str =
      if delta.delta >= 0 do
        "+#{Float.round(delta.delta * 1.0, 1)}"
      else
        "#{Float.round(delta.delta * 1.0, 1)}"
      end

    "  #{String.pad_trailing(name, 16)} #{Float.round(delta.baseline * 1.0, 1)} → #{Float.round(delta.new * 1.0, 1)} (#{delta_str}) #{arrow}"
  end

  defp format_issue_list([], default_message), do: "  #{default_message}"

  defp format_issue_list(issues, _) do
    issues
    |> Enum.map(fn issue ->
      "  • #{humanize(issue.category)}: #{issue.baseline_count || 0} → #{issue.new_count || 0}"
    end)
    |> Enum.join("\n")
  end

  defp format_config_changes(%{changed: false}), do: "  No configuration changes."

  defp format_config_changes(%{changed: true, diff: []}) do
    "  Configuration changed (hash differs)"
  end

  defp format_config_changes(%{changed: true, diff: changes}) when length(changes) > 0 do
    changes
    |> Enum.take(10)
    |> Enum.map(fn {path, type, old, new} ->
      path_str = Enum.join(path, ".")

      case type do
        :added -> "  + #{path_str}: #{inspect(new)}"
        :removed -> "  - #{path_str}: #{inspect(old)}"
        :changed -> "  ~ #{path_str}: #{inspect(old)} → #{inspect(new)}"
      end
    end)
    |> Enum.join("\n")
  end

  defp format_config_changes(_), do: "  No configuration changes."

  defp humanize(atom) when is_atom(atom), do: humanize(Atom.to_string(atom))

  defp humanize(string) when is_binary(string) do
    string
    |> String.replace("_", " ")
    |> String.split(" ")
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end

  defp atomize_keys(map) when is_map(map) do
    map
    |> Enum.map(fn {k, v} ->
      key =
        if is_binary(k) do
          try do
            String.to_existing_atom(k)
          rescue
            ArgumentError -> k
          end
        else
          k
        end

      {key, atomize_keys(v)}
    end)
    |> Enum.into(%{})
  rescue
    _ -> map
  end

  defp atomize_keys(list) when is_list(list) do
    Enum.map(list, &atomize_keys/1)
  end

  defp atomize_keys(other), do: other
end
