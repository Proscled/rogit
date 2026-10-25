//! Branches live in `.rogit/branches/`: `<name>.rbxl` is the file you open in Studio, and `<name>/` keeps its
//! details and starting point.

use crate::place;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

/// Each 4 MiB base64 part from the plugin decodes to exactly this many bytes.
pub const PART_BYTES: u64 = 3 * 1024 * 1024;

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct Branch {
    pub name: String,
    /// Unix time in seconds.
    pub created: u64,
    pub has_starting_point: bool,
    /// Unix time of the last merge into main.
    #[serde(default)]
    pub merged: Option<u64>,
}

fn now() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or_default()
}

fn modified(path: &Path) -> Option<u64> {
    fs::metadata(path).and_then(|m| m.modified()).ok()?.duration_since(UNIX_EPOCH).ok().map(|d| d.as_secs())
}

pub struct Branches {
    data: PathBuf,
}

pub fn valid_name(name: &str) -> bool {
    let mut chars = name.chars();
    name.len() <= 40
        && chars.next().is_some_and(|c| c.is_ascii_alphanumeric())
        && chars.all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
}

pub fn valid_capture(id: &str) -> bool {
    (8..=32).contains(&id.len()) && id.chars().all(|c| c.is_ascii_alphanumeric())
}

impl Branches {
    pub fn new(data: PathBuf) -> Self {
        Branches { data }
    }

    fn dir(&self) -> PathBuf {
        self.data.join("branches")
    }

    pub fn file(&self, name: &str) -> PathBuf {
        self.dir().join(format!("{name}.rbxl"))
    }

    fn details(&self, name: &str) -> PathBuf {
        self.dir().join(name).join("branch.json")
    }

    pub fn upload_dir(&self, capture: &str) -> PathBuf {
        self.data.join("uploads").join(capture)
    }

    /// Stores one base64 part of an uploaded service copy at its place in the file.
    pub fn store_part(&self, capture: &str, service: &str, part: u64, bytes: &[u8]) -> Result<(), String> {
        let dir = self.upload_dir(capture);
        fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
        let file = fs::OpenOptions::new()
            .create(true)
            .write(true)
            .truncate(false)
            .open(dir.join(format!("{service}.rbxm")))
            .map_err(|e| e.to_string())?;
        write_at(&file, bytes, part * PART_BYTES).map_err(|e| e.to_string())
    }

    pub fn get(&self, name: &str) -> Option<Branch> {
        serde_json::from_slice(&fs::read(self.details(name)).ok()?).ok()
    }

    pub fn list(&self) -> Vec<Branch> {
        let mut list: Vec<Branch> = fs::read_dir(self.dir())
            .into_iter()
            .flatten()
            .flatten()
            .filter(|entry| entry.path().is_dir())
            .filter_map(|entry| self.get(&entry.file_name().to_string_lossy()))
            .collect();
        list.sort_by(|a, b| b.created.cmp(&a.created));
        list
    }

    fn save(&self, branch: &Branch) -> Result<(), String> {
        let path = self.details(&branch.name);
        fs::create_dir_all(path.parent().unwrap()).map_err(|e| e.to_string())?;
        fs::write(path, serde_json::to_vec_pretty(branch).unwrap()).map_err(|e| e.to_string())
    }

    /// Builds `<name>.rbxl` from an uploaded copy of main.
    pub fn create(&self, name: &str, capture: &str, manifest: &Value) -> Result<place::BuildReport, String> {
        if !valid_name(name) {
            return Err("Use 1–40 letters, numbers, - or _ for the branch name, starting with a letter or number.".into());
        }
        if self.get(name).is_some() || self.file(name).exists() {
            return Err(format!("A branch called {name} already exists."));
        }
        fs::create_dir_all(self.dir()).map_err(|e| e.to_string())?;
        let upload = self.upload_dir(capture);
        let report = place::build(&upload, manifest, &self.file(name));
        let _ = fs::remove_dir_all(&upload);
        let report = report?;
        self.save(&Branch { name: name.to_owned(), created: now(), has_starting_point: false, merged: None })?;
        Ok(report)
    }

    /// Keeps the copy taken when the branch first opened as its starting point.
    pub fn set_starting_point(&self, name: &str, capture: &str, manifest: &Value) -> Result<(), String> {
        let mut branch = self.get(name).ok_or_else(|| format!("There's no branch called {name}."))?;
        let target = self.dir().join(name).join("start");
        let _ = fs::remove_dir_all(&target);
        fs::rename(self.upload_dir(capture), &target).map_err(|e| format!("Couldn't keep the starting point: {e}"))?;
        fs::write(target.join("manifest.json"), manifest.to_string()).map_err(|e| e.to_string())?;
        // Studio changes some things when it opens a file (its lighting upgrade, for example). Rewrite the
        // branch file from the starting point, so it matches it until you save the branch yourself.
        place::build(&target, manifest, &self.file(name))?;
        branch.has_starting_point = true;
        self.save(&branch)
    }

    /// The branch as it was when it first opened, put back together in memory.
    pub fn starting_point(&self, name: &str) -> Result<rbx_dom_weak::WeakDom, String> {
        let branch = self.get(name).ok_or_else(|| format!("There's no branch called {name}."))?;
        if !branch.has_starting_point {
            return Err(format!("{name} has no starting point yet. Open it in Studio once first."));
        }
        let dir = self.dir().join(name).join("start");
        let manifest: Value = serde_json::from_slice(&fs::read(dir.join("manifest.json")).map_err(|e| e.to_string())?)
            .map_err(|e| e.to_string())?;
        place::assemble(&dir, &manifest).map(|(dom, _)| dom)
    }

    /// Keeps the newest copy of the branch from Studio (it includes unsaved edits).
    pub fn keep_latest(&self, name: &str, capture: &str, manifest: &Value) -> Result<rbx_dom_weak::WeakDom, String> {
        let target = self.dir().join(name).join("latest");
        let _ = fs::remove_dir_all(&target);
        fs::rename(self.upload_dir(capture), &target).map_err(|e| format!("Couldn't keep the copy: {e}"))?;
        fs::write(target.join("manifest.json"), manifest.to_string()).map_err(|e| e.to_string())?;
        place::assemble(&target, manifest).map(|(dom, _)| dom)
    }

    /// The branch's newest content: its saved file, or the copy from its last review if that's newer (it includes
    /// edits made before saving). Returns the place, where it came from, and when.
    pub fn newest(&self, name: &str) -> Result<(rbx_dom_weak::WeakDom, &'static str, u64), String> {
        let file = self.file(name);
        let latest = self.dir().join(name).join("latest");
        let file_time = modified(&file).unwrap_or_default();
        match modified(&latest.join("manifest.json")) {
            Some(review_time) if review_time > file_time => {
                let manifest: Value = serde_json::from_slice(&fs::read(latest.join("manifest.json")).map_err(|e| e.to_string())?)
                    .map_err(|e| e.to_string())?;
                Ok((place::assemble(&latest, &manifest)?.0, "reviewed", review_time))
            }
            _ => Ok((place::read(&file)?, "saved", file_time)),
        }
    }

    fn merge_copy(&self, name: &str, merge: &str) -> PathBuf {
        self.dir().join(name).join("merges").join(format!("{merge}.rbxl"))
    }

    /// Keeps the branch as it was merged, so the next merge only brings what changed after it. Keeps the last few,
    /// since main may still have an older merge (the newest one could be undone or never saved).
    pub fn keep_merge(&self, name: &str, merge: &str, dom: &rbx_dom_weak::WeakDom) -> Result<(), String> {
        let file = self.merge_copy(name, merge);
        let dir = file.parent().unwrap();
        fs::create_dir_all(dir).map_err(|e| e.to_string())?;
        place::write(dom, &file)?;
        let mut copies: Vec<(u64, PathBuf)> =
            fs::read_dir(dir).into_iter().flatten().flatten().map(|e| (modified(&e.path()).unwrap_or_default(), e.path())).collect();
        copies.sort_by(|a, b| b.0.cmp(&a.0));
        for (_, old) in copies.into_iter().skip(5) {
            let _ = fs::remove_file(old);
        }
        Ok(())
    }

    /// What a merge compares the branch with: the branch as it was last merged, if main still has that merge (its
    /// record says `last`), or else its starting point. Returns the place and whether it's a merge.
    pub fn merge_base(&self, name: &str, last: Option<&str>) -> Result<(rbx_dom_weak::WeakDom, bool), String> {
        if let Some(file) = last.filter(|id| valid_capture(id)).map(|id| self.merge_copy(name, id)).filter(|f| f.exists()) {
            return Ok((place::read(&file)?, true));
        }
        Ok((self.starting_point(name)?, false))
    }

    pub fn mark_merged(&self, name: &str) -> Result<(), String> {
        let mut branch = self.get(name).ok_or_else(|| format!("There's no branch called {name}."))?;
        branch.merged = Some(now());
        self.save(&branch)
    }

    pub fn open(&self, name: &str) -> Result<(), String> {
        let file = self.file(name);
        if !file.exists() {
            return Err(format!("There's no branch file for {name}."));
        }
        open_in_studio(&file).map_err(|e| format!("Couldn't open Studio: {e}"))
    }
}

#[cfg(unix)]
fn write_at(file: &fs::File, bytes: &[u8], offset: u64) -> std::io::Result<()> {
    std::os::unix::fs::FileExt::write_all_at(file, bytes, offset)
}

#[cfg(windows)]
fn write_at(file: &fs::File, bytes: &[u8], offset: u64) -> std::io::Result<()> {
    let mut written = 0;
    while written < bytes.len() {
        written += std::os::windows::fs::FileExt::seek_write(file, &bytes[written..], offset + written as u64)?;
    }
    Ok(())
}

fn open_in_studio(file: &Path) -> std::io::Result<()> {
    if cfg!(windows) {
        Command::new("cmd").args(["/C", "start", ""]).arg(file).spawn()?;
        return Ok(());
    }
    // Opening Studio by name can pick another app copy with the same name, which starts Studio without the
    // file. The installed app's full path always opens the file.
    let home = std::env::var("HOME").unwrap_or_default();
    let studio = [PathBuf::from("/Applications/RobloxStudio.app"), Path::new(&home).join("Applications/RobloxStudio.app")]
        .into_iter()
        .find(|path| path.exists())
        .ok_or_else(|| std::io::Error::new(std::io::ErrorKind::NotFound, "Roblox Studio isn't installed in Applications"))?;
    Command::new("open").arg("-a").arg(studio).arg(file).spawn()?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn branch_names() {
        assert!(valid_name("new-map_2"));
        assert!(!valid_name(""));
        assert!(!valid_name("-start"));
        assert!(!valid_name("has space"));
        assert!(!valid_name("../escape"));
        assert!(!valid_name(&"x".repeat(41)));
    }

    #[test]
    fn parts_land_in_order_whatever_order_they_arrive() {
        let data = std::env::temp_dir().join(format!("rogit-parts-{}", std::process::id()));
        let branches = Branches::new(data.clone());
        let second = vec![2u8; 10];
        let first = vec![1u8; PART_BYTES as usize];
        branches.store_part("capture01", "Workspace", 1, &second).unwrap();
        branches.store_part("capture01", "Workspace", 0, &first).unwrap();
        let joined = fs::read(branches.upload_dir("capture01").join("Workspace.rbxm")).unwrap();
        assert_eq!(joined.len(), PART_BYTES as usize + 10);
        assert!(joined[..PART_BYTES as usize].iter().all(|b| *b == 1) && joined[PART_BYTES as usize..].iter().all(|b| *b == 2));
        fs::remove_dir_all(data).unwrap();
    }
}
