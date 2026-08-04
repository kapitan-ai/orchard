defmodule Orchard.BuildInfo.Resolver do
  @moduledoc false

  @sha_pattern ~r/\A[0-9a-f]{40}\z/

  @type git_state :: :override | :git_available | :git_unavailable | :repository_unavailable
  @type metadata :: %{
          git_sha: String.t(),
          build_date: String.t(),
          build_channel: String.t(),
          git_state: git_state()
        }

  @doc "Resolves the current compile-time build metadata and provenance source state."
  @spec resolve() :: metadata()
  def resolve do
    {git_sha, git_state} = resolve_git_sha()

    %{
      git_sha: git_sha,
      build_date: Date.utc_today() |> Date.to_iso8601(),
      build_channel: resolve_build_channel(),
      git_state: git_state
    }
  end

  defp resolve_git_sha do
    case System.get_env("ORCHARD_BUILD_SHA") do
      nil -> resolve_git_sha_from_repository()
      value -> {validate_sha!(value, "ORCHARD_BUILD_SHA"), :override}
    end
  end

  defp resolve_git_sha_from_repository do
    case System.find_executable("git") do
      nil ->
        {"unknown", :git_unavailable}

      executable ->
        case run_git(executable) do
          {:ok, sha} ->
            git_sha = sha |> String.trim() |> validate_sha!("Git-derived build provenance")
            {git_sha, :git_available}

          {:error, :repository_unavailable} ->
            {"unknown", :repository_unavailable}

          {:error, :git_unavailable} ->
            {"unknown", :git_unavailable}
        end
    end
  end

  defp run_git(executable) do
    case System.cmd(executable, ["rev-parse", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> {:ok, sha}
      {_output, _status} -> {:error, :repository_unavailable}
    end
  rescue
    ArgumentError -> {:error, :git_unavailable}
    ErlangError -> {:error, :git_unavailable}
  end

  defp validate_sha!(value, source) do
    if Regex.match?(@sha_pattern, value) do
      value
    else
      raise ArgumentError, "#{source} must be a 40-character lowercase Git commit"
    end
  end

  defp resolve_build_channel do
    case System.get_env("ORCHARD_BUILD_CHANNEL") do
      nil -> "dev"
      channel -> channel |> String.trim() |> default_channel()
    end
  end

  defp default_channel(""), do: "dev"
  defp default_channel(channel), do: channel
end

defmodule Orchard.BuildInfo do
  @moduledoc """
  Compile-time build metadata.

  Bakes the full source commit, build date, and build channel into BEAM bytecode at
  compile time, per `SPEC.md` §13.1. Available in releases without `.git` access.
  Override with env vars for CI/release builds where `.git` is absent.
  """

  alias Orchard.BuildInfo.Resolver

  @build_info Resolver.resolve()

  @doc "Returns whether any effective compile-time build metadata input changed."
  @spec __mix_recompile__?() :: boolean()
  def __mix_recompile__?, do: Resolver.resolve() != @build_info

  @spec git_sha() :: String.t()
  def git_sha, do: @build_info.git_sha

  @spec build_date() :: String.t()
  def build_date, do: @build_info.build_date

  @spec build_channel() :: String.t()
  def build_channel, do: @build_info.build_channel
end
