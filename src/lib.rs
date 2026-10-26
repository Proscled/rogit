//! RoGit: branches for Roblox places. Two programs use this: `rogit`, the command, and on Windows `rogit-background`,
//! which runs `rogit serve` without a console window when you log in.

mod autostart;
mod branches;
mod diff;
mod history;
mod live;
mod merge;
mod place;
mod project;
mod roblox;
mod server;
mod setup;
mod stage;
mod store;
#[cfg(windows)]
mod windows;

use std::io::{self, IsTerminal};
use std::time::{SystemTime, UNIX_EPOCH};
use std::{env, fs, process};

const PLUGIN: &str = include_str!("../plugin/RoGit.lua");

const HELP: &str = "RoGit: branches for your Roblox places.

Usage:
  rogit serve [--port <port>]    Run RoGit for Studio's RoGit panel (the installer starts it when you log in)
  rogit autostart [on|off]       Start RoGit when you log in (and now), or stop starting it
  rogit diff [<branch>] [--json] Show what a branch changed, or list every game's branches
  rogit update                   Update RoGit and its plugin to the newest version
  rogit uninstall                Remove RoGit and its plugin (your branches stay)
  rogit self-install             Install RoGit from where it was unpacked (the installers run this)
  rogit plugin install           Install the RoGit plugin into Roblox Studio
  rogit --version                Show the version";

/// The `rogit` command.
pub fn cli() {
    let args: Vec<String> = env::args().skip(1).collect();
    let args: Vec<&str> = args.iter().map(String::as_str).collect();
    let result = match args.as_slice() {
        ["serve"] => server::serve(None),
        ["serve", "--port", port] => port.parse().map_err(|_| format!("Invalid port: {port}")).and_then(|port| server::serve(Some(port))),
        ["autostart"] | ["autostart", "on"] => autostart::on(),
        ["autostart", "off"] => autostart::off(),
        ["plugin", "install"] => setup::install_plugin(),
        ["update"] => setup::update(),
        ["uninstall"] => setup::uninstall(),
        ["self-install"] => setup::self_install(),
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

/// The games set up so far, by name, with their branches.
/// `rogit serve` with no window to show anything in: the background program on Windows.
pub fn serve_in_background() {
    if server::serve(None).is_err() {
        process::exit(1);
    }
}

fn games() -> Result<Vec<(project::Game, branches::Branches)>, String> {
    let mut games: Vec<(project::Game, branches::Branches)> = fs::read_dir(project::games()?)
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|entry| {
            let config = project::Project::new(entry.path()).config().ok()??;
            Some((config.game, branches::Branches::new(entry.path())))
        })
        .collect();
    games.sort_by(|a, b| a.0.name.cmp(&b.0.name));
    Ok(games)
}

/// The branches of the game that has a branch called `name`.
fn branches_with(name: &str) -> Result<branches::Branches, String> {
    let mut found: Vec<(project::Game, branches::Branches)> = games()?.into_iter().filter(|(_, b)| b.get(name).is_some()).collect();
    match found.len() {
        0 => Err(format!("There's no branch called {name}.")),
        1 => Ok(found.remove(0).1),
        _ => Err(format!(
            "Several games have a branch called {name}: {}.",
            found.iter().map(|(game, _)| game.name.as_str()).collect::<Vec<_>>().join(", ")
        )),
    }
}

fn diff(name: Option<&str>, as_json: bool) -> Result<(), String> {
    let Some(name) = name else {
        let games = games()?;
        if games.is_empty() {
            println!("No games set up yet. Open a game's start place in Studio and click Init in the RoGit panel.");
        }
        for (game, branches) in games {
            println!("{}", game.name);
            let list = branches.list();
            if list.is_empty() {
                println!("  No branches yet.");
            }
            for branch in list {
                println!("  {}  (made {})", branch.name, ago(branch.created));
            }
        }
        return Ok(());
    };
    let branches = branches_with(name)?;
    // Like a merge: the saved branch file, or the copy from the last review in Studio if that's newer. Compared,
    // like a review, with the last update from main or else the starting point.
    let (current, source, time) = branches.newest(name)?;
    let (base, _, _) = branches.base(name, None, merge::last_update(&current).as_deref())?;
    let review = diff::compare(&base, &current);
    if as_json {
        println!("{}", serde_json::to_string(&review).map_err(|e| e.to_string())?);
        return Ok(());
    }
    print_review(name, &review, source, time);
    Ok(())
}

fn plan_merge(name: &str, main: &str) -> Result<(), String> {
    let branches = branches_with(name)?;
    let main = place::read(std::path::Path::new(main))?;
    let (branch, _, _) = branches.newest(name)?;
    let (base, _, _) = branches.base(name, merge::last_merge(&main, name).as_deref(), merge::last_update(&branch).as_deref())?;
    let plan = merge::plan(&base, &branch, &main, merge::Direction::Merge)?;
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

/// Checks on the Studio plugin's source, for mistakes Studio only reports when it loads the plugin.
#[cfg(test)]
mod plugin_checks {
    use super::PLUGIN;
    use std::collections::HashMap;

    /// A line without its comment and without what's inside its string literals.
    fn code(line: &str) -> String {
        let mut out = String::new();
        let mut quote: Option<char> = None;
        let mut chars = line.chars().peekable();
        while let Some(c) = chars.next() {
            match quote {
                Some(q) if c == '\\' => {
                    chars.next();
                    let _ = q;
                }
                Some(q) if c == q => {
                    quote = None;
                    out.push(c);
                }
                Some(_) => {}
                None if c == '"' || c == '\'' => {
                    quote = Some(c);
                    out.push(c);
                }
                None if c == '-' && chars.peek() == Some(&'-') => break,
                None => out.push(c),
            }
        }
        out
    }

    /// Names declared by top-level `local` lines, with their line numbers.
    fn top_level_locals() -> Vec<(String, usize)> {
        let mut names = Vec::new();
        for (number, line) in PLUGIN.lines().enumerate() {
            let Some(rest) = line.strip_prefix("local ") else { continue };
            let rest = rest.strip_prefix("function ").unwrap_or(rest);
            let declared = rest.split(['=', '(', ':']).next().unwrap_or_default();
            for name in declared.split(',') {
                let name = name.trim();
                if !name.is_empty() {
                    names.push((name.to_owned(), number));
                }
            }
        }
        names
    }

    #[test]
    fn stays_within_luaus_local_limit() {
        // Luau allows 200 locals in one scope; past that the plugin doesn't load at all. Sections that keep their
        // locals to themselves live in `do` blocks or functions.
        let count = top_level_locals().len();
        assert!(count <= 185, "the plugin has {count} top-level locals; move a section into a do block");
    }

    /// Every name bound anywhere (inner locals, function parameters, loop variables) and the first line it's bound on.
    fn bindings() -> HashMap<String, usize> {
        let mut first = HashMap::new();
        for (number, line) in PLUGIN.lines().enumerate() {
            let line = code(line);
            let mut bind = |names: &str| {
                for name in names.split(',') {
                    let name = name.split(':').next().unwrap_or_default().trim();
                    if !name.is_empty() && name.chars().all(|c| c.is_alphanumeric() || c == '_') {
                        first.entry(name.to_owned()).or_insert(number);
                    }
                }
            };
            for (i, _) in line.match_indices("local ") {
                let rest = &line[i + 6..];
                let rest = rest.strip_prefix("function ").unwrap_or(rest);
                bind(rest.split(['=', '(']).next().unwrap_or_default());
            }
            if let Some(i) = line.find("function") {
                if let (Some(open), Some(close)) = (line[i..].find('('), line[i..].find(')')) {
                    bind(&line[i + open + 1..i + close]);
                }
            }
            if let Some(rest) = line.trim_start().strip_prefix("for ") {
                bind(rest.split([' ', '=']).take_while(|w| *w != "in").collect::<Vec<_>>().join(",").as_str());
            }
        }
        first
    }

    #[test]
    fn uses_no_top_level_name_before_declaring_it() {
        // Using a local before its declaration reads a global of the same name instead (nil), silently.
        let declared: HashMap<String, usize> =
            top_level_locals().into_iter().fold(HashMap::new(), |mut first, (name, line)| {
                first.entry(name).or_insert(line);
                first
            });
        let bound = bindings();
        for (number, line) in PLUGIN.lines().enumerate() {
            let line = code(line);
            let words = line.split(|c: char| !(c.is_alphanumeric() || c == '_' || c == '.' || c == ':'));
            for word in words {
                // `a.b` and `a:b` use `a`; what comes after the dot is a field.
                let name = word.split(['.', ':']).next().unwrap_or_default();
                let Some(&at) = declared.get(name) else { continue };
                // A parameter or inner local of the same name bound earlier is a different variable.
                let shadowed = bound.get(name).is_some_and(|&b| b < at && b <= number);
                assert!(number >= at || shadowed, "line {}: `{name}` is used before its declaration on line {}", number + 1, at + 1);
            }
        }
    }
}
