Write-Host "Stopping lunet processes..."
Stop-Process -Name "lunet" -ErrorAction SilentlyContinue -Force
Write-Host "All lunet processes stopped."
