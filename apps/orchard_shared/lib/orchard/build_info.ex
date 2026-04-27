defmodule Orchard.BuildInfo do
  @moduledoc """
  Compile-time build metadata.

  Bakes the git SHA, build date, and build channel into BEAM bytecode at compile time.
  Available in releases without `.git` access. Override with env vars
  for CI/release builds where `.git` is absent.
  """

  @git_sha (case System.get_env("ORCHARD_BUILD_SHA") do
              sha when is_binary(sha) and sha != "" ->
                String.trim(sha)

              _ ->
                case System.cmd("git", ["rev-parse", "--short=7", "HEAD"], stderr_to_stdout: true) do
                  {sha, 0} -> String.trim(sha)
                  _ -> "unknown"
                end
            end)

  @build_date Date.utc_today() |> Date.to_iso8601()

  @build_channel (case System.get_env("ORCHARD_BUILD_CHANNEL") do
                    channel when is_binary(channel) ->
                      case String.trim(channel) do
                        "" -> "dev"
                        trimmed -> trimmed
                      end

                    _ ->
                      "dev"
                  end)

  @spec git_sha() :: String.t()
  def git_sha, do: @git_sha

  @spec build_date() :: String.t()
  def build_date, do: @build_date

  @spec build_channel() :: String.t()
  def build_channel, do: @build_channel
end
