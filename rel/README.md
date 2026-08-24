# Orchard releases

Release definitions live in the umbrella `mix.exs`. This directory currently has
no Mix release overlays; add release-specific overlays or helper scripts here
only when the release build needs files that cannot live in `packaging/`.

Internal release identities remain underscore-based (`orchard_controller`, `orchard_node_agent`, `orchard_cli`).
Hyphenated daemon commands and `orchardctl` are treated as packaging-level wrapper names rather than renamed Mix release outputs.

See `../packaging/README.md` for the current payload, app lifecycle, and operator runbook.
