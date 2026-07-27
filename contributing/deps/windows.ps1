function Invoke-VcpkgWithRetry {
    param(
        [Parameter(Mandatory = $true)][string]$PackageSpec,
        [int]$MaxAttempts = 4
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        Write-Host "Installing $PackageSpec (attempt $attempt/$MaxAttempts)"
        & vcpkg install $PackageSpec
        if ($LASTEXITCODE -eq 0) {
            return
        }
        if ($attempt -eq $MaxAttempts) {
            throw "vcpkg install failed for $PackageSpec after $MaxAttempts attempts."
        }
        $delay = 5 * $attempt
        Write-Host "Retrying $PackageSpec in $delay seconds..."
        Start-Sleep -Seconds $delay
    }
}

Invoke-VcpkgWithRetry "libuv:x64-windows"
Invoke-VcpkgWithRetry "luajit:x64-windows"
Invoke-VcpkgWithRetry "zlib:x64-windows"
Invoke-VcpkgWithRetry "sqlite3:x64-windows"
Invoke-VcpkgWithRetry "libpq[lz4,openssl,zlib]:x64-windows"
Invoke-VcpkgWithRetry "libmysql:x64-windows"
Invoke-VcpkgWithRetry "curl:x64-windows"
Invoke-VcpkgWithRetry "libsodium:x64-windows"
