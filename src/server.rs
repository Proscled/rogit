//! `rogit serve`: the local server the Studio plugin talks to, like `rojo serve`.

use crate::branches::{self, Branches, Commit, Since};
use crate::diff;
use crate::history::{Event, History};
use crate::merge::{self, Direction};
use crate::project::{DATA_DIR, Game, Project};
use crate::roblox::Roblox;
use base64::Engine;
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};
use rbx_dom_weak::WeakDom;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tiny_http::{Header, Method, Request, Response, Server};

pub const DEFAULT_PORT: u16 = 34875;

type Reply = Result<Value, (u16, String)>;

struct State {
    project: Project,
    branches: Branches,
    roblox: Roblox,
    seen_places: HashSet<String>,
    history: History,
    /// Planned merges by branch: the merge's ID, the branch as it was merged (kept once the plugin applies it), and
    /// the rows for the history.
    planned: HashMap<String, (String, WeakDom, Value)>,
    /// Updates from main by branch.
    updates: HashMap<String, Update>,
    /// Planned reverts and restores by branch: what's brought back (for the history) and the rows.
    restores: HashMap<String, (String, Value)>,
    /// When each Studio window (plugin session) first checked in, in Unix seconds.
    sessions: HashMap<String, u64>,
    /// Whether a branch's unsaved copy differs from its saved file, by (file time, copy time).
    unsaved: HashMap<String, ((u64, u64), bool)>,
    /// What each branch's changes are measured from (its last commit, or where it last met main), kept in memory
    /// between refreshes: which one it is, the place, and its description.
    committed: HashMap<String, (String, WeakDom, Value)>,
}

/// A branch's update from main. Main's plugin sees the request when it next checks in and sends a copy of main.
struct Update {
    /// The ID main's copy is uploaded under.
    capture: String,
    asked: Instant,
    /// Whether main has been asked for its copy yet.
    offered: bool,
    /// The branch as it was when the update was asked for.
    branch: WeakDom,
    /// Once main's copy arrived: the update's ID, main's copy, and the plan for the branch.
    ready: Option<(String, WeakDom, Value)>,
    failed: Option<String>,
}

/// How long a branch waits for main to pick up an update request, and then for main's copy.
const MAIN_PICKUP: Duration = Duration::from_secs(30);
const MAIN_COPY: Duration = Duration::from_secs(180);

pub fn serve(project: Project, port: u16) -> Result<(), String> {
    let address = format!("127.0.0.1:{port}");
    let server = Server::http(&address).map_err(|e| format!("Couldn't listen on {address}: {e}"))?;
    let branches = Branches::new(project.root.join(DATA_DIR));
    let history = History::new(project.root.join(DATA_DIR));
    let mut state = State {
        project, branches, history, roblox: Roblox::new(), seen_places: HashSet::new(), planned: HashMap::new(),
        updates: HashMap::new(), restores: HashMap::new(), sessions: HashMap::new(), unsaved: HashMap::new(),
        committed: HashMap::new(),
    };
    println!("RoGit {} is serving {} on http://{address}", env!("CARGO_PKG_VERSION"), state.project.folder_name());
    match state.project.config() {
        Ok(Some(config)) => println!("Project: {} (main place {})", config.game.name, config.game.main_place_id),
        Ok(None) => println!("Not set up yet. Open your game's start place in Studio and click Init in the RoGit panel."),
        Err(e) => println!("Warning: {e}"),
    }
    for request in server.incoming_requests() {
        handle(&mut state, request);
    }
    Ok(())
}

fn handle(state: &mut State, mut request: Request) {
    let started = Instant::now();
    let mut body = String::new();
    let _ = request.as_reader().read_to_string(&mut body);
    let url = request.url().to_owned();
    let (path, query) = url.split_once('?').unwrap_or((&url, ""));
    let result = match (request.method(), path) {
        (Method::Get, "/api/rogit") => Ok(status(state, query)),
        (Method::Get, "/api/place") => place(state, query),
        (Method::Post, "/api/init") => init(state, &body),
        (Method::Post, "/api/init/done") => Ok(init_done(&body)),
        (Method::Post, "/api/upload") => upload(state, query, &body),
        (Method::Post, "/api/branches") => create_branch(state, &body),
        (Method::Post, "/api/branches/start") => starting_point(state, &body),
        (Method::Post, "/api/branches/open") => open_branch(state, &body),
        (Method::Post, "/api/branches/merge") => plan_merge(state, &body),
        (Method::Post, "/api/branches/merged") => merged(state, &body),
        (Method::Post, "/api/branches/update") => update_branch(state, &body),
        (Method::Get, "/api/branches/update") => update_status(state, query),
        (Method::Post, "/api/branches/updated") => updated(state, &body),
        (Method::Post, "/api/branches/cancel") => cancel(state, &body),
        (Method::Post, "/api/main/copy") => main_copy(state, &body),
        (Method::Post, "/api/branches/pin") => pin(state, &body),
        (Method::Post, "/api/branches/archive") => archive(state, &body),
        (Method::Get, "/api/history/rows") => history_rows(state, query),
        (Method::Post, "/api/branches/commit") => commit(state, &body),
        (Method::Post, "/api/branches/changes") => changes(state, &body),
        (Method::Post, "/api/branches/stage") => stage(state, &body),
        (Method::Post, "/api/branches/commit/view") => view_commit(state, &body),
        (Method::Post, "/api/branches/revert") => plan_revert(state, &body),
        (Method::Post, "/api/branches/restore") => plan_restore(state, &body),
        (Method::Post, "/api/branches/discard") => plan_discard(state, &body),
        (Method::Post, "/api/branches/restored") => restored(state, &body),
        (Method::Post, "/api/branches/unsaved/dismiss") => dismiss_unsaved(state, &body),
        _ => Err((404, "Not found.".to_owned())),
    };
    let (code, value) = match result {
        Ok(value) => (200, value),
        Err((code, message)) => (code, json!({ "error": message })),
    };
    // ROGIT_TRACE=1 prints every request with its size and time, for finding slow spots.
    if std::env::var_os("ROGIT_TRACE").is_some() {
        let since = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default();
        eprintln!("{}.{:03} {path} {} KB {} ms", since.as_secs() % 100, since.subsec_millis(), body.len() / 1024, started.elapsed().as_millis());
    }
    let header = Header::from_bytes(&b"Content-Type"[..], &b"application/json"[..]).unwrap();
    let _ = request.respond(Response::from_string(value.to_string()).with_status_code(code).with_header(header));
}

fn param<'a>(query: &'a str, name: &str) -> Option<&'a str> {
    query.split('&').find_map(|pair| pair.strip_prefix(name)?.strip_prefix('='))
}

/// Decodes `%XX` escapes and `+` (Studio's HttpService:UrlEncode escapes `-` and `.` too).
fn decode(value: &str) -> String {
    let hex = |b: u8| (b as char).to_digit(16).map(|d| d as u8);
    let bytes = value.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        let escaped = match bytes.get(i + 1..i + 3) {
            Some(&[high, low]) if bytes[i] == b'%' => hex(high).zip(hex(low)).map(|(h, l)| h * 16 + l),
            _ => None,
        };
        match (escaped, bytes[i]) {
            (Some(byte), _) => {
                out.push(byte);
                i += 3;
            }
            (None, b'+') => {
                out.push(b' ');
                i += 1;
            }
            (None, byte) => {
                out.push(byte);
                i += 1;
            }
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

#[cfg(test)]
mod tests {
    #[test]
    fn decodes_studio_url_encoding() {
        assert_eq!(super::decode("test%2D1%2Erbxl"), "test-1.rbxl");
        assert_eq!(super::decode("a+b%20c%"), "a b c%");
        assert_eq!(super::decode("%zz%E2%9C%93"), "%zz✓");
    }
}

fn number(query: &str, name: &str) -> Option<u64> {
    param(query, name)?.parse().ok()
}

fn json_body(body: &str) -> Result<Value, (u16, String)> {
    serde_json::from_str(body).map_err(|_| (400, "Invalid request.".to_owned()))
}

fn require_game(state: &State) -> Result<Game, (u16, String)> {
    match state.project.config() {
        Ok(Some(config)) => Ok(config.game),
        Ok(None) => Err((409, "This folder isn't set up yet. Click Init in your game's start place.".into())),
        Err(e) => Err((500, e.to_string())),
    }
}

fn status(state: &mut State, query: &str) -> Value {
    let place = param(query, "place").unwrap_or("?");
    let file = decode(param(query, "file").unwrap_or(""));
    let file = file.as_str();
    if state.seen_places.insert(format!("{place}/{file}")) {
        match place {
            "0" => println!("Studio connected from local file {file}"),
            _ => println!("Studio connected from place {place}"),
        }
    }
    // A branch file opens in Studio as a local file named <branch>.rbxl.
    let file_branch = file.strip_suffix(".rbxl").filter(|name| branches::valid_name(name));
    let branch = file_branch.and_then(|name| state.branches.get(name));
    // A window still showing a branch that was archived.
    let archived = file_branch
        .filter(|name| branch.is_none() && state.history.list().iter().any(|e| e.kind == "archive" && e.branch == *name))
        .map(str::to_owned);
    // Main sends a copy of itself when a branch is waiting to be updated from it.
    let is_main = state.project.config().ok().flatten().is_some_and(|c| c.game.main_place_id.to_string() == place);
    let copy = state
        .updates
        .iter_mut()
        .find(|(_, u)| is_main && !u.offered && u.ready.is_none() && u.asked.elapsed() < MAIN_PICKUP)
        .map(|(name, update)| {
            update.offered = true;
            json!({ "capture": update.capture, "branch": name })
        });
    let session = param(query, "session").unwrap_or("").to_owned();
    let opened = *state.sessions.entry(session).or_insert_with(unix_now);
    let (commits, unsaved) = match &branch {
        Some(b) => (Some(state.branches.commits(&b.name)), unsaved_work(state, &b.name, opened)),
        None => (None, None),
    };
    json!({
        "archived": archived,
        "copy": copy,
        "commits": commits,
        "unsaved": unsaved,
        "graph": graph(state),
        "server": "rogit",
        "version": env!("CARGO_PKG_VERSION"),
        "project": { "folder": state.project.folder_name(), "game": state.project.config().ok().flatten().map(|c| c.game) },
        "rojo": state.project.rojo_paths(),
        "branches": state.branches.list(),
        "branch": branch,
    })
}

/// Tells the plugin whether the open place is its experience's start place.
fn place(state: &mut State, query: &str) -> Reply {
    let (Some(game), Some(place)) = (number(query, "game"), number(query, "place")) else {
        return Err((400, "Missing game or place.".into()));
    };
    let experience = state.roblox.experience(game).map_err(|e| (502, e))?;
    Ok(json!({ "isMain": experience.start_place_id == place, "experience": experience.name }))
}

fn init(state: &mut State, body: &str) -> Reply {
    let request = json_body(body)?;
    let (Some(game), Some(place)) = (request["game"].as_u64(), request["place"].as_u64()) else {
        return Err((400, "Missing game or place.".into()));
    };
    if let Ok(Some(config)) = state.project.config() {
        if config.game.universe_id != game {
            return Err((409, format!("This folder is already set up for {}.", config.game.name)));
        }
    }
    let experience = state.roblox.experience(game).map_err(|e| (502, e))?;
    if experience.start_place_id != place {
        return Err((409, format!("Init only works in the start place of {}.", experience.name)));
    }
    let game = Game { name: experience.name, universe_id: game, main_place_id: place };
    let config = state.project.init(game).map_err(|e| (500, format!("Couldn't write the project files: {e}")))?;
    println!("Set up {} in {}", config.game.name, state.project.folder_name());
    Ok(json!({ "game": config.game, "rojo": state.project.rojo_paths() }))
}

fn init_done(body: &str) -> Value {
    let report: Value = serde_json::from_str(body).unwrap_or_default();
    println!(
        "Tagged {} objects in {:.1} s (skipped {} that Rojo or scripts own)",
        report["tagged"], report["seconds"].as_f64().unwrap_or_default(), report["skipped"]
    );
    json!({ "ok": true })
}

/// One base64 part of a service copy: `?capture=<id>&file=<Service>&part=<n>`.
fn upload(state: &mut State, query: &str, body: &str) -> Reply {
    let capture = param(query, "capture").filter(|id| branches::valid_capture(id));
    let service = param(query, "file").filter(|name| !name.is_empty() && name.chars().all(|c| c.is_ascii_alphanumeric()));
    let (Some(capture), Some(service), Some(part)) = (capture, service, number(query, "part")) else {
        return Err((400, "Invalid upload.".into()));
    };
    let bytes = base64::engine::general_purpose::STANDARD.decode(body.trim()).map_err(|_| (400, "Invalid upload data.".to_owned()))?;
    state.branches.store_part(capture, service, part, &bytes).map_err(|e| (500, e))?;
    Ok(json!({ "ok": true }))
}

fn capture_request(body: &str) -> Result<(String, String, Value), (u16, String)> {
    let request = json_body(body)?;
    let name = request["name"].as_str().unwrap_or_default().to_owned();
    let capture = request["capture"].as_str().filter(|id| branches::valid_capture(id)).ok_or((400, "Invalid copy.".to_owned()))?;
    Ok((name, capture.to_owned(), request["manifest"].clone()))
}

fn create_branch(state: &mut State, body: &str) -> Reply {
    require_game(state)?;
    let started = Instant::now();
    let (name, capture, manifest) = capture_request(body)?;
    let report = state.branches.create(&name, &capture, &manifest).map_err(|e| (409, e))?;
    state.committed.remove(&name);
    println!(
        "Created branch {name}: {} objects in {} ms ({} settings Studio doesn't let plugins read stay at their defaults)",
        report.objects, started.elapsed().as_millis(), report.settings_skipped
    );
    let created = state.branches.get(&name).map(|b| b.created).unwrap_or_else(unix_now);
    let event = Event { id: format!("n{created:x}"), kind: "create".into(), branch: name.clone(), time: created, summary: None, has_rows: false, message: None };
    let _ = state.history.add(event, None);
    state.branches.open(&name).map_err(|e| (500, e))?;
    Ok(json!({ "branch": state.branches.get(&name), "objects": report.objects }))
}

fn starting_point(state: &mut State, body: &str) -> Reply {
    let (name, capture, manifest) = capture_request(body)?;
    state.branches.set_starting_point(&name, &capture, &manifest).map_err(|e| (409, e))?;
    state.committed.remove(&name);
    println!("Recorded the starting point of {name}");
    Ok(json!({ "branch": state.branches.get(&name) }))
}

/// Unsaved work to offer when a branch opens: a copy RoGit made (autosave or review) before this Studio window opened,
/// newer than the saved file and different from it. Returns when it was made.
fn unsaved_work(state: &mut State, name: &str, opened: u64) -> Option<u64> {
    let copy = state.branches.unsaved_copy(name).filter(|time| *time < opened)?;
    let saved = std::fs::metadata(state.branches.file(name))
        .and_then(|m| m.modified())
        .ok()
        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
        .map(|d| d.as_secs())
        .unwrap_or_default();
    if let Some((times, differs)) = state.unsaved.get(name) {
        if *times == (saved, copy) {
            return differs.then_some(copy);
        }
    }
    let rojo = state.project.rojo_paths();
    let differs = match (crate::place::read(&state.branches.file(name)), state.branches.latest_place(name)) {
        (Ok(file), Ok(latest)) => !diff::compare(&file, &latest, &rojo).rows.is_empty(),
        _ => false,
    };
    state.unsaved.insert(name.to_owned(), ((saved, copy), differs));
    differs.then_some(copy)
}

fn since_words(since: Since) -> &'static str {
    match since {
        Since::Start => "it started",
        Since::Merge => "the last merge",
        Since::Update => "the last update from main",
    }
}

/// The branch named in a request, which must exist.
fn existing(state: &State, name: &str) -> Result<(), (u16, String)> {
    match branches::valid_name(name) && state.branches.get(name).is_some() {
        true => Ok(()),
        false => Err((404, format!("There's no branch called {name}."))),
    }
}

/// Puts an uploaded copy back together in memory and removes the upload.
fn take_upload(state: &State, capture: &str, manifest: &Value) -> Result<WeakDom, (u16, String)> {
    let upload = state.branches.upload_dir(capture);
    let place = crate::place::assemble(&upload, manifest);
    let _ = std::fs::remove_dir_all(&upload);
    place.map(|(dom, _)| dom).map_err(|e| (500, e))
}

fn unix_now() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or_default()
}

/// Plans merging a branch into main as it is in Studio right now (`capture` is main's copy).
fn plan_merge(state: &mut State, body: &str) -> Reply {
    require_game(state)?;
    let started = Instant::now();
    let (name, capture, manifest) = capture_request(body)?;
    existing(state, &name)?;
    let main = take_upload(state, &capture, &manifest)?;
    // Like git, a merge takes the branch's last commit; without commits, its newest copy.
    let commits = state.branches.commits(&name);
    let (branch, source, time) = match commits.first() {
        Some(last) => (state.branches.commit_place(&name, &last.id).map_err(|e| (500, e))?, "commit", last.time),
        None => state.branches.newest(&name).map_err(|e| (500, e))?,
    };
    let uncommitted = match commits.first() {
        Some(_) => match state.branches.newest(&name) {
            Ok((newest, _, _)) => diff::compare(&branch, &newest, &state.project.rojo_paths()).rows.iter().filter(|r| r.status != diff::Status::Context).count(),
            Err(_) => 0,
        },
        None => 0,
    };
    let (base, since, since_time) = state
        .branches
        .base(&name, merge::last_merge(&main, &name).as_deref(), merge::last_update(&branch).as_deref())
        .map_err(|e| (409, e))?;
    let plan = merge::plan(&base, &branch, &main, &state.project.rojo_paths(), Direction::Merge).map_err(|e| (500, e))?;
    let s = &plan.summary;
    println!(
        "Planned merging {name} ({source} branch, since {}): {} added, {} removed, {} changed, {} conflicts ({} ms)",
        since_words(since), s.added, s.removed, s.changed, s.conflicts, started.elapsed().as_millis()
    );
    let id = branches::new_id(Since::Merge);
    let reply = json!({
        "plan": plan, "source": source, "sourceTime": time, "since": since, "sinceTime": since_time, "merge": id,
        "commit": commits.first().map(|c| c.message.clone()), "uncommitted": uncommitted,
    });
    let rows = json!({ "rows": reply["plan"]["rows"], "truncated": reply["plan"]["truncated"] });
    state.planned.insert(name, (id, branch, rows));
    Ok(reply)
}

/// Prints what the plugin reports after applying a merge or an update.
fn print_report(heading: &str, report: &Value) {
    println!(
        "{heading}: {} operations applied, {} skipped by choice, {} problems",
        report["applied"], report["skipped"], report["failed"].as_array().map(Vec::len).unwrap_or_default()
    );
    for problem in report["failed"].as_array().into_iter().flatten().take(20) {
        println!("  {}", problem.as_str().unwrap_or_default());
    }
}

fn merged(state: &mut State, body: &str) -> Reply {
    let report = json_body(body)?;
    let name = report["name"].as_str().unwrap_or_default();
    state.branches.mark_merged(name).map_err(|e| (404, e))?;
    print_report(&format!("Merged {name} into main"), &report);
    // The plugin records the merge in main only when everything applied; then the next merge can start from here.
    let planned = state.planned.remove(name);
    if let Some(id) = report["merge"].as_str() {
        match &planned {
            Some((planned, branch, _)) if planned == id => {
                state.branches.keep_base(name, id, branch).map_err(|e| (500, format!("Couldn't keep the merged copy: {e}")))?;
            }
            _ => println!("  This merge wasn't planned by this rogit serve, so the next merge of {name} starts from earlier."),
        }
    }
    let rows = planned.map(|(_, _, rows)| rows);
    log_event(state, "merge", name, &report, rows);
    Ok(json!({ "branch": state.branches.get(name) }))
}

/// A branch asks to be updated from main (`capture` is the branch's copy). Main sends its copy when it next checks in.
fn update_branch(state: &mut State, body: &str) -> Reply {
    require_game(state)?;
    let (name, capture, manifest) = capture_request(body)?;
    existing(state, &name)?;
    let branch = state.branches.keep_latest(&name, &capture, &manifest).map_err(|e| (500, e))?;
    let capture = format!("c{:x}", SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_nanos());
    let update = Update { capture, asked: Instant::now(), offered: false, branch, ready: None, failed: None };
    state.updates.insert(name.clone(), update);
    println!("Updating {name} from main: waiting for main to send a copy");
    Ok(json!({ "waiting": true }))
}

/// Main's copy for a branch that's waiting to be updated: plan the update and keep it for the branch.
fn main_copy(state: &mut State, body: &str) -> Reply {
    let started = Instant::now();
    let request = json_body(body)?;
    let capture = request["capture"].as_str().unwrap_or_default();
    let name = state.updates.iter().find(|(_, u)| u.capture == capture).map(|(name, _)| name.clone());
    let Some(name) = name else {
        return Err((404, "No branch is waiting for this copy any more.".into()));
    };
    if let Some(failure) = request["failed"].as_str() {
        state.updates.get_mut(&name).unwrap().failed = Some(format!("Main couldn't send a copy: {failure}"));
        return Ok(json!({ "branch": name }));
    }
    let main = take_upload(state, capture, &request["manifest"])?;
    let rojo = state.project.rojo_paths();
    let update = state.updates.get_mut(&name).unwrap();
    let planned = state
        .branches
        .base(&name, merge::last_merge(&main, &name).as_deref(), merge::last_update(&update.branch).as_deref())
        .and_then(|(base, since, since_time)| {
            merge::plan(&base, &main, &update.branch, &rojo, Direction::Update).map(|plan| (plan, since, since_time))
        });
    match planned {
        Ok((plan, since, since_time)) => {
            let s = &plan.summary;
            println!(
                "Planned updating {name} from main (since {}): {} added, {} removed, {} changed, {} conflicts ({} ms)",
                since_words(since), s.added, s.removed, s.changed, s.conflicts, started.elapsed().as_millis()
            );
            let id = branches::new_id(Since::Update);
            let reply = json!({ "plan": plan, "since": since, "sinceTime": since_time, "mainTime": unix_now(), "update": id });
            update.ready = Some((id, main, reply));
        }
        Err(e) => update.failed = Some(e),
    }
    Ok(json!({ "branch": name }))
}

/// The branch checks on its update: still waiting, the plan, or what went wrong.
fn update_status(state: &mut State, query: &str) -> Reply {
    let name = decode(param(query, "name").unwrap_or(""));
    let Some(update) = state.updates.get(&name) else {
        return Err((404, "There's no update of this branch in progress.".into()));
    };
    if let Some((_, _, reply)) = &update.ready {
        return Ok(reply.clone());
    }
    let failure = match &update.failed {
        Some(failure) => Some(failure.clone()),
        None if !update.offered && update.asked.elapsed() > MAIN_PICKUP => Some(match state.project.config() {
            Ok(Some(config)) => format!("Main didn't answer. Open {} in Studio, then try again.", config.game.name),
            _ => "Main didn't answer. Open your game's start place in Studio, then try again.".into(),
        }),
        None if update.asked.elapsed() > MAIN_COPY => Some("Main took too long to send its copy. Try again.".into()),
        None => None,
    };
    match failure {
        Some(failure) => {
            state.updates.remove(&name);
            Err((409, failure))
        }
        None => Ok(json!({ "waiting": true, "offered": update.offered })),
    }
}

fn updated(state: &mut State, body: &str) -> Reply {
    let report = json_body(body)?;
    let name = report["name"].as_str().unwrap_or_default();
    state.branches.mark_updated(name).map_err(|e| (404, e))?;
    print_report(&format!("Updated {name} from main"), &report);
    // Recorded in the branch only when everything applied; then the next review, merge or update starts from here.
    let ready = state.updates.remove(name).and_then(|u| u.ready);
    if let Some(id) = report["update"].as_str() {
        match &ready {
            Some((planned, main, _)) if planned == id => {
                state.branches.keep_base(name, id, main).map_err(|e| (500, format!("Couldn't keep main's copy: {e}")))?;
            }
            _ => println!("  This update wasn't planned by this rogit serve, so the next one starts from earlier."),
        }
    }
    let rows = ready.map(|(_, _, reply)| json!({ "rows": reply["plan"]["rows"], "truncated": reply["plan"]["truncated"] }));
    log_event(state, "update", name, &report, rows);
    Ok(json!({ "branch": state.branches.get(name) }))
}

/// The plugin closed a merge or update without applying it.
fn cancel(state: &mut State, body: &str) -> Reply {
    let request = json_body(body)?;
    let name = request["name"].as_str().unwrap_or_default();
    match request["kind"].as_str() {
        Some("update") => state.updates.remove(name).map(|_| ()),
        Some("revert" | "restore") => state.restores.remove(name).map(|_| ()),
        _ => state.planned.remove(name).map(|_| ()),
    };
    Ok(json!({ "ok": true }))
}

fn open_branch(state: &mut State, body: &str) -> Reply {
    let request = json_body(body)?;
    let name = request["name"].as_str().unwrap_or_default();
    state.branches.open(name).map_err(|e| (404, e))?;
    Ok(json!({ "ok": true }))
}

/// Adds a merge, update, revert or restore the plugin applied to the history.
fn log_event(state: &State, kind: &str, branch: &str, report: &Value, rows: Option<Value>) {
    let summary = rows.as_ref().map(|r| {
        let count = |status: &str| r["rows"].as_array().map(|rows| rows.iter().filter(|row| row["status"] == status).count()).unwrap_or(0);
        json!({ "added": count("added"), "removed": count("removed"), "changed": count("changed"), "applied": report["applied"] })
    });
    let event = Event { id: branches::new_id(Since::Merge), kind: kind.into(), branch: branch.into(), time: unix_now(), summary, has_rows: false, message: None };
    if let Err(e) = state.history.add(event, rows) {
        println!("  Couldn't add this to the history: {e}");
    }
}

fn pin(state: &mut State, body: &str) -> Reply {
    let request = json_body(body)?;
    let name = request["name"].as_str().unwrap_or_default();
    existing(state, name)?;
    state.branches.set_pinned(name, request["pinned"].as_bool().unwrap_or(false)).map_err(|e| (500, e))?;
    Ok(json!({ "branches": state.branches.list() }))
}

/// Deletes a branch (closing it in Studio first) and notes it in the history.
fn archive(state: &mut State, body: &str) -> Reply {
    let request = json_body(body)?;
    let name = request["name"].as_str().unwrap_or_default().to_owned();
    existing(state, &name)?;
    state.planned.remove(&name);
    state.updates.remove(&name);
    state.restores.remove(&name);
    state.committed.remove(&name);
    let closed = state.branches.archive(&name).map_err(|e| (500, e))?;
    println!("Archived {name}{}", if closed > 0 { " (closed it in Studio)" } else { "" });
    let event = Event { id: branches::new_id(Since::Merge), kind: "archive".into(), branch: name, time: unix_now(), summary: None, has_rows: false, message: None };
    let _ = state.history.add(event, None);
    Ok(json!({ "branches": state.branches.list() }))
}

fn history_rows(state: &mut State, query: &str) -> Reply {
    state.history.rows(param(query, "id").unwrap_or("")).map_err(|e| (404, e))
}

/// What the branch's uncommitted changes are measured from: its last commit, or (before the first commit) where it
/// last met main. Returns the place and a description for the plugin.
fn committed(state: &State, name: &str, live: &WeakDom) -> Result<(WeakDom, Value), (u16, String)> {
    match state.branches.commits(name).first() {
        Some(last) => {
            let dom = state.branches.commit_place(name, &last.id).map_err(|e| (500, e))?;
            Ok((dom, json!({ "kind": "commit", "message": last.message, "time": last.time })))
        }
        None => {
            let (dom, since, time) = state.branches.base(name, None, merge::last_update(live).as_deref()).map_err(|e| (409, e))?;
            Ok((dom, json!({ "kind": since, "time": time })))
        }
    }
}

/// The staged keys that are still among the changes.
fn staged_now(state: &State, name: &str, review: &diff::Review) -> Vec<String> {
    let keys: HashSet<&str> = review.rows.iter().filter(|r| r.status != diff::Status::Context).map(|r| r.key.as_str()).collect();
    state.branches.staged(name).into_iter().filter(|k| keys.contains(k.as_str())).collect()
}

/// The branch as it is in Studio right now (`capture`): kept as its autosave copy, and compared with its last commit.
fn changes(state: &mut State, body: &str) -> Reply {
    let (name, capture, manifest) = capture_request(body)?;
    existing(state, &name)?;
    let live = state.branches.keep_latest(&name, &capture, &manifest).map_err(|e| (500, e))?;
    // Refreshes come often, so the place they're measured from stays in memory until it changes.
    let which = match state.branches.commits(&name).first() {
        Some(last) => last.id.clone(),
        None => format!("base:{}", merge::last_update(&live).unwrap_or_default()),
    };
    if state.committed.get(&name).is_none_or(|(cached, _, _)| *cached != which) {
        let (dom, since) = committed(state, &name, &live)?;
        state.committed.insert(name.clone(), (which, dom, since));
    }
    let (_, base, since) = &state.committed[&name];
    let review = diff::compare(base, &live, &state.project.rojo_paths());
    let since = since.clone();
    let staged = staged_now(state, &name, &review);
    Ok(json!({ "changes": review, "staged": staged, "since": since, "time": unix_now() }))
}

fn stage(state: &mut State, body: &str) -> Reply {
    let request = json_body(body)?;
    let name = request["name"].as_str().unwrap_or_default();
    existing(state, name)?;
    let keys: Vec<String> = request["keys"].as_array().into_iter().flatten().filter_map(|k| k.as_str().map(str::to_owned)).collect();
    state.branches.set_staged(name, &keys).map_err(|e| (500, e))?;
    Ok(json!({ "staged": keys }))
}

/// Commits the branch as it is in Studio right now (`capture`), like `git commit`: only the staged changes when some
/// are staged, otherwise all of them. `auto` commits everything (after a pull or a revert).
fn commit(state: &mut State, body: &str) -> Reply {
    let started = Instant::now();
    let (name, capture, manifest) = capture_request(body)?;
    existing(state, &name)?;
    let request = json_body(body)?;
    let message = request["message"].as_str().unwrap_or("").trim().chars().take(100).collect::<String>();
    let auto = request["auto"].as_bool().unwrap_or(false);
    let upload = state.branches.upload_dir(&capture);
    let result = (|| {
        let live = crate::place::assemble(&upload, &manifest).map_err(|e| (500, e))?.0;
        let (previous, _) = committed(state, &name, &live)?;
        let rojo = state.project.rojo_paths();
        let all = diff::compare(&previous, &live, &rojo);
        let staged: HashSet<String> = if auto { HashSet::new() } else { staged_now(state, &name, &all).into_iter().collect() };
        let snapshot = if staged.is_empty() {
            crate::place::assemble(&upload, &manifest).map_err(|e| (500, e))?.0
        } else {
            let copy = crate::place::assemble(&upload, &manifest).map_err(|e| (500, e))?.0;
            crate::stage::partial(&previous, copy, &all.rows, &staged, &rojo)
        };
        let summary = diff::compare(&previous, &snapshot, &rojo).summary;
        if summary == diff::Summary::default() {
            return Err((409, "Nothing to commit.".to_owned()));
        }
        let count = state.branches.commits(&name).len();
        let message = if message.is_empty() { format!("Commit {}", count + 1) } else { message };
        let id = format!("c{:x}", SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_nanos());
        let commit = Commit { id, message, time: unix_now(), summary, auto };
        state.branches.add_commit(&name, &snapshot, &commit).map_err(|e| (500, e))?;
        state.branches.set_staged(&name, &[]).map_err(|e| (500, e))?;
        if !auto {
            let event = Event {
                id: commit.id.clone(), kind: "commit".into(), branch: name.clone(), time: commit.time,
                summary: serde_json::to_value(&commit.summary).ok(), has_rows: false, message: Some(commit.message.clone()),
            };
            let _ = state.history.add(event, None);
        }
        let left = diff::compare(&snapshot, &live, &rojo);
        Ok((commit, left))
    })();
    let _ = std::fs::remove_dir_all(&upload);
    let (commit, left) = result?;
    println!("Committed {name}: \"{}\" ({} ms)", commit.message, started.elapsed().as_millis());
    let since = json!({ "kind": "commit", "message": commit.message, "time": commit.time });
    Ok(json!({ "commit": commit, "commits": state.branches.commits(&name), "changes": left, "staged": [], "since": since }))
}

/// Everything that happened, newest first, for the plugin's graph: branches made, commits, merges, pulls, reverts
/// and archives. Branches and commits from before the history kept them are added from their own records.
fn graph(state: &State) -> Vec<Event> {
    let mut events = state.history.list();
    let known: HashSet<String> = events.iter().map(|e| e.id.clone()).collect();
    let made: HashSet<String> = events.iter().filter(|e| e.kind == "create").map(|e| e.branch.clone()).collect();
    for branch in state.branches.list() {
        if !made.contains(&branch.name) {
            let id = format!("n{:x}", branch.created);
            events.push(Event { id, kind: "create".into(), branch: branch.name.clone(), time: branch.created, summary: None, has_rows: false, message: None });
        }
        for commit in state.branches.commits(&branch.name).into_iter().filter(|c| !c.auto && !known.contains(&c.id)) {
            events.push(Event {
                id: commit.id, kind: "commit".into(), branch: branch.name.clone(), time: commit.time,
                summary: serde_json::to_value(&commit.summary).ok(), has_rows: false, message: Some(commit.message),
            });
        }
    }
    events.sort_by(|a, b| b.time.cmp(&a.time));
    events.truncate(80);
    events
}

/// What a commit changed: compared with the commit before it, or with where the branch started.
fn view_commit(state: &mut State, body: &str) -> Reply {
    let request = json_body(body)?;
    let name = request["name"].as_str().unwrap_or_default();
    existing(state, name)?;
    let id = request["id"].as_str().unwrap_or_default();
    let commits = state.branches.commits(name);
    let position = commits.iter().position(|c| c.id == id).ok_or((404, "That commit doesn't exist any more.".to_owned()))?;
    let this = state.branches.commit_place(name, id).map_err(|e| (500, e))?;
    let before = match commits.get(position + 1) {
        Some(previous) => state.branches.commit_place(name, &previous.id),
        None => state.branches.starting_point(name),
    }
    .map_err(|e| (500, e))?;
    Ok(json!({ "review": diff::compare(&before, &this, &state.project.rojo_paths()), "commit": commits[position] }))
}

/// Plans bringing an earlier copy of the branch back into the branch as it is now (`current`). The reply carries
/// the copy's update record, which the plugin sets too, so later merges and updates measure from the right place.
fn plan_restore_of(state: &mut State, name: &str, kind: &str, copy: &WeakDom, current: &WeakDom) -> Reply {
    let plan = merge::plan(current, copy, current, &state.project.rojo_paths(), Direction::Restore).map_err(|e| (500, e))?;
    let rows = json!({ "rows": plan.rows, "truncated": plan.truncated });
    let s = &plan.summary;
    println!("Planned {kind} of {name}: {} added, {} removed, {} changed", s.added, s.removed, s.changed);
    let reply = json!({ "plan": plan, "record": merge::last_update(copy).unwrap_or_default() });
    state.restores.insert(name.to_owned(), (kind.to_owned(), rows));
    Ok(reply)
}

/// Plans turning the branch (as it is in Studio, `capture`) back into one of its commits.
fn plan_revert(state: &mut State, body: &str) -> Reply {
    let (name, capture, manifest) = capture_request(body)?;
    existing(state, &name)?;
    let id = json_body(body)?["id"].as_str().unwrap_or_default().to_owned();
    let current = take_upload(state, &capture, &manifest)?;
    let copy = state.branches.commit_place(&name, &id).map_err(|e| (404, e))?;
    plan_restore_of(state, &name, "revert", &copy, &current)
}

/// Plans discarding some uncommitted changes (`keys`), like VS Code's Discard Changes: the branch as it is in Studio
/// (`capture`), with those changes put back the way its last commit had them. Nothing goes in the history.
fn plan_discard(state: &mut State, body: &str) -> Reply {
    let (name, capture, manifest) = capture_request(body)?;
    existing(state, &name)?;
    let discard: HashSet<String> =
        json_body(body)?["keys"].as_array().into_iter().flatten().filter_map(|k| k.as_str().map(str::to_owned)).collect();
    let upload = state.branches.upload_dir(&capture);
    let result = (|| {
        let current = crate::place::assemble(&upload, &manifest).map_err(|e| (500, e))?.0;
        let (previous, _) = committed(state, &name, &current)?;
        let rojo = state.project.rojo_paths();
        let rows = diff::compare(&previous, &current, &rojo).rows;
        let keep: HashSet<String> =
            rows.iter().filter(|r| r.status != diff::Status::Context && !discard.contains(&r.key)).map(|r| r.key.clone()).collect();
        let copy = crate::place::assemble(&upload, &manifest).map_err(|e| (500, e))?.0;
        let wanted = crate::stage::partial(&previous, copy, &rows, &keep, &rojo);
        let plan = merge::plan(&current, &wanted, &current, &rojo, Direction::Restore).map_err(|e| (500, e))?;
        Ok(json!({ "plan": plan }))
    })();
    let _ = std::fs::remove_dir_all(&upload);
    result
}

/// Plans bringing back unsaved work (the newest copy RoGit made) into the branch as it is in Studio (`capture`).
/// Measured against the window as it is, so work that's still there isn't added twice.
fn plan_restore(state: &mut State, body: &str) -> Reply {
    let (name, capture, manifest) = capture_request(body)?;
    existing(state, &name)?;
    let current = take_upload(state, &capture, &manifest)?;
    let copy = state.branches.latest_place(&name).map_err(|e| (500, e))?;
    plan_restore_of(state, &name, "restore", &copy, &current)
}

fn restored(state: &mut State, body: &str) -> Reply {
    let report = json_body(body)?;
    let name = report["name"].as_str().unwrap_or_default().to_owned();
    existing(state, &name)?;
    let (kind, rows) = state.restores.remove(&name).ok_or((409, "Nothing was planned for this branch.".to_owned()))?;
    print_report(&format!("{} {name}", if kind == "revert" { "Reverted" } else { "Restored unsaved work in" }), &report);
    if kind == "restore" {
        let _ = state.branches.dismiss_unsaved(&name);
    }
    log_event(state, &kind, &name, &report, Some(rows));
    Ok(json!({ "branch": state.branches.get(&name) }))
}

fn dismiss_unsaved(state: &mut State, body: &str) -> Reply {
    let request = json_body(body)?;
    let name = request["name"].as_str().unwrap_or_default();
    existing(state, name)?;
    state.branches.dismiss_unsaved(name).map_err(|e| (500, e))?;
    Ok(json!({ "ok": true }))
}
