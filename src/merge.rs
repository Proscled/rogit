//! Merge and update: what one side changed since the base (where the branch and main last met), applied to the
//! other side as it is now (a three-way merge). A merge takes the branch into main; an update takes main into the
//! branch. The result is a list of operations for the plugin plus a bundle (an rbxm) holding the source's versions
//! of changed and new objects.

use crate::diff::{self, Change, IGNORED, Index, Row, Status, Tree};
use crate::project::RojoPaths;
use base64::Engine;
use rbx_dom_weak::types::{Attributes, Ref, Variant};
use rbx_dom_weak::{InstanceBuilder, WeakDom};
use serde::Serialize;
use serde_json::{Map, Value, json};
use std::collections::{HashMap, HashSet};

/// Attribute that links a bundle object to its operation.
pub const OP_TAG: &str = "RoGitOp";
/// Attribute that marks a bundle object whose reference must be pointed at an existing object in the target.
pub const REF_TAG: &str = "RoGitRef";

#[derive(Serialize, Debug)]
#[serde(tag = "kind", rename_all = "lowercase")]
pub enum Op {
    /// Copy these properties from the bundle template onto the object. `refs` point properties at objects in the target
    /// ("" means none).
    Set { target: String, properties: Vec<String>, template: usize, refs: Map<String, Value>, conflict: Option<usize> },
    /// Services can't travel in the bundle, so their settings come as plain values.
    Settings { service: String, values: Map<String, Value>, conflict: Option<usize> },
    Rename { target: String, name: String, conflict: Option<usize> },
    Move { target: String, parent: String, conflict: Option<usize> },
    /// Put the bundle template (a whole new object with everything inside) under `parent`.
    Add { parent: String, template: usize, fixups: Vec<Fixup>, conflict: Option<usize> },
    Remove { target: String, conflict: Option<usize> },
}

/// Which way the changes go.
#[derive(Clone, Copy, PartialEq, Debug)]
pub enum Direction {
    /// The branch into main.
    Merge,
    /// Main into the branch.
    Update,
    /// An earlier copy of the branch (a commit, or unsaved work) back into the branch.
    Restore,
}

impl Direction {
    fn source(self) -> &'static str {
        match self {
            Direction::Merge => "the branch",
            Direction::Update => "main",
            Direction::Restore => "the copy",
        }
    }

    fn target(self) -> &'static str {
        if self == Direction::Merge { "main" } else { "the branch" }
    }
}

/// "the branch" -> "The branch".
fn capitalized(text: &str) -> String {
    let mut chars = text.chars();
    chars.next().map(|c| c.to_uppercase().chain(chars).collect()).unwrap_or_default()
}

#[derive(Serialize, Debug)]
pub struct Fixup {
    pub marker: String,
    pub property: String,
    pub target: String,
}

#[derive(Serialize, Debug)]
pub struct Conflict {
    pub id: usize,
    pub path: String,
    pub what: String,
}

#[derive(Serialize, Default, Debug, PartialEq)]
pub struct Summary {
    pub added: usize,
    pub removed: usize,
    pub changed: usize,
    pub conflicts: usize,
    /// Scripts inside added or removed objects. Added ones are left out; Rojo keeps scripts.
    pub scripts_left_out: usize,
}

#[derive(Serialize, Debug)]
pub struct Plan {
    pub summary: Summary,
    pub rows: Vec<Row>,
    pub truncated: usize,
    pub operations: Vec<Op>,
    pub conflicts: Vec<Conflict>,
    /// Base64 rbxm with the templates the operations refer to.
    pub bundle: String,
}

struct Place<'a> {
    dom: &'a WeakDom,
    index: Index,
}

impl Place<'_> {
    fn property(&self, key: &str, name: &str) -> Option<&Variant> {
        let entry = self.index.get(key)?;
        let inst = self.dom.get_by_ref(entry.referent)?;
        inst.properties.iter().find(|(k, _)| k.as_str() == name).map(|(_, v)| v)
    }

    fn name(&self, key: &str) -> String {
        self.index.get(key).and_then(|e| self.dom.get_by_ref(e.referent)).map(|i| i.name.clone()).unwrap_or_default()
    }

    fn class(&self, key: &str) -> String {
        self.index.get(key).and_then(|e| self.dom.get_by_ref(e.referent)).map(|i| i.class.to_string()).unwrap_or_default()
    }

    fn path(&self, key: &str) -> String {
        self.index.get(key).map(|e| e.path.clone()).unwrap_or_default()
    }

    /// Keys of everything inside `key`, using the index's parent links.
    fn inside(&self, key: &str) -> Vec<String> {
        let mut children: HashMap<&str, Vec<&str>> = HashMap::new();
        for entry in &self.index.entries {
            if let Some(parent) = &entry.parent {
                children.entry(parent.as_str()).or_default().push(entry.key.as_str());
            }
        }
        let mut out = Vec::new();
        let mut stack = vec![key];
        while let Some(k) = stack.pop() {
            for child in children.get(k).into_iter().flatten() {
                out.push(child.to_string());
                stack.push(child);
            }
        }
        out
    }

    fn scripts_inside(&self, key: &str) -> usize {
        let Some(entry) = self.index.get(key) else { return 0 };
        self.dom.descendants_of(entry.referent).filter(|i| diff::is_script(i)).count()
    }
}

/// Properties compared for a merge: present on all three sides and not ignored.
fn property_names(sides: [&Place; 3], key: &str) -> Vec<String> {
    let Some(entry) = sides[0].index.get(key) else { return vec![] };
    let inst = sides[0].dom.get_by_ref(entry.referent).unwrap();
    let mut names: Vec<String> = inst
        .properties
        .keys()
        .map(|k| k.to_string())
        .filter(|k| !IGNORED.contains(&k.as_str()))
        .filter(|k| sides[1].property(key, k).is_some() && sides[2].property(key, k).is_some())
        .collect();
    names.sort();
    names
}

/// A value the plugin can set on a service, as {"t": type, "v": value}.
fn encode(value: &Variant) -> Option<Value> {
    Some(match value {
        Variant::Bool(b) => json!({ "t": "boolean", "v": b }),
        Variant::Float32(n) => json!({ "t": "number", "v": n }),
        Variant::Float64(n) => json!({ "t": "number", "v": n }),
        Variant::Int32(n) => json!({ "t": "number", "v": n }),
        Variant::Int64(n) => json!({ "t": "number", "v": n }),
        Variant::String(s) => json!({ "t": "string", "v": s }),
        Variant::Color3(c) => json!({ "t": "Color3", "v": [c.r, c.g, c.b] }),
        Variant::Color3uint8(c) => json!({ "t": "Color3", "v": [c.r as f32 / 255.0, c.g as f32 / 255.0, c.b as f32 / 255.0] }),
        Variant::Vector3(v) => json!({ "t": "Vector3", "v": [v.x, v.y, v.z] }),
        Variant::Vector2(v) => json!({ "t": "Vector2", "v": [v.x, v.y] }),
        Variant::Enum(e) => json!({ "t": "EnumItem", "v": e.to_u32() }),
        Variant::NumberRange(r) => json!({ "t": "NumberRange", "v": [r.min, r.max] }),
        Variant::ContentId(c) => json!({ "t": "string", "v": c.as_str() }),
        _ => return None,
    })
}

fn with_attribute(dom: &mut WeakDom, referent: Ref, key: &str, value: &str) {
    let inst = dom.get_by_ref_mut(referent).unwrap();
    let mut attributes = match inst.properties.get(&"Attributes".into()) {
        Some(Variant::Attributes(a)) => a.clone(),
        _ => Attributes::new(),
    };
    attributes.insert(key.to_owned(), Variant::String(value.to_owned()));
    inst.properties.insert("Attributes".into(), Variant::Attributes(attributes));
}

struct Builder<'a> {
    base: Place<'a>,
    source: Place<'a>,
    target: Place<'a>,
    direction: Direction,
    bundle: WeakDom,
    templates: usize,
    markers: usize,
    operations: Vec<Op>,
    conflicts: Vec<Conflict>,
    summary: Summary,
    tree: Tree,
}

impl Builder<'_> {
    fn conflict(&mut self, key: &str, what: String) -> usize {
        let id = self.conflicts.len() + 1;
        self.conflicts.push(Conflict { id, path: self.target.path(key), what });
        id
    }

    /// The target's key for an object (what Studio finds it by), from the shared key.
    fn target_key(&self, key: &str) -> Option<String> {
        self.target.index.get(key).map(|e| e.own_key.clone())
    }

    /// A reference property's target, as the target's key ("" for none or for something it doesn't have).
    fn ref_target(&self, value: &Variant) -> Value {
        let Variant::Ref(r) = value else { return json!("") };
        let target = self.source.index.by_ref.get(r).and_then(|k| self.target_key(k));
        json!(target.unwrap_or_default())
    }

    /// The source's version of one object, without its children or references.
    fn template(&mut self, key: &str) -> usize {
        let entry = self.source.index.get(key).unwrap();
        let inst = self.source.dom.get_by_ref(entry.referent).unwrap();
        let mut builder = InstanceBuilder::new(inst.class).with_name(inst.name.clone());
        for (name, value) in &inst.properties {
            if !matches!(value, Variant::Ref(_)) {
                builder = builder.with_property(*name, value.clone());
            }
        }
        let referent = self.bundle.insert(self.bundle.root_ref(), builder);
        self.templates += 1;
        with_attribute(&mut self.bundle, referent, OP_TAG, &self.templates.to_string());
        self.templates
    }

    /// The source's whole new object, with references to objects outside it recorded as fixups. Scripts are left
    /// out (Rojo keeps scripts).
    fn subtree(&mut self, key: &str) -> (usize, Vec<Fixup>) {
        let original = self.source.index.get(key).unwrap().referent;
        let copy = self.source.dom.clone_into_external(original, &mut self.bundle);
        self.bundle.transfer_within(copy, self.bundle.root_ref());
        // Walk the original and the copy together (same shape) to find references that point outside.
        let inside: HashSet<Ref> = self.source.dom.descendants_of(original).map(|i| i.referent()).collect();
        let mut fixups = Vec::new();
        let mut scripts = Vec::new();
        let mut pairs = vec![(original, copy)];
        while let Some((from, to)) = pairs.pop() {
            let source = self.source.dom.get_by_ref(from).unwrap();
            if diff::is_script(source) {
                scripts.push(to);
                continue;
            }
            let mut marker: Option<String> = None;
            for (name, value) in &source.properties {
                if let Variant::Ref(target) = value {
                    if !target.is_none() && !inside.contains(target) {
                        let marker = marker.get_or_insert_with(|| {
                            self.markers += 1;
                            self.markers.to_string()
                        });
                        let target = self.ref_target(value).as_str().unwrap_or_default().to_owned();
                        fixups.push(Fixup { marker: marker.clone(), property: name.to_string(), target });
                    }
                }
            }
            if let Some(marker) = marker {
                with_attribute(&mut self.bundle, to, REF_TAG, &marker);
            }
            let to_children = self.bundle.get_by_ref(to).unwrap().children().to_vec();
            pairs.extend(source.children().iter().copied().zip(to_children));
        }
        self.summary.scripts_left_out += scripts.len();
        for script in scripts {
            self.bundle.destroy(script);
        }
        self.templates += 1;
        with_attribute(&mut self.bundle, copy, OP_TAG, &self.templates.to_string());
        (self.templates, fixups)
    }

    /// Whether the source changed this object at all (properties, name or parent) since the base.
    fn source_changed(&self, key: &str) -> bool {
        let parent = |place: &Place| place.index.get(key).and_then(|e| e.parent.clone());
        if self.base.name(key) != self.source.name(key) || parent(&self.base) != parent(&self.source) {
            return true;
        }
        property_names([&self.base, &self.source, &self.source], key).iter().any(|n| match (self.base.property(key, n), self.source.property(key, n)) {
            (Some(a), Some(b)) => !diff::same(a, b, (&self.base.index, &self.source.index)),
            _ => false,
        })
    }

    /// An object that exists in the base and in the source.
    fn changed(&mut self, key: &str) {
        let Some(target) = self.target_key(key) else {
            if !self.source_changed(key) {
                return; // The target removed it and the source didn't touch it: it stays removed.
            }
            // The target removed what the source changed: put the source's version back only if asked.
            let Some(parent) = self.source.index.get(key).and_then(|e| e.parent.clone()).and_then(|p| self.target_key(&p)) else {
                return;
            };
            let (from, into) = (self.direction.source(), self.direction.target());
            let id = self.conflict(key, format!("{} was changed in {from} but removed in {into}.", self.source.name(key)));
            let (template, fixups) = self.subtree(key);
            self.operations.push(Op::Add { parent, template, fixups, conflict: Some(id) });
            self.summary.changed += 1;
            self.tree.add(self.source.dom, &self.source.index, key, Status::Changed, vec![]);
            self.tree.mark_conflict(key, id);
            return;
        };
        let is_service = key.starts_with("service:");
        let class = self.target.class(key);
        let mut rows = Vec::new();
        let mut clean = Vec::new();
        let mut refs = Map::new();
        let mut settings = Map::new();
        for name in property_names([&self.base, &self.source, &self.target], key) {
            // Work out the change with borrowed values; only owned results leave this block.
            let (label, mut change, target_changed, encoded, ref_target) = {
                let (Some(base), Some(theirs), Some(ours)) =
                    (self.base.property(key, &name), self.source.property(key, &name), self.target.property(key, &name))
                else {
                    continue;
                };
                if diff::same(base, theirs, (&self.base.index, &self.source.index)) {
                    continue;
                }
                let target_changed = !diff::same(base, ours, (&self.base.index, &self.target.index));
                if target_changed && diff::same(ours, theirs, (&self.target.index, &self.source.index)) {
                    continue;
                }
                let encoded = if is_service { encode(theirs) } else { None };
                if is_service && encoded.is_none() {
                    continue;
                }
                let rotated = diff::rotation_differs(ours, theirs);
                let label = diff::label(&name, rotated);
                let change = Change::new(
                    label.clone(),
                    diff::show(ours, &class, &name, &self.target.index, rotated),
                    diff::show(theirs, &class, &name, &self.source.index, rotated),
                );
                let ref_target = matches!(theirs, Variant::Ref(_)).then(|| self.ref_target(theirs));
                (label, change, target_changed, encoded, ref_target)
            };
            if target_changed {
                let id = self.conflict(key, format!("{label} was changed on both sides."));
                change.conflict = Some(id);
                if let Some(value) = encoded {
                    let values = Map::from_iter([(name.clone(), value)]);
                    self.operations.push(Op::Settings { service: self.target.name(key), values, conflict: Some(id) });
                } else {
                    let template = self.template(key);
                    let (properties, refs) = match ref_target {
                        Some(target) => (vec![], Map::from_iter([(name.clone(), target)])),
                        None => (vec![name.clone()], Map::new()),
                    };
                    self.operations.push(Op::Set { target: target.clone(), properties, template, refs, conflict: Some(id) });
                }
            } else if let Some(value) = encoded {
                settings.insert(name.clone(), value);
            } else if let Some(target) = ref_target {
                refs.insert(name.clone(), target);
            } else {
                clean.push(name.clone());
            }
            rows.push(change);
        }
        if !settings.is_empty() {
            self.operations.push(Op::Settings { service: self.target.name(key), values: settings, conflict: None });
        }
        if !clean.is_empty() || !refs.is_empty() {
            let template = self.template(key);
            self.operations.push(Op::Set { target: target.clone(), properties: clean, template, refs, conflict: None });
        }
        // Name and parent, three-way like properties.
        let (base_name, their_name, our_name) = (self.base.name(key), self.source.name(key), self.target.name(key));
        if base_name != their_name && our_name != their_name {
            let mut change = Change::new("Name", our_name.clone(), their_name.clone());
            let conflict = (our_name != base_name).then(|| self.conflict(key, "Its name was changed on both sides.".into()));
            change.conflict = conflict;
            self.operations.push(Op::Rename { target: target.clone(), name: their_name, conflict });
            rows.insert(0, change);
        }
        let parent = |place: &Place| place.index.get(key).and_then(|e| e.parent.clone());
        let (base_parent, their_parent, our_parent) = (parent(&self.base), parent(&self.source), parent(&self.target));
        if base_parent != their_parent && our_parent != their_parent {
            if let Some(new_parent) = their_parent.as_deref().and_then(|p| self.target_key(p)) {
                let mut change =
                    Change::new("Parent", our_parent.as_deref().map(|p| self.target.path(p)).unwrap_or_default(), self.source.path(their_parent.as_deref().unwrap()));
                let conflict = (our_parent != base_parent).then(|| self.conflict(key, "It was moved on both sides.".into()));
                change.conflict = conflict;
                self.operations.push(Op::Move { target: target.clone(), parent: new_parent, conflict });
                rows.insert(0, change);
            }
        }
        if !rows.is_empty() {
            self.summary.changed += 1;
            self.tree.add(self.target.dom, &self.target.index, key, Status::Changed, rows);
        }
    }

    fn added(&mut self, key: &str) {
        if self.target_key(key).is_some() {
            return; // The target has it already, for example from an earlier merge of this branch.
        }
        let entry = self.source.index.get(key).unwrap();
        let Some(parent) = entry.parent.clone().and_then(|p| self.target_key(&p)) else {
            return; // Its parent is gone from the target; nothing to add it to.
        };
        let inside = self.source.inside(key).len();
        let (template, fixups) = self.subtree(key);
        self.operations.push(Op::Add { parent, template, fixups, conflict: None });
        self.summary.added += 1;
        let contents = if inside > 0 { vec![Change::new("Contains", "", format!("{inside} objects"))] } else { vec![] };
        self.tree.add(self.source.dom, &self.source.index, key, Status::Added, contents);
    }

    fn removed(&mut self, key: &str) {
        let Some(target) = self.target_key(key) else { return };
        // If the target changed the object (or anything in it) since the base, removing it needs a choice.
        let mut keys = vec![key.to_owned()];
        keys.extend(self.target.inside(key));
        let target_changed = keys.iter().any(|k| match self.base.index.get(k) {
            None => true,
            Some(_) => {
                let names = property_names([&self.base, &self.target, &self.target], k);
                names.iter().any(|n| match (self.base.property(k, n), self.target.property(k, n)) {
                    (Some(a), Some(b)) => !diff::same(a, b, (&self.base.index, &self.target.index)),
                    _ => false,
                })
            }
        });
        let (from, into) = (capitalized(self.direction.source()), self.direction.target());
        let conflict = target_changed.then(|| self.conflict(key, format!("{from} removed {}, but {into} changed it.", self.target.name(key))));
        self.operations.push(Op::Remove { target, conflict });
        self.summary.removed += 1;
        let inside = keys.len() - 1;
        let scripts = self.target.scripts_inside(key);
        let mut contents = Vec::new();
        if inside > 0 {
            contents.push(Change::new("Contains", "", format!("{inside} objects")));
        }
        if scripts > 0 {
            contents.push(Change::new("Scripts", "", format!("{scripts} inside will be removed with it")));
        }
        self.tree.add(self.target.dom, &self.target.index, key, Status::Removed, contents);
        if let Some(id) = conflict {
            self.tree.mark_conflict(key, id);
        }
    }
}

/// The last merge of `branch` that main still has, from main's merge record. The plugin writes the record in the
/// same undo step as the merge, so it's gone if the merge was undone or main wasn't saved.
pub fn last_merge(main: &WeakDom, branch: &str) -> Option<String> {
    let record: Value = serde_json::from_str(&workspace_attribute(main, diff::MERGES)?).ok()?;
    record.get(branch)?.as_str().map(str::to_owned)
}

/// The last update from main that the branch still has, from the branch's update record (written the same way).
pub fn last_update(branch: &WeakDom) -> Option<String> {
    workspace_attribute(branch, diff::UPDATE)
}

fn workspace_attribute(dom: &WeakDom, name: &str) -> Option<String> {
    let workspace = dom.root().children().iter().filter_map(|r| dom.get_by_ref(*r)).find(|i| i.class == "Workspace")?;
    let Some(Variant::Attributes(attributes)) = workspace.properties.get(&"Attributes".into()) else { return None };
    match attributes.get(name)? {
        Variant::String(s) => Some(s.clone()),
        Variant::BinaryString(b) => Some(String::from_utf8_lossy(b.as_ref()).into_owned()),
        _ => None,
    }
}

/// Plans bringing what `source` changed since `base` into `target`: the branch into main for a merge, main into the
/// branch for an update.
pub fn plan(base: &WeakDom, source: &WeakDom, target: &WeakDom, rojo: &RojoPaths, direction: Direction) -> Result<Plan, String> {
    let base_index = diff::index(base, rojo);
    let mut source_index = diff::index(source, rojo);
    diff::adopt_new_ids(base, &base_index, source, &mut source_index);
    let mut target_index = diff::index(target, rojo);
    diff::adopt_new_ids(base, &base_index, target, &mut target_index);
    let mut b = Builder {
        base: Place { dom: base, index: base_index },
        source: Place { dom: source, index: source_index },
        target: Place { dom: target, index: target_index },
        direction,
        bundle: WeakDom::new(InstanceBuilder::new("Folder")),
        templates: 0,
        markers: 0,
        operations: Vec::new(),
        conflicts: Vec::new(),
        summary: Summary::default(),
        tree: Tree::default(),
    };
    let top = |index: &Index, set: &HashSet<String>, key: &str| {
        let mut parent = index.get(key).and_then(|e| e.parent.clone());
        while let Some(p) = parent {
            if set.contains(&p) {
                return false;
            }
            parent = index.get(&p).and_then(|e| e.parent.clone());
        }
        true
    };
    let added: HashSet<String> =
        b.source.index.entries.iter().filter(|e| b.base.index.get(&e.key).is_none()).map(|e| e.key.clone()).collect();
    let removed: HashSet<String> =
        b.base.index.entries.iter().filter(|e| b.source.index.get(&e.key).is_none()).map(|e| e.key.clone()).collect();
    let changed: Vec<String> = b.source.index.entries.iter().filter(|e| !added.contains(&e.key)).map(|e| e.key.clone()).collect();
    for key in changed {
        b.changed(&key);
    }
    let added_top: Vec<String> =
        b.source.index.entries.iter().filter(|e| added.contains(&e.key) && top(&b.source.index, &added, &e.key)).map(|e| e.key.clone()).collect();
    for key in added_top {
        b.added(&key);
    }
    let removed_top: Vec<String> =
        b.base.index.entries.iter().filter(|e| removed.contains(&e.key) && top(&b.base.index, &removed, &e.key)).map(|e| e.key.clone()).collect();
    for key in removed_top {
        b.removed(&key);
    }
    let tops = b.bundle.root().children().to_vec();
    let mut bytes = Vec::new();
    if !tops.is_empty() {
        rbx_binary::to_writer(&mut bytes, &b.bundle, &tops).map_err(|e| format!("Couldn't pack the merge: {e}"))?;
    }
    let (rows, truncated, joined) = b.tree.rows();
    // Conflicts folded into a moved model's row are decided with the model's move.
    for op in &mut b.operations {
        let conflict = match op {
            Op::Set { conflict, .. }
            | Op::Settings { conflict, .. }
            | Op::Rename { conflict, .. }
            | Op::Move { conflict, .. }
            | Op::Add { conflict, .. }
            | Op::Remove { conflict, .. } => conflict,
        };
        if let Some(model) = conflict.and_then(|id| joined.get(&id)) {
            *conflict = Some(*model);
        }
    }
    b.conflicts.retain(|c| !joined.contains_key(&c.id));
    b.summary.conflicts = b.conflicts.len();
    // A moved model counts once, like in a review.
    b.summary.changed = rows.iter().filter(|r| r.status == Status::Changed).count();
    Ok(Plan {
        summary: b.summary,
        rows,
        truncated,
        operations: b.operations,
        conflicts: b.conflicts,
        bundle: base64::engine::general_purpose::STANDARD.encode(bytes),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use rbx_dom_weak::types::{Color3, Vector3};

    fn tagged(class: &str, name: &str, id: &str) -> InstanceBuilder {
        let mut attributes = Attributes::new();
        attributes.insert(diff::TAG.to_owned(), Variant::BinaryString(id.as_bytes().to_vec().into()));
        InstanceBuilder::new(class).with_name(name).with_property("Attributes", Variant::Attributes(attributes))
    }

    /// Workspace > Map > (Gate, Tower, Shed > Roof).
    fn place() -> WeakDom {
        let mut dom = WeakDom::new(InstanceBuilder::new("DataModel"));
        let workspace = dom.insert(dom.root_ref(), InstanceBuilder::new("Workspace").with_name("Workspace"));
        let map = dom.insert(workspace, tagged("Model", "Map", "map"));
        dom.insert(map, tagged("Part", "Gate", "gate").with_property("Color", Variant::Color3(Color3::new(0.5, 0.0, 0.0))));
        dom.insert(map, tagged("Part", "Tower", "tower").with_property("Size", Variant::Vector3(Vector3::new(1.0, 2.0, 3.0))));
        let shed = dom.insert(map, tagged("Model", "Shed", "shed"));
        dom.insert(shed, tagged("Part", "Roof", "roof").with_property("Size", Variant::Vector3(Vector3::new(4.0, 1.0, 4.0))));
        dom
    }

    fn set(dom: &mut WeakDom, name: &str, property: &str, value: Variant) {
        let r = dom.descendants().find(|i| i.name == name).unwrap().referent();
        dom.get_by_ref_mut(r).unwrap().properties.insert(property.into(), value);
    }

    fn remove(dom: &mut WeakDom, name: &str) {
        let r = dom.descendants().find(|i| i.name == name).unwrap().referent();
        dom.destroy(r);
    }

    #[test]
    fn branch_changes_go_into_main_and_main_changes_stay() {
        let start = place();
        let mut branch = place();
        set(&mut branch, "Gate", "Color", Variant::Color3(Color3::new(1.0, 0.0, 0.0)));
        remove(&mut branch, "Shed");
        let map = branch.descendants().find(|i| i.name == "Map").unwrap().referent();
        let lamp = branch.insert(map, InstanceBuilder::new("Model").with_name("Lamp"));
        branch.insert(lamp, InstanceBuilder::new("Part").with_name("Bulb"));
        branch.insert(lamp, InstanceBuilder::new("Script").with_name("Flicker"));
        let mut main = place();
        set(&mut main, "Tower", "Size", Variant::Vector3(Vector3::new(9.0, 9.0, 9.0)));

        let plan = plan(&start, &branch, &main, &RojoPaths::default(), Direction::Merge).unwrap();
        assert_eq!(plan.summary, Summary { added: 1, removed: 1, changed: 1, conflicts: 0, scripts_left_out: 1 });
        assert!(plan.operations.iter().any(|op| matches!(op, Op::Set { target, properties, .. } if target == "gate" && properties == &["Color"])));
        assert!(plan.operations.iter().any(|op| matches!(op, Op::Remove { target, conflict: None } if target == "shed")));
        assert!(plan.operations.iter().any(|op| matches!(op, Op::Add { parent, .. } if parent == "map")));
        // Main's own change to the Tower isn't touched.
        assert!(!plan.operations.iter().any(|op| matches!(op, Op::Set { target, .. } if target == "tower")));

        let bundle = base64::engine::general_purpose::STANDARD.decode(&plan.bundle).unwrap();
        let bundle = rbx_binary::from_reader(&bundle[..]).unwrap();
        let lamp = bundle.descendants().find(|i| i.name == "Lamp").unwrap();
        assert_eq!(lamp.children().len(), 1, "the script is left out");
    }

    #[test]
    fn the_same_property_changed_on_both_sides_is_a_conflict() {
        let start = place();
        let mut branch = place();
        set(&mut branch, "Gate", "Color", Variant::Color3(Color3::new(1.0, 0.0, 0.0)));
        let mut main = place();
        set(&mut main, "Gate", "Color", Variant::Color3(Color3::new(0.0, 0.0, 1.0)));
        set(&mut main, "Roof", "Size", Variant::Vector3(Vector3::new(8.0, 1.0, 8.0)));
        remove(&mut branch, "Shed");

        let plan = plan(&start, &branch, &main, &RojoPaths::default(), Direction::Merge).unwrap();
        assert_eq!(plan.summary.conflicts, 2);
        let gate = plan.rows.iter().find(|r| r.name == "Gate").unwrap();
        assert_eq!(gate.changes[0].old, "0, 0, 255");
        assert_eq!(gate.changes[0].new, "255, 0, 0");
        assert!(gate.changes[0].conflict.is_some());
        // The shed's roof changed in main, so removing the shed needs a choice too.
        assert!(plan.rows.iter().find(|r| r.name == "Shed").unwrap().conflict.is_some());
    }

    #[test]
    fn same_change_on_both_sides_is_not_a_conflict() {
        let start = place();
        let mut branch = place();
        let mut main = place();
        for dom in [&mut branch, &mut main] {
            set(dom, "Gate", "Color", Variant::Color3(Color3::new(1.0, 0.0, 0.0)));
        }
        let plan = plan(&start, &branch, &main, &RojoPaths::default(), Direction::Merge).unwrap();
        assert_eq!(plan.summary, Summary::default());
        assert!(plan.operations.is_empty());
    }

    /// The branch after its first round of work: a red gate and a new lamp.
    fn first_round() -> WeakDom {
        let mut dom = place();
        set(&mut dom, "Gate", "Color", Variant::Color3(Color3::new(1.0, 0.0, 0.0)));
        let map = dom.descendants().find(|i| i.name == "Map").unwrap().referent();
        dom.insert(map, tagged("Model", "Lamp", "lamp"));
        dom
    }

    #[test]
    fn merging_again_starts_from_the_last_merge() {
        // Main took the first round and recorded the merge; the branch then turned the gate green.
        let merged = first_round();
        let mut main = first_round();
        let workspace = main.root().children()[0];
        let mut attributes = Attributes::new();
        attributes.insert(diff::MERGES.to_owned(), Variant::BinaryString(br#"{"test-1":"m1"}"#.to_vec().into()));
        main.get_by_ref_mut(workspace).unwrap().properties.insert("Attributes".into(), Variant::Attributes(attributes));
        let mut branch = first_round();
        set(&mut branch, "Gate", "Color", Variant::Color3(Color3::new(0.0, 1.0, 0.0)));

        assert_eq!(last_merge(&main, "test-1").as_deref(), Some("m1"));
        assert_eq!(last_merge(&main, "other"), None);
        let again = plan(&merged, &branch, &main, &RojoPaths::default(), Direction::Merge).unwrap();
        assert_eq!(again.summary, Summary { changed: 1, ..Summary::default() });
        assert!(matches!(&again.operations[..], [Op::Set { target, conflict: None, .. }] if target == "gate"));
        // Measured from the starting point instead, the gate would look changed on both sides.
        let from_start = plan(&place(), &branch, &main, &RojoPaths::default(), Direction::Merge).unwrap();
        assert_eq!(from_start.summary.conflicts, 1);
    }

    #[test]
    fn an_update_brings_main_changes_into_the_branch() {
        let start = place();
        let mut main = place();
        set(&mut main, "Gate", "Color", Variant::Color3(Color3::new(0.0, 0.0, 1.0)));
        set(&mut main, "Roof", "Size", Variant::Vector3(Vector3::new(8.0, 1.0, 8.0)));
        remove(&mut main, "Shed");
        let mut branch = place();
        set(&mut branch, "Tower", "Size", Variant::Vector3(Vector3::new(9.0, 9.0, 9.0)));
        set(&mut branch, "Roof", "Size", Variant::Vector3(Vector3::new(6.0, 1.0, 6.0)));

        let plan = plan(&start, &main, &branch, &RojoPaths::default(), Direction::Update).unwrap();
        assert!(plan.operations.iter().any(|op| matches!(op, Op::Set { target, conflict: None, .. } if target == "gate")));
        // The branch's own work stays.
        assert!(!plan.operations.iter().any(|op| matches!(op, Op::Set { target, .. } if target == "tower")));
        // Main removed the shed the branch worked on: that's the branch's call.
        assert_eq!(plan.conflicts.len(), 1);
        assert_eq!(plan.conflicts[0].what, "Main removed Shed, but the branch changed it.");
    }

    #[test]
    fn a_model_moved_on_both_sides_is_one_conflict() {
        use rbx_dom_weak::types::{CFrame, Matrix3};
        let at = |x: f32, z: f32| CFrame::new(Vector3::new(x, 0.0, z), Matrix3::identity());
        let placed = |shed: CFrame, roof: CFrame| {
            let mut dom = place();
            set(&mut dom, "Shed", "WorldPivotData", Variant::OptionalCFrame(Some(shed)));
            set(&mut dom, "Roof", "CFrame", Variant::CFrame(roof));
            dom
        };
        let start = placed(at(0.0, 0.0), at(0.0, 0.0));
        let branch = placed(at(10.0, 0.0), at(10.0, 0.0));
        let main = placed(at(0.0, 5.0), at(0.0, 5.0));

        let plan = plan(&start, &branch, &main, &RojoPaths::default(), Direction::Merge).unwrap();
        assert_eq!(plan.conflicts.len(), 1, "one choice for the whole move");
        let id = plan.conflicts[0].id;
        let conflicts: Vec<Option<usize>> = plan.operations.iter().map(|op| match op {
            Op::Set { conflict, .. } => *conflict,
            _ => None,
        }).collect();
        assert_eq!(conflicts, vec![Some(id), Some(id)], "the roof follows the shed's choice");
        let shed = plan.rows.iter().find(|r| r.name == "Shed").unwrap();
        assert!(shed.changes.iter().any(|c| c.name == "Moved with it"));
        assert!(!plan.rows.iter().any(|r| r.name == "Roof"));
    }

    #[test]
    fn an_object_main_already_has_is_not_added_twice() {
        let plan = plan(&place(), &first_round(), &first_round(), &RojoPaths::default(), Direction::Merge).unwrap();
        assert!(!plan.operations.iter().any(|op| matches!(op, Op::Add { .. })));
    }
}
