defmodule Mix.Tasks.InterviewStudio.FeedbackLoop do
  @moduledoc """
  Automated feedback loop for testing and tuning interview agent configurations.

  Runs batch conversations with simulated interviewees to evaluate agent behavior,
  detect issues, and track regressions across configuration changes.

  ## Usage

      # Run 10 cooperative conversations (default)
      mix interview_studio.feedback_loop

      # Run with multiple personas
      mix interview_studio.feedback_loop --count 30 --personas cooperative,terse,frustrated

      # Run with all available personas
      mix interview_studio.feedback_loop --count 30 --personas all

      # Parallel execution
      mix interview_studio.feedback_loop --parallel 4

      # Generate HTML report
      mix interview_studio.feedback_loop --format html --output report.html

      # Save as baseline for future comparison
      mix interview_studio.feedback_loop --save-baseline

      # Compare against saved baseline
      mix interview_studio.feedback_loop --compare baseline.json

      # Full tuning workflow
      mix interview_studio.feedback_loop --count 20 --personas all --save-baseline
      # Edit YAML configs...
      mix interview_studio.feedback_loop --count 20 --personas all --compare baseline.json

  ## Options

      --count, -n        Number of conversations to run (default: 10)
      --personas, -p     Comma-separated persona names or 'all' (default: cooperative)
      --parallel, -j     Number of parallel conversations (default: 1)
      --domain, -d       Domain name (default: interview)
      --max-exchanges    Maximum exchanges per conversation (default: 20)
      --format, -f       Output format: cli, json, html (default: cli)
      --output, -o       Output file path for json/html formats
      --save-baseline    Save results as baseline.json
      --compare          Path to baseline file for comparison
      --config-reload    Reload config from disk before running
      --verbose, -v      Show detailed progress
      --quiet, -q        Minimal output

  ## Available Personas

      cooperative   - Friendly, detailed responses (baseline quality testing)
      terse         - Short, minimal responses (tests probe effectiveness)
      tangential    - Goes off-topic frequently (tests topic redirection)
      frustrated    - Shows resistance, builds frustration (tests frustration detection)
      nervous       - Hesitant, needs encouragement (tests gentle probing)

  ## Why Multiple Personas Matter

  Different personas catch different types of issues:

      | Persona      | What it catches                              |
      |--------------|----------------------------------------------|
      | cooperative  | Baseline quality, theme discovery, flow      |
      | terse        | Short answer handling, probe effectiveness   |
      | tangential   | Topic redirection, staying on track          |
      | frustrated   | Frustration detection, graceful exit         |
      | nervous      | Encouragement, patience, gentle probing      |

  Running with --personas all ensures comprehensive coverage.
  """

  use Mix.Task
  require Logger

  alias InterviewStudio.Testing.FeedbackLoop.BatchRunner
  alias InterviewStudio.Testing.FeedbackLoop.ReportGenerator
  alias InterviewStudio.Testing.FeedbackLoop.Comparison
  alias InterviewStudio.Testing.FeedbackLoop.Persona

  @shortdoc "Run automated feedback loop for agent tuning"

  @switches [
    count: :integer,
    personas: :string,
    parallel: :integer,
    domain: :string,
    max_exchanges: :integer,
    format: :string,
    output: :string,
    save_baseline: :boolean,
    compare: :string,
    config_reload: :boolean,
    verbose: :boolean,
    quiet: :boolean,
    help: :boolean
  ]

  @aliases [
    n: :count,
    p: :personas,
    j: :parallel,
    d: :domain,
    f: :format,
    o: :output,
    v: :verbose,
    q: :quiet,
    h: :help
  ]

  @impl Mix.Task
  def run(args) do
    # Start application
    Mix.Task.run("app.start")

    {opts, _, _} = OptionParser.parse(args, switches: @switches, aliases: @aliases)

    if opts[:help] do
      print_help()
    else
      run_feedback_loop(opts)
    end
  end

  defp run_feedback_loop(opts) do
    count = opts[:count] || 10
    personas = parse_personas(opts[:personas] || "cooperative")
    parallel = opts[:parallel] || 1
    domain = opts[:domain] || "interview"
    max_exchanges = opts[:max_exchanges] || 20
    format = String.to_atom(opts[:format] || "cli")
    output_path = opts[:output]
    save_baseline = opts[:save_baseline] || false
    compare_path = opts[:compare]
    config_reload = opts[:config_reload] || false
    verbose = opts[:verbose] || false
    quiet = opts[:quiet] || false

    unless quiet do
      print_header(count, personas, parallel, domain)
    end

    progress_callback =
      if verbose and not quiet do
        fn
          {:progress, current, total, persona} ->
            IO.write("\r  Running #{current}/#{total} (#{persona})...")

          {:completed, current, total, result} ->
            status = if result.error, do: "✗", else: "✓"
            IO.write("\r  [#{status}] #{current}/#{total} completed\n")
        end
      else
        nil
      end

    # Run batch
    results =
      BatchRunner.run(
        count: count,
        personas: personas,
        parallel: parallel,
        domain: domain,
        max_exchanges: max_exchanges,
        config_reload: config_reload,
        progress_callback: progress_callback
      )

    # Handle comparison if requested
    comparison =
      if compare_path do
        case Comparison.compare_with_baseline(results, compare_path) do
          {:ok, comp} -> comp
          {:error, reason} ->
            Mix.shell().error("Failed to load baseline: #{inspect(reason)}")
            nil
        end
      else
        nil
      end

    # Generate and display report
    unless quiet do
      report = ReportGenerator.generate(results, format)

      case format do
        :cli ->
          IO.puts(report)

        :json ->
          if output_path do
            File.write!(output_path, report)
            Mix.shell().info("JSON report saved to: #{output_path}")
          else
            IO.puts(report)
          end

        :html ->
          if output_path do
            File.write!(output_path, report)
            Mix.shell().info("HTML report saved to: #{output_path}")
          else
            Mix.shell().info("Use --output to save HTML report to a file")
          end
      end

      # Print comparison if available
      if comparison do
        IO.puts("\n")
        IO.puts(Comparison.format_comparison(comparison))
      end
    end

    # Save baseline if requested
    if save_baseline do
      baseline_path = "baseline.json"
      case BatchRunner.save_results(results, baseline_path) do
        :ok ->
          Mix.shell().info("Baseline saved to: #{baseline_path}")

        {:error, reason} ->
          Mix.shell().error("Failed to save baseline: #{inspect(reason)}")
      end
    end

    # Return exit code based on results
    if results.aggregate_metrics.failed_runs > 0 do
      exit({:shutdown, 1})
    end

    results
  end

  defp parse_personas("all"), do: :all

  defp parse_personas(personas_str) when is_binary(personas_str) do
    personas_str
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.map(&String.to_atom/1)
  end

  defp print_header(count, personas, parallel, domain) do
    persona_str =
      case personas do
        :all -> "all (#{length(Persona.list_available())} personas)"
        list -> Enum.join(list, ", ")
      end

    IO.puts("""

    ╔══════════════════════════════════════════════════════════╗
    ║           Interview Studio Feedback Loop                 ║
    ╠══════════════════════════════════════════════════════════╣
    ║  Conversations: #{String.pad_trailing(to_string(count), 40)}║
    ║  Personas:      #{String.pad_trailing(persona_str, 40)}║
    ║  Parallel:      #{String.pad_trailing(to_string(parallel), 40)}║
    ║  Domain:        #{String.pad_trailing(domain, 40)}║
    ╚══════════════════════════════════════════════════════════╝

    Starting batch run...
    """)
  end

  defp print_help do
    IO.puts(@moduledoc)
  end
end
