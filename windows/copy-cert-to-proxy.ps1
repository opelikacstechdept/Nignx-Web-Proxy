<#
.SYNOPSIS
  Copies the wildcard certificate that win-acme created on this IIS server to the
  nginx proxy, so both servers use the same *.opelikaschools.org certificate.

.DESCRIPTION
  win-acme runs this after every issue/renewal (installation step "Run a custom
  script"). It takes the newest PEM files win-acme wrote to $PemFolder, uploads
  them to the proxy over SSH as fullchain.pem + privkey.pem, and swaps them in
  in one step. The proxy notices the new certificate within 5 minutes and
  reloads nginx by itself - no restart needed.

  Needs the built-in Windows OpenSSH client (ssh.exe / scp.exe) and an SSH key
  that the proxy's user accepts (see README: "Certificates from the IIS server").

.EXAMPLE
  powershell.exe -ExecutionPolicy Bypass -File C:\certs\copy-cert-to-proxy.ps1
#>
param(
    [string]$PemFolder  = "C:\certs\pem",                 # win-acme "PEM encoded files" store path
    [string]$ProxyHost  = "10.1.0.145",
    [string]$ProxyUser  = "localadmin",
    [string]$RemoteDir  = "/opt/nginx-proxy/certs/opelikaschools.org",
    [string]$KeyFile    = "C:\certs\proxy_ssh_key",        # private SSH key for $ProxyUser
    [string]$KnownHosts = "C:\certs\known_hosts",
    [string]$LogFile    = "C:\certs\copy-cert-to-proxy.log"
)
$ErrorActionPreference = "Stop"

function Log($msg) {
    $line = "{0}  {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $msg
    Write-Output $line
    Add-Content -Path $LogFile -Value $line
}

function Newest($filter, $exclude) {
    Get-ChildItem -Path $PemFolder -Filter $filter -File |
        Where-Object { -not $exclude -or $_.Name -notlike $exclude } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
}

function Run($exe, [string[]]$arguments) {
    & $exe @arguments
    if ($LASTEXITCODE -ne 0) { throw "$exe failed with exit code $LASTEXITCODE" }
}

try {
    Log "Starting copy to $ProxyUser@$ProxyHost"

    # win-acme PEM store writes: <name>-crt.pem (cert), <name>-chain-only.pem
    # (intermediates), <name>-chain.pem (cert + intermediates), <name>-key.pem
    $key       = Newest "*-key.pem"
    $crt       = Newest "*-crt.pem"
    $chainOnly = Newest "*-chain-only.pem"
    $chain     = Newest "*-chain.pem" "*-chain-only.pem"
    if (-not $key) { throw "No *-key.pem found in $PemFolder" }

    $tmp = Join-Path $env:TEMP ("proxy-cert-" + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $tmp | Out-Null
    $utf8 = New-Object System.Text.UTF8Encoding($false)   # no BOM

    # fullchain.pem = server cert followed by intermediates (what nginx needs)
    if ($crt -and $chainOnly) {
        $full = ([IO.File]::ReadAllText($crt.FullName).TrimEnd() + "`n" +
                 [IO.File]::ReadAllText($chainOnly.FullName).TrimEnd() + "`n")
    } elseif ($chain) {
        $full = [IO.File]::ReadAllText($chain.FullName).TrimEnd() + "`n"
    } else {
        throw "No certificate PEM files (*-crt.pem / *-chain.pem) found in $PemFolder"
    }
    if (-not $full.Contains("BEGIN CERTIFICATE")) { throw "Certificate PEM looks invalid" }
    [IO.File]::WriteAllText("$tmp\fullchain.pem", $full.Replace("`r`n", "`n"), $utf8)
    [IO.File]::WriteAllText("$tmp\privkey.pem",
        [IO.File]::ReadAllText($key.FullName).Replace("`r`n", "`n"), $utf8)
    Log "Using $($key.Name) and $(if ($crt -and $chainOnly) { "$($crt.Name) + $($chainOnly.Name)" } else { $chain.Name })"

    $sshOpts = @("-i", $KeyFile, "-o", "BatchMode=yes",
                 "-o", "UserKnownHostsFile=$KnownHosts", "-o", "StrictHostKeyChecking=accept-new")
    $staging = "$RemoteDir.new"

    Run "ssh.exe" ($sshOpts + @("$ProxyUser@$ProxyHost", "rm -rf '$staging' && mkdir -p '$staging'"))
    Run "scp.exe" ($sshOpts + @("$tmp\fullchain.pem", "$tmp\privkey.pem", "${ProxyUser}@${ProxyHost}:$staging/"))
    # Swap the new files in together so the proxy never sees a half-copied pair
    Run "ssh.exe" ($sshOpts + @("$ProxyUser@$ProxyHost",
        "chmod 644 '$staging/fullchain.pem' && chmod 600 '$staging/privkey.pem' && rm -rf '$RemoteDir.old' && { [ ! -d '$RemoteDir' ] || mv '$RemoteDir' '$RemoteDir.old'; } && mv '$staging' '$RemoteDir' && rm -rf '$RemoteDir.old'"))

    Log "Done. The proxy will pick up the new certificate within 5 minutes."
}
catch {
    Log "ERROR: $($_.Exception.Message)"
    exit 1
}
finally {
    if ($tmp -and (Test-Path $tmp)) { Remove-Item $tmp -Recurse -Force }
}
