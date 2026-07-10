# DMG packaging

The DMG's primary interactive artifact is a verified `Orchard.app`.
The app owns the root-authorized service lifecycle, while PKG remains a separate compatible path for operator-driven, offline, and manual installs.

The first productization slice proves app assembly, sandboxed install/update/uninstall behavior, inner-first signing, local Amore DMG assembly, mounted-app verification, and nested-signature preservation.
Sparkle, broad updater UX, real notarization, publication, and destructive host installation remain outside that slice.
