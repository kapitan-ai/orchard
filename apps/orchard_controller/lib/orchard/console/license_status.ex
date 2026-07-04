defmodule OrchardConsole.LicenseStatus do
  @moduledoc false

  alias Orchard.Licensing
  alias Orchard.Licensing.Gate

  @type summary :: %{
          required(:state) => Licensing.state(),
          required(:status) => String.t(),
          required(:reason) => String.t() | nil,
          required(:message) => String.t(),
          required(:expires_at) => String.t() | nil,
          required(:license_id) => String.t() | nil,
          required(:machine_id) => String.t() | nil,
          required(:licensee) => String.t() | nil,
          required(:max_machines) => pos_integer() | nil,
          required(:tracking) => Licensing.tracking_metadata() | nil,
          required(:activation_guidance) => String.t() | nil,
          required(:visible?) => boolean()
        }

  @spec fetch() :: summary()
  def fetch do
    status = licensing_impl().inspect_local()

    summarize(status, safe_enforcement_mode())
  rescue
    _ ->
      summarize(
        %Licensing{
          state: :malformed_bundle,
          message: "License inspection failed.",
          bundle_path: ""
        },
        safe_enforcement_mode()
      )
  end

  @spec valid?(summary()) :: boolean()
  def valid?(%{state: :valid}), do: true
  def valid?(_summary), do: false

  @doc """
  Returns whether Console license surfaces should render.

  Valid license status stays visible in every enforcement mode.
  Non-valid states stay quiet in `:off` and render in `:warn` or `:hard` for operator remediation.
  """
  @spec visible?(summary()) :: boolean()
  def visible?(%{visible?: visible?}) when is_boolean(visible?), do: visible?
  def visible?(_summary), do: true

  @spec badge_label(summary()) :: String.t()
  def badge_label(%{state: :valid, licensee: licensee}) do
    non_empty_string(licensee) || "Licensed"
  end

  def badge_label(%{reason: reason, status: status}) do
    reason
    |> non_empty_string()
    |> Kernel.||(status)
    |> humanize_state()
  end

  @spec badge_tone(summary()) :: :neutral | :warning
  def badge_tone(%{state: :valid}), do: :neutral
  def badge_tone(_summary), do: :warning

  @spec state_label(summary()) :: String.t()
  def state_label(%{state: state}), do: humanize_state(Atom.to_string(state))

  @spec tracking_label(summary()) :: String.t() | nil
  def tracking_label(%{tracking: tracking}) when is_map(tracking) do
    [
      tracking_part("program", Map.get(tracking, :program)),
      tracking_part("ref", Map.get(tracking, :reference))
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      parts -> Enum.join(parts, " ")
    end
  end

  def tracking_label(_summary), do: nil

  defp summarize(%Licensing{} = status, enforcement_mode) do
    health = Licensing.health_summary(status)
    activation_guidance = activation_guidance(status)

    %{
      state: status.state,
      status: health.status,
      reason: health.reason,
      message: health.message,
      expires_at: health.expires_at,
      license_id: Map.get(health, :license_id),
      machine_id: Map.get(health, :machine_id),
      licensee: Map.get(health, :licensee),
      max_machines: Map.get(health, :max_machines),
      tracking: Map.get(health, :tracking),
      activation_guidance: activation_guidance,
      visible?: visible_status?(status, enforcement_mode)
    }
  end

  defp visible_status?(%Licensing{state: :valid}, _enforcement_mode), do: true
  defp visible_status?(%Licensing{}, :off), do: false

  defp visible_status?(%Licensing{}, enforcement_mode) when enforcement_mode in [:warn, :hard],
    do: true

  defp safe_enforcement_mode do
    Licensing.enforcement_mode()
  rescue
    _ -> :hard
  end

  defp activation_guidance(%Licensing{state: :valid}), do: nil
  defp activation_guidance(%Licensing{} = status), do: Gate.denial(status).activation_guidance

  defp licensing_impl do
    Application.get_env(:orchard_controller, :console, [])
    |> Keyword.get(:licensing_impl, Orchard.Licensing)
  end

  defp tracking_part(_label, value) when not is_binary(value), do: nil

  defp tracking_part(label, value) do
    case non_empty_string(value) do
      nil -> nil
      trimmed -> "#{label}=#{trimmed}"
    end
  end

  defp humanize_state(value) do
    value
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp non_empty_string(nil), do: nil

  defp non_empty_string(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed != "", do: trimmed
  end

  defp non_empty_string(_value), do: nil
end
