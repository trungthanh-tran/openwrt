$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$desktop = Join-Path (Split-Path -Parent $here) "desktop"
$env:PYTHONPATH = "$desktop;$env:PYTHONPATH"
python (Join-Path $here "web_deployer.py")
