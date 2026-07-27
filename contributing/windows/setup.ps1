$ErrorActionPreference = "Stop"

& "$PSScriptRoot\deps\windows.ps1"

Write-Host ""
Write-Host "=== QA tools note (Windows) ==="
Write-Host "luarocks QA tools (luacheck, busted, luafilesystem) are optional on Windows."
Write-Host "xmake init handles them if needed: run 'xmake init' from the repo root."
