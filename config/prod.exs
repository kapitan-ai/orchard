import Config

# Console disabled by default in production.
# Enabled only when runtime.exs sets ORCHARD_CONSOLE_ENABLED=true with valid credentials.
# This ensures production is fail-closed even if the runtime.exs release-name branch
# does not execute (e.g. MIX_ENV=prod without RELEASE_NAME).
config :orchard_controller, :console, enabled: false
