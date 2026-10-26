//! `rogit serve`: the local server the Studio plugin talks to. One serves every game; each game's data is in its own
//! folder (see `project`).

use crate::branches::{self, Branches, Commit, Since};
use crate::diff;
use crate::history::{Event, History};
use crate::live::Live;
use crate::merge::{self, Direction};
use crate::project::{self, Game, Project};
use crate::roblox::Roblox;
use base64::Engine;
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};
use rbx_dom_weak::WeakDom;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tiny_http::{Header, Method, Request, Response, Server};

/// The ports rogit serve can use: the first free one. The plugin looks through them for it.
pub const PORTS: std::ops::RangeInclusive<u16> = 34875..=34879;

type Reply = Result<Value, (u16, String)>;

/// One game: its data folder and what's going on with its branches.
struct State {
    /// The game's ID (Roblox's universe ID).
    id: u64,
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
    /// between refreshes.
    committed: HashMap<String, Committed>,
    /// Each open branch as it is in Studio, kept current by the plugin's patches.
    live: HashMap<String, Live>,
    /// Branches with unsaved work waiting to be restored: their autosave isn't overwritten until it's restored,
    /// dismissed, or the branch is saved.
    recovering: HashSet<String>,
}

impl State {
    fn new(id: u64, project: Project) -> State {
        let branches = Branches::new(project.root.clone());
        let history = History::new(project.root.clone());
        State {
            id, project, branches, history, roblox: Roblox::new(), seen_places: HashSet::new(), planned: HashMap::new(),
            updates: HashMap::new(), restores: HashMap::new(), sessions: HashMap::new(), unsaved: HashMap::new(),
            committed: HashMap::new(), live: HashMap::new(), recovering: HashSet::new(),
        }
    }
}

/// A branch's last commit (or where it last met main), indexed once.
struct Committed {
    /// The commit's ID, or the base it stands for.
    which: String,
    dom: WeakDom,
    index: diff::Index,
    /// What it is, for the plugin: `{ kind, message?, time }`.
    since: Value,
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

/// Every game RoGit has data for, loaded when Studio first asks about it.
struct Games {
    /// The folder with a folder per game.
    root: std::path::PathBuf,
    games: HashMap<u64, State>,
}

impl Games {
    fn new(root: std::path::PathBuf) -> Games {
        Games { root, games: HashMap::new() }
    }

    fn get(&mut self, id: u64) -> &mut State {
        let root = &self.root;
        self.games.entry(id).or_insert_with(|| State::new(id, Project::new(root.join(id.to_string()))))
    }

    /// The folders of the games set up so far, by ID.
    fn known(&self) -> Vec<(u64, Project)> {
        let entries = std::fs::read_dir(&self.root).into_iter().flatten().flatten();
        let mut games: Vec<(u64, Project)> =
            entries.filter_map(|e| Some((e.file_name().to_str()?.parse().ok()?, Project::new(e.path())))).collect();
        games.sort_by_key(|(id, _)| *id);
        games
    }

    /// The game a branch belongs to, for branch files made before they said so themselves.
    fn find_branch(&self, name: &str) -> Option<u64> {
        self.known().into_iter().find(|(_, project)| Branches::new(project.root.clone()).get(name).is_some()).map(|(id, _)| id)
    }
}

/// Serves every game on `port`, or on the first free port of `PORTS`. Does nothing if RoGit is already running.
pub fn serve(port: Option<u16>) -> Result<(), String> {
    // A second server would work on the same files as the first.
    if let Some((running, version)) = running() {
        if newer_or_same(&version, env!("CARGO_PKG_VERSION")) {
            println!("RoGit is already running on http://127.0.0.1:{running}.");
            return Ok(());
        }
        println!("An older RoGit ({version}) is running on port {running}. Stop it, so Studio talks to this one.");
    }
    let ports: Vec<u16> = match port {
        Some(port) => vec![port],
        None => PORTS.collect(),
    };
    let found = ports.iter().find_map(|port| Server::http(format!("127.0.0.1:{port}")).ok().map(|server| (*port, server)));
    let Some((port, server)) = found else {
        return Err(match port {
            Some(port) => format!("Couldn't listen on port {port}; something else is using it."),
            None => format!("Ports {} to {} are all in use.", PORTS.start(), PORTS.end()),
        });
    };
    let mut games = Games::new(project::games()?);
    println!("RoGit {} is running on http://127.0.0.1:{port}. Leave it running while you use RoGit in Studio.", env!("CARGO_PKG_VERSION"));
    for (_, project) in games.known() {
        if let Ok(Some(config)) = project.config() {
            println!("  {} (main place {})", config.game.name, config.game.main_place_id);
        }
    }
    loop {
        match server.recv_timeout(Duration::from_millis(500)) {
            Ok(Some(request)) => {
                handle(&mut games, request);
                games.games.values_mut().for_each(|state| autosave(state, false));
            }
            Ok(None) => games.games.values_mut().for_each(|state| autosave(state, true)),
            Err(e) => return Err(format!("The server stopped: {e}")),
        }
    }
}

/// A RoGit already running on this computer: its port and version.
fn running() -> Option<(u16, String)> {
    let agent: ureq::Agent = ureq::Agent::config_builder().timeout_global(Some(Duration::from_millis(500))).build().into();
    PORTS.into_iter().find_map(|port| {
        let text = agent.get(&format!("http://127.0.0.1:{port}/api/rogit")).call().ok()?.body_mut().read_to_string().ok()?;
        let reply: Value = serde_json::from_str(&text).ok()?;
        (reply["server"] == "rogit").then(|| (port, reply["version"].as_str().unwrap_or("0").to_owned()))
    })
}

/// Whether version `a` ("1.2.3") is at least `b`.
fn newer_or_same(a: &str, b: &str) -> bool {
    let parts = |v: &str| v.split('.').map(|n| n.parse::<u64>().unwrap_or(0)).collect::<Vec<_>>();
    parts(a) >= parts(b)
}

/// Writes each open branch's copy in memory to disk as its autosave. A big place takes a fifth of a second to write,
/// so this waits until nothing else is going on (`idle`), at most every 10 seconds; during nonstop activity, it still
/// writes at least once a minute.
fn autosave(state: &mut State, idle: bool) {
    let every = Duration::from_secs(if idle { 10 } else { 60 });
    for (name, live) in state.live.iter_mut() {
        // Unsaved work from before waits to be restored; the autosave mustn't replace it.
        if !live.changed || live.saved.elapsed() < every || state.recovering.contains(name) {
            continue;
        }
        live.saved = Instant::now();
        live.changed = false;
        match state.branches.save_latest(name, &live.dom) {
            Ok(()) => live.saved_at = Some(unix_now()),
            Err(e) => println!("Couldn't autosave {name}: {e}"),
        }
    }
}

fn handle(games: &mut Games, mut request: Request) {
    let started = Instant::now();
    let mut body = String::new();
    let _ = request.as_reader().read_to_string(&mut body);
    let url = request.url().to_owned();
    let (path, query) = url.split_once('?').unwrap_or((&url, ""));
    // The plugin says which game every request is about. A branch file from before branches said which game they're
    // from is found by its name.
    let file = decode(param(query, "file").unwrap_or(""));
    let game = number(query, "game")
        .filter(|id| *id != 0)
        .or_else(|| file.strip_suffix(".rbxl").filter(|name| branches::valid_name(name)).and_then(|name| games.find_branch(name)));
    let result = match game {
        Some(id) => route(games.get(id), request.method(), path, query, &body),
        None if path == "/api/rogit" => Ok(json!({ "server": "rogit", "version": env!("CARGO_PKG_VERSION"), "game": null })),
        None => Err((400, "Open a published game's place in Studio, or one of its branches.".to_owned())),
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

/// Answers one request from the plugin.
fn route(state: &mut State, method: &Method, path: &str, query: &str, body: &str) -> Reply {
    match (method, path) {
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
        (Method::Post, "/api/branches/patch") => patch(state, &body),
        (Method::Post, "/api/branches/stage") => stage(state, &body),
        (Method::Post, "/api/branches/commit/view") => view_commit(state, &body),
        (Method::Post, "/api/branches/revert") => plan_revert(state, &body),
        (Method::Post, "/api/branches/restore") => plan_restore(state, &body),
        (Method::Post, "/api/branches/discard") => plan_discard(state, &body),
        (Method::Post, "/api/branches/restored") => restored(state, &body),
        (Method::Post, "/api/branches/unsaved/dismiss") => dismiss_unsaved(state, &body),
        _ => Err((404, "Not found.".to_owned())),
    }
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
    use super::*;
    use rbx_dom_weak::types::{Ref, Variant};

    #[test]
    fn finds_the_game_of_a_branch_and_keeps_games_apart() {
        let root = std::env::temp_dir().join(format!("rogit-games-{}", std::process::id()));
        let mut games = Games::new(root.clone());
        for (id, name) in [(10, "Tycoon"), (20, "Obby")] {
            games.get(id).project.init(Game { name: name.into(), universe_id: id, main_place_id: id + 1 }).unwrap();
        }
        // A branch of the obby, made the way rogit serve makes one.
        let store = &games.get(20).branches;
        let upload = store.upload_dir("copy12345");
        std::fs::create_dir_all(&upload).unwrap();
        store.create("lobby", "copy12345", &json!({ "services": [] }), 20).unwrap();
        assert_eq!(games.find_branch("lobby"), Some(20));
        assert_eq!(games.find_branch("nothing"), None);
        assert!(games.get(10).branches.list().is_empty());
        let status = status(games.get(20), "place=0&file=lobby.rbxl");
        assert_eq!((status["game"].clone(), status["branch"]["name"].clone()), (json!(20), json!("lobby")));
        assert_eq!(status["project"]["game"]["name"], json!("Obby"));
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn compares_versions() {
        assert!(newer_or_same("0.2.0", "0.2.0"));
        assert!(newer_or_same("0.10.0", "0.9.1"));
        assert!(!newer_or_same("0.1.0", "0.2.0"));
    }

    #[test]
    fn decodes_studio_url_encoding() {
        assert_eq!(super::decode("test%2D1%2Erbxl"), "test-1.rbxl");
        assert_eq!(super::decode("a+b%20c%"), "a b c%");
        assert_eq!(super::decode("%zz%E2%9C%93"), "%zz✓");
    }

    /// Plays the plugin's part on a big place (ROGIT_BENCH_PLACE, a .rbxl): a branch's full copy, an edit sent as a
    /// patch, an empty patch, a commit and a merge, printing how long rogit serve takes for each.
    /// `ROGIT_BENCH_PLACE=… cargo test --release replays_the_plugin -- --ignored --nocapture`
    #[test]
    #[ignore]
    fn replays_the_plugin_on_a_big_place() {
        let Ok(path) = std::env::var("ROGIT_BENCH_PLACE") else { return };
        let place = crate::place::read(std::path::Path::new(&path)).unwrap();
        let root = std::env::temp_dir().join(format!("rogit-replay-{}", std::process::id()));
        let project = Project::new(root.clone());
        project.init(Game { name: "Bench".into(), universe_id: 1, main_place_id: 2 }).unwrap();
        let mut state = State::new(1, project);

        // Studio's session IDs, made up: one per object, listed in the plugin's walk order.
        let mut ids: HashMap<Ref, String> = HashMap::new();
        let walk = |dom: &WeakDom, top: Ref| {
            let mut out = Vec::new();
            let mut stack = vec![top];
            while let Some(r) = stack.pop() {
                out.push(r);
                stack.extend(dom.get_by_ref(r).unwrap().children().iter().rev().copied());
            }
            out
        };
        for r in place.descendants().map(|i| i.referent()).collect::<Vec<_>>() {
            let n = ids.len();
            ids.insert(r, format!("d{n}"));
        }
        let listed = |dom: &WeakDom, top: Ref, ids: &HashMap<Ref, String>| -> Vec<String> {
            walk(dom, top).into_iter().map(|r| format!("{}|{}", ids[&r], dom.get_by_ref(r).unwrap().class)).collect()
        };
        // A full copy of `dom` uploaded the way the plugin does: one file per service, and a manifest.
        let upload = |state: &State, capture: &str| -> Value {
            let dir = state.branches.upload_dir(capture);
            std::fs::create_dir_all(&dir).unwrap();
            let mut services = Vec::new();
            for &service in place.root().children() {
                let inst = place.get_by_ref(service).unwrap();
                let file = std::fs::File::create(dir.join(format!("{}.rbxm", inst.name))).unwrap();
                rbx_binary::to_writer(file, &place, inst.children()).unwrap();
                let listed: Vec<String> = inst.children().iter().flat_map(|&c| listed(&place, c, &ids)).collect();
                services.push(json!({ "name": inst.name, "className": inst.class.as_str(), "settings": {}, "attributes": {}, "ids": listed }));
            }
            json!({ "services": services })
        };
        let timed = |state: &mut State, what: &str, path: &str, body: Value| -> Value {
            let started = Instant::now();
            let reply = route(state, &Method::Post, path, "", &body.to_string()).unwrap_or_else(|(code, e)| panic!("{what}: {code} {e}"));
            println!("REPLAY {what}: {} ms", started.elapsed().as_millis());
            reply
        };

        // New branch (made directly: the request would open it in Studio), then its window's first full copy.
        let manifest = upload(&state, "benchmain1");
        state.branches.create("bench", "benchmain1", &manifest, 1).unwrap();
        let manifest = upload(&state, "benchstart1");
        timed(&mut state, "starting point", "/api/branches/start", json!({ "name": "bench", "capture": "benchstart1", "manifest": manifest }));
        let manifest = upload(&state, "benchcopy1");
        let reply = timed(&mut state, "full copy", "/api/branches/changes", json!({ "name": "bench", "capture": "benchcopy1", "manifest": manifest, "session": "s" }));
        assert_eq!(reply["live"], json!(true));

        // Move the biggest model in Workspace with fewer than 3,000 objects by 20 studs, as one patch.
        let workspace = place.root().children().iter().copied().find(|&r| place.get_by_ref(r).unwrap().class.as_str() == "Workspace").unwrap();
        let model = place
            .get_by_ref(workspace)
            .unwrap()
            .children()
            .iter()
            .copied()
            .filter(|&r| place.get_by_ref(r).unwrap().class.as_str() == "Model")
            .max_by_key(|&r| place.descendants_of(r).count().min(3000) as i64 - (place.descendants_of(r).count() >= 3000) as i64 * 10_000)
            .unwrap();
        let mut data = WeakDom::new(rbx_dom_weak::InstanceBuilder::new("Folder"));
        let copy = place.clone_into_external(model, &mut data);
        // A move, as Studio makes one: each part's CFrame and the model's pivot shift; offsets inside stay.
        for r in walk(&data, copy) {
            for (name, value) in data.get_by_ref_mut(r).unwrap().properties.iter_mut() {
                match (name.as_str(), value) {
                    ("CFrame", Variant::CFrame(c)) => c.position.x += 20.0,
                    ("WorldPivotData", Variant::OptionalCFrame(Some(c))) => c.position.x += 20.0,
                    _ => {}
                }
            }
        }
        let patch_dir = state.branches.upload_dir("benchpatch1");
        std::fs::create_dir_all(&patch_dir).unwrap();
        rbx_binary::to_writer(std::fs::File::create(patch_dir.join("Patch.rbxm")).unwrap(), &data, &[copy]).unwrap();
        let upsert = json!({ "id": ids[&model], "parent": "service:Workspace", "ids": listed(&place, model, &ids) });
        let objects = place.descendants_of(model).count() + 1;
        let reply = timed(&mut state, &format!("patch moving a model with {objects} objects"), "/api/branches/patch", json!({
            "name": "bench", "capture": "benchpatch1", "upserts": [upsert], "removes": [], "services": [], "refs": [],
        }));
        assert_ne!(reply["full"], json!(true), "the patch should apply");
        let rows = reply["changes"]["rows"].as_array().unwrap().iter().filter(|r| r["status"] != json!("context")).count();
        println!("REPLAY changes listed: {rows}");
        timed(&mut state, "empty patch", "/api/branches/patch", json!({ "name": "bench", "upserts": [], "removes": [], "services": [], "refs": [] }));
        timed(&mut state, "commit", "/api/branches/commit", json!({ "name": "bench", "message": "Move", "live": true }));
        let manifest = upload(&state, "benchmain2");
        let reply = timed(&mut state, "merge plan", "/api/branches/merge", json!({ "name": "bench", "capture": "benchmain2", "manifest": manifest }));
        println!("REPLAY merge summary: {}", reply["plan"]["summary"]);
        std::fs::remove_dir_all(&root).unwrap();
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
        Ok(None) => Err((409, "This game isn't set up yet. Click Init in its start place.".into())),
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
        "game": state.id,
        "project": { "game": state.project.config().ok().flatten().map(|c| c.game) },
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
    if game != state.id {
        return Err((400, "That's a different game.".into()));
    }
    let experience = state.roblox.experience(game).map_err(|e| (502, e))?;
    if experience.start_place_id != place {
        return Err((409, format!("Init only works in the start place of {}.", experience.name)));
    }
    let game = Game { name: experience.name, universe_id: game, main_place_id: place };
    let config = state.project.init(game).map_err(|e| (500, format!("Couldn't write RoGit's files for this game: {e}")))?;
    println!("Set up {}", config.game.name);
    Ok(json!({ "game": config.game }))
}

fn init_done(body: &str) -> Value {
    let report: Value = serde_json::from_str(body).unwrap_or_default();
    println!(
        "Tagged {} objects in {:.1} s (skipped {} scripts and what holds them)",
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
    let report = state.branches.create(&name, &capture, &manifest, state.id).map_err(|e| (409, e))?;
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
    state.branches.set_starting_point(&name, &capture, &manifest, state.id).map_err(|e| (409, e))?;
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
    let differs = match (crate::place::read(&state.branches.file(name)), state.branches.latest_place(name)) {
        (Ok(file), Ok(latest)) => !diff::compare(&file, &latest).rows.is_empty(),
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
    assemble_upload(&state.branches, capture, manifest)
}

fn assemble_upload(branches: &Branches, capture: &str, manifest: &Value) -> Result<WeakDom, (u16, String)> {
    let upload = branches.upload_dir(capture);
    let place = crate::place::assemble(&upload, manifest);
    let _ = std::fs::remove_dir_all(&upload);
    place.map(|(dom, _)| dom).map_err(|e| (500, e))
}

/// With ROGIT_TRACE set, prints how long a step of a request took, and starts timing the next one.
fn step(name: &str, since: &mut Instant) {
    if std::env::var_os("ROGIT_TRACE").is_some() {
        eprintln!("  {name}: {} ms", since.elapsed().as_millis());
    }
    *since = Instant::now();
}

fn unix_now() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or_default()
}

/// Plans merging a branch into main as it is in Studio right now (`capture` is main's copy).
fn plan_merge(state: &mut State, body: &str) -> Reply {
    require_game(state)?;
    let started = Instant::now();
    let mut timer = Instant::now();
    let (name, capture, manifest) = capture_request(body)?;
    existing(state, &name)?;
    // Like git, a merge takes the branch's last commit; without commits, its newest copy. It's read while main's copy
    // is put together: in a big game each takes a moment.
    let commits = state.branches.commits(&name);
    let branches = &state.branches;
    let (main, branch) = std::thread::scope(|scope| {
        let main = scope.spawn(|| assemble_upload(branches, &capture, &manifest));
        let branch = match commits.first() {
            Some(last) => branches.commit_place(&name, &last.id).map(|dom| (dom, "commit", last.time)),
            None => branches.newest(&name),
        };
        (main.join().unwrap(), branch)
    });
    let (main, (branch, source, time)) = (main?, branch.map_err(|e| (500, e))?);
    step("main's copy and the branch", &mut timer);
    // The branch's changes since its last commit, as its window last showed them.
    let uncommitted = match (commits.first(), state.live.get(&name)) {
        (None, _) => 0,
        (Some(_), Some(live)) => live.uncommitted,
        (Some(_), None) => match state.branches.newest(&name) {
            Ok((newest, _, _)) => diff::compare(&branch, &newest).rows.iter().filter(|r| r.status != diff::Status::Context).count(),
            Err(_) => 0,
        },
    };
    let (base, since, since_time) = state
        .branches
        .base(&name, merge::last_merge(&main, &name).as_deref(), merge::last_update(&branch).as_deref())
        .map_err(|e| (409, e))?;
    step("uncommitted count and base", &mut timer);
    let plan = merge::plan(&base, &branch, &main, Direction::Merge).map_err(|e| (500, e))?;
    step("plan", &mut timer);
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
    let update = state.updates.get_mut(&name).unwrap();
    let planned = state
        .branches
        .base(&name, merge::last_merge(&main, &name).as_deref(), merge::last_update(&update.branch).as_deref())
        .and_then(|(base, since, since_time)| {
            merge::plan(&base, &main, &update.branch, Direction::Update).map(|plan| (plan, since, since_time))
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
    state.live.remove(&name);
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
/// last met main (`record` is the branch's update record). Returns the place and a description for the plugin.
fn committed(state: &State, name: &str, record: Option<&str>) -> Result<(WeakDom, Value), (u16, String)> {
    match state.branches.commits(name).first() {
        Some(last) => {
            let dom = state.branches.commit_place(name, &last.id).map_err(|e| (500, e))?;
            Ok((dom, json!({ "kind": "commit", "message": last.message, "time": last.time })))
        }
        None => {
            let (dom, since, time) = state.branches.base(name, None, record).map_err(|e| (409, e))?;
            Ok((dom, json!({ "kind": since, "time": time })))
        }
    }
}

/// Makes sure what the branch's changes are measured from is in memory and indexed: refreshes come often, and a big
/// place takes a while to read and index.
fn load_committed(state: &mut State, name: &str, record: Option<String>) -> Result<(), (u16, String)> {
    let which = match state.branches.commits(name).first() {
        Some(last) => last.id.clone(),
        None => format!("base:{}", record.clone().unwrap_or_default()),
    };
    if state.committed.get(name).is_none_or(|c| c.which != which) {
        let (dom, since) = committed(state, name, record.as_deref())?;
        let index = diff::index(&dom);
        state.committed.insert(name.to_owned(), Committed { which, dom, index, since });
    }
    Ok(())
}

/// The changes in `current` since what `load_committed` loaded.
fn uncommitted(state: &State, name: &str, current: &WeakDom) -> diff::Review {
    let base = &state.committed[name];
    diff::compare_with(&base.dom, &base.index, current)
}

/// How many changes a review lists (not counting the rows that only show where they are).
fn count(review: &diff::Review) -> usize {
    review.rows.iter().filter(|r| r.status != diff::Status::Context).count()
}

/// The staged keys that are still among the changes.
fn staged_now(state: &State, name: &str, review: &diff::Review) -> Vec<String> {
    let keys: HashSet<&str> = review.rows.iter().filter(|r| r.status != diff::Status::Context).map(|r| r.key.as_str()).collect();
    state.branches.staged(name).into_iter().filter(|k| keys.contains(k.as_str())).collect()
}

/// The reply with a branch's changes; `saved` is when its autosave copy was written, if it just was.
fn changes_reply(state: &State, name: &str, review: diff::Review, saved: Option<u64>) -> Value {
    let staged = staged_now(state, name, &review);
    json!({ "changes": review, "staged": staged, "since": state.committed[name].since, "time": saved })
}

/// A full copy of the branch as it is in Studio (`capture`): kept as its autosave copy and in memory, and compared
/// with its last commit. After this, edits arrive as patches with just the objects that changed.
fn changes(state: &mut State, body: &str) -> Reply {
    let (name, capture, manifest) = capture_request(body)?;
    existing(state, &name)?;
    // A window that just opened after Studio closed unexpectedly: its copy mustn't replace the unsaved work.
    let session = json_body(body)?["session"].as_str().unwrap_or_default().to_owned();
    if let Some(opened) = state.sessions.get(&session).copied() {
        if unsaved_work(state, &name, opened).is_some() {
            state.recovering.insert(name.clone());
        }
    }
    let dom = if state.recovering.contains(&name) {
        take_upload(state, &capture, &manifest)?
    } else {
        state.branches.keep_latest(&name, &capture, &manifest).map_err(|e| (500, e))?
    };
    load_committed(state, &name, merge::last_update(&dom))?;
    let mut live = Live::new(dom, &manifest);
    live.saved_at = Some(unix_now());
    let identified = live.identified;
    let review = uncommitted(state, &name, &live.dom);
    live.uncommitted = count(&review);
    state.live.insert(name.clone(), live);
    let mut reply = changes_reply(state, &name, review, Some(unix_now()));
    reply["live"] = json!(identified);
    Ok(reply)
}

/// Just what changed in Studio since the last copy (see `Live::patch`); the changed objects are uploaded under
/// `capture` as `Patch`. Replies like `changes`, or with `full: true` when the plugin should send a full copy.
fn patch(state: &mut State, body: &str) -> Reply {
    let mut timer = Instant::now();
    let request = json_body(body)?;
    let name = request["name"].as_str().unwrap_or_default().to_owned();
    existing(state, &name)?;
    let list = |key: &str| request[key].as_array().cloned().unwrap_or_default();
    let data = match request["capture"].as_str().filter(|c| branches::valid_capture(c)) {
        Some(capture) => {
            let upload = state.branches.upload_dir(capture);
            let dom = std::fs::read(upload.join("Patch.rbxm")).ok().and_then(|bytes| rbx_binary::from_reader(&bytes[..]).ok());
            let _ = std::fs::remove_dir_all(&upload);
            match dom {
                Some(dom) => Some(dom),
                None => return Ok(json!({ "full": true })),
            }
        }
        None => None,
    };
    let removes: Vec<String> = list("removes").iter().filter_map(|v| v.as_str().map(str::to_owned)).collect();
    let Some(live) = state.live.get_mut(&name) else { return Ok(json!({ "full": true })) };
    if !live.patch(&list("upserts"), data, &removes, &list("services"), &list("refs")) {
        state.live.remove(&name);
        return Ok(json!({ "full": true }));
    }
    step("patch", &mut timer);
    // The copy in memory is also the autosave (see `autosave`). Saving the branch ends any wait to restore unsaved
    // work from before.
    let saved = live.saved_at;
    if state.recovering.contains(&name) && state.branches.unsaved_copy(&name).is_none() {
        state.recovering.remove(&name);
    }
    let record = merge::last_update(&state.live[&name].dom);
    load_committed(state, &name, record)?;
    let review = uncommitted(state, &name, &state.live[&name].dom);
    step("compare", &mut timer);
    state.live.get_mut(&name).unwrap().uncommitted = count(&review);
    Ok(changes_reply(state, &name, review, saved))
}

fn stage(state: &mut State, body: &str) -> Reply {
    let request = json_body(body)?;
    let name = request["name"].as_str().unwrap_or_default();
    existing(state, name)?;
    let keys: Vec<String> = request["keys"].as_array().into_iter().flatten().filter_map(|k| k.as_str().map(str::to_owned)).collect();
    state.branches.set_staged(name, &keys).map_err(|e| (500, e))?;
    Ok(json!({ "staged": keys }))
}

/// The branch as it is in Studio, for a commit or a restore: a copy of the one kept in memory (`live: true`, with its
/// .rbxl bytes), or a full copy uploaded under `capture`. None when there's no copy in memory (the plugin sends one).
fn current_copy(state: &State, body: &str, request: &Value, name: &str) -> Result<Option<(WeakDom, Option<Vec<u8>>)>, (u16, String)> {
    if request["live"].as_bool().unwrap_or(false) {
        return match state.live.get(name) {
            Some(live) => live.copy().map(|(dom, bytes)| Some((dom, Some(bytes)))).map_err(|e| (500, e)),
            None => Ok(None),
        };
    }
    let (_, capture, manifest) = capture_request(body)?;
    assemble_upload(&state.branches, &capture, &manifest).map(|dom| Some((dom, None)))
}

/// Commits the branch as it is in Studio, like `git commit`: only the staged changes when some are staged, otherwise
/// all of them. `auto` commits everything (after a pull or a revert).
fn commit(state: &mut State, body: &str) -> Reply {
    let started = Instant::now();
    let mut timer = Instant::now();
    let request = json_body(body)?;
    let name = request["name"].as_str().unwrap_or_default().to_owned();
    existing(state, &name)?;
    let message = request["message"].as_str().unwrap_or("").trim().chars().take(100).collect::<String>();
    let auto = request["auto"].as_bool().unwrap_or(false);
    let Some((current, bytes)) = current_copy(state, body, &request, &name)? else { return Ok(json!({ "full": true })) };
    step("copy", &mut timer);
    load_committed(state, &name, merge::last_update(&current))?;
    let all = uncommitted(state, &name, &current);
    step("compare", &mut timer);
    let staged: HashSet<String> = if auto { HashSet::new() } else { staged_now(state, &name, &all).into_iter().collect() };
    let (snapshot, summary, left) = if staged.is_empty() {
        let summary = all.summary.clone();
        let left = diff::Review { summary: diff::Summary::default(), rows: vec![], truncated: 0 };
        (current, summary, left)
    } else {
        let previous = &state.committed[&name].dom;
        let copy = crate::live::copy_of(&current).map_err(|e| (500, e))?;
        let snapshot = crate::stage::partial(previous, copy, &all.rows, &staged);
        let summary = diff::compare_with(previous, &state.committed[&name].index, &snapshot).summary;
        let left = diff::compare(&snapshot, &current);
        (snapshot, summary, left)
    };
    if summary == diff::Summary::default() {
        return Err((409, "Nothing to commit.".to_owned()));
    }
    let number = state.branches.commits(&name).len() + 1;
    let message = if message.is_empty() { format!("Commit {number}") } else { message };
    let id = format!("c{:x}", SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_nanos());
    let commit = Commit { id, message, time: unix_now(), summary, auto };
    // Written while the commit is indexed (it's what changes are measured from next). When everything is committed,
    // the copy's bytes are the file.
    let bytes = bytes.filter(|_| staged.is_empty());
    let branches = &state.branches;
    let index = std::thread::scope(|scope| {
        let written = scope.spawn(|| branches.add_commit(&name, &snapshot, bytes.as_deref(), &commit));
        let index = diff::index(&snapshot);
        written.join().unwrap().map(|()| index)
    })
    .map_err(|e| (500, e))?;
    state.branches.set_staged(&name, &[]).map_err(|e| (500, e))?;
    step("write and index", &mut timer);
    if let Some(live) = state.live.get_mut(&name) {
        live.uncommitted = count(&left);
    }
    if !auto {
        let event = Event {
            id: commit.id.clone(), kind: "commit".into(), branch: name.clone(), time: commit.time,
            summary: serde_json::to_value(&commit.summary).ok(), has_rows: false, message: Some(commit.message.clone()),
        };
        let _ = state.history.add(event, None);
    }
    // The new commit is what changes are measured from now; keep it in memory instead of reading it back.
    let since = json!({ "kind": "commit", "message": commit.message, "time": commit.time });
    state.committed.insert(name.clone(), Committed { which: commit.id.clone(), dom: snapshot, index, since: since.clone() });
    println!("Committed {name}: \"{}\" ({} ms)", commit.message, started.elapsed().as_millis());
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
    Ok(json!({ "review": diff::compare(&before, &this), "commit": commits[position] }))
}

/// Plans bringing an earlier copy of the branch back into the branch as it is now (`current`). The reply carries
/// the copy's update record, which the plugin sets too, so later merges and updates measure from the right place.
fn plan_restore_of(state: &mut State, name: &str, kind: &str, copy: &WeakDom, current: &WeakDom) -> Reply {
    let plan = merge::plan(current, copy, current, Direction::Restore).map_err(|e| (500, e))?;
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
    let request = json_body(body)?;
    let name = request["name"].as_str().unwrap_or_default().to_owned();
    existing(state, &name)?;
    let discard: HashSet<String> =
        request["keys"].as_array().into_iter().flatten().filter_map(|k| k.as_str().map(str::to_owned)).collect();
    // The copy in memory is compared where it is and copied once; an uploaded copy is the copy's source.
    let live = request["live"].as_bool().unwrap_or(false);
    let uploaded = match live {
        true if !state.live.contains_key(&name) => return Ok(json!({ "full": true })),
        true => None,
        false => current_copy(state, body, &request, &name)?.map(|(dom, _)| dom),
    };
    let record = merge::last_update(uploaded.as_ref().unwrap_or_else(|| &state.live[&name].dom));
    load_committed(state, &name, record)?;
    let current = uploaded.as_ref().unwrap_or_else(|| &state.live[&name].dom);
    let rows = uncommitted(state, &name, current).rows;
    let keep: HashSet<String> =
        rows.iter().filter(|r| r.status != diff::Status::Context && !discard.contains(&r.key)).map(|r| r.key.clone()).collect();
    let copy = crate::live::copy_of(current).map_err(|e| (500, e))?;
    let wanted = crate::stage::partial(&state.committed[&name].dom, copy, &rows, &keep);
    let plan = merge::plan(current, &wanted, current, Direction::Restore).map_err(|e| (500, e))?;
    Ok(json!({ "plan": plan }))
}

/// Plans bringing back unsaved work (the newest copy RoGit made) into the branch as it is in Studio (`capture`).
/// Measured against the window as it is, so work that's still there isn't added twice.
fn plan_restore(state: &mut State, body: &str) -> Reply {
    let request = json_body(body)?;
    let name = request["name"].as_str().unwrap_or_default().to_owned();
    existing(state, &name)?;
    let Some((current, _)) = current_copy(state, body, &request, &name)? else { return Ok(json!({ "full": true })) };
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
        state.recovering.remove(&name);
    }
    log_event(state, &kind, &name, &report, Some(rows));
    Ok(json!({ "branch": state.branches.get(&name) }))
}

fn dismiss_unsaved(state: &mut State, body: &str) -> Reply {
    let request = json_body(body)?;
    let name = request["name"].as_str().unwrap_or_default();
    existing(state, name)?;
    state.branches.dismiss_unsaved(name).map_err(|e| (500, e))?;
    state.recovering.remove(name);
    Ok(json!({ "ok": true }))
}
