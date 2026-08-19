# Run the native Tkinter console from source (no HTML/WebView dependencies).
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $here

python -c "import tkinter; print('Tkinter OK', tkinter.TkVersion)"
python main.py
