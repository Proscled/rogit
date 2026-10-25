//! `rogit serve`: the local server the Studio plugin talks to, like `rojo serve`.

use crate::branches::{self, Branches};
use crate::project::{DATA_DIR, Game, Project};
use crate::roblox::Roblox;
use base64::Engine;
use serde_json::{Value, json};
use std::collections::HashSet;
use std::time::Instant;
use tiny_http::{Header, Method, Request, Response, Server};

pub const DEFAULT_PORT: u16 = 34875;

type Reply = Result<Value, (u16, String)>;

struct State {
    project: Project,
    branches: Branches,
    roblox: Roblox,
    seen_places: HashSet<String>,
}

pub fn serve(project: Project, port: u16) -> Result<(), String> {
    let address = format!("127.0.0.1:{port}");
    let server = Server::http(&address).map_err(|e| format!("Couldn't listen on {address}: {e}"))?;
    let branches = Branches::new(project.root.join(DATA_DIR));
    let mut state = State { project, branches, roblox: Roblox::new(), seen_places: HashSet::new() };
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
        _ => Err((404, "Not found.".to_owned())),
    };
    let (code, value) = match result {
        Ok(value) => (200, value),
        Err((code, message)) => (code, json!({ "error": message })),
    };
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
    let branch = file.strip_suffix(".rbxl").filter(|name| branches::valid_name(name)).and_then(|name| state.branches.get(name));
    json!({
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
    println!(
        "Created branch {name}: {} objects in {} ms ({} settings Studio doesn't let plugins read stay at their defaults)",
        report.objects, started.elapsed().as_millis(), report.settings_skipped
    );
    state.branches.open(&name).map_err(|e| (500, e))?;
    Ok(json!({ "branch": state.branches.get(&name), "objects": report.objects }))
}

fn starting_point(state: &mut State, body: &str) -> Reply {
    let (name, capture, manifest) = capture_request(body)?;
    state.branches.set_starting_point(&name, &capture, &manifest).map_err(|e| (409, e))?;
    println!("Recorded the starting point of {name}");
    Ok(json!({ "branch": state.branches.get(&name) }))
}

fn open_branch(state: &mut State, body: &str) -> Reply {
    let request = json_body(body)?;
    let name = request["name"].as_str().unwrap_or_default();
    state.branches.open(name).map_err(|e| (404, e))?;
    Ok(json!({ "ok": true }))
}
