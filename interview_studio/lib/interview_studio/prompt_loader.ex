defmodule InterviewStudio.PromptLoader do
  @moduledoc """
  Loads prompt templates from external files with variable substitution.

  Prompts are stored in:
    priv/domains/{domain}/prompts/{agent}/{prompt_name}.txt

  Supports:
  - {{variable}} placeholder substitution
  - Fallback to default domain if specific not found
  - Caching for performance (ETS-based)
  """

  require Logger

  @prompts_base_dir "priv/domains"
  @default_domain "interview"
  @cache_table :prompt_cache

  @doc """
  Initialize the prompt cache. Call during application startup.
  """
  def init_cache do
    if :ets.whereis(@cache_table) == :undefined do
      :ets.new(@cache_table, [:named_table, :public, :set, read_concurrency: true])
    end
    :ok
  end

  @doc """
  Load a prompt template for the given domain, agent, and prompt name.

  ## Examples

      iex> PromptLoader.load("interview", "director", "system")
      {:ok, "You are a warm, skilled interviewer..."}

      iex> PromptLoader.load("interview", "director", "dynamic_question")
      {:ok, "Recent conversation:\\n{{history}}\\n..."}
  """
  def load(domain, agent, prompt_name) do
    cache_key = {domain, agent, prompt_name}

    case get_cached(cache_key) do
      {:ok, content} ->
        {:ok, content}

      :miss ->
        case load_from_file(domain, agent, prompt_name) do
          {:ok, content} ->
            cache_prompt(cache_key, content)
            {:ok, content}

          {:error, :not_found} ->
            # Try fallback to default domain
            if domain != @default_domain do
              case load_from_file(@default_domain, agent, prompt_name) do
                {:ok, content} ->
                  cache_prompt(cache_key, content)
                  {:ok, content}

                {:error, reason} ->
                  {:error, reason}
              end
            else
              {:error, :not_found}
            end

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @doc """
  Load a prompt and substitute variables.

  Variables are specified as {{variable_name}} in the template.

  ## Examples

      iex> PromptLoader.load_with_vars("interview", "director", "system", %{
      ...>   themes_text: "resilience, creativity",
      ...>   current_phase: "core_questions"
      ...> })
      {:ok, "...current phase: core_questions...themes: resilience, creativity..."}
  """
  def load_with_vars(domain, agent, prompt_name, variables) when is_map(variables) do
    case load(domain, agent, prompt_name) do
      {:ok, template} ->
        {:ok, substitute_variables(template, variables)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Load a prompt with variables, returning the content directly or a default on error.
  """
  def load_with_vars!(domain, agent, prompt_name, variables, default \\ "") do
    case load_with_vars(domain, agent, prompt_name, variables) do
      {:ok, content} -> content
      {:error, reason} ->
        Logger.warning("[PromptLoader] Failed to load #{domain}/#{agent}/#{prompt_name}: #{inspect(reason)}")
        default
    end
  end

  @doc """
  Load a prompt directly, returning content or default on error.
  """
  def load!(domain, agent, prompt_name, default \\ "") do
    case load(domain, agent, prompt_name) do
      {:ok, content} -> content
      {:error, reason} ->
        Logger.warning("[PromptLoader] Failed to load #{domain}/#{agent}/#{prompt_name}: #{inspect(reason)}")
        default
    end
  end

  @doc """
  Clear the prompt cache. Useful for development/testing.
  """
  def clear_cache do
    if :ets.whereis(@cache_table) != :undefined do
      :ets.delete_all_objects(@cache_table)
    end
    :ok
  end

  @doc """
  Reload a specific prompt from disk (bypassing cache).
  """
  def reload(domain, agent, prompt_name) do
    cache_key = {domain, agent, prompt_name}
    delete_cached(cache_key)
    load(domain, agent, prompt_name)
  end

  # Private functions

  defp load_from_file(domain, agent, prompt_name) do
    path = build_path(domain, agent, prompt_name)

    case File.read(path) do
      {:ok, content} ->
        {:ok, String.trim(content)}

      {:error, :enoent} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_path(domain, agent, prompt_name) do
    # Support both .txt and .md extensions
    base = Path.join([@prompts_base_dir, domain, "prompts", agent, prompt_name])

    cond do
      File.exists?("#{base}.txt") -> "#{base}.txt"
      File.exists?("#{base}.md") -> "#{base}.md"
      true -> "#{base}.txt"  # Default to .txt
    end
  end

  defp substitute_variables(template, variables) do
    Enum.reduce(variables, template, fn {key, value}, acc ->
      placeholder = "{{#{key}}}"
      String.replace(acc, placeholder, to_string(value))
    end)
  end

  # ETS cache operations

  defp get_cached(key) do
    if :ets.whereis(@cache_table) != :undefined do
      case :ets.lookup(@cache_table, key) do
        [{^key, content}] -> {:ok, content}
        [] -> :miss
      end
    else
      :miss
    end
  end

  defp cache_prompt(key, content) do
    if :ets.whereis(@cache_table) != :undefined do
      :ets.insert(@cache_table, {key, content})
    end
    :ok
  end

  defp delete_cached(key) do
    if :ets.whereis(@cache_table) != :undefined do
      :ets.delete(@cache_table, key)
    end
    :ok
  end
end
