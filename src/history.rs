//! What happened in this project: merges into main, updates from main, reverts and archived branches. The plugin
//! lists it, and opening a merge or an update shows what it changed.

use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::fs;
use std::path::PathBuf;

/// How many events the list keeps.
const KEEP: usize = 200;

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct Event {
    pub id: String,
    /// "create", "commit", "merge", "update", "revert", "restore" or "archive".
    pub kind: String,
    pub branch: String,
    /// Unix time in seconds.
    pub time: u64,
    /// Added, removed and changed counts, when the event changed a place.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub summary: Option<Value>,
    /// Whether the rows of what changed were kept, so the event can be opened.
    #[serde(default)]
    pub has_rows: bool,
    /// A commit's message.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
}

pub struct History {
    data: PathBuf,
}

impl History {
    pub fn new(data: PathBuf) -> Self {
        History { data }
    }

    fn file(&self) -> PathBuf {
        self.data.join("history.json")
    }

    fn rows_file(&self, id: &str) -> PathBuf {
        self.data.join("history").join(format!("{id}.json"))
    }

    /// Newest first.
    pub fn list(&self) -> Vec<Event> {
        fs::read(self.file()).ok().and_then(|bytes| serde_json::from_slice(&bytes).ok()).unwrap_or_default()
    }

    /// Adds an event, with the rows of what it changed if there are any.
    pub fn add(&self, mut event: Event, rows: Option<Value>) -> Result<(), String> {
        fs::create_dir_all(self.data.join("history")).map_err(|e| e.to_string())?;
        if let Some(rows) = rows {
            fs::write(self.rows_file(&event.id), rows.to_string()).map_err(|e| e.to_string())?;
            event.has_rows = true;
        }
        let mut events = self.list();
        events.insert(0, event);
        for old in events.drain(KEEP.min(events.len())..) {
            let _ = fs::remove_file(self.rows_file(&old.id));
        }
        fs::write(self.file(), serde_json::to_vec_pretty(&events).unwrap()).map_err(|e| e.to_string())
    }

    /// The rows an event kept: `{ "rows": [...], "truncated": n }`.
    pub fn rows(&self, id: &str) -> Result<Value, String> {
        if !id.chars().all(|c| c.is_ascii_alphanumeric()) {
            return Err("Invalid history entry.".into());
        }
        let bytes = fs::read(self.rows_file(id)).map_err(|_| "That history entry has no details.".to_owned())?;
        serde_json::from_slice(&bytes).map_err(|e| e.to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn keeps_events_newest_first_with_their_rows() {
        let data = std::env::temp_dir().join(format!("rogit-history-{}", std::process::id()));
        let history = History::new(data.clone());
        let event = |id: &str| Event { id: id.into(), kind: "merge".into(), branch: "b".into(), time: 1, summary: None, has_rows: false, message: None };
        history.add(event("m1"), Some(json!({ "rows": [], "truncated": 0 }))).unwrap();
        history.add(event("a2"), None).unwrap();
        let list = history.list();
        assert_eq!(list.iter().map(|e| e.id.as_str()).collect::<Vec<_>>(), ["a2", "m1"]);
        assert!(list[1].has_rows && !list[0].has_rows);
        assert_eq!(history.rows("m1").unwrap()["truncated"], 0);
        assert!(history.rows("../x").is_err());
        fs::remove_dir_all(data).unwrap();
    }
}
