defmodule Orchard.Inference.EffortProfiles do
  @moduledoc """
  Validates the closed source-owned registry before effort mappings are used.
  """

  @profile_keys ~w(chat_template_digest default_effort effort_argument efforts generation_argument model_artifact_digest render_contract render_contract_version)
  @digest ~r/\A[0-9a-f]{64}\z/
  @identifier ~r/\A[A-Za-z_][A-Za-z0-9_]*\z/
  @version ~r/\A[1-9][0-9]*\z/

  @spec load!(Path.t()) :: [map()]
  def load!(path), do: path |> File.read!() |> Jason.decode!() |> validate!()

  @spec validate!(term()) :: [map()]
  def validate!(%{"profiles" => profiles} = registry)
      when map_size(registry) == 1 and is_list(profiles) do
    Enum.each(profiles, &validate_profile!/1)

    identities =
      Enum.map(profiles, &{&1["model_artifact_digest"], &1["chat_template_digest"]})

    if length(identities) != MapSet.size(MapSet.new(identities)), do: invalid!()
    profiles
  end

  def validate!(_registry), do: invalid!()

  defp validate_profile!(profile) when is_map(profile) do
    with true <- Enum.sort(Map.keys(profile)) == @profile_keys,
         true <- valid_identity?(profile),
         true <- valid_arguments?(profile),
         true <- valid_efforts?(profile["efforts"]),
         true <- valid_value?(profile["default_effort"]),
         true <- Map.has_key?(profile["efforts"], profile["default_effort"]) do
      :ok
    else
      _invalid -> invalid!()
    end
  end

  defp validate_profile!(_profile), do: invalid!()

  defp valid_identity?(profile) do
    matches?(profile["model_artifact_digest"], @digest) and
      matches?(profile["chat_template_digest"], @digest) and
      matches?(profile["render_contract"], @identifier) and
      matches?(profile["render_contract_version"], @version)
  end

  defp valid_arguments?(%{
         "generation_argument" => %{"key" => key, "value" => true} = generation,
         "effort_argument" => effort
       }) do
    map_size(generation) == 2 and matches?(key, @identifier) and
      matches?(effort, @identifier) and key != effort
  end

  defp valid_arguments?(_profile), do: false

  defp valid_efforts?(efforts) when is_map(efforts) do
    map_size(efforts) > 0 and Enum.all?(Map.keys(efforts), &valid_value?/1) and
      Enum.all?(Map.keys(efforts), &(&1 not in ~w(none off disabled false))) and
      Enum.all?(Map.values(efforts), &(is_binary(&1) and String.trim(&1) != ""))
  end

  defp valid_efforts?(_efforts), do: false

  @doc "Validates the bounded public identifier syntax, independently of model support."
  @spec valid_value?(term()) :: boolean()
  def valid_value?(value), do: matches?(value, ~r/\A[a-z][a-z0-9_]{0,31}\z/)

  defp matches?(value, regex), do: is_binary(value) and Regex.match?(regex, value)
  defp invalid!, do: raise(ArgumentError, "invalid rendered effort registry")
end
