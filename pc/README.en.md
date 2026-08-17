# PC tools — update, backup, and restore

**Language:** [Tiếng Việt](README.md) | English

These scripts run on an administrator's Windows, Linux, macOS, or Git Bash computer and manage the router over SSH.

| Task | PowerShell | POSIX shell |
|---|---|---|
| Update code | `.\pc\update.ps1` | `sh pc/update.sh` |
| Download backup | `.\pc\backup.ps1` | `sh pc/backup.sh` |
| Restore backup | `.\pc\restore.ps1` | `sh pc/restore.sh` |

## Configuration

Values use this precedence: command-line arguments, config file, defaults. Copy `pc/sbproxy-pc.conf.example` to the ignored `pc/sbproxy-pc.conf`, or pass `-RouterHost`/`--host` directly.

```powershell
.\pc\update.ps1 -RouterHost 192.168.8.1 -Apply
.\pc\backup.ps1 -RouterHost 192.168.8.1
.\pc\restore.ps1 -RouterHost 192.168.8.1
```

```sh
sh pc/update.sh --host 192.168.8.1 --apply
sh pc/backup.sh --host 192.168.8.1
sh pc/restore.sh --host 192.168.8.1
```

Update preserves router-side `wifi-socks.conf` and `settings.sh` unless `-WithSettings`/`--with-settings` is supplied. Backup downloads a complete project snapshot. Restore asks for confirmation and overwrites active router configuration.

Use SSH keys where possible. Keep local backups encrypted because they contain Wi-Fi and SOCKS credentials.
