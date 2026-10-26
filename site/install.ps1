# Installs RoGit on Windows: downloads the latest release into %LOCALAPPDATA%\rogit\bin, puts that folder on your PATH,
# installs the RoGit Studio plugin, and starts RoGit in the background (and from now on whenever you log in). Run it
# again to update.
#
#   powershell -ExecutionPolicy Bypass -c "irm https://__SITE__/install.ps1 | iex"
#
# Set $env:ROGIT_VERSION = "v0.2.0" first to install that release instead of the latest, or $env:ROGIT_NO_AUTOSTART = "1"
# to start RoGit yourself (rogit serve).

# Everything runs in its own scope: with `irm | iex` this script runs in your PowerShell session, and its variables
# and settings shouldn't stay behind there.
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
    $bin = Join-Path $env:LOCALAPPDATA 'rogit\bin'
    $exe = Join-Path $bin 'rogit.exe'

    if (-not [Environment]::Is64BitOperatingSystem) {
        Write-Host 'rogit needs 64-bit Windows.' -ForegroundColor Red
        return
    }

    New-Item -ItemType Directory -Force -Path $bin | Out-Null
    $tmp = Join-Path $bin ('download-' + [guid]::NewGuid().ToString('N'))
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
        # rogit.exe is the command; rogit-background.exe is RoGit running in the background, without a window.
        $programs = @('rogit.exe', 'rogit-background.exe')
        foreach ($program in $programs) {
            if (-not (Test-Path "$tmp\$program")) {
                Write-Host "$asset doesn't contain $program." -ForegroundColor Red
                return
            }
        }
        foreach ($program in $programs) {
            # A running RoGit keeps its program open. Windows still lets it be renamed, so the old copy moves aside
            # and is cleaned up by the next install.
            Get-ChildItem -Path $bin -Filter "$program.old-*" | Remove-Item -Force -ErrorAction SilentlyContinue
            if (Test-Path "$bin\$program") {
                Rename-Item -Path "$bin\$program" -NewName ("$program.old-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
            }
            Move-Item -Path "$tmp\$program" -Destination "$bin\$program"
        }
    } finally {
        Remove-Item -Path $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }

    # PATH: read and written through the registry as it's stored, so entries like %USERPROFILE%\... stay as they are.
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
    try {
        $saved = $key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $parts = @($saved -split ';' | Where-Object { $_ })
        $added = $parts -notcontains $bin
        if ($added) {
            $key.SetValue('Path', ((@($bin) + $parts) -join ';'), [Microsoft.Win32.RegistryValueKind]::ExpandString)
        }
    } finally {
        $key.Close()
    }
    if ($added) {
        # Setting any user variable this way tells Explorer that the environment changed, so programs started from
        # now on see the new PATH.
        [Environment]::SetEnvironmentVariable('ROGIT_INSTALLING', '1', 'User')
        [Environment]::SetEnvironmentVariable('ROGIT_INSTALLING', $null, 'User')
    }
    if (($env:Path -split ';') -notcontains $bin) {
        $env:Path = "$bin;$env:Path"
    }

    & $exe plugin install
    if ($LASTEXITCODE -ne 0) {
        Write-Host "rogit is installed, but the Studio plugin wasn't. Run: rogit plugin install" -ForegroundColor Yellow
    }

    # From now on RoGit runs in the background whenever you're logged in; this also restarts it after an update.
    $started = $false
    if (-not $env:ROGIT_NO_AUTOSTART) {
        & $exe autostart
        $started = $LASTEXITCODE -eq 0
    }

    Write-Host ''
    Write-Host "$(& $exe --version) is installed in $bin."
    if ($added) {
        Write-Host 'Added it to your PATH for new terminals.'
    }
    if (-not $started) {
        Write-Host 'Start RoGit with: rogit serve'
    }
    Write-Host ''
    Write-Host "Next, in Roblox Studio: open your game's start place, then Plugins > RoGit, and click Init."
    Write-Host 'Later, rogit update updates RoGit and rogit uninstall removes it.'
    Write-Host ''
}
