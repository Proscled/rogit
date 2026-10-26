//! Running `rogit serve` in the background whenever you're logged in, so nobody has to keep a terminal open: a
//! LaunchAgent on macOS, and on Windows a Run entry that starts it without a window.

use crate::project;
use std::path::Path;
use std::process::Command;
use std::{env, fs, thread, time::Duration};

const LABEL: &str = "com.rogit.serve";
const RUN_KEY: &str = r"HKCU\Software\Microsoft\Windows\CurrentVersion\Run";

/// Starts RoGit now (replacing one already running, so an update takes effect) and whenever you log in.
pub fn on() -> Result<(), String> {
    let exe = env::current_exe().map_err(|e| format!("Couldn't find rogit itself: {e}"))?;
    if cfg!(windows) { windows_on(&exe) } else { mac_on(&exe) }
}

/// Stops starting RoGit when you log in. One that's running keeps running until you log out.
pub fn off() -> Result<(), String> {
    if cfg!(windows) {
        let _ = Command::new("reg").args(["delete", RUN_KEY, "/v", "RoGit", "/f"]).output();
        let _ = fs::remove_file(project::home()?.join("start.vbs"));
    } else {
        let plist = launch_agent()?;
        let _ = Command::new("launchctl").args(["bootout", &format!("{}/{LABEL}", gui_domain()?)]).output();
        let _ = fs::remove_file(plist);
    }
    println!("RoGit won't start when you log in any more. Run rogit serve to start it yourself.");
    Ok(())
}

fn launch_agent() -> Result<std::path::PathBuf, String> {
    let home = env::var_os("HOME").ok_or("HOME isn't set.")?;
    Ok(Path::new(&home).join("Library").join("LaunchAgents").join(format!("{LABEL}.plist")))
}

fn gui_domain() -> Result<String, String> {
    let output = Command::new("id").arg("-u").output().map_err(|e| e.to_string())?;
    Ok(format!("gui/{}", String::from_utf8_lossy(&output.stdout).trim()))
}

fn xml(text: &str) -> String {
    text.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;")
}

fn mac_on(exe: &Path) -> Result<(), String> {
    let plist = launch_agent()?;
    let log = project::home()?.join("serve.log");
    fs::create_dir_all(plist.parent().unwrap()).map_err(|e| e.to_string())?;
    fs::create_dir_all(log.parent().unwrap()).map_err(|e| e.to_string())?;
    // Restarted if it stops with an error; not when it finds RoGit already running and steps aside.
    let text = format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>{LABEL}</string>
  <key>ProgramArguments</key><array><string>{exe}</string><string>serve</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>StandardOutPath</key><string>{log}</string>
  <key>StandardErrorPath</key><string>{log}</string>
</dict>
</plist>
"#,
        exe = xml(&exe.display().to_string()),
        log = xml(&log.display().to_string()),
    );
    fs::write(&plist, text).map_err(|e| format!("Couldn't write {}: {e}", plist.display()))?;
    let domain = gui_domain()?;
    let _ = Command::new("launchctl").args(["bootout", &format!("{domain}/{LABEL}")]).output();
    // Right after bootout, launchd can still be letting go of the old one.
    for attempt in 0..10 {
        let status = Command::new("launchctl").arg("bootstrap").arg(&domain).arg(&plist).output().map_err(|e| e.to_string())?;
        if status.status.success() {
            println!("RoGit is running in the background and starts when you log in (log: {}).", log.display());
            return Ok(());
        }
        if attempt == 9 {
            return Err(format!("Couldn't start RoGit in the background: {}", String::from_utf8_lossy(&status.stderr).trim()));
        }
        thread::sleep(Duration::from_millis(300));
    }
    unreachable!()
}

fn windows_on(exe: &Path) -> Result<(), String> {
    // wscript runs it without a console window, which rogit.exe would otherwise open at every login.
    let vbs = project::home()?.join("start.vbs");
    fs::create_dir_all(vbs.parent().unwrap()).map_err(|e| e.to_string())?;
    let command = format!("\"{}\" serve", exe.display()).replace('"', "\"\"");
    fs::write(&vbs, format!("CreateObject(\"WScript.Shell\").Run \"{command}\", 0, False\r\n")).map_err(|e| e.to_string())?;
    let run = format!("wscript.exe \"{}\"", vbs.display());
    let added = Command::new("reg").args(["add", RUN_KEY, "/v", "RoGit", "/t", "REG_SZ", "/d", &run, "/f"]).output().map_err(|e| e.to_string())?;
    if !added.status.success() {
        return Err(format!("Couldn't set RoGit to start when you log in: {}", String::from_utf8_lossy(&added.stderr).trim()));
    }
    // Replace whichever RoGit is running (an older version, after an update) with this one.
    let _ = Command::new("taskkill").args(["/F", "/IM", "rogit.exe", "/FI", &format!("PID ne {}", std::process::id())]).output();
    Command::new("wscript.exe").arg(&vbs).spawn().map_err(|e| format!("Couldn't start RoGit in the background: {e}"))?;
    println!("RoGit is running in the background and starts when you log in.");
    Ok(())
}
