//! Compares a branch with its starting point, object by object, and lays the result out like Studio's Explorer.

use crate::place::property_type;
use crate::project::RojoPaths;
use rbx_dom_weak::types::{CFrame, Ref, Variant, Vector3};
use rbx_dom_weak::{Instance, WeakDom};
use rbx_reflection::DataType;
use serde::Serialize;
use std::collections::{HashMap, HashSet};

pub const TAG: &str = "RoGitId";
/// Workspace attribute in main that records the last merge of each branch.
pub const MERGES: &str = "RoGitMerges";
/// Workspace attribute in a branch that records the last update from main.
pub const UPDATE: &str = "RoGitUpdate";
const MAX_ROWS: usize = 2000;
/// Services whose contents are saved in place files. Matches the plugin's list.
pub(crate) const SERVICES: [&str; 18] = [
    "Workspace", "Lighting", "MaterialService", "ReplicatedFirst", "ReplicatedStorage", "ServerScriptService",
    "ServerStorage", "StarterGui", "StarterPack", "StarterPlayer", "Teams", "SoundService", "TextChatService",
    "Chat", "LocalizationService", "TestService", "SocialService", "VoiceChatService",
];
/// Properties that Studio changes by itself, or that only one kind of copy contains.
pub(crate) const IGNORED: [&str; 9] = [
    "UniqueId", "HistoryId", "Capabilities", "DefinesCapabilities", "SourceAssetId", "PhysicsGrid", "NeedsPivotMigration",
    // Studio keeps this in step with the model's pivot; it can't be set and moves whenever the model moves.
    "ModelMeshCFrame",
    // Studio's own camera, which isn't part of a branch.
    "CurrentCamera",
];
/// Changes that only move or turn an object. A moved model shows once, with these folded in from inside it.
const SPATIAL: [&str; 3] = ["Position", "Rotation", "Pivot"];

#[derive(Serialize, Clone, Copy, PartialEq, Debug)]
#[serde(rename_all = "lowercase")]
pub enum Status {
    Added,
    Removed,
    Changed,
    Context,
}

#[derive(Serialize, Clone, Debug, PartialEq)]
pub struct Change {
    pub name: String,
    pub old: String,
    pub new: String,
    /// Set when this change conflicts with main and needs a choice.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub conflict: Option<usize>,
}

impl Change {
    pub fn new(name: impl Into<String>, old: impl Into<String>, new: impl Into<String>) -> Self {
        Change { name: name.into(), old: old.into(), new: new.into(), conflict: None }
    }
}

#[derive(Serialize, Debug)]
pub struct Row {
    pub depth: usize,
    pub key: String,
    pub name: String,
    pub class: String,
    pub status: Status,
    pub changes: Vec<Change>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub conflict: Option<usize>,
}

#[derive(Serialize, serde::Deserialize, Default, Clone, Debug, PartialEq)]
pub struct Summary {
    pub added: usize,
    pub removed: usize,
    pub changed: usize,
}

#[derive(Serialize, Debug)]
pub struct Review {
    pub summary: Summary,
    pub rows: Vec<Row>,
    /// Rows left out because the review was too long.
    pub truncated: usize,
}

// Index of the objects RoGit tracks in one place ----------------------------------------------------

pub(crate) struct Entry {
    /// The key shared across places (the starting point's, once matched).
    pub key: String,
    /// The key as found in this place: its own RoGit ID or path. Studio finds the object by this one.
    pub own_key: String,
    pub referent: Ref,
    pub parent: Option<String>,
    pub path: String,
}

#[derive(Default)]
pub(crate) struct Index {
    pub entries: Vec<Entry>,
    pub by_key: HashMap<String, usize>,
    pub by_ref: HashMap<Ref, String>,
}

impl Index {
    pub fn get(&self, key: &str) -> Option<&Entry> {
        self.by_key.get(key).map(|&i| &self.entries[i])
    }

    fn push(&mut self, entry: Entry) {
        self.by_key.insert(entry.key.clone(), self.entries.len());
        self.by_ref.insert(entry.referent, entry.key.clone());
        self.entries.push(entry);
    }

    fn truncate(&mut self, len: usize) {
        for entry in self.entries.drain(len..) {
            self.by_key.remove(&entry.key);
            self.by_ref.remove(&entry.referent);
        }
    }
}

/// The Attributes property's name, made once: making a property name takes a global lock.
static ATTRIBUTES: std::sync::LazyLock<rbx_dom_weak::Ustr> = std::sync::LazyLock::new(|| rbx_dom_weak::ustr("Attributes"));

pub(crate) fn is_script(inst: &Instance) -> bool {
    matches!(inst.class.as_str(), "Script" | "LocalScript" | "ModuleScript")
}

fn tag(inst: &Instance) -> Option<String> {
    inst.properties.get(&*ATTRIBUTES).and_then(|v| match v {
        // Place files store attribute text as raw bytes, so the ID usually arrives as a BinaryString.
        Variant::Attributes(attributes) => match attributes.get(TAG) {
            Some(Variant::String(id)) if !id.is_empty() => Some(id.clone()),
            Some(Variant::BinaryString(bytes)) => {
                let bytes: &[u8] = bytes.as_ref();
                (!bytes.is_empty()).then(|| String::from_utf8_lossy(bytes).into_owned())
            }
            _ => None,
        },
        _ => None,
    })
}

/// Lists what RoGit tracks, using the same rules as the plugin: everything in the saved services except
/// scripts, Folders that contain a script anywhere inside, and whatever Rojo syncs. Objects are keyed by their
/// RoGit ID; objects without one (or with a copied one) are keyed by their path.
pub(crate) fn index(dom: &WeakDom, rojo: &RojoPaths) -> Index {
    let mut index = Index::default();
    if rojo.all {
        return index;
    }
    let rojo: HashSet<&str> = rojo.paths.iter().map(String::as_str).collect();
    let mut untagged: HashMap<String, usize> = HashMap::new();
    for &service_ref in dom.root().children() {
        let service = dom.get_by_ref(service_ref).unwrap();
        if !SERVICES.contains(&service.class.as_str()) || rojo.contains(service.name.as_str()) {
            continue;
        }
        let key = format!("service:{}", service.name);
        index.push(Entry { key: key.clone(), own_key: key.clone(), referent: service_ref, parent: None, path: service.name.clone() });
        visit(dom, service_ref, &service.name, &key, &rojo, &mut untagged, &mut index);
    }
    index
}

fn visit(
    dom: &WeakDom,
    parent: Ref,
    parent_path: &str,
    parent_key: &str,
    rojo: &HashSet<&str>,
    untagged: &mut HashMap<String, usize>,
    index: &mut Index,
) -> bool {
    let mut has_script = false;
    for &child_ref in dom.get_by_ref(parent).unwrap().children() {
        let child = dom.get_by_ref(child_ref).unwrap();
        let path = format!("{parent_path}/{}", child.name);
        if is_script(child) {
            has_script = true;
            continue;
        }
        // Studio's camera moves whenever you look around; it isn't part of a branch.
        if child.class.as_str() == "Camera" {
            continue;
        }
        if rojo.contains(path.as_str()) {
            continue;
        }
        let key = match tag(child).filter(|id| !index.by_key.contains_key(id)) {
            Some(id) => id,
            None => {
                let n = untagged.entry(path.clone()).or_default();
                *n += 1;
                format!("path:{path}#{n}")
            }
        };
        let mark = index.entries.len();
        index.push(Entry { key: key.clone(), own_key: key.clone(), referent: child_ref, parent: Some(parent_key.to_owned()), path: path.clone() });
        if visit(dom, child_ref, &path, &key, rojo, untagged, index) {
            has_script = true;
            if child.class.as_str() == "Folder" {
                index.truncate(mark);
            }
        }
    }
    has_script
}

// Comparing values ---------------------------------------------------------------------------------

/// Equal within rounding. Infinite values (common in constraints and UI limits) and broken NaN values count as
/// equal to themselves.
fn close(a: f32, b: f32) -> bool {
    if a.is_nan() || b.is_nan() || a.is_infinite() || b.is_infinite() {
        return a == b || (a.is_nan() && b.is_nan());
    }
    (a - b).abs() <= 1e-4 * (1.0 + a.abs().max(b.abs()))
}

fn close3(a: &Vector3, b: &Vector3) -> bool {
    close(a.x, b.x) && close(a.y, b.y) && close(a.z, b.z)
}

fn close_cframe(a: &CFrame, b: &CFrame) -> bool {
    close3(&a.position, &b.position)
        && close3(&a.orientation.x, &b.orientation.x)
        && close3(&a.orientation.y, &b.orientation.y)
        && close3(&a.orientation.z, &b.orientation.z)
}

/// Attributes that never count as changes: RoGit's own, and the `RBX_` ones Roblox keeps for itself (for example
/// while upgrading a place's lighting).
pub(crate) fn own_attribute(name: &str) -> bool {
    name == TAG || name == MERGES || name == UPDATE || name.starts_with("RBX_")
}

/// Equal, allowing for rounding in saved numbers. References compare by what they point at.
pub(crate) fn same(a: &Variant, b: &Variant, refs: (&Index, &Index)) -> bool {
    match (a, b) {
        (Variant::Float32(x), Variant::Float32(y)) => close(*x, *y),
        (Variant::Float64(x), Variant::Float64(y)) => close(*x as f32, *y as f32),
        (Variant::Vector3(x), Variant::Vector3(y)) => close3(x, y),
        (Variant::Vector2(x), Variant::Vector2(y)) => close(x.x, y.x) && close(x.y, y.y),
        (Variant::Color3(x), Variant::Color3(y)) => close(x.r, y.r) && close(x.g, y.g) && close(x.b, y.b),
        (Variant::CFrame(x), Variant::CFrame(y)) => close_cframe(x, y),
        (Variant::OptionalCFrame(x), Variant::OptionalCFrame(y)) => match (x, y) {
            (Some(x), Some(y)) => close_cframe(x, y),
            (x, y) => x.is_none() && y.is_none(),
        },
        (Variant::Ref(x), Variant::Ref(y)) => refs.0.by_ref.get(x) == refs.1.by_ref.get(y),
        (Variant::Attributes(x), Variant::Attributes(y)) => {
            let keys: HashSet<&String> = x.iter().chain(y.iter()).map(|(k, _)| k).filter(|k| !own_attribute(k)).collect();
            keys.into_iter().all(|k| match (x.get(k.as_str()), y.get(k.as_str())) {
                (Some(a), Some(b)) => same(a, b, refs),
                (a, b) => a.is_none() && b.is_none(),
            })
        }
        _ => a == b,
    }
}

fn number(n: f64) -> String {
    let text = format!("{n:.3}");
    let text = text.trim_end_matches('0').trim_end_matches('.');
    if text == "-0" { "0".into() } else { text.into() }
}

fn rgb(r: f32, g: f32, b: f32) -> String {
    let byte = |c: f32| (c * 255.0).round() as i32;
    format!("{}, {}, {}", byte(r), byte(g), byte(b))
}

fn vector(v: &Vector3) -> String {
    format!("{}, {}, {}", number(v.x as f64), number(v.y as f64), number(v.z as f64))
}

/// A short, readable version of a value for the review.
pub(crate) fn show(value: &Variant, class: &str, property: &str, index: &Index, other_rotation_differs: bool) -> String {
    let text = match value {
        Variant::Bool(b) => b.to_string(),
        Variant::Float32(n) => number(*n as f64),
        Variant::Float64(n) => number(*n),
        Variant::Int32(n) => n.to_string(),
        Variant::Int64(n) => n.to_string(),
        Variant::String(s) if s.is_empty() => "(empty)".into(),
        Variant::String(s) => s.clone(),
        Variant::Color3(c) => rgb(c.r, c.g, c.b),
        Variant::Color3uint8(c) => format!("{}, {}, {}", c.r, c.g, c.b),
        Variant::Vector3(v) => vector(v),
        Variant::Vector2(v) => format!("{}, {}", number(v.x as f64), number(v.y as f64)),
        Variant::CFrame(c) if other_rotation_differs => angles(c),
        Variant::CFrame(c) => vector(&c.position),
        Variant::OptionalCFrame(Some(c)) => vector(&c.position),
        Variant::OptionalCFrame(None) => "none".into(),
        Variant::Enum(e) => enum_name(class, property, e.to_u32()).unwrap_or_else(|| e.to_u32().to_string()),
        Variant::ContentId(c) => c.as_str().to_owned(),
        Variant::Ref(r) => index.by_ref.get(r).and_then(|k| index.get(k)).map(|e| e.path.clone()).unwrap_or_else(|| "none".into()),
        Variant::BinaryString(_) | Variant::SharedString(_) => "(data)".into(),
        Variant::Attributes(a) => {
            let mut parts: Vec<String> =
                a.iter().filter(|(k, _)| !own_attribute(k)).map(|(k, v)| format!("{k}={}", show(v, "", "", index, false))).collect();
            parts.sort();
            if parts.is_empty() { "none".into() } else { parts.join(", ") }
        }
        other => format!("{other:?}"),
    };
    if text.chars().count() > 80 { format!("{}…", text.chars().take(80).collect::<String>()) } else { text }
}

/// Rotation as X, Y, Z degrees, like Studio's Orientation (rows of the rotation matrix, Roblox's XYZ order).
fn angles(c: &CFrame) -> String {
    let m = &c.orientation;
    let degrees = |radians: f32| number((radians.to_degrees() as f64 * 10.0).round() / 10.0);
    let x = (-m.y.z).atan2(m.z.z);
    let y = m.x.z.clamp(-1.0, 1.0).asin();
    let z = (-m.x.y).atan2(m.x.x);
    format!("{}°, {}°, {}°", degrees(x), degrees(y), degrees(z))
}

fn enum_name(class: &str, property: &str, value: u32) -> Option<String> {
    let DataType::Enum(name) = property_type(class, property)? else { return None };
    let db = rbx_reflection_database::get().ok()?;
    db.enums.get(&name[..])?.items.iter().find(|(_, v)| **v == value).map(|(item, _)| item.to_string())
}

/// What builders call a property in the review.
pub(crate) fn label(property: &str, rotated: bool) -> String {
    match property {
        "CFrame" if rotated => "Rotation",
        "CFrame" => "Position",
        "WorldPivotData" => "Pivot",
        other => other,
    }
    .to_owned()
}

pub(crate) fn rotation_differs(a: &Variant, b: &Variant) -> bool {
    match (a, b) {
        (Variant::CFrame(x), Variant::CFrame(y)) => close3(&x.position, &y.position) && !close_cframe(x, y),
        _ => false,
    }
}

fn changes(start: (&WeakDom, &Index, Ref), current: (&WeakDom, &Index, Ref)) -> Vec<Change> {
    let (old, new) = (start.0.get_by_ref(start.2).unwrap(), current.0.get_by_ref(current.2).unwrap());
    let mut out = Vec::new();
    if old.name != new.name {
        out.push(Change::new("Name", old.name.clone(), new.name.clone()));
    }
    let class = new.class.as_str();
    // Looked up by name (not searched), since big places have millions of properties.
    let mut changed: Vec<(&str, &Variant, &Variant)> = Vec::new();
    for (key, after) in &new.properties {
        let name = key.as_str();
        if IGNORED.contains(&name) {
            continue;
        }
        if let Some(before) = old.properties.get(key) {
            if !same(before, after, (start.1, current.1)) {
                changed.push((name, before, after));
            }
        }
    }
    changed.sort_unstable_by_key(|(name, _, _)| *name);
    for (name, before, after) in changed {
        let rotated = rotation_differs(before, after);
        out.push(Change::new(label(name, rotated), show(before, class, name, start.1, rotated), show(after, class, name, current.1, rotated)));
    }
    out
}

// Laying the review out like Explorer --------------------------------------------------------------

struct Node {
    name: String,
    class: String,
    status: Status,
    changes: Vec<Change>,
    conflict: Option<usize>,
    children: Vec<String>,
}

#[derive(Default)]
pub(crate) struct Tree {
    nodes: HashMap<String, Node>,
    roots: Vec<String>,
}

impl Tree {
    /// Adds `key` and the chain of its parents, taking names from the place `key` lives in.
    pub fn add(&mut self, dom: &WeakDom, index: &Index, key: &str, status: Status, changes: Vec<Change>) {
        let mut chain = vec![key.to_owned()];
        while let Some(parent) = index.get(chain.last().unwrap()).and_then(|e| e.parent.clone()) {
            chain.push(parent);
        }
        chain.reverse();
        let mut parent: Option<String> = None;
        for link in &chain {
            if !self.nodes.contains_key(link) {
                let inst = dom.get_by_ref(index.get(link).unwrap().referent).unwrap();
                let node = Node {
                    name: inst.name.clone(), class: inst.class.to_string(), status: Status::Context, changes: vec![], conflict: None, children: vec![],
                };
                self.nodes.insert(link.clone(), node);
                match &parent {
                    Some(p) => self.nodes.get_mut(p).unwrap().children.push(link.clone()),
                    None => self.roots.push(link.clone()),
                }
            }
            parent = Some(link.clone());
        }
        let node = self.nodes.get_mut(key).unwrap();
        node.status = status;
        node.changes = changes;
    }

    /// Marks a whole row (an added or removed object) as needing a choice.
    pub fn mark_conflict(&mut self, key: &str, id: usize) {
        if let Some(node) = self.nodes.get_mut(key) {
            node.conflict = Some(id);
        }
    }

    /// Rows in Explorer order. An object that only moved because its model moved is folded into the model's row
    /// ("Moved with it: N objects") instead of getting a row of its own. If the model's move is a conflict, the folded
    /// objects' conflicts become part of it (one choice for the whole move); the result maps each folded conflict to
    /// the model's. A folded object's conflict with nothing to join keeps its own row.
    pub fn rows(mut self) -> (Vec<Row>, usize, HashMap<usize, usize>) {
        let spatial = |changes: &[Change]| !changes.is_empty() && changes.iter().all(|c| SPATIAL.contains(&c.name.as_str()));
        // Parts of the tree where things only moved. A model like that is one moved row too, even if its own pivot
        // didn't change (for example its parts were moved together).
        let mut moves: HashMap<String, (bool, usize)> = HashMap::new();
        let keys: Vec<String> = self.nodes.keys().cloned().collect();
        for key in &keys {
            self.only_moves_below(key, &spatial, &mut moves);
        }
        let moved_inside: HashSet<String> = keys
            .iter()
            .filter(|k| {
                let node = &self.nodes[*k];
                node.class == "Model"
                    && node.status == Status::Context
                    && moves[*k].0
                    && moves[*k].1 >= 2
                    && self.moved_together(k, &mut None)
            })
            .cloned()
            .collect();
        let move_conflict = |changes: &[Change]| changes.iter().find(|c| SPATIAL.contains(&c.name.as_str())).and_then(|c| c.conflict);
        let mut rows: Vec<Row> = Vec::new();
        let mut truncated = 0;
        let mut moved_with: HashMap<usize, usize> = HashMap::new();
        let mut joined: HashMap<usize, usize> = HashMap::new();
        let mut roots = std::mem::take(&mut self.roots);
        self.sort(&mut roots);
        // Each entry: key, depth, and the row of the nearest shown ancestor that moved.
        let mut stack: Vec<(String, usize, Option<usize>)> = roots.into_iter().rev().map(|k| (k, 0, None)).collect();
        while let Some((key, depth, mover)) = stack.pop() {
            let mut node = self.nodes.remove(&key).unwrap();
            let mut children = std::mem::take(&mut node.children);
            self.sort(&mut children);
            if let Some(owner) = mover {
                // Something unchanged inside a moved model, with only moves below it: fold it and its contents in.
                if node.status == Status::Context && moves.get(&key).is_some_and(|m| m.0) {
                    stack.extend(children.into_iter().rev().map(|k| (k, depth, Some(owner))));
                    continue;
                }
                let owner_conflict = move_conflict(&rows[owner].changes);
                let conflicts: Vec<usize> = node.changes.iter().filter_map(|c| c.conflict).collect();
                let can_join = conflicts.is_empty() || owner_conflict.is_some();
                if node.status == Status::Changed && node.conflict.is_none() && spatial(&node.changes) && can_join {
                    for conflict in conflicts {
                        joined.insert(conflict, owner_conflict.unwrap());
                    }
                    *moved_with.entry(owner).or_default() += 1;
                    stack.extend(children.into_iter().rev().map(|k| (k, depth, Some(owner))));
                    continue;
                }
            }
            let mut child_mover = None;
            if rows.len() >= MAX_ROWS {
                truncated += 1;
            } else {
                let mut moved = node.status == Status::Changed && node.changes.iter().any(|c| SPATIAL.contains(&c.name.as_str()));
                if moved_inside.contains(&key) && !moved {
                    moved = true;
                    node.status = Status::Changed;
                }
                rows.push(Row {
                    depth, key: key.clone(), name: node.name, class: node.class, status: node.status, changes: node.changes, conflict: node.conflict,
                });
                if moved {
                    child_mover = Some(rows.len() - 1);
                }
            }
            stack.extend(children.into_iter().rev().map(|k| (k, depth + 1, child_mover)));
        }
        for (row, count) in moved_with {
            let own_move = rows[row].changes.iter().any(|c| SPATIAL.contains(&c.name.as_str()));
            let label = if own_move { "Moved with it" } else { "Moved inside" };
            rows[row].changes.push(Change::new(label, "", format!("{count} objects")));
        }
        (rows, truncated, joined)
    }

    /// Whether everything that changed inside `key` only moved (no conflicts, nothing added or removed), and how
    /// many objects moved. Remembered in `memo`.
    fn only_moves_below(&self, key: &str, spatial: &impl Fn(&[Change]) -> bool, memo: &mut HashMap<String, (bool, usize)>) -> (bool, usize) {
        if let Some(known) = memo.get(key) {
            return *known;
        }
        let mut result = (true, 0);
        for child in &self.nodes[key].children {
            let c = &self.nodes[child];
            let moved = match c.status {
                Status::Context => Some(false),
                Status::Changed if c.conflict.is_none() && c.changes.iter().all(|x| x.conflict.is_none()) && spatial(&c.changes) => Some(true),
                _ => None,
            };
            let below = self.only_moves_below(child, spatial, memo);
            match moved {
                Some(counted) => result = (result.0 && below.0, result.1 + below.1 + counted as usize),
                None => result.0 = false,
            }
        }
        memo.insert(key.to_owned(), result);
        result
    }

    /// Whether everything that moved inside `key` moved by the same offset, without turning, and no model inside
    /// moved by its own pivot (that model shows its own row instead).
    fn moved_together(&self, key: &str, offset: &mut Option<[f64; 3]>) -> bool {
        let parse = |text: &str| -> Option<[f64; 3]> {
            let mut parts = text.split(", ").map(|n| n.parse::<f64>().ok());
            Some([parts.next()??, parts.next()??, parts.next()??])
        };
        self.nodes[key].children.iter().all(|child| {
            let node = &self.nodes[child];
            if node.status == Status::Changed {
                if node.class == "Model" || node.changes.iter().any(|c| c.name == "Rotation") {
                    return false;
                }
                for change in node.changes.iter().filter(|c| c.name == "Position" || c.name == "Pivot") {
                    let (Some(old), Some(new)) = (parse(&change.old), parse(&change.new)) else { return false };
                    let delta = [new[0] - old[0], new[1] - old[1], new[2] - old[2]];
                    match offset {
                        Some(first) if first.iter().zip(delta).any(|(a, b)| (a - b).abs() > 0.01) => return false,
                        Some(_) => {}
                        None => *offset = Some(delta),
                    }
                }
            }
            self.moved_together(child, offset)
        })
    }

    fn sort(&self, keys: &mut [String]) {
        keys.sort_by_key(|k| self.nodes.get(k).map(|n| n.name.to_lowercase()).unwrap_or_default());
    }
}

/// Objects whose ID didn't carry over are still the same object: one Studio created after the start and RoGit
/// tagged later, or one in main whose ID was never saved. Unmatched objects with the same path and class are paired
/// and re-keyed under the starting point's key; each keeps its `own_key`, so Studio can still find it.
pub(crate) fn adopt_new_ids(start: &WeakDom, old: &Index, current: &WeakDom, new: &mut Index) {
    let class = |dom: &WeakDom, r: Ref| dom.get_by_ref(r).map(|i| i.class.to_string()).unwrap_or_default();
    let mut unmatched: HashMap<(String, String), Vec<String>> = HashMap::new();
    for entry in old.entries.iter().filter(|e| !e.key.starts_with("service:") && new.get(&e.key).is_none()) {
        unmatched.entry((entry.path.clone(), class(start, entry.referent))).or_default().push(entry.key.clone());
    }
    let mut renamed: HashMap<String, String> = HashMap::new();
    for entry in &new.entries {
        if entry.key.starts_with("service:") || old.get(&entry.key).is_some() {
            continue;
        }
        if let Some(keys) = unmatched.get_mut(&(entry.path.clone(), class(current, entry.referent))) {
            if !keys.is_empty() {
                renamed.insert(entry.key.clone(), keys.remove(0));
            }
        }
    }
    if renamed.is_empty() {
        return;
    }
    let entries = std::mem::take(&mut new.entries);
    *new = Index::default();
    for mut entry in entries {
        if let Some(key) = renamed.get(&entry.key) {
            entry.key = key.clone();
        }
        if let Some(parent) = entry.parent.as_ref().and_then(|p| renamed.get(p)) {
            entry.parent = Some(parent.clone());
        }
        new.push(entry);
    }
}

/// Everything that changed between the starting point and the branch now.
pub fn compare(start: &WeakDom, current: &WeakDom, rojo: &RojoPaths) -> Review {
    compare_with(start, &index(start, rojo), current, rojo)
}

/// Like `compare`, with the starting point's index made once and kept (a big place takes a while to index).
pub(crate) fn compare_with(start: &WeakDom, old: &Index, current: &WeakDom, rojo: &RojoPaths) -> Review {
    let mut new = index(current, rojo);
    adopt_new_ids(start, &old, current, &mut new);
    let mut tree = Tree::default();
    let mut summary = Summary::default();
    let added: HashSet<&str> = new.entries.iter().filter(|e| old.get(&e.key).is_none()).map(|e| e.key.as_str()).collect();
    let removed: HashSet<&str> = old.entries.iter().filter(|e| new.get(&e.key).is_none()).map(|e| e.key.as_str()).collect();
    // A new model counts once, not once per part inside it.
    let mut inside: HashMap<String, usize> = HashMap::new();
    let top = |index: &Index, set: &HashSet<&str>, key: &str| -> Option<String> {
        let mut found = None;
        let mut parent = index.get(key).and_then(|e| e.parent.clone());
        while let Some(p) = parent {
            if set.contains(p.as_str()) {
                found = Some(p.clone());
            }
            parent = index.get(&p).and_then(|e| e.parent.clone());
        }
        found
    };
    for entry in &new.entries {
        if added.contains(entry.key.as_str()) {
            if let Some(owner) = top(&new, &added, &entry.key) {
                *inside.entry(owner).or_default() += 1;
            }
            continue;
        }
        let before = old.get(&entry.key).unwrap();
        let mut list = changes((start, &old, before.referent), (current, &new, entry.referent));
        if before.parent != entry.parent {
            let path = |index: &Index, key: &Option<String>| key.as_ref().and_then(|k| index.get(k)).map(|e| e.path.clone()).unwrap_or_default();
            list.insert(0, Change::new("Parent", path(&old, &before.parent), path(&new, &entry.parent)));
        }
        if !list.is_empty() {
            summary.changed += 1;
            tree.add(current, &new, &entry.key, Status::Changed, list);
        }
    }
    for entry in &old.entries {
        if removed.contains(entry.key.as_str()) {
            if let Some(owner) = top(&old, &removed, &entry.key) {
                *inside.entry(owner).or_default() += 1;
            }
        }
    }
    let contents = |key: &str| match inside.get(key) {
        Some(n) => vec![Change::new("Contains", "", format!("{n} objects"))],
        None => vec![],
    };
    for entry in new.entries.iter().filter(|e| added.contains(e.key.as_str()) && top(&new, &added, &e.key).is_none()) {
        summary.added += 1;
        tree.add(current, &new, &entry.key, Status::Added, contents(&entry.key));
    }
    for entry in old.entries.iter().filter(|e| removed.contains(e.key.as_str()) && top(&old, &removed, &e.key).is_none()) {
        summary.removed += 1;
        tree.add(start, &old, &entry.key, Status::Removed, contents(&entry.key));
    }
    let (rows, truncated, _) = tree.rows();
    summary.changed = rows.iter().filter(|r| r.status == Status::Changed).count();
    Review { summary, rows, truncated }
}

#[cfg(test)]
mod tests {
    use super::*;
    use rbx_dom_weak::InstanceBuilder;
    use rbx_dom_weak::types::{Attributes, Color3};

    /// Tags the way real place files do: attribute text arrives as a BinaryString.
    fn tagged(class: &str, name: &str, id: &str) -> InstanceBuilder {
        let mut attributes = Attributes::new();
        attributes.insert(TAG.to_owned(), Variant::BinaryString(id.as_bytes().to_vec().into()));
        InstanceBuilder::new(class).with_name(name).with_property("Attributes", Variant::Attributes(attributes))
    }

    #[test]
    fn same_objects_in_a_different_order_still_match() {
        let start = place(0.5, "Tower", true, false);
        let mut current = place(0.5, "Tower", true, false);
        // Studio doesn't keep sibling order between copies; move the Gate to the end of Map.
        let map = current.descendants().find(|i| i.name == "Map").unwrap().referent();
        let gate = current.descendants().find(|i| i.name == "Gate").unwrap().referent();
        current.transfer_within(gate, current.root_ref());
        current.transfer_within(gate, map);
        let review = compare(&start, &current, &RojoPaths::default());
        assert_eq!(review.summary, Summary::default());
    }

    /// Workspace > Map > (Gate, Tower, Shed), plus ServerStorage > Scripts (a Folder with a script).
    fn place(gate_color: f32, tower_name: &str, keep_shed: bool, add_crate: bool) -> WeakDom {
        let mut dom = WeakDom::new(InstanceBuilder::new("DataModel"));
        let workspace = dom.insert(dom.root_ref(), InstanceBuilder::new("Workspace").with_name("Workspace"));
        let map = dom.insert(workspace, tagged("Model", "Map", "map"));
        dom.insert(map, tagged("Part", "Gate", "gate").with_property("Color", Variant::Color3(Color3::new(gate_color, 0.0, 0.0))));
        dom.insert(map, tagged("Part", "Tower", "tower").with_property("Size", Variant::Vector3(Vector3::new(1.0, 2.0, 3.000_01))));
        if keep_shed {
            let shed = dom.insert(map, tagged("Model", "Shed", "shed"));
            dom.insert(shed, tagged("Part", "Roof", "roof"));
        }
        if add_crate {
            let crate_model = dom.insert(map, InstanceBuilder::new("Model").with_name("Crate"));
            dom.insert(crate_model, InstanceBuilder::new("Part").with_name("Lid"));
        }
        let storage = dom.insert(dom.root_ref(), InstanceBuilder::new("ServerStorage").with_name("ServerStorage"));
        let scripts = dom.insert(storage, InstanceBuilder::new("Folder").with_name("Scripts"));
        dom.insert(scripts, InstanceBuilder::new("Part").with_name("Hidden"));
        dom.insert(scripts, InstanceBuilder::new("Script").with_name("Main"));
        let _ = tower_name;
        dom
    }

    #[test]
    fn finds_added_removed_and_changed_objects() {
        let start = place(0.5, "Tower", true, false);
        let mut current = place(1.0, "Tower", false, true);
        // Rename the tower and nudge its size by less than rounding.
        let tower = current.descendants().find(|i| i.name == "Tower").unwrap().referent();
        current.get_by_ref_mut(tower).unwrap().name = "Watchtower".into();
        let review = compare(&start, &current, &RojoPaths::default());
        assert_eq!(review.summary, Summary { added: 1, removed: 1, changed: 2 });
        let row = |name: &str| review.rows.iter().find(|r| r.name == name).unwrap();
        assert_eq!(row("Gate").status, Status::Changed);
        assert_eq!(row("Gate").changes, vec![Change::new("Color", "128, 0, 0", "255, 0, 0")]);
        assert_eq!(row("Watchtower").changes[0].name, "Name");
        assert_eq!(row("Crate").status, Status::Added);
        assert_eq!(row("Crate").changes[0].new, "1 objects");
        assert_eq!(row("Shed").status, Status::Removed);
        assert_eq!(row("Map").status, Status::Context);
        assert!(review.rows.iter().all(|r| r.name != "Scripts" && r.name != "Hidden" && r.name != "Lid"));
    }

    #[test]
    fn an_object_tagged_after_the_start_is_not_new() {
        let mut start = place(0.5, "Tower", true, false);
        let mut current = place(0.5, "Tower", true, false);
        for dom in [&mut start, &mut current] {
            let map = dom.descendants().find(|i| i.name == "Map").unwrap().referent();
            dom.insert(map, InstanceBuilder::new("Folder").with_name("Effects"));
        }
        // Tag the folder only in the current copy, as the plugin does before a review.
        let effects = current.descendants().find(|i| i.name == "Effects").unwrap().referent();
        let mut attributes = Attributes::new();
        attributes.insert(TAG.to_owned(), Variant::BinaryString(b"late".to_vec().into()));
        current.get_by_ref_mut(effects).unwrap().properties.insert("Attributes".into(), Variant::Attributes(attributes));
        let review = compare(&start, &current, &RojoPaths::default());
        assert_eq!(review.summary, Summary::default());
    }

    #[test]
    fn a_moved_model_is_one_row() {
        let mut start = place(0.5, "Tower", true, false);
        let mut current = place(0.5, "Tower", true, false);
        let moved = Variant::CFrame(CFrame::new(Vector3::new(10.0, 0.0, 0.0), rbx_dom_weak::types::Matrix3::identity()));
        let still = Variant::CFrame(CFrame::new(Vector3::new(0.0, 0.0, 0.0), rbx_dom_weak::types::Matrix3::identity()));
        // The shed's pivot and its roof both moved: one row for the shed, the roof folded in.
        for (dom, value) in [(&mut start, &still), (&mut current, &moved)] {
            for name in ["Shed", "Roof"] {
                let r = dom.descendants().find(|i| i.name == name).unwrap().referent();
                let property = if name == "Shed" { "WorldPivotData" } else { "CFrame" };
                let value = if name == "Shed" {
                    match value { Variant::CFrame(c) => Variant::OptionalCFrame(Some(*c)), other => other.clone() }
                } else {
                    value.clone()
                };
                dom.get_by_ref_mut(r).unwrap().properties.insert(property.into(), value);
            }
        }
        let review = compare(&start, &current, &RojoPaths::default());
        assert_eq!(review.summary.changed, 1);
        let shed = review.rows.iter().find(|r| r.name == "Shed").unwrap();
        assert_eq!(shed.changes[0].name, "Pivot");
        assert_eq!(shed.changes.last().unwrap(), &Change::new("Moved with it", "", "1 objects"));
        assert!(review.rows.iter().all(|r| r.name != "Roof"));
    }

    #[test]
    fn parts_moved_together_fold_into_their_model() {
        let at = |x: f32| Variant::CFrame(CFrame::new(Vector3::new(x, 0.0, 0.0), rbx_dom_weak::types::Matrix3::identity()));
        let mut start = place(0.5, "Tower", true, false);
        let mut current = place(0.5, "Tower", true, false);
        // The map has no pivot of its own; its parts (and the shed's roof, one model down) moved together.
        for (dom, x) in [(&mut start, 0.0), (&mut current, 25.0)] {
            for name in ["Gate", "Tower", "Roof"] {
                let r = dom.descendants().find(|i| i.name == name).unwrap().referent();
                dom.get_by_ref_mut(r).unwrap().properties.insert("CFrame".into(), at(x));
            }
        }
        let review = compare(&start, &current, &RojoPaths::default());
        let names: Vec<&str> = review.rows.iter().map(|r| r.name.as_str()).collect();
        assert_eq!(names, ["Workspace", "Map"]);
        assert_eq!(review.rows[1].changes, vec![Change::new("Moved inside", "", "3 objects")]);
        assert_eq!(review.summary.changed, 1);
    }

    #[test]
    fn roblox_and_rogit_attributes_are_not_changes() {
        let start = place(0.5, "Tower", true, false);
        let mut current = place(0.5, "Tower", true, false);
        let gate = current.descendants().find(|i| i.name == "Gate").unwrap().referent();
        let mut attributes = Attributes::new();
        attributes.insert(TAG.to_owned(), Variant::BinaryString(b"gate".to_vec().into()));
        attributes.insert("RBX_LightingCompatibilityMigrated".to_owned(), Variant::Bool(true));
        attributes.insert(UPDATE.to_owned(), Variant::String("u1".into()));
        current.get_by_ref_mut(gate).unwrap().properties.insert("Attributes".into(), Variant::Attributes(attributes));
        assert_eq!(compare(&start, &current, &RojoPaths::default()).summary, Summary::default());
    }

    #[test]
    fn rotations_read_as_degrees() {
        use rbx_dom_weak::types::Matrix3;
        // A quarter turn around Y.
        let turned = CFrame::new(
            Vector3::new(0.0, 0.0, 0.0),
            Matrix3::new(Vector3::new(0.0, 0.0, 1.0), Vector3::new(0.0, 1.0, 0.0), Vector3::new(-1.0, 0.0, 0.0)),
        );
        assert_eq!(angles(&turned), "0°, 90°, 0°");
    }

    #[test]
    fn infinite_and_nan_values_equal_themselves() {
        assert!(close(f32::INFINITY, f32::INFINITY));
        assert!(close(f32::NAN, f32::NAN));
        assert!(close(1.0, 1.000_01));
        assert!(!close(f32::INFINITY, 1.0e30));
        assert!(!close(1.0, 1.1));
    }

    #[test]
    fn identical_places_have_no_changes() {
        let review = compare(&place(0.5, "Tower", true, false), &place(0.5, "Tower", true, false), &RojoPaths::default());
        assert_eq!(review.summary, Summary::default());
        assert!(review.rows.is_empty());
    }
}

#[cfg(test)]
mod bench {
    use super::*;

    /// Times a review of a big place against itself: `ROGIT_BENCH_PLACE=<file.rbxl> cargo test --release -- --ignored`.
    #[test]
    #[ignore]
    fn compare_a_big_place() {
        let Ok(path) = std::env::var("ROGIT_BENCH_PLACE") else { return };
        let started = std::time::Instant::now();
        let start = crate::place::read(std::path::Path::new(&path)).unwrap();
        let current = crate::place::read(std::path::Path::new(&path)).unwrap();
        let read = started.elapsed();
        let started = std::time::Instant::now();
        let index_only = index(&start, &RojoPaths::default()).entries.len();
        let indexed = started.elapsed();
        let started = std::time::Instant::now();
        let review = compare(&start, &current, &RojoPaths::default());
        println!(
            "{} objects tracked: read both {:?}, index one {:?}, compare {:?} ({} rows)",
            index_only, read, indexed, started.elapsed(), review.rows.len()
        );
    }
}
