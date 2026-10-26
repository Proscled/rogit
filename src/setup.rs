//! Installing the Studio plugin, updating RoGit, and removing it again.

use crate::{autostart, project};
use std::path::PathBuf;
use std::process::Command;
use std::time::Duration;
use std::{env, fs};

/// Where Studio loads plugins from.
fn plugins_folder() -> Result<PathBuf, String> {
    if cfg!(windows) {
        let local = env::var("LOCALAPPDATA").map_err(|_| "LOCALAPPDATA isn't set.".to_owned())?;
        Ok(PathBuf::from(local).join("Roblox").join("Plugins"))
    } else {
        let home = env::var("HOME").map_err(|_| "HOME isn't set.".to_owned())?;
        Ok(PathBuf::from(home).join("Documents").join("Roblox").join("Plugins"))
    }
}

/// Writes the plugin into Studio's plugins folder, marked with this version so it can tell when RoGit and it differ.
pub fn install_plugin() -> Result<(), String> {
    let folder = plugins_folder()?;
    fs::create_dir_all(&folder).map_err(|e| format!("Couldn't create {}: {e}", folder.display()))?;
    let target = folder.join("RoGit.lua");
    let plugin = crate::PLUGIN.replace("__ROGIT_VERSION__", env!("CARGO_PKG_VERSION"));
    fs::write(&target, plugin).map_err(|e| format!("Couldn't write {}: {e}", target.display()))?;
    println!("Installed the RoGit plugin to {}. Studio picks it up automatically.", target.display());
    Ok(())
}

/// Whether version `a` ("1.2.3") is at least `b`.
pub fn at_least(a: &str, b: &str) -> bool {
    let parts = |v: &str| v.trim_start_matches('v').split('.').map(|n| n.parse::<u64>().unwrap_or(0)).collect::<Vec<_>>();
    parts(a) >= parts(b)
}

/// The newest release on GitHub, like "0.3.0".
pub fn latest_release() -> Result<String, String> {
    let repo = env!("CARGO_PKG_REPOSITORY").trim_start_matches("https://github.com/");
    let agent: ureq::Agent = ureq::Agent::config_builder().timeout_global(Some(Duration::from_secs(10))).build().into();
    let text = agent
        .get(&format!("https://api.github.com/repos/{repo}/releases/latest"))
        .call()
        .and_then(|mut res| res.body_mut().read_to_string())
        .map_err(|e| format!("Couldn't reach GitHub: {e}"))?;
    let release: serde_json::Value = serde_json::from_str(&text).map_err(|e| e.to_string())?;
    release["tag_name"].as_str().map(|tag| tag.trim_start_matches('v').to_owned()).ok_or("GitHub has no release of RoGit.".into())
}

/// Installs the newest release with the installer from RoGit's site, which also updates the plugin and restarts
/// RoGit in the background.
pub fn update() -> Result<(), String> {
    let current = env!("CARGO_PKG_VERSION");
    match latest_release() {
        Ok(latest) if at_least(current, &latest) => {
            println!("RoGit {current} is the newest version.");
            return Ok(());
        }
        Ok(latest) => println!("Updating RoGit {current} to {latest}..."),
        Err(e) => println!("{e}. Installing the newest version anyway..."),
    }
    let site = env!("CARGO_PKG_HOMEPAGE");
    let status = if cfg!(windows) {
        let command = format!("irm {site}/install.ps1 | iex");
        Command::new("powershell").args(["-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", &command]).status()
    } else {
        Command::new("sh").args(["-c", &format!("curl -fsSL {site}/install.sh | sh")]).status()
    };
    match status {
        Ok(status) if status.success() => Ok(()),
        _ => Err(format!("The update didn't finish. You can run the install command from {site} instead.")),
    }
}

/// Removes RoGit: stops it, stops it starting when you log in, and removes the plugin, the program and its PATH
/// entry. Every game's branches stay where they are.
pub fn uninstall() -> Result<(), String> {
    let home = project::home()?;
    autostart::disable()?;
    if cfg!(windows) {
        // The one running in the background (disable only stops it starting at login).
        let _ = Command::new("taskkill").args(["/F", "/IM", "rogit.exe", "/FI", &format!("PID ne {}", std::process::id())]).output();
    }
    let plugin = plugins_folder()?.join("RoGit.lua");
    if plugin.exists() {
        fs::remove_file(&plugin).map_err(|e| format!("Couldn't remove {}: {e}", plugin.display()))?;
    }
    let bin = home.join("bin");
    remove_from_path(&bin)?;
    for leftover in ["env", "serve.log", "start.vbs"] {
        let _ = fs::remove_file(home.join(leftover));
    }
    // The program itself, when it's the installer's copy. One installed some other way (cargo) stays.
    let exe = env::current_exe().ok().and_then(|e| e.canonicalize().ok());
    let installed = exe.as_ref().is_some_and(|e| bin.canonicalize().is_ok_and(|b| e.starts_with(b)));
    if installed {
        remove_folder(&bin)?;
    } else if let Some(exe) = exe {
        println!("This rogit ({}) wasn't put there by the installer; delete it yourself.", exe.display());
    }
    println!("RoGit is uninstalled.");
    println!("Your branches are still in {}. Delete that folder if you don't need them.", project::games()?.display());
    Ok(())
}

/// Undoes what the installers did to PATH.
fn remove_from_path(bin: &std::path::Path) -> Result<(), String> {
    if cfg!(windows) {
        // Read and written as stored, so the other entries (like %USERPROFILE%\...) stay as they are.
        let script = format!(
            "$bin = '{}'; $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true); \
             $saved = $key.GetValue('Path', '', 'DoNotExpandEnvironmentNames'); \
             $parts = @($saved -split ';' | Where-Object {{ $_ -and $_ -ne $bin }}); \
             $key.SetValue('Path', ($parts -join ';'), 'ExpandString'); $key.Close(); \
             [Environment]::SetEnvironmentVariable('ROGIT_INSTALLING', '1', 'User'); \
             [Environment]::SetEnvironmentVariable('ROGIT_INSTALLING', $null, 'User')",
            bin.display().to_string().replace('\'', "''")
        );
        let done = Command::new("powershell").args(["-NoProfile", "-Command", &script]).output().map_err(|e| e.to_string())?;
        if !done.status.success() {
            return Err(format!("Couldn't take RoGit off your PATH: {}", String::from_utf8_lossy(&done.stderr).trim()));
        }
        return Ok(());
    }
    let user = env::var_os("HOME").map(PathBuf::from).ok_or("HOME isn't set.")?;
    let zdotdir = env::var_os("ZDOTDIR").map(PathBuf::from).unwrap_or_else(|| user.clone());
    let line = ". \"$HOME/.rogit/env\"";
    for profile in [zdotdir.join(".zshenv"), user.join(".bash_profile"), user.join(".bash_login"), user.join(".profile"), user.join(".bashrc")] {
        let Ok(text) = fs::read_to_string(&profile) else { continue };
        if !text.lines().any(|l| l == line) {
            continue;
        }
        // The installer added a line break, the line and another; taking them out leaves the file as it was.
        let kept = text.replace(&format!("\n{line}\n"), "").replace(&format!("{line}\n"), "");
        fs::write(&profile, kept).map_err(|e| format!("Couldn't update {}: {e}", profile.display()))?;
    }
    let fish = user.join(".config").join("fish").join("conf.d").join("rogit.fish");
    if fs::read_to_string(&fish).is_ok_and(|t| t.contains("rogit installer")) {
        let _ = fs::remove_file(fish);
    }
    Ok(())
}

/// Deletes the folder with rogit in it. Windows can't delete a program that's running, so there it goes a moment
/// after rogit exits.
fn remove_folder(bin: &std::path::Path) -> Result<(), String> {
    if !cfg!(windows) {
        return fs::remove_dir_all(bin).map_err(|e| format!("Couldn't delete {}: {e}", bin.display()));
    }
    let mut later = Command::new("cmd");
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        // cmd reads its command line itself, so it goes as written (escaped quotes would break the folder's path).
        // No console window for it.
        later.raw_arg(format!("/C ping 127.0.0.1 -n 3 > nul & rmdir /S /Q \"{}\"", bin.display())).creation_flags(0x0800_0000);
    }
    later.spawn().map(|_| ()).map_err(|e| format!("Couldn't delete {}: {e}", bin.display()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn compares_versions() {
        assert!(at_least("0.2.0", "0.2.0"));
        assert!(at_least("v0.10.0", "0.9.1"));
        assert!(!at_least("0.1.0", "0.2.0"));
    }
}
