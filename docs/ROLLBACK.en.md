# ROLLBACK — Recovery guide

**Language:** [Tiếng Việt](ROLLBACK.md) | English

Every full apply, SOCKS change, and uninstall creates a snapshot under `/root/sbproxy-backups` unless explicitly disabled.

## List and restore

```sh
sh scripts/rollback.sh --list
sh scripts/rollback.sh
sh scripts/rollback.sh 20260812-101500-pre-apply
```

Rollback restores OpenWrt UCI configuration, sing-box configuration, nftables data, and `wifi-socks.conf`, then reloads affected services. It overwrites the active configuration and asks for confirmation unless `SB_YES=1` is supplied by trusted automation.

## Off-device recovery

Download snapshots regularly with the UI or `pc/backup.sh`. Router-side backups are lost when storage is erased or the device is unrecoverable.

For serious firmware failure, use the included `sysupgrade-backup.tar.gz` through LuCI recovery or the GL-MT6000 U-Boot recovery flow. Use LAN2–LAN4 rather than the switchable LAN1 port during GL.iNet recovery.

Always create a fresh backup before restoring an older snapshot when the router is still accessible.
