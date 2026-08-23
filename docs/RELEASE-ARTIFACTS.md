# Release artifacts

The GitHub release workflow builds the Windows desktop executable and publishes
four downloadable artifacts:

| Artifact | Contents | Use |
|---|---|---|
| `sbproxy-console.exe` | Native Tkinter desktop console with the matching router payload embedded | Run the management console on Windows |
| `sbproxy-update-<version>.tar.gz` | Complete router-side update package | Install or update `/root/sbproxy` |
| `sbproxy-agent-<version>.tar.gz` | `agent/`, version metadata, and agent documentation | Deploy or inspect the CGI/health-agent portion |
| `sbproxy-scripts-docs-<version>.tar.gz` | `scripts/`, `docs/`, project guides, and security/contribution files | Offline operations, review, and field documentation |

The workflow runs on tags matching either `0.4.0` or `v0.4.0`. On a tag, the
tag version must match `VERSION`; the release job then attaches all artifacts to
the GitHub Release. `workflow_dispatch` can build the same artifacts from the
current branch without publishing a release.
