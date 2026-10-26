# Installs RoGit on Windows: downloads the newest release and runs `rogit.exe self-install`, which puts RoGit in
# %LOCALAPPDATA%\rogit\bin, adds that folder to your PATH, installs the RoGit Studio plugin, and starts RoGit in the
# background (and from then on whenever you log in). Paste this in PowerShell:
#
#   irm https://__SITE__/install.ps1 | iex
#
# Set $env:ROGIT_VERSION = "v0.3.3" first to install that release instead of the newest, or
# $env:ROGIT_NO_AUTOSTART = "1" to start RoGit yourself (rogit serve).

# Its own scope: with `irm | iex` this runs in your PowerShell session, and nothing should stay behind there.
& {
    $ErrorActionPreference = 'Stop'
    # Invoke-WebRequest is many times slower while it draws its progress bar.
    $ProgressPreference = 'SilentlyContinue'
    # Windows PowerShell 5.1 doesn't always offer TLS 1.2, which GitHub needs.
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    $repo = if ($env:ROGIT_REPO) { $env:ROGIT_REPO } else { '__REPO__' }
    $version = if ($env:ROGIT_VERSION) { $env:ROGIT_VERSION } else { 'latest' }
    $asset = 'rogit-windows-x86_64.zip'
    $url = if ($version -eq 'latest') {
        "https://github.com/$repo/releases/latest/download/$asset"
    } else {
        "https://github.com/$repo/releases/download/$version/$asset"
    }

    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('rogit-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        Write-Host "Downloading $asset..."
        try {
            Invoke-WebRequest -Uri $url -OutFile "$tmp\rogit.zip" -UseBasicParsing
        } catch {
            Write-Host "Couldn't download $url. Check your connection, or that the release exists." -ForegroundColor Red
            return
        }
        Expand-Archive -Path "$tmp\rogit.zip" -DestinationPath $tmp -Force
        & "$tmp\rogit.exe" self-install
        if ($LASTEXITCODE -ne 0) {
            Write-Host "RoGit couldn't install itself (see above)." -ForegroundColor Red
            return
        }
        # rogit.exe saved the new PATH for windows opened from now on; this one gets it too, so rogit works here now.
        $bin = Join-Path $env:LOCALAPPDATA 'rogit\bin'
        if (($env:Path -split ';') -notcontains $bin) {
            $env:Path = "$bin;$env:Path"
        }
        Write-Host 'rogit works in this PowerShell window too.'
    } finally {
        Remove-Item -Path $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}
