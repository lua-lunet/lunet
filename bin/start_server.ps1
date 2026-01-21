param (
    [string]$LuaFile = "app/main.lua"
)

$ErrorActionPreference = "Stop"

# Ensure .tmp directory exists
if (-not (Test-Path ".tmp")) {
    New-Item -ItemType Directory -Path ".tmp" | Out-Null
}

# 1. Kill existing process on port 8080
Write-Host "Checking for existing process on port 8080..."
$netstat = Get-NetTCPConnection -LocalPort 8080 -ErrorAction SilentlyContinue
if ($netstat) {
    $pidToKill = $netstat.OwningProcess
    Write-Host "Killing process $pidToKill listening on port 8080..."
    Stop-Process -Id $pidToKill -Force -ErrorAction SilentlyContinue
}

# 2. Setup logging
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss_fff"
$logDir = ".tmp/logs/$timestamp"
New-Item -ItemType Directory -Path $logDir | Out-Null
$logFile = "$logDir/server.log"
$pidFile = "$logDir/server.pid"

Write-Host "Logs will be written to $logDir"

# 3. Start server
$exePath = @("build\Release\lunet.exe", "build\Debug\lunet.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $exePath) {
    Write-Error "Executable not found at build\Release\lunet.exe or build\Debug\lunet.exe"
    exit 1
}

Write-Host "Starting $exePath $LuaFile..."

# Start-Process doesn't easily allow redirecting stdout/stderr to a file while running in background and keeping a PID.
# Using System.Diagnostics.Process is more robust for this.

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = Resolve-Path $exePath
$psi.Arguments = $LuaFile
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$psi.WorkingDirectory = Get-Location

$process = New-Object System.Diagnostics.Process
$process.StartInfo = $psi

# Event handlers for async logging
$outputHandler = { param($sender, $e) if ($e.Data) { Add-Content -Path $Global:logFile -Value $e.Data } }
Register-ObjectEvent -InputObject $process -EventName OutputDataReceived -Action $outputHandler | Out-Null
Register-ObjectEvent -InputObject $process -EventName ErrorDataReceived -Action $outputHandler | Out-Null

$Global:logFile = $logFile
$process.Start() | Out-Null
$process.BeginOutputReadLine()
$process.BeginErrorReadLine()

$process.Id | Out-File -FilePath $pidFile -Encoding ascii
Write-Host "Server started with PID $($process.Id)"

# 4. Wait for port 8080
Write-Host "Waiting for port 8080 to open..."
$retries = 0
$maxRetries = 20
$started = $false

while ($retries -lt $maxRetries) {
    Start-Sleep -Milliseconds 500
    
    if ($process.HasExited) {
        Write-Error "Server process exited prematurely!"
        Get-Content $logFile | Write-Host
        exit 1
    }

    $conns = Get-NetTCPConnection -LocalPort 8080 -ErrorAction SilentlyContinue
    if ($conns -and $conns.State -eq 'Listen') {
        Write-Host "Server is LISTENING on port 8080."
        $started = $true
        break
    }
    $retries++
}

if (-not $started) {
    Write-Error "Timed out waiting for port 8080."
    Get-Content $logFile | Write-Host
    Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    exit 1
}
