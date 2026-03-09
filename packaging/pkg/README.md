# PKG skeleton

Milestone 0 packaging placeholder for Orchard enterprise/unattended installs.

## Naming strategy

- Internal release names remain underscore-based (`orchard_controller`, `orchard_node_agent`, `orchard_cli`).
- Installed operator-facing commands use the Orchard product names expected by `SPEC.md` and launchd:
  - `orchard-controller`
  - `orchard-node-agent`
  - `orchardctl`
  - `orchard-managed-postgres`
- The PKG is expected to provide these external commands as wrapper scripts under `/Library/Application Support/Orchard/bin/`.

Expected future responsibilities:
- package Orchard releases into install paths under `/Library/Application Support/Orchard/`
- install wrapper commands into `/Library/Application Support/Orchard/bin/`
- expose `orchardctl` via `/usr/local/bin/orchardctl`
- install launchd plists under `/Library/LaunchDaemons/` and `/Library/LaunchAgents/`
- create postinstall hooks for launchd registration
