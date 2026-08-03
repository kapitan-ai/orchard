defmodule Orchard.API.ReadinessRemediation do
  @moduledoc false

  @type remediation :: %{
          reason: String.t(),
          summary: String.t(),
          commands: [String.t()],
          docs_anchor: String.t() | nil
        }

  @spec for_reason(atom()) :: remediation()
  def for_reason(:postgres_reachable) do
    %{
      reason: "postgres_reachable",
      summary:
        "Postgres is not reachable. Check database configuration and initialize the Orchard environment if it has not been created.",
      commands: ["sudo orchardctl env init"],
      docs_anchor: "readiness-postgres"
    }
  end

  def for_reason(:migrations_current) do
    %{
      reason: "migrations_current",
      summary:
        "Database migrations are not current. Run the Orchard migration command before starting normal operation.",
      commands: ["sudo orchardctl migrate"],
      docs_anchor: "readiness-migrations"
    }
  end

  def for_reason(:public_api_https_enabled) do
    %{
      reason: "public_api_https_enabled",
      summary:
        "The public API is not configured for HTTPS. Enable local HTTPS or configure a reverse proxy before declaring the controller ready.",
      commands: [
        "sudo orchardctl transport enable-local-https --host <host> --port 8443",
        "configure a reverse proxy with HTTPS"
      ],
      docs_anchor: "readiness-transport"
    }
  end

  def for_reason(:controller_boot_completed) do
    %{
      reason: "controller_boot_completed",
      summary:
        "Controller boot has not completed. Restart the controller and check service logs if readiness does not recover.",
      commands: ["sudo orchardctl start"],
      docs_anchor: "readiness-controller"
    }
  end

  def for_reason(:readiness_unavailable) do
    %{
      reason: "readiness_unavailable",
      summary:
        "Readiness evaluation is unavailable. Retry the request and check Orchard controller logs if the condition persists.",
      commands: [],
      docs_anchor: nil
    }
  end

  def for_reason(reason) do
    %{
      reason: Atom.to_string(reason),
      summary: "Readiness failed. Check Orchard service logs for details.",
      commands: [],
      docs_anchor: nil
    }
  end
end
