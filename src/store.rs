//! Copies of a game's places, with each piece stored once. A copy's place file is cut into pieces where its content
//! says to, so an edit changes only the pieces around it, and each piece is kept once in `store/`, compressed. A copy
//! itself (`*.copy`) is just the list of its pieces: commits, starting points and autosaves that share most of a place
//! share most of their pieces.

use crate::diff::par_map_by;
use rbx_dom_weak::WeakDom;
use std::collections::HashSet;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

const FORMAT: &str = "rogit-copy 1";

/// Pieces are at least this long (except the last), and at most `MAX_PIECE`; about 48 KiB on average.
const MIN_PIECE: usize = 16 << 10;
const MAX_PIECE: usize = 192 << 10;

/// Random numbers for the rolling hash that decides where pieces end (made at compile time, the same on every
/// computer, so the same content is always cut the same way).
const GEAR: [u64; 256] = {
    let mut table = [0u64; 256];
    let mut seed = 0x2545_f491_4f6c_dd1du64;
    let mut i = 0;
    while i < 256 {
        seed = seed.wrapping_add(0x9e37_79b9_7f4a_7c15);
        let mut z = seed;
        z = (z ^ (z >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
        table[i] = z ^ (z >> 31);
        i += 1;
    }
    table
};

pub struct Store {
    dir: PathBuf,
}

impl Store {
    /// The store of the game whose data is in `game`.
    pub fn new(game: &Path) -> Store {
        Store { dir: game.join("store") }
    }

    fn piece_file(&self, hash: &str) -> PathBuf {
        self.dir.join(&hash[..2]).join(&hash[2..])
    }

    /// Keeps a place file (as RoGit or Studio writes it) as the copy `file`: only pieces the store doesn't have yet are
    /// written.
    pub fn keep(&self, place: &[u8], file: &Path) -> Result<(), String> {
        let unpacked = unpack(place)?;
        let pieces = cut(&unpacked);
        let hashes: Vec<String> = par_map_by(&pieces, 64, |piece| blake3::hash(piece).to_hex()[..32].to_owned());
        let mut new = HashSet::new();
        let missing: Vec<(&str, &[u8])> = hashes
            .iter()
            .zip(&pieces)
            .filter(|(hash, _)| new.insert(hash.as_str()) && !self.piece_file(hash).exists())
            .map(|(hash, piece)| (hash.as_str(), *piece))
            .collect();
        for written in par_map_by(&missing, 4, |(hash, piece)| self.write_piece(hash, piece)) {
            written?;
        }
        let mut list = format!("{FORMAT} {}\n", unpacked.len());
        for hash in &hashes {
            list.push_str(hash);
            list.push('\n');
        }
        if let Some(parent) = file.parent() {
            fs::create_dir_all(parent).map_err(|e| e.to_string())?;
        }
        write_whole(file, list.as_bytes())
    }

    /// Keeps a place in memory as the copy `file`.
    pub fn keep_place(&self, dom: &WeakDom, file: &Path) -> Result<(), String> {
        self.keep(&crate::live::to_bytes(dom)?, file)
    }

    fn write_piece(&self, hash: &str, piece: &[u8]) -> Result<(), String> {
        let path = self.piece_file(hash);
        fs::create_dir_all(path.parent().unwrap()).map_err(|e| format!("Couldn't create {}: {e}", self.dir.display()))?;
        let packed = zstd::bulk::compress(piece, 3).map_err(|e| e.to_string())?;
        write_whole(&path, &packed)
    }

    /// The place file a copy holds. Its parts are stored uncompressed, which place files allow.
    pub fn bytes(&self, file: &Path) -> Result<Vec<u8>, String> {
        let (size, hashes) = read_list(file)?;
        let pieces = par_map_by(&hashes, 16, |hash| {
            let packed = fs::read(self.piece_file(hash)).map_err(|e| format!("A piece of {} is missing: {e}", file.display()))?;
            zstd::bulk::decompress(&packed, MAX_PIECE).map_err(|e| format!("A piece of {} is damaged: {e}", file.display()))
        });
        let mut place = Vec::with_capacity(size);
        for piece in pieces {
            place.extend_from_slice(&piece?);
        }
        Ok(place)
    }

    /// A copy, put back together in memory.
    pub fn read(&self, file: &Path) -> Result<WeakDom, String> {
        let bytes = self.bytes(file)?;
        rbx_binary::from_reader(&bytes[..]).map_err(|e| format!("Couldn't read {}: {e}", file.display()))
    }

    /// Deletes the pieces no copy of the game uses any more (for example after a branch was archived). Returns how
    /// many it deleted and how many bytes they took.
    pub fn sweep(&self) -> Result<(usize, u64), String> {
        let mut used = HashSet::new();
        for copy in copies(self.dir.parent().unwrap()) {
            // A copy that can't be read might still need its pieces.
            used.extend(read_list(&copy)?.1);
        }
        let (mut deleted, mut bytes) = (0, 0);
        let an_hour_ago = SystemTime::now() - Duration::from_secs(3600);
        for folder in fs::read_dir(&self.dir).into_iter().flatten().flatten() {
            let prefix = folder.file_name().to_string_lossy().into_owned();
            for entry in fs::read_dir(folder.path()).into_iter().flatten().flatten() {
                let name = entry.file_name().to_string_lossy().into_owned();
                let unused = match name.strip_suffix(".tmp") {
                    // Left by a write that didn't finish.
                    Some(_) => entry.metadata().and_then(|m| m.modified()).is_ok_and(|time| time < an_hour_ago),
                    None => !used.contains(&format!("{prefix}{name}")),
                };
                if unused {
                    let size = entry.metadata().map(|m| m.len()).unwrap_or_default();
                    if fs::remove_file(entry.path()).is_ok() {
                        deleted += 1;
                        bytes += size;
                    }
                }
            }
        }
        Ok((deleted, bytes))
    }
}

/// Every copy in a game's folder.
fn copies(game: &Path) -> Vec<PathBuf> {
    let mut found = Vec::new();
    let mut folders = vec![game.to_path_buf()];
    while let Some(folder) = folders.pop() {
        for entry in fs::read_dir(&folder).into_iter().flatten().flatten() {
            let path = entry.path();
            if path.is_dir() {
                if entry.file_name() != "store" {
                    folders.push(path);
                }
            } else if path.extension().is_some_and(|ext| ext == "copy") {
                found.push(path);
            }
        }
    }
    found
}

/// A copy's size and the pieces it's made of.
fn read_list(file: &Path) -> Result<(usize, Vec<String>), String> {
    let text = fs::read_to_string(file).map_err(|e| format!("Couldn't read {}: {e}", file.display()))?;
    let mut lines = text.lines();
    let size = lines.next().and_then(|line| line.strip_prefix(FORMAT)).and_then(|size| size.trim().parse().ok());
    let size = size.ok_or_else(|| format!("{} isn't a copy RoGit can read.", file.display()))?;
    let hashes: Vec<String> = lines.map(str::to_owned).collect();
    if hashes.iter().any(|hash| hash.len() != 32 || !hash.bytes().all(|b| b.is_ascii_hexdigit())) {
        return Err(format!("{} is damaged.", file.display()));
    }
    Ok((size, hashes))
}

/// Writes a file in one go: a half-written file never takes its place.
fn write_whole(path: &Path, bytes: &[u8]) -> Result<(), String> {
    let partial = path.with_extension("tmp");
    fs::write(&partial, bytes).map_err(|e| format!("Couldn't write {}: {e}", path.display()))?;
    fs::rename(&partial, path).map_err(|e| format!("Couldn't write {}: {e}", path.display()))
}

/// The same place file with every part stored uncompressed. Compressed, one edit changes a whole part (all the
/// positions of every Part, say); uncompressed, only the bytes it touches.
fn unpack(place: &[u8]) -> Result<Vec<u8>, String> {
    const HEADER: usize = 32;
    let invalid = || "That isn't a place file RoGit can read.".to_owned();
    if place.len() < HEADER || &place[..8] != b"<roblox!" {
        return Err(invalid());
    }
    let mut out = Vec::with_capacity(place.len() * 3);
    out.extend_from_slice(&place[..HEADER]);
    let mut at = HEADER;
    let number = |at: usize| u32::from_le_bytes(place[at..at + 4].try_into().unwrap()) as usize;
    while at + 16 <= place.len() {
        let (name, compressed, size) = (&place[at..at + 4], number(at + 4), number(at + 8));
        let stored = if compressed == 0 { size } else { compressed };
        let body = place.get(at + 16..at + 16 + stored).ok_or_else(invalid)?;
        out.extend_from_slice(name);
        out.extend_from_slice(&0u32.to_le_bytes());
        out.extend_from_slice(&(size as u32).to_le_bytes());
        out.extend_from_slice(&place[at + 12..at + 16]);
        if compressed == 0 {
            out.extend_from_slice(body);
        } else if body.starts_with(&[0x28, 0xb5, 0x2f, 0xfd]) {
            out.extend_from_slice(&zstd::bulk::decompress(body, size).map_err(|_| invalid())?);
        } else {
            out.extend_from_slice(&lz4_flex::block::decompress(body, size).map_err(|_| invalid())?);
        }
        at += 16 + stored;
        if name == b"END\0" {
            break;
        }
    }
    out.extend_from_slice(&place[at..]);
    Ok(out)
}

/// Cuts `data` into pieces where a rolling hash of the last 64 bytes says to, so the same content is cut the same way
/// wherever it sits.
fn cut(data: &[u8]) -> Vec<&[u8]> {
    let mut pieces = Vec::with_capacity(data.len() / (48 << 10) + 1);
    let mut rest = data;
    while !rest.is_empty() {
        let end = piece_end(rest);
        pieces.push(&rest[..end]);
        rest = &rest[end..];
    }
    pieces
}

fn piece_end(data: &[u8]) -> usize {
    if data.len() <= MIN_PIECE {
        return data.len();
    }
    let end = data.len().min(MAX_PIECE);
    let mut hash = 0u64;
    for (i, byte) in data[..end].iter().enumerate().skip(MIN_PIECE) {
        hash = (hash << 1).wrapping_add(GEAR[*byte as usize]);
        // One in 32,768: a piece ends about 32 KiB after its minimum.
        if hash >> 49 == 0 {
            return i + 1;
        }
    }
    end
}

#[cfg(test)]
mod tests {
    use super::*;
    use rbx_dom_weak::InstanceBuilder;
    use rbx_dom_weak::types::{CFrame, Matrix3, Variant, Vector3};

    fn place(parts: usize, moved: Option<usize>) -> WeakDom {
        let mut dom = WeakDom::new(InstanceBuilder::new("DataModel"));
        let workspace = dom.insert(dom.root_ref(), InstanceBuilder::new("Workspace"));
        for i in 0..parts {
            let x = if moved == Some(i) { 1000.0 } else { i as f32 };
            let part = InstanceBuilder::new("Part")
                .with_name(format!("Part{i}"))
                .with_property("CFrame", Variant::CFrame(CFrame::new(Vector3::new(x, 2.0, 3.0), Matrix3::identity())))
                .with_property("Anchored", Variant::Bool(i % 3 == 0));
            dom.insert(workspace, part);
        }
        dom
    }

    fn folder(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("rogit-store-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        dir
    }

    fn pieces(dir: &Path) -> usize {
        fs::read_dir(dir.join("store")).into_iter().flatten().flatten().map(|d| fs::read_dir(d.path()).unwrap().count()).sum()
    }

    #[test]
    fn a_copy_reads_back_as_the_same_place() {
        let dir = folder("same");
        let store = Store::new(&dir);
        let original = place(20_000, None);
        store.keep_place(&original, &dir.join("a.copy")).unwrap();
        let back = store.read(&dir.join("a.copy")).unwrap();
        assert!(crate::diff::compare(&original, &back, crate::diff::Rules::default()).rows.is_empty());
        assert_eq!(back.descendants().count(), original.descendants().count());
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn a_small_edit_stores_only_a_few_new_pieces() {
        let dir = folder("edit");
        let store = Store::new(&dir);
        store.keep_place(&place(60_000, None), &dir.join("a.copy")).unwrap();
        let first = pieces(&dir);
        store.keep_place(&place(60_000, Some(30_000)), &dir.join("b.copy")).unwrap();
        let added = pieces(&dir) - first;
        assert!(first > 10 && added > 0 && added <= first / 4, "{added} new pieces of {first}");
        // The same place again adds nothing.
        store.keep_place(&place(60_000, None), &dir.join("c.copy")).unwrap();
        assert_eq!(pieces(&dir), first + added);
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn sweeping_keeps_what_copies_use() {
        let dir = folder("sweep");
        let store = Store::new(&dir);
        store.keep_place(&place(30_000, None), &dir.join("branches/a/start.copy")).unwrap();
        store.keep_place(&place(30_000, Some(5)), &dir.join("branches/b/commits/c1.copy")).unwrap();
        let all = pieces(&dir);
        assert_eq!(store.sweep().unwrap().0, 0);
        fs::remove_dir_all(dir.join("branches/b")).unwrap();
        let (deleted, _) = store.sweep().unwrap();
        assert!(deleted > 0 && pieces(&dir) == all - deleted, "deleted {deleted} of {all}, {} left", pieces(&dir));
        assert!(store.read(&dir.join("branches/a/start.copy")).is_ok());
        fs::remove_dir_all(dir).unwrap();
    }

    /// Measures storing real places: `ROGIT_BENCH_COPIES` lists place files, separated by `;`, stored in order.
    #[test]
    #[ignore]
    fn stores_real_places() {
        let Ok(files) = std::env::var("ROGIT_BENCH_COPIES") else { return };
        let dir = folder("bench");
        let store = Store::new(&dir);
        let mut before = 0;
        for (i, file) in files.split(';').enumerate() {
            let bytes = fs::read(file).unwrap();
            let started = std::time::Instant::now();
            let copy = dir.join(format!("{i}.copy"));
            store.keep(&bytes, &copy).unwrap();
            let kept = started.elapsed();
            let started = std::time::Instant::now();
            let dom = store.read(&copy).unwrap();
            let read = started.elapsed();
            let size: u64 = fs::read_dir(dir.join("store"))
                .unwrap()
                .flatten()
                .flat_map(|d| fs::read_dir(d.path()).unwrap().flatten())
                .map(|e| e.metadata().unwrap().len())
                .sum();
            println!(
                "{file}: {} MB file, kept in {} ms (+{:.1} MB in the store, {} pieces in all), read back in {} ms ({} objects)",
                bytes.len() >> 20, kept.as_millis(), (size - before) as f64 / 1048576.0, pieces(&dir), read.as_millis(),
                dom.descendants().count()
            );
            before = size;
        }
        fs::remove_dir_all(dir).unwrap();
    }
}
