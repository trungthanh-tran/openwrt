param(
  [string]$RouterHost = '192.168.8.1',
  [string]$ClientIp = '192.168.14.150',
  [string]$Mac = 'f0:20:ff:20:08:a5',
  [string]$ExpectedProxyIp = '178.93.44.10',
  [int]$SsidIndex = 4
)

$ErrorActionPreference = 'Stop'
Write-Host "Kick/reconnect real client $Mac on idx=$SsidIndex ..."
ssh "root@$RouterHost" "sh /root/sbproxy/scripts/kick.sh $SsidIndex $Mac"
Start-Sleep -Seconds 8

$body = & curl.exe -4 --interface $ClientIp --no-keepalive --max-time 20 -sS `
  "https://api.ipify.org/?t=$([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())"
if ($LASTEXITCODE -ne 0 -or $body.Trim() -ne $ExpectedProxyIp) {
  throw "Egress failed: source=$ClientIp expected=$ExpectedProxyIp actual=$($body.Trim())"
}
Write-Host "PASS: real client egress=$($body.Trim()) via $ClientIp"

$clientJson = ssh "root@$RouterHost" "sh /root/sbproxy/scripts/clients.sh"
$client = ($clientJson | ConvertFrom-Json).clients |
  Where-Object { $_.mac -eq $Mac -and $_.online -eq $true }
if (-not $client -or $null -eq $client.slot -or $client.proxy_state -ne 'pinned') {
  throw 'Client did not reconnect with a pinned proxy.'
}
Write-Host "PASS: client online slot=$($client.slot) proxy=$($client.proxy_host)"
