# Release packages

Download the package for the operating system you use. The Windows Console ZIP
contains the full desktop manager and the documentation needed to use it.

| Platform | Package | Purpose |
|---|---|---|
| Windows x64 | `sbproxy-console-<version>-windows-x64.exe` | Full SSID, proxy, device and router manager |
| Windows x64 | `sbproxy-console-<version>-windows-x64.zip` | Console EXE plus guides, screenshots, license and checksums |
| Windows x64 | `sbproxy-web-deployer-<version>-windows-x64.exe` | Check, install/update router and open Web Console |
| Linux | `sbproxy-web-deploy-<version>-linux-<arch>.tar.gz` | Linux Web Deployer bundle |

## Windows Console ZIP

```text
sbproxy-console-<version>-windows-x64/
├── sbproxy-console-<version>-windows-x64.exe
├── README.md
├── desktop-user-guide.md
├── WEB-DEPLOYER.md
├── WEB-DEPLOY.md
├── RELEASE-ARTIFACTS.md
├── images/
├── LICENSE
└── SHA256SUMS
```

Run the EXE directly for the full Windows manager. The ZIP is useful when the
operator also needs the usage guides and screenshots offline.

## Build on Windows

```powershell
.\console\desktop\package-windows.ps1
.\console\deployer\package-windows.ps1
```

The output is written to `dist/release/`. The desktop script creates both the
standalone EXE and the documentation ZIP. The deployer script creates only the
standalone Web Deployer EXE.

## Verify the Console ZIP

```powershell
Expand-Archive .\dist\release\sbproxy-console-*-windows-x64.zip .\check
Get-Content .\check\sbproxy-console-*\SHA256SUMS
$exe = Get-ChildItem .\check\sbproxy-console-*\sbproxy-console-*-windows-x64.exe
Get-FileHash $exe.FullName -Algorithm SHA256
$p = Start-Process $exe.FullName -ArgumentList --self-test-gui -Wait -PassThru
$p.ExitCode # must be 0
```

## GitHub Release

`.github/workflows/deploy-release.yml` builds the Desktop Console EXE, the
Console documentation ZIP, the Web Deployer EXE and the Linux TAR.GZ. A tag
must match `VERSION`; the workflow then publishes all four assets together.

For the normal release flow, keep `VERSION` on `main` as `x.y.z-SNAPSHOT`,
commit the changes, then choose the release level:

```powershell
.\scripts\release.ps1 -ReleaseType patch -Push -Wait
# or: -ReleaseType minor / -ReleaseType major
```

Linux/macOS:

```sh
sh scripts/release.sh --release-type minor --push --wait
```

The script removes `-SNAPSHOT` for the release commit and tag, then creates
the next `patch`, `minor`, or `major` version with `-SNAPSHOT` on `main`.
