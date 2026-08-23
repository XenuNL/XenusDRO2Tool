# Xenu's DRO2 Tool

Launcher, updater and tools for CarX Drift Racing Online 2.

## Update distribution

The application uses two online update branches:

- **Stable** — normal public releases.
- **Xenu's Testing** — opt-in test builds before promotion to Stable.

Small update manifests are stored in `update/`. Release ZIP files are distributed through GitHub Releases rather than committed to the repository.

The updater validates downloaded packages using SHA256 before replacing the installed files and keeps rollback data inside the tool's own `UpdateData` directory.

> The project is currently in development. There is no public Stable release yet.
