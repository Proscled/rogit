mod project;
mod roblox;
mod server;

use std::path::PathBuf;
use std::{env, fs, process};

const PLUGIN: &str = include_str!("../plugin/RoGit.lua");

const HELP: &str = "RoGit: branches for your Roblox places' assets.

Usage:
  rogit serve [--port <port>]   Serve this project folder to the RoGit Studio plugin
  rogit plugin install          Install the RoGit plugin into Roblox Studio
  rogit --version               Show the version";

fn main() {
    let args: Vec<String> = env::args().skip(1).collect();
    let args: Vec<&str> = args.iter().map(String::as_str).collect();
    let result = match args.as_slice() {
        ["serve"] => serve(server::DEFAULT_PORT),
        ["serve", "--port", port] => port.parse().map_err(|_| format!("Invalid port: {port}")).and_then(serve),
        ["plugin", "install"] => install_plugin(),
        ["--version" | "-V"] => Ok(println!("rogit {}", env!("CARGO_PKG_VERSION"))),
        [] | ["help" | "--help" | "-h"] => Ok(println!("{HELP}")),
        _ => Err(format!("Unknown command.\n\n{HELP}")),
    };
    if let Err(message) = result {
        eprintln!("{message}");
        process::exit(1);
    }
}

fn serve(port: u16) -> Result<(), String> {
    let root = env::current_dir().map_err(|e| format!("Couldn't read the current folder: {e}"))?;
    server::serve(project::Project::new(root), port)
}

fn plugins_folder() -> Result<PathBuf, String> {
    if cfg!(windows) {
        let local = env::var("LOCALAPPDATA").map_err(|_| "LOCALAPPDATA isn't set.".to_owned())?;
        Ok(PathBuf::from(local).join("Roblox").join("Plugins"))
    } else {
        let home = env::var("HOME").map_err(|_| "HOME isn't set.".to_owned())?;
        Ok(PathBuf::from(home).join("Documents").join("Roblox").join("Plugins"))
    }
}

fn install_plugin() -> Result<(), String> {
    let folder = plugins_folder()?;
    fs::create_dir_all(&folder).map_err(|e| format!("Couldn't create {}: {e}", folder.display()))?;
    let target = folder.join("RoGit.lua");
    fs::write(&target, PLUGIN).map_err(|e| format!("Couldn't write {}: {e}", target.display()))?;
    println!("Installed the RoGit plugin to {}. Studio picks it up automatically.", target.display());
    Ok(())
}
