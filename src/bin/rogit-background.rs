//! RoGit in the background, started when you log in on Windows: `rogit serve` built as a Windows program, which opens
//! no console window. (On macOS, launchd runs `rogit serve` itself.)

#![windows_subsystem = "windows"]

fn main() {
    rogit::serve_in_background();
}
