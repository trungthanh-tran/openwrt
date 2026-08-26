# tests/vm/qemu-win.ps1 — download and boot an OpenWrt x86-64 VM on Windows,
# to stand in for the router where the design risk is not radio-related.
#
#   .\tests\vm\qemu-win.ps1 -Fetch     # download and unpack the image, once
#   .\tests\vm\qemu-win.ps1            # boot it
#
# QEMU must be installed first. This script does not install it:
#   winget install --id SoftwareFreedomConservancy.QEMU
# then reopen the terminal, or pass -QemuPath "C:\Program Files\qemu".
#
# NOT TESTED ON THE MACHINE THIS WAS WRITTEN ON — no hypervisor was available
# there. Treat the first run as a bring-up, not as a known-good path.
[CmdletBinding()]
param(
  [switch]$Fetch,
  [string]$Version  = '25.12.5',
  [string]$WorkDir  = "$PSScriptRoot\.vm",
  [string]$QemuPath = '',
  [int]$SshPort     = 2222,
  [int]$MemoryMb    = 512
)

$ErrorActionPreference = 'Stop'

$image   = "openwrt-$Version-x86-64-generic-ext4-combined-efi.img"
$archive = "$image.gz"
$url     = "https://downloads.openwrt.org/releases/$Version/targets/x86/64/$archive"
$disk    = Join-Path $WorkDir $image

function Resolve-Qemu {
  if ($QemuPath) { return (Join-Path $QemuPath 'qemu-system-x86_64.exe') }
  $cmd = Get-Command qemu-system-x86_64.exe -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  foreach ($candidate in @("$env:ProgramFiles\qemu\qemu-system-x86_64.exe",
                           "${env:ProgramFiles(x86)}\qemu\qemu-system-x86_64.exe")) {
    if (Test-Path $candidate) { return $candidate }
  }
  throw "qemu-system-x86_64.exe not found. Install QEMU, or pass -QemuPath."
}

if ($Fetch) {
  New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
  $gz = Join-Path $WorkDir $archive
  if (-not (Test-Path $gz)) {
    Write-Host "Downloading $url"
    Invoke-WebRequest -Uri $url -OutFile $gz
  }
  if (-not (Test-Path $disk)) {
    Write-Host "Unpacking $archive"
    $in  = [System.IO.File]::OpenRead($gz)
    $out = [System.IO.File]::Create($disk)
    try {
      $gzip = New-Object System.IO.Compression.GZipStream($in, [System.IO.Compression.CompressionMode]::Decompress)
      $gzip.CopyTo($out)
      $gzip.Dispose()
    } finally { $out.Dispose(); $in.Dispose() }
  }
  # The stock image is tiny. Growing it now avoids running out of room the
  # first time opkg installs sing-box.
  $qemuImg = Join-Path (Split-Path (Resolve-Qemu)) 'qemu-img.exe'
  if (Test-Path $qemuImg) { & $qemuImg resize -f raw $disk 2G | Out-Null }
  Write-Host "Ready: $disk"
  Write-Host "Now boot it with:  .\tests\vm\qemu-win.ps1"
  return
}

if (-not (Test-Path $disk)) { throw "$disk not found. Run with -Fetch first." }
$qemu = Resolve-Qemu

# eth0 is the first NIC and becomes br-lan (192.168.1.1). hostfwd points at that
# address directly, so the host reaches the router's SSH on localhost:$SshPort.
# The second NIC becomes the WAN and gets its address from QEMU's own DHCP.
$qemuArgs = @(
  '-machine', 'q35',
  '-m', "$MemoryMb",
  '-drive', "file=$disk,format=raw,if=virtio",
  '-bios', 'OVMF.fd',
  '-netdev', "user,id=lan,net=192.168.1.0/24,host=192.168.1.2,hostfwd=tcp::${SshPort}-192.168.1.1:22",
  '-device', 'virtio-net-pci,netdev=lan',
  '-netdev', 'user,id=wan',
  '-device', 'virtio-net-pci,netdev=wan',
  '-nographic'
)

Write-Host "Booting OpenWrt $Version. Ctrl-A X quits QEMU."
Write-Host "Once it is up, in the VM console set a root password:  passwd"
Write-Host "Then from another terminal:  ssh -p $SshPort root@127.0.0.1"
& $qemu @qemuArgs
