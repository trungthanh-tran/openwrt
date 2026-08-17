<# Verify a downloaded firmware image against its published SHA-256 digest. #>
param(
  [Parameter(Mandatory = $true)][string]$File,
  [Parameter(Mandatory = $true)][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$ExpectedSha256
)
$resolved = Resolve-Path -LiteralPath $File -ErrorAction Stop
$actual = (Get-FileHash -LiteralPath $resolved -Algorithm SHA256).Hash.ToLowerInvariant()
$expected = $ExpectedSha256.ToLowerInvariant()
if ($actual -ne $expected) {
  throw "SHA-256 mismatch.`nExpected: $expected`nActual:   $actual"
}
Write-Host "SHA-256 verified: $actual"
