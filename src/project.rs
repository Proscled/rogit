//! Where RoGit keeps its data: a folder per game under `~/.rogit/games` (`%LOCALAPPDATA%\rogit\games` on Windows),
//! named after the game's ID. Each holds the game's branches and their history, and `game.toml` once Init has run in
//! the game's start place.

use serde::{Deserialize, Serialize};
use std::fs;
use std::io;
use std::path::PathBuf;

const CONFIG_FILE: &str = "game.toml";

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

/// RoGit's own folder: `~/.rogit`, or `%LOCALAPPDATA%\rogit` on Windows (the installers put rogit itself in its
/// `bin`). `ROGIT_HOME` points it somewhere else.
pub fn home() -> Result<PathBuf, String> {
    if let Some(dir) = std::env::var_os("ROGIT_HOME") {
        return Ok(PathBuf::from(dir));
    }
    if cfg!(windows) {
        let local = std::env::var_os("LOCALAPPDATA").ok_or("LOCALAPPDATA isn't set.")?;
        Ok(PathBuf::from(local).join("rogit"))
    } else {
        let home = std::env::var_os("HOME").ok_or("HOME isn't set.")?;
        Ok(PathBuf::from(home).join(".rogit"))
    }
}

/// The folder with a folder for each game.
pub fn games() -> Result<PathBuf, String> {
    Ok(home()?.join("games"))
}

/// One game's data.
pub struct Project {
    pub root: PathBuf,
}

impl Project {
    pub fn new(root: PathBuf) -> Self {
        Project { root }
    }

    /// The game this folder is for, once it's set up.
    pub fn config(&self) -> io::Result<Option<Config>> {
        match fs::read_to_string(self.root.join(CONFIG_FILE)) {
            Ok(text) => toml::from_str(&text)
                .map(Some)
                .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, format!("{CONFIG_FILE} is invalid: {e}"))),
            Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(None),
            Err(e) => Err(e),
        }
    }

    pub fn init(&self, game: Game) -> io::Result<Config> {
        let config = Config { game };
        let text = toml::to_string(&config).map_err(|e| io::Error::new(io::ErrorKind::Other, e.to_string()))?;
        fs::create_dir_all(&self.root)?;
        fs::write(self.root.join(CONFIG_FILE), text)?;
        Ok(config)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn init_writes_the_game_once() {
        let root = std::env::temp_dir().join(format!("rogit-test-{}", std::process::id())).join("games").join("1");
        let project = Project::new(root.clone());
        assert_eq!(project.config().unwrap(), None);
        let game = Game { name: "Test".into(), universe_id: 1, main_place_id: 2 };
        project.init(game.clone()).unwrap();
        project.init(game.clone()).unwrap();
        assert_eq!(project.config().unwrap(), Some(Config { game }));
        fs::remove_dir_all(root.parent().unwrap().parent().unwrap()).unwrap();
    }
}
