# Security

## Reporting a problem

Please report security problems privately: on GitHub, open the repository's **Security** tab and click **Report a
vulnerability**. Don't open a public issue for them. You'll get an answer within a few days, and a fix is released as
soon as it's ready. Only the latest release gets fixes, and `rogit update` installs it.

## What RoGit does on your computer

- **One local server.** `rogit serve` listens on `127.0.0.1` (ports 34875–34879), which other computers can't reach.
  It answers only Roblox Studio and rogit itself: it refuses requests from web pages (anything a browser marks with
  `Origin`, `Referer` or `Sec-Fetch-*`, or that names a host other than `127.0.0.1`/`localhost`).
- **No accounts or keys.** RoGit never asks for a Roblox login, cookie or API key.
- **Two kinds of internet requests.** At Init it looks up your game's public info on `develop.roblox.com`; every six
  hours it checks GitHub for a newer release. Your places and branches never leave your computer.
- **Files.** Everything RoGit keeps is in `~/.rogit` (macOS) or `%LOCALAPPDATA%\rogit` (Windows), and the plugin in
  Studio's plugins folder. Branch names are limited to letters, numbers, `-` and `_`, so requests can't reach files
  outside a game's folder.
- **Starting at login.** On Windows, the value `RoGit` under `HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run`
  starts `rogit-background.exe` (RoGit without a console window); on macOS, the LaunchAgent `com.rogit.serve` starts
  `rogit serve`. `rogit autostart off` removes them. On Windows, RoGit starts no PowerShell, scripts or other programs:
  only its own (`rogit-background.exe`, and a new version when it updates) and Studio, to open a branch. It closes
  Studio windows of a branch you archive.
- **What it can't protect against.** Like Rojo, RoGit trusts programs running on the same computer: anything that
  runs as you (or another account on a shared computer) can talk to `127.0.0.1` too.

## Checking a download

Every release has `SHA256SUMS`, and GitHub signs a record of the workflow run and commit each zip was built from. With
the [GitHub CLI](https://cli.github.com):

```sh
gh attestation verify rogit-windows-x86_64.zip --repo Proscled/rogit
```

## If your antivirus flags RoGit

Microsoft Defender has wrongly quarantined RoGit's Windows programs (as `Trojan:Win32/Bearfoos.B!ml`, a machine
learning guess about a program it hasn't seen before, and before 0.3.2 its start-up script as `Trojan:VBS/AgentTesla`).
Check the download as above, then report it as a false positive (Microsoft's form is at
<https://www.microsoft.com/en-us/wdsi/filesubmission>), and open an issue so it can be reported for everyone.
