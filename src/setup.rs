//! Installing RoGit (from where an installer unpacked it), its Studio plugin, updating it, and removing it again. All
//! of it happens here, in rogit itself; the install scripts only download a release and run `rogit self-install`.

use crate::{autostart, project};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use std::{env, fs};

/// rogit's programs: on Windows, rogit-background.exe runs RoGit at login without a window.
const PROGRAMS: &[&str] = if cfg!(windows) { &["rogit.exe", "rogit-background.exe"] } else { &["rogit"] };

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

/// Installs RoGit from wherever it was unpacked: its programs go to RoGit's `bin` folder, which goes on PATH, the
/// plugin goes into Studio, and RoGit starts in the background, now and whenever you log in (unless
/// ROGIT_NO_AUTOSTART is set). Running it again updates an installed RoGit.
pub fn self_install() -> Result<(), String> {
    let here = env::current_exe().map_err(|e| format!("Couldn't find rogit itself: {e}"))?;
    let bin = project::home()?.join("bin");
    fs::create_dir_all(&bin).map_err(|e| format!("Couldn't create {}: {e}", bin.display()))?;
    for program in PROGRAMS {
        let from = here.with_file_name(program);
        if !from.exists() {
            return Err(format!("{program} isn't next to rogit; unpack the whole release."));
        }
        place(&from, &bin.join(program))?;
    }
    let changed = add_to_path(&bin)?;
    install_plugin()?;
    let installed = bin.join(PROGRAMS[0]);
    let started = env::var_os("ROGIT_NO_AUTOSTART").is_none() && autostart::enable(&installed).map_err(|e| println!("{e}")).is_ok();
    println!();
    println!("RoGit {} is installed in {}.", env!("CARGO_PKG_VERSION"), bin.display());
    if !changed.is_empty() {
        println!("Added it to your PATH ({}). Terminals opened from now on find rogit.", changed.join(", "));
    }
    if !started {
        println!("Start RoGit with: rogit serve");
    }
    println!();
    println!("Next, in Roblox Studio: open your game's start place, then Plugins > RoGit, and click Init.");
    println!("Later, rogit update updates RoGit and rogit uninstall removes it.");
    Ok(())
}

/// Puts `from` at `to`. A running program can't be replaced, but it can be renamed: the one at `to` moves aside (and
/// the next install removes it), so this works while RoGit runs.
fn place(from: &Path, to: &Path) -> Result<(), String> {
    if from.canonicalize().ok() == to.canonicalize().ok() && to.exists() {
        return Ok(());
    }
    let name = to.file_name().unwrap().to_string_lossy().into_owned();
    let folder = to.parent().unwrap();
    for entry in fs::read_dir(folder).into_iter().flatten().flatten() {
        if entry.file_name().to_string_lossy().starts_with(&format!("{name}.old-")) {
            let _ = fs::remove_file(entry.path());
        }
    }
    // Copied in under a new name first, so `to` is never half written.
    let incoming = folder.join(format!("{name}.new"));
    fs::copy(from, &incoming).map_err(|e| format!("Couldn't copy {name} into {}: {e}", folder.display()))?;
    if to.exists() && cfg!(windows) {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_millis();
        fs::rename(to, folder.join(format!("{name}.old-{stamp}"))).map_err(|e| format!("Couldn't replace {}: {e}", to.display()))?;
    }
    fs::rename(&incoming, to).map_err(|e| format!("Couldn't replace {}: {e}", to.display()))
}

/// Whether version `a` ("1.2.3") is at least `b`.
pub fn at_least(a: &str, b: &str) -> bool {
    let parts = |v: &str| v.trim_start_matches('v').split('.').map(|n| n.parse::<u64>().unwrap_or(0)).collect::<Vec<_>>();
    parts(a) >= parts(b)
}

fn agent(timeout: u64) -> ureq::Agent {
    ureq::Agent::config_builder().timeout_global(Some(Duration::from_secs(timeout))).build().into()
}

/// The newest release on GitHub, like "0.3.0".
pub fn latest_release() -> Result<String, String> {
    let repo = env!("CARGO_PKG_REPOSITORY").trim_start_matches("https://github.com/");
    let text = agent(10)
        .get(&format!("https://api.github.com/repos/{repo}/releases/latest"))
        .call()
        .and_then(|mut res| res.body_mut().read_to_string())
        .map_err(|e| format!("Couldn't reach GitHub: {e}"))?;
    let release: serde_json::Value = serde_json::from_str(&text).map_err(|e| e.to_string())?;
    release["tag_name"].as_str().map(|tag| tag.trim_start_matches('v').to_owned()).ok_or("GitHub has no release of RoGit.".into())
}

/// Downloads the newest release for this computer and installs it with its own `self-install`, which also updates
/// the plugin and restarts RoGit.
pub fn update() -> Result<(), String> {
    let current = env!("CARGO_PKG_VERSION");
    let latest = latest_release()?;
    if at_least(current, &latest) {
        println!("RoGit {current} is the newest version.");
        return Ok(());
    }
    println!("Updating RoGit {current} to {latest}...");
    let platform = match (env::consts::OS, env::consts::ARCH) {
        ("windows", _) => "windows-x86_64",
        ("macos", "aarch64") => "macos-aarch64",
        ("macos", _) => "macos-x86_64",
        (os, arch) => return Err(format!("RoGit has no release for {os} on {arch}.")),
    };
    let repo = env!("CARGO_PKG_REPOSITORY");
    let url = format!("{repo}/releases/download/v{latest}/rogit-{platform}.zip");
    let zip = agent(300)
        .get(&url)
        .call()
        .and_then(|mut res| res.body_mut().with_config().limit(200 * 1024 * 1024).read_to_vec())
        .map_err(|e| format!("Couldn't download {url}: {e}"))?;
    let unpacked = env::temp_dir().join(format!("rogit-{latest}-{}", std::process::id()));
    let _ = fs::remove_dir_all(&unpacked);
    zip::ZipArchive::new(std::io::Cursor::new(zip))
        .and_then(|mut archive| archive.extract(&unpacked))
        .map_err(|e| format!("Couldn't unpack the download: {e}"))?;
    let status = Command::new(unpacked.join(PROGRAMS[0])).arg("self-install").status();
    let _ = fs::remove_dir_all(&unpacked);
    match status {
        Ok(status) if status.success() => Ok(()),
        Ok(_) => Err("The new version couldn't install itself.".into()),
        Err(e) => Err(format!("Couldn't run the new version: {e}")),
    }
}

/// Removes RoGit: stops it, stops it starting when you log in, and removes the plugin, the program and its PATH
/// entry. Every game's branches stay where they are.
pub fn uninstall() -> Result<(), String> {
    let home = project::home()?;
    autostart::disable()?;
    autostart::stop_running();
    let plugin = plugins_folder()?.join("RoGit.lua");
    if plugin.exists() {
        fs::remove_file(&plugin).map_err(|e| format!("Couldn't remove {}: {e}", plugin.display()))?;
    }
    let bin = home.join("bin");
    remove_from_path(&bin)?;
    for leftover in ["env", "serve.log", "start.vbs"] {
        let _ = fs::remove_file(home.join(leftover));
    }
    // The programs themselves, when they're the installer's copies. One installed some other way (cargo) stays.
    let exe = env::current_exe().ok().and_then(|e| e.canonicalize().ok());
    let installed = exe.as_ref().is_some_and(|e| bin.canonicalize().is_ok_and(|b| e.starts_with(b)));
    if installed {
        // Windows can't delete a program that's running, but it can move it: this one goes to the temp folder,
        // which Windows clears out.
        if cfg!(windows) {
            if let Some(exe) = &exe {
                let _ = fs::rename(exe, env::temp_dir().join(format!("rogit-uninstalled-{}.exe", std::process::id())));
            }
        }
        fs::remove_dir_all(&bin).map_err(|e| format!("Couldn't delete {}: {e}", bin.display()))?;
    } else if let Some(exe) = exe {
        println!("This rogit ({}) wasn't put there by the installer; delete it yourself.", exe.display());
    }
    println!("RoGit is uninstalled.");
    println!("Your branches are still in {}. Delete that folder if you don't need them.", project::games()?.display());
    Ok(())
}

/// The line the installer adds to shell profiles on macOS, and the file it loads.
const PROFILE_LINE: &str = ". \"$HOME/.rogit/env\"";

/// Shell profiles that load RoGit's PATH on macOS: zsh's always, and the one bash reads.
fn profiles() -> Result<Vec<PathBuf>, String> {
    let user = env::var_os("HOME").map(PathBuf::from).ok_or("HOME isn't set.")?;
    let zdotdir = env::var_os("ZDOTDIR").map(PathBuf::from).unwrap_or_else(|| user.clone());
    let mut profiles = vec![zdotdir.join(".zshenv")];
    // bash login shells read only the first of these that exists.
    let bash = [".bash_profile", ".bash_login", ".profile"].iter().map(|f| user.join(f)).find(|f| f.exists());
    let uses_bash = env::var("SHELL").is_ok_and(|s| s.ends_with("/bash"));
    match bash {
        Some(profile) => profiles.push(profile),
        None if uses_bash => profiles.push(user.join(".bash_profile")),
        None => {}
    }
    if user.join(".bashrc").exists() {
        profiles.push(user.join(".bashrc"));
    }
    Ok(profiles)
}

/// Puts `bin` on PATH for terminals opened from now on. Returns what changed, for the summary.
fn add_to_path(bin: &Path) -> Result<Vec<String>, String> {
    #[cfg(windows)]
    {
        let changed = crate::windows::set_on_path(&bin.display().to_string(), true)?;
        return Ok(if changed { vec!["your user PATH".to_owned()] } else { vec![] });
    }
    #[cfg(not(windows))]
    {
        let home = bin.parent().unwrap();
        // One small file that shells load, so the profiles get a single line that never changes.
        fs::write(
            home.join("env"),
            "# Added by the RoGit installer: puts rogit on your PATH.\ncase \":$PATH:\" in\n    *\":$HOME/.rogit/bin:\"*) ;;\n    *) export PATH=\"$HOME/.rogit/bin:$PATH\" ;;\nesac\n",
        )
        .map_err(|e| e.to_string())?;
        let user = env::var_os("HOME").map(PathBuf::from).ok_or("HOME isn't set.")?;
        let mut changed = Vec::new();
        for profile in profiles()? {
            let text = fs::read_to_string(&profile).unwrap_or_default();
            if text.lines().any(|line| line == PROFILE_LINE) {
                continue;
            }
            fs::write(&profile, format!("{text}\n{PROFILE_LINE}\n")).map_err(|e| format!("Couldn't update {}: {e}", profile.display()))?;
            changed.push(format!("~/{}", profile.strip_prefix(&user).unwrap_or(&profile).display()));
        }
        let fish = user.join(".config").join("fish");
        if fish.is_dir() || env::var("SHELL").is_ok_and(|s| s.ends_with("/fish")) {
            fs::create_dir_all(fish.join("conf.d")).map_err(|e| e.to_string())?;
            fs::write(
                fish.join("conf.d").join("rogit.fish"),
                "# Added by the RoGit installer: puts rogit on your PATH.\ncontains -- $HOME/.rogit/bin $PATH; or set -gx PATH $HOME/.rogit/bin $PATH\n",
            )
            .map_err(|e| e.to_string())?;
        }
        Ok(changed)
    }
}

/// Undoes `add_to_path`.
fn remove_from_path(bin: &Path) -> Result<(), String> {
    #[cfg(windows)]
    {
        crate::windows::set_on_path(&bin.display().to_string(), false)?;
        return Ok(());
    }
    #[cfg(not(windows))]
    {
        let _ = bin;
        let user = env::var_os("HOME").map(PathBuf::from).ok_or("HOME isn't set.")?;
        let zdotdir = env::var_os("ZDOTDIR").map(PathBuf::from).unwrap_or_else(|| user.clone());
        let candidates = [zdotdir.join(".zshenv"), user.join(".bash_profile"), user.join(".bash_login"), user.join(".profile"), user.join(".bashrc")];
        for profile in candidates {
            let Ok(text) = fs::read_to_string(&profile) else { continue };
            if !text.lines().any(|line| line == PROFILE_LINE) {
                continue;
            }
            // The installer added a line break, the line and another; taking them out leaves the file as it was.
            let kept = text.replace(&format!("\n{PROFILE_LINE}\n"), "").replace(&format!("{PROFILE_LINE}\n"), "");
            fs::write(&profile, kept).map_err(|e| format!("Couldn't update {}: {e}", profile.display()))?;
        }
        let fish = user.join(".config").join("fish").join("conf.d").join("rogit.fish");
        if fs::read_to_string(&fish).is_ok_and(|t| t.contains("RoGit installer") || t.contains("rogit installer")) {
            let _ = fs::remove_file(fish);
        }
        Ok(())
    }
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

    #[test]
    fn places_a_program_over_an_older_one() {
        let dir = env::temp_dir().join(format!("rogit-place-test-{}", std::process::id()));
        fs::create_dir_all(dir.join("new")).unwrap();
        fs::write(dir.join("new").join("rogit"), "new").unwrap();
        fs::write(dir.join("rogit"), "old").unwrap();
        place(&dir.join("new").join("rogit"), &dir.join("rogit")).unwrap();
        assert_eq!(fs::read_to_string(dir.join("rogit")).unwrap(), "new");
        // Placing it where it already is changes nothing.
        place(&dir.join("rogit"), &dir.join("rogit")).unwrap();
        assert_eq!(fs::read_to_string(dir.join("rogit")).unwrap(), "new");
        fs::remove_dir_all(dir).unwrap();
    }
}
