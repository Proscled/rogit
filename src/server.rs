//! `rogit serve`: the local server the Studio plugin talks to, like `rojo serve`.

use crate::project::{Game, Project};
use crate::roblox::Roblox;
use serde_json::{Value, json};
use std::collections::HashSet;
use tiny_http::{Header, Method, Request, Response, Server};

pub const DEFAULT_PORT: u16 = 34875;

struct State {
    project: Project,
    roblox: Roblox,
    seen_places: HashSet<u64>,
}

pub fn serve(project: Project, port: u16) -> Result<(), String> {
    let address = format!("127.0.0.1:{port}");
    let server = Server::http(&address).map_err(|e| format!("Couldn't listen on {address}: {e}"))?;
    let mut state = State { project, roblox: Roblox::new(), seen_places: HashSet::new() };
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
    let (path, query) = request.url().split_once('?').unwrap_or((request.url(), ""));
    let result = match (request.method(), path) {
        (Method::Get, "/api/rogit") => Ok(status(state, query)),
        (Method::Get, "/api/place") => place(state, query),
        (Method::Post, "/api/init") => init(state, &body),
        (Method::Post, "/api/init/done") => Ok(init_done(&body)),
        _ => Err((404, "Not found.".to_owned())),
    };
    let (code, value) = match result {
        Ok(value) => (200, value),
        Err((code, message)) => (code, json!({ "error": message })),
    };
    let header = Header::from_bytes(&b"Content-Type"[..], &b"application/json"[..]).unwrap();
    let _ = request.respond(Response::from_string(value.to_string()).with_status_code(code).with_header(header));
}

fn param(query: &str, name: &str) -> Option<u64> {
    query.split('&').find_map(|pair| pair.strip_prefix(name)?.strip_prefix('=')?.parse().ok())
}

fn status(state: &mut State, query: &str) -> Value {
    if let Some(place) = param(query, "place") {
        if state.seen_places.insert(place) {
            println!("Studio connected from place {place}");
        }
    }
    let config = state.project.config().ok().flatten();
    json!({
        "server": "rogit",
        "version": env!("CARGO_PKG_VERSION"),
        "project": { "folder": state.project.folder_name(), "game": config.map(|c| c.game) },
    })
}

/// Tells the plugin whether the open place is its experience's start place.
fn place(state: &mut State, query: &str) -> Result<Value, (u16, String)> {
    let (Some(game), Some(place)) = (param(query, "game"), param(query, "place")) else {
        return Err((400, "Missing game or place.".into()));
    };
    let experience = state.roblox.experience(game).map_err(|e| (502, e))?;
    Ok(json!({ "isMain": experience.start_place_id == place, "experience": experience.name }))
}

fn init(state: &mut State, body: &str) -> Result<Value, (u16, String)> {
    let request: Value = serde_json::from_str(body).map_err(|_| (400, "Invalid request.".to_owned()))?;
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
