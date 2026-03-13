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

## Env File Overrides

Wrapper scripts (`bin/orchard-node-agent`, `bin/orchard-controller`) source
optional env files before starting the BEAM release:

| Service | Env File |
|---------|----------|
| node-agent | `/Library/Application Support/Orchard/config/node-agent.env` |
| controller | `/Library/Application Support/Orchard/config/controller.env` |

Format: plain `KEY=value` lines. Comments (`#`) and blank lines are fine.

Primary use case: operational rollback of the worker backend without editing
launchd plists or global environment.

```bash
# Example: rollback to stub backend
echo 'ORCHARD_WORKER_BACKEND=stub' | sudo tee \
  '/Library/Application Support/Orchard/config/node-agent.env'
sudo launchctl kickstart -k system/com.orchard.node-agent
```

**Security note:** These files are sourced by shell scripts running as root
(via launchd). They must remain root-owned with restrictive permissions.

Expected future responsibilities:
- package Orchard releases into install paths under `/Library/Application Support/Orchard/`
- install wrapper commands into `/Library/Application Support/Orchard/bin/`
- expose `orchardctl` via `/usr/local/bin/orchardctl`
- install launchd plists under `/Library/LaunchDaemons/` and `/Library/LaunchAgents/`
- create postinstall hooks for launchd registration
