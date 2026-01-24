defmodule InterviewStudio.Testing.FeedbackLoop.ReportGenerator do
  @moduledoc """
  Generates reports in multiple formats for batch test results.

  Supports:
  - CLI: Table output with summary stats
  - JSON: Machine-readable for automation
  - HTML: Visual report with charts
  """

  @doc """
  Generates a report in the specified format.

  ## Formats
    * `:cli` - Formatted text output for terminal
    * `:json` - Machine-readable JSON
    * `:html` - Visual HTML report
  """
  @spec generate(map(), atom(), keyword()) :: String.t()
  def generate(batch_results, format, opts \\ []) do
    case format do
      :cli -> generate_cli(batch_results, opts)
      :json -> generate_json(batch_results, opts)
      :html -> generate_html(batch_results, opts)
      _ -> generate_cli(batch_results, opts)
    end
  end

  @doc """
  Writes a report to a file.
  """
  @spec write_report(map(), String.t(), atom()) :: :ok | {:error, term()}
  def write_report(batch_results, path, format) do
    content = generate(batch_results, format)
    File.write(path, content)
  end

  # CLI Report Generation

  defp generate_cli(batch, _opts) do
    agg = batch.aggregate_metrics

    """
    #{header("Feedback Loop Results")}

    #{section("Summary")}
    #{summary_table(batch, agg)}

    #{section("Scores")}
    #{scores_section(agg)}

    #{section("Issues by Category")}
    #{issues_table(agg.issue_counts)}

    #{section("Rating Distribution")}
    #{rating_table(agg.rating_distribution)}

    #{section("By Persona")}
    #{persona_breakdown(batch.by_persona)}

    #{section("Phase Distribution")}
    #{phase_table(agg.phase_distribution)}

    #{if agg.failed_runs > 0, do: error_section(agg.error_types), else: ""}

    #{footer(batch)}
    """
  end

  defp header(title) do
    line = String.duplicate("=", 60)
    "\n#{line}\n  #{title}\n#{line}"
  end

  defp section(title) do
    "\n--- #{title} #{String.duplicate("-", 50 - String.length(title))}"
  end

  defp footer(batch) do
    """

    ────────────────────────────────────────────────────────────
    Batch ID: #{batch.batch_id}
    Config Hash: #{String.slice(batch.config_snapshot.config_hash || "", 0..15)}...
    Generated: #{DateTime.utc_now() |> DateTime.to_iso8601()}
    """
  end

  defp summary_table(batch, agg) do
    """
    Total Runs:        #{agg.total_runs}
    Successful:        #{agg.successful_runs} (#{percentage(agg.successful_runs, agg.total_runs)})
    Failed:            #{agg.failed_runs}
    Duration:          #{format_duration(batch.duration_ms)}
    Parallel Workers:  #{batch.parallel}
    Personas Used:     #{Enum.join(batch.personas_used, ", ")}
    """
  end

  defp scores_section(agg) do
    """
    Average Score:     #{Float.round(agg.avg_score * 1.0, 1)}
    Min Score:         #{agg.min_score}
    Max Score:         #{agg.max_score}
    Avg Exchanges:     #{Float.round(agg.avg_exchanges * 1.0, 1)}
    Avg Duration:      #{format_duration(agg.avg_duration_ms)}
    Total Issues:      #{agg.total_issues}
    """
  end

  defp issues_table(issue_counts) when map_size(issue_counts) == 0 do
    "  No issues detected!"
  end

  defp issues_table(issue_counts) do
    issue_counts
    |> Enum.sort_by(fn {_, count} -> -count end)
    |> Enum.map(fn {category, count} ->
      "  #{pad_right(humanize(category), 30)} #{count}"
    end)
    |> Enum.join("\n")
  end

  defp rating_table(distribution) when map_size(distribution) == 0 do
    "  No ratings available"
  end

  defp rating_table(distribution) do
    order = [:excellent, :good, :needs_improvement, :poor]

    order
    |> Enum.map(fn rating ->
      count = Map.get(distribution, rating, 0) || Map.get(distribution, to_string(rating), 0)
      bar = String.duplicate("█", min(count, 40))
      "  #{pad_right(humanize(rating), 20)} #{pad_left(count, 3)} #{bar}"
    end)
    |> Enum.join("\n")
  end

  defp persona_breakdown(by_persona) when map_size(by_persona) == 0 do
    "  No persona data available"
  end

  defp persona_breakdown(by_persona) do
    by_persona
    |> Enum.map(fn {persona, data} ->
      agg = data.aggregate

      """
        #{humanize(persona)}:
          Runs: #{data.count}, Avg Score: #{Float.round(agg.avg_score, 1)}, Issues: #{agg.total_issues}
      """
    end)
    |> Enum.join("")
  end

  defp phase_table(distribution) when map_size(distribution) == 0 do
    "  No phase data available"
  end

  defp phase_table(distribution) do
    distribution
    |> Enum.map(fn {phase, count} ->
      "  #{pad_right(humanize(phase), 20)} #{count}"
    end)
    |> Enum.join("\n")
  end

  defp error_section(error_types) do
    """

    #{section("Errors")}
    #{error_types |> Enum.map(fn {type, count} -> "  #{humanize(type)}: #{count}" end) |> Enum.join("\n")}
    """
  end

  # JSON Report Generation

  defp generate_json(batch, opts) do
    pretty = Keyword.get(opts, :pretty, true)

    data = %{
      batch_id: batch.batch_id,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      summary: %{
        total_runs: batch.aggregate_metrics.total_runs,
        successful_runs: batch.aggregate_metrics.successful_runs,
        failed_runs: batch.aggregate_metrics.failed_runs,
        duration_ms: batch.duration_ms,
        personas_used: batch.personas_used
      },
      scores: %{
        average: batch.aggregate_metrics.avg_score,
        min: batch.aggregate_metrics.min_score,
        max: batch.aggregate_metrics.max_score
      },
      issues: batch.aggregate_metrics.issue_counts,
      rating_distribution: stringify_keys(batch.aggregate_metrics.rating_distribution),
      by_persona: stringify_persona_data(batch.by_persona),
      phase_distribution: stringify_keys(batch.aggregate_metrics.phase_distribution),
      config_snapshot: %{
        hash: batch.config_snapshot.config_hash,
        timestamp: batch.config_snapshot.timestamp
      }
    }

    if pretty do
      Jason.encode!(data, pretty: true)
    else
      Jason.encode!(data)
    end
  end

  # HTML Report Generation

  defp generate_html(batch, _opts) do
    agg = batch.aggregate_metrics

    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="UTF-8">
      <meta name="viewport" content="width=device-width, initial-scale=1.0">
      <title>Feedback Loop Report - #{batch.batch_id}</title>
      <style>
        #{html_styles()}
      </style>
    </head>
    <body>
      <div class="container">
        <h1>Feedback Loop Report</h1>
        <p class="subtitle">Batch ID: #{batch.batch_id}</p>

        #{html_summary_cards(batch, agg)}

        #{html_score_chart(agg)}

        #{html_issues_table(agg.issue_counts)}

        #{html_persona_breakdown(batch.by_persona)}

        #{html_rating_chart(agg.rating_distribution)}

        <footer>
          <p>Generated: #{DateTime.utc_now() |> DateTime.to_iso8601()}</p>
          <p>Config Hash: #{batch.config_snapshot.config_hash}</p>
        </footer>
      </div>
    </body>
    </html>
    """
  end

  defp html_styles do
    """
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; background: #f5f5f5; color: #333; line-height: 1.6; }
    .container { max-width: 1200px; margin: 0 auto; padding: 2rem; }
    h1 { color: #2c3e50; margin-bottom: 0.5rem; }
    h2 { color: #34495e; margin: 2rem 0 1rem; border-bottom: 2px solid #3498db; padding-bottom: 0.5rem; }
    .subtitle { color: #7f8c8d; margin-bottom: 2rem; }
    .cards { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 1rem; margin-bottom: 2rem; }
    .card { background: white; padding: 1.5rem; border-radius: 8px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
    .card h3 { font-size: 0.875rem; color: #7f8c8d; text-transform: uppercase; letter-spacing: 0.05em; }
    .card .value { font-size: 2rem; font-weight: 600; color: #2c3e50; }
    .card.success .value { color: #27ae60; }
    .card.warning .value { color: #f39c12; }
    .card.danger .value { color: #e74c3c; }
    table { width: 100%; border-collapse: collapse; background: white; border-radius: 8px; overflow: hidden; box-shadow: 0 2px 4px rgba(0,0,0,0.1); margin-bottom: 2rem; }
    th, td { padding: 1rem; text-align: left; border-bottom: 1px solid #ecf0f1; }
    th { background: #34495e; color: white; }
    tr:hover { background: #f8f9fa; }
    .bar { height: 20px; background: #3498db; border-radius: 4px; }
    .bar-container { background: #ecf0f1; border-radius: 4px; overflow: hidden; }
    .persona-card { background: white; padding: 1.5rem; border-radius: 8px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); margin-bottom: 1rem; }
    .persona-card h4 { color: #2c3e50; margin-bottom: 0.5rem; }
    .persona-stats { display: flex; gap: 2rem; }
    .persona-stat { }
    .persona-stat label { font-size: 0.75rem; color: #7f8c8d; text-transform: uppercase; }
    .persona-stat .value { font-size: 1.25rem; font-weight: 600; }
    footer { margin-top: 3rem; padding-top: 1rem; border-top: 1px solid #bdc3c7; color: #7f8c8d; font-size: 0.875rem; }
    """
  end

  defp html_summary_cards(batch, agg) do
    success_rate = if agg.total_runs > 0, do: agg.successful_runs / agg.total_runs * 100, else: 0

    card_class =
      cond do
        success_rate >= 90 -> "success"
        success_rate >= 70 -> "warning"
        true -> "danger"
      end

    score_class =
      cond do
        agg.avg_score >= 85 -> "success"
        agg.avg_score >= 70 -> "warning"
        true -> "danger"
      end

    """
    <div class="cards">
      <div class="card">
        <h3>Total Runs</h3>
        <div class="value">#{agg.total_runs}</div>
      </div>
      <div class="card #{card_class}">
        <h3>Success Rate</h3>
        <div class="value">#{Float.round(success_rate, 1)}%</div>
      </div>
      <div class="card #{score_class}">
        <h3>Average Score</h3>
        <div class="value">#{Float.round(agg.avg_score, 1)}</div>
      </div>
      <div class="card">
        <h3>Duration</h3>
        <div class="value">#{format_duration(batch.duration_ms)}</div>
      </div>
      <div class="card">
        <h3>Total Issues</h3>
        <div class="value">#{agg.total_issues}</div>
      </div>
      <div class="card">
        <h3>Avg Exchanges</h3>
        <div class="value">#{Float.round(agg.avg_exchanges, 1)}</div>
      </div>
    </div>
    """
  end

  defp html_score_chart(agg) do
    """
    <h2>Score Summary</h2>
    <div class="cards">
      <div class="card">
        <h3>Min Score</h3>
        <div class="value">#{agg.min_score}</div>
      </div>
      <div class="card">
        <h3>Average Score</h3>
        <div class="value">#{Float.round(agg.avg_score, 1)}</div>
      </div>
      <div class="card">
        <h3>Max Score</h3>
        <div class="value">#{agg.max_score}</div>
      </div>
    </div>
    """
  end

  defp html_issues_table(issue_counts) when map_size(issue_counts) == 0 do
    """
    <h2>Issues</h2>
    <p>No issues detected!</p>
    """
  end

  defp html_issues_table(issue_counts) do
    max_count = issue_counts |> Map.values() |> Enum.max(fn -> 1 end)

    rows =
      issue_counts
      |> Enum.sort_by(fn {_, count} -> -count end)
      |> Enum.map(fn {category, count} ->
        width = count / max_count * 100

        """
        <tr>
          <td>#{humanize(category)}</td>
          <td>#{count}</td>
          <td style="width: 50%">
            <div class="bar-container">
              <div class="bar" style="width: #{width}%"></div>
            </div>
          </td>
        </tr>
        """
      end)
      |> Enum.join("")

    """
    <h2>Issues by Category</h2>
    <table>
      <thead>
        <tr>
          <th>Category</th>
          <th>Count</th>
          <th>Distribution</th>
        </tr>
      </thead>
      <tbody>
        #{rows}
      </tbody>
    </table>
    """
  end

  defp html_persona_breakdown(by_persona) when map_size(by_persona) == 0 do
    ""
  end

  defp html_persona_breakdown(by_persona) do
    cards =
      by_persona
      |> Enum.map(fn {persona, data} ->
        agg = data.aggregate

        """
        <div class="persona-card">
          <h4>#{humanize(persona)}</h4>
          <div class="persona-stats">
            <div class="persona-stat">
              <label>Runs</label>
              <div class="value">#{data.count}</div>
            </div>
            <div class="persona-stat">
              <label>Avg Score</label>
              <div class="value">#{Float.round(agg.avg_score, 1)}</div>
            </div>
            <div class="persona-stat">
              <label>Issues</label>
              <div class="value">#{agg.total_issues}</div>
            </div>
            <div class="persona-stat">
              <label>Avg Exchanges</label>
              <div class="value">#{Float.round(agg.avg_exchanges, 1)}</div>
            </div>
          </div>
        </div>
        """
      end)
      |> Enum.join("")

    """
    <h2>Results by Persona</h2>
    #{cards}
    """
  end

  defp html_rating_chart(distribution) when map_size(distribution) == 0 do
    ""
  end

  defp html_rating_chart(distribution) do
    total = distribution |> Map.values() |> Enum.sum()
    if total == 0, do: "", else: do_html_rating_chart(distribution, total)
  end

  defp do_html_rating_chart(distribution, total) do
    colors = %{
      excellent: "#27ae60",
      good: "#2ecc71",
      needs_improvement: "#f39c12",
      poor: "#e74c3c"
    }

    rows =
      [:excellent, :good, :needs_improvement, :poor]
      |> Enum.map(fn rating ->
        count = Map.get(distribution, rating, 0) || Map.get(distribution, to_string(rating), 0)
        width = count / total * 100
        color = Map.get(colors, rating, "#3498db")

        """
        <tr>
          <td>#{humanize(rating)}</td>
          <td>#{count}</td>
          <td style="width: 50%">
            <div class="bar-container">
              <div class="bar" style="width: #{width}%; background: #{color}"></div>
            </div>
          </td>
        </tr>
        """
      end)
      |> Enum.join("")

    """
    <h2>Rating Distribution</h2>
    <table>
      <thead>
        <tr>
          <th>Rating</th>
          <th>Count</th>
          <th>Distribution</th>
        </tr>
      </thead>
      <tbody>
        #{rows}
      </tbody>
    </table>
    """
  end

  # Utility functions

  defp percentage(part, total) when total > 0 do
    "#{Float.round(part / total * 100, 1)}%"
  end

  defp percentage(_, _), do: "0%"

  defp format_duration(ms) when is_number(ms) do
    cond do
      ms < 1000 -> "#{ms}ms"
      ms < 60_000 -> "#{Float.round(ms / 1000, 1)}s"
      true -> "#{Float.round(ms / 60_000, 1)}m"
    end
  end

  defp format_duration(_), do: "N/A"

  defp humanize(atom) when is_atom(atom), do: humanize(Atom.to_string(atom))

  defp humanize(string) when is_binary(string) do
    string
    |> String.replace("_", " ")
    |> String.split(" ")
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end

  defp pad_right(str, len) do
    String.pad_trailing(to_string(str), len)
  end

  defp pad_left(val, len) do
    String.pad_leading(to_string(val), len)
  end

  defp stringify_keys(map) when is_map(map) do
    map
    |> Enum.map(fn {k, v} -> {to_string(k), v} end)
    |> Enum.into(%{})
  end

  defp stringify_persona_data(by_persona) do
    by_persona
    |> Enum.map(fn {persona, data} ->
      {to_string(persona),
       %{
         "count" => data.count,
         "avg_score" => data.aggregate.avg_score,
         "total_issues" => data.aggregate.total_issues
       }}
    end)
    |> Enum.into(%{})
  end
end
