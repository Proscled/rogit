//! The project folder `rogit serve` runs in: `rogit.toml`, the private `.rogit/` folder, and Rojo's paths.

use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

pub const CONFIG_FILE: &str = "rogit.toml";
pub const DATA_DIR: &str = ".rogit";

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Config {
    pub game: Game,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Game {
    pub name: String,
    pub universe_id: u64,
    pub main_place_id: u64,
}

/// What Rojo syncs, as Studio instance paths like `ReplicatedStorage/Shared`.
#[derive(Serialize, Debug, Default, PartialEq)]
pub struct RojoPaths {
    /// The project maps the whole place, so RoGit leaves everything to Rojo.
    pub all: bool,
    pub paths: Vec<String>,
}

pub struct Project {
    pub root: PathBuf,
}

impl Project {
    pub fn new(root: PathBuf) -> Self {
        Project { root }
    }

    pub fn folder_name(&self) -> String {
        self.root.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default()
    }

    pub fn config(&self) -> io::Result<Option<Config>> {
        match fs::read_to_string(self.root.join(CONFIG_FILE)) {
            Ok(text) => toml::from_str(&text)
                .map(Some)
                .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, format!("{CONFIG_FILE} is invalid: {e}"))),
            Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(None),
            Err(e) => Err(e),
        }
    }

    /// Writes `rogit.toml`, creates `.rogit/` and keeps it out of Git.
    pub fn init(&self, game: Game) -> io::Result<Config> {
        let config = Config { game };
        let text = toml::to_string(&config).map_err(|e| io::Error::new(io::ErrorKind::Other, e.to_string()))?;
        fs::write(self.root.join(CONFIG_FILE), format!("# RoGit project file. Commit this file.\n{text}"))?;
        fs::create_dir_all(self.root.join(DATA_DIR))?;
        ignore_data_dir(&self.root.join(".gitignore"))?;
        Ok(config)
    }

    pub fn rojo_paths(&self) -> RojoPaths {
        fs::read_to_string(self.root.join("default.project.json"))
            .ok()
            .and_then(|text| serde_json::from_str::<Value>(&text).ok())
            .map(|project| rojo_paths(&project))
            .unwrap_or_default()
    }
}

fn ignore_data_dir(gitignore: &Path) -> io::Result<()> {
    let existing = fs::read_to_string(gitignore).unwrap_or_default();
    let ignored = existing.lines().map(str::trim).any(|line| line == ".rogit" || line == ".rogit/" || line == "/.rogit/");
    if ignored {
        return Ok(());
    }
    let separator = if existing.is_empty() || existing.ends_with('\n') { "" } else { "\n" };
    fs::write(gitignore, format!("{existing}{separator}{DATA_DIR}/\n"))
}

/// Every tree node with a `$path` belongs to Rojo, together with everything under it.
pub fn rojo_paths(project: &Value) -> RojoPaths {
    let tree = &project["tree"];
    if tree.get("$path").is_some() {
        return RojoPaths { all: true, paths: Vec::new() };
    }
    let mut paths = Vec::new();
    collect(tree, "", &mut paths);
    paths.sort();
    RojoPaths { all: false, paths }
}

fn collect(node: &Value, path: &str, out: &mut Vec<String>) {
    let Some(children) = node.as_object() else { return };
    for (name, child) in children.iter().filter(|(name, _)| !name.starts_with('$')) {
        let child_path = if path.is_empty() { name.clone() } else { format!("{path}/{name}") };
        if child.get("$path").is_some() {
            out.push(child_path);
        } else {
            collect(child, &child_path, out);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn rojo_paths_follow_path_nodes() {
        let project = json!({
            "name": "game",
            "tree": {
                "$className": "DataModel",
                "ReplicatedStorage": {"$className": "ReplicatedStorage", "Shared": {"$path": "src/shared"}},
                "ServerScriptService": {"$className": "ServerScriptService", "Server": {"$path": "src/server"}},
                "Workspace": {"$className": "Workspace", "$properties": {"Gravity": 100}}
            }
        });
        let paths = rojo_paths(&project);
        assert!(!paths.all);
        assert_eq!(paths.paths, vec!["ReplicatedStorage/Shared", "ServerScriptService/Server"]);
    }

    #[test]
    fn a_whole_place_project_belongs_to_rojo() {
        assert!(rojo_paths(&json!({"tree": {"$path": "place"}})).all);
    }

    #[test]
    fn init_writes_config_and_ignores_data_dir_once() {
        let root = std::env::temp_dir().join(format!("rogit-test-{}", std::process::id()));
        fs::create_dir_all(&root).unwrap();
        fs::write(root.join(".gitignore"), "target/").unwrap();
        let project = Project::new(root.clone());
        let game = Game { name: "Test".into(), universe_id: 1, main_place_id: 2 };
        project.init(game.clone()).unwrap();
        project.init(game.clone()).unwrap();
        assert_eq!(project.config().unwrap(), Some(Config { game }));
        assert_eq!(fs::read_to_string(root.join(".gitignore")).unwrap(), "target/\n.rogit/\n");
        assert!(root.join(DATA_DIR).is_dir());
        fs::remove_dir_all(root).unwrap();
    }
}
