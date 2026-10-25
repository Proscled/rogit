mod branches;
mod diff;
mod history;
mod live;
mod merge;
mod place;
mod project;
mod roblox;
mod server;
mod stage;

use std::path::PathBuf;
use std::io::{self, IsTerminal};
use std::time::{SystemTime, UNIX_EPOCH};
use std::{env, fs, process};

const PLUGIN: &str = include_str!("../plugin/RoGit.lua");

const HELP: &str = "RoGit: branches for your Roblox places' assets.

Usage:
  rogit serve [--port <port>]   Serve this project folder to the RoGit Studio plugin
  rogit diff [<branch>] [--json] Show what a branch changed, or list branches
  rogit plugin install          Install the RoGit plugin into Roblox Studio
  rogit --version               Show the version";

fn main() {
    let args: Vec<String> = env::args().skip(1).collect();
    let args: Vec<&str> = args.iter().map(String::as_str).collect();
    let result = match args.as_slice() {
        ["serve"] => serve(server::DEFAULT_PORT),
        ["serve", "--port", port] => port.parse().map_err(|_| format!("Invalid port: {port}")).and_then(serve),
        ["plugin", "install"] => install_plugin(),
        ["diff"] => diff(None, false),
        ["diff", name] => diff(Some(name), false),
        ["diff", name, "--json"] => diff(Some(name), true),
        // Development aid: plan a merge against a saved copy of main and print the plan.
        ["plan-merge", name, main] => plan_merge(name, main),
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

fn diff(name: Option<&str>, as_json: bool) -> Result<(), String> {
    let root = env::current_dir().map_err(|e| format!("Couldn't read the current folder: {e}"))?;
    let project = project::Project::new(root.clone());
    let branches = branches::Branches::new(root.join(project::DATA_DIR));
    let Some(name) = name else {
        let list = branches.list();
        if list.is_empty() {
            println!("No branches yet. Make one with New branch in the RoGit panel in main.");
        }
        for branch in list {
            println!("{}  (made {})", branch.name, ago(branch.created));
        }
        return Ok(());
    };
    // Like a merge: the saved branch file, or the copy from the last review in Studio if that's newer. Compared,
    // like a review, with the last update from main or else the starting point.
    let (current, source, time) = branches.newest(name)?;
    let (base, _, _) = branches.base(name, None, merge::last_update(&current).as_deref())?;
    let review = diff::compare(&base, &current, &project.rojo_paths());
    if as_json {
        println!("{}", serde_json::to_string(&review).map_err(|e| e.to_string())?);
        return Ok(());
    }
    print_review(name, &review, source, time);
    Ok(())
}

fn plan_merge(name: &str, main: &str) -> Result<(), String> {
    let root = env::current_dir().map_err(|e| format!("Couldn't read the current folder: {e}"))?;
    let project = project::Project::new(root.clone());
    let branches = branches::Branches::new(root.join(project::DATA_DIR));
    let main = place::read(std::path::Path::new(main))?;
    let (branch, _, _) = branches.newest(name)?;
    let (base, _, _) = branches.base(name, merge::last_merge(&main, name).as_deref(), merge::last_update(&branch).as_deref())?;
    let plan = merge::plan(&base, &branch, &main, &project.rojo_paths(), merge::Direction::Merge)?;
    println!("{}", serde_json::to_string(&plan).map_err(|e| e.to_string())?);
    Ok(())
}

fn ago(unix: u64) -> String {
    let now = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(unix);
    match now.saturating_sub(unix) {
        s if s < 60 => "just now".into(),
        s if s < 3600 => format!("{} min ago", s / 60),
        s if s < 86400 => format!("{} h ago", s / 3600),
        s => format!("{} days ago", s / 86400),
    }
}

fn print_review(name: &str, review: &diff::Review, source: &str, time: u64) {
    let color = io::stdout().is_terminal();
    let paint = |code: &str, text: &str| if color { format!("\x1b[{code}m{text}\x1b[0m") } else { text.to_owned() };
    let s = &review.summary;
    println!(
        "{}: {} added, {} removed, {} changed{}",
        paint("1", name), s.added, s.removed, s.changed,
        if source == "saved" { format!(" (branch file saved {})", ago(time)) } else { format!(" (as reviewed in Studio {})", ago(time)) }
    );
    if review.rows.is_empty() {
        println!("No changes since the branch started. Save the branch in Studio (Ctrl+S) to include recent edits.");
    }
    for row in &review.rows {
        let indent = "  ".repeat(row.depth);
        let (mark, code) = match row.status {
            diff::Status::Added => ("+", "32"),
            diff::Status::Removed => ("-", "31"),
            diff::Status::Changed => ("~", "33"),
            diff::Status::Context => (" ", "2"),
        };
        println!("{indent}{} {} {}", paint(code, mark), row.name, paint("2", &format!("({})", row.class)));
        for change in &row.changes {
            let line = if change.old.is_empty() {
                format!("{}: {}", change.name, change.new)
            } else {
                format!("{}: {} → {}", change.name, change.old, change.new)
            };
            println!("{indent}    {}", paint("2", &line));
        }
    }
    if review.truncated > 0 {
        println!("…and {} more rows.", review.truncated);
    }
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
