//! Committing only some changes, like `git add` before `git commit`: the branch as it is, with every change that
//! isn't staged put back the way the last commit had it.

use crate::diff::{self, Index, Row, Status};
use rbx_dom_weak::WeakDom;
use rbx_dom_weak::types::Variant;
use std::collections::HashSet;

/// `snapshot` is a copy of the branch as it is now; `rows` are its changes since `previous` (the last commit).
pub fn partial(previous: &WeakDom, mut snapshot: WeakDom, rows: &[Row], staged: &HashSet<String>) -> WeakDom {
    let old = diff::index(previous);
    let mut new = diff::index(&snapshot);
    diff::adopt_new_ids(previous, &old, &snapshot, &mut new);
    let shown: HashSet<&str> = rows.iter().filter(|r| r.status != Status::Context).map(|r| r.key.as_str()).collect();
    let unstaged: Vec<&Row> = rows.iter().filter(|r| r.status != Status::Context && !staged.contains(&r.key)).collect();
    for row in unstaged.iter().filter(|r| r.status == Status::Changed) {
        revert(previous, &old, &mut snapshot, &new, &row.key);
        // Objects folded into this row (for example the parts of a moved model) go back with it.
        let Some(entry) = old.get(&row.key) else { continue };
        let inside: Vec<String> =
            previous.descendants_of(entry.referent).filter_map(|i| old.by_ref.get(&i.referent()).cloned()).collect();
        for key in inside.iter().filter(|k| !shown.contains(k.as_str())) {
            revert(previous, &old, &mut snapshot, &new, key);
        }
    }
    for row in unstaged.iter().filter(|r| r.status == Status::Removed) {
        let Some(entry) = old.get(&row.key) else { continue };
        let Some(parent) = entry.parent.as_ref().and_then(|p| new.get(p)) else { continue };
        let copy = previous.clone_into_external(entry.referent, &mut snapshot);
        snapshot.transfer_within(copy, parent.referent);
    }
    for row in unstaged.iter().filter(|r| r.status == Status::Added) {
        if let Some(entry) = new.get(&row.key) {
            if snapshot.get_by_ref(entry.referent).is_some() {
                snapshot.destroy(entry.referent);
            }
        }
    }
    snapshot
}

/// Puts one object's name, parent and properties back the way `previous` had them.
fn revert(previous: &WeakDom, old: &Index, snapshot: &mut WeakDom, new: &Index, key: &str) {
    let (Some(before), Some(now)) = (old.get(key), new.get(key)) else { return };
    let source = previous.get_by_ref(before.referent).unwrap();
    let mut values = Vec::new();
    for (name, value) in &source.properties {
        match value {
            // References point at the same object in this copy; one RoGit can't find keeps its current value.
            Variant::Ref(target) => {
                if let Some(found) = old.by_ref.get(target).and_then(|k| new.get(k)) {
                    values.push((*name, Variant::Ref(found.referent)));
                }
            }
            other => values.push((*name, other.clone())),
        }
    }
    let Some(inst) = snapshot.get_by_ref_mut(now.referent) else { return };
    inst.name = source.name.clone();
    for (name, value) in values {
        inst.properties.insert(name, value);
    }
    if before.parent != now.parent {
        if let Some(parent) = before.parent.as_ref().and_then(|p| new.get(p)) {
            snapshot.transfer_within(now.referent, parent.referent);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use rbx_dom_weak::InstanceBuilder;
    use rbx_dom_weak::types::{Attributes, Color3, Vector3};

    fn tagged(class: &str, name: &str, id: &str) -> InstanceBuilder {
        let mut attributes = Attributes::new();
        attributes.insert(diff::TAG.to_owned(), Variant::BinaryString(id.as_bytes().to_vec().into()));
        InstanceBuilder::new(class).with_name(name).with_property("Attributes", Variant::Attributes(attributes))
    }

    /// Workspace > Map > (Gate, Tower, Shed > Roof), and a Crate when `crate_too`.
    fn place(gate: f32, tower: f32, shed: bool, crate_too: bool) -> WeakDom {
        let mut dom = WeakDom::new(InstanceBuilder::new("DataModel"));
        let workspace = dom.insert(dom.root_ref(), InstanceBuilder::new("Workspace").with_name("Workspace"));
        let map = dom.insert(workspace, tagged("Model", "Map", "map"));
        dom.insert(map, tagged("Part", "Gate", "gate").with_property("Color", Variant::Color3(Color3::new(gate, 0.0, 0.0))));
        dom.insert(map, tagged("Part", "Tower", "tower").with_property("Size", Variant::Vector3(Vector3::new(tower, 1.0, 1.0))));
        if shed {
            let shed = dom.insert(map, tagged("Model", "Shed", "shed"));
            dom.insert(shed, tagged("Part", "Roof", "roof"));
        }
        if crate_too {
            dom.insert(map, tagged("Model", "Crate", "crate"));
        }
        dom
    }

    #[test]
    fn only_staged_changes_are_committed() {
        let previous = place(0.0, 1.0, true, false);
        let live = || place(1.0, 5.0, false, true);
        let rows = diff::compare(&previous, &live()).rows;
        let staged: HashSet<String> = ["gate".to_owned()].into();

        let commit = partial(&previous, live(), &rows, &staged);
        let committed = diff::compare(&previous, &commit);
        assert_eq!(committed.summary, diff::Summary { added: 0, removed: 0, changed: 1 });
        assert_eq!(committed.rows.iter().find(|r| r.status != Status::Context).unwrap().name, "Gate");
        // What's left uncommitted: the tower, the new crate and the removed shed.
        let left = diff::compare(&commit, &live());
        assert_eq!(left.summary, diff::Summary { added: 1, removed: 1, changed: 1 });
    }

    #[test]
    fn discarding_puts_only_those_changes_back() {
        // Discarding is the same move the other way round: keep every change except the discarded ones.
        let previous = place(0.0, 1.0, true, false);
        let live = || place(1.0, 5.0, false, true);
        let rows = diff::compare(&previous, &live()).rows;
        let keep: HashSet<String> = ["tower".to_owned(), "shed".to_owned()].into();

        let wanted = partial(&previous, live(), &rows, &keep);
        let left = diff::compare(&previous, &wanted);
        let names: Vec<(&str, Status)> =
            left.rows.iter().filter(|r| r.status != Status::Context).map(|r| (r.name.as_str(), r.status)).collect();
        assert_eq!(names, [("Shed", Status::Removed), ("Tower", Status::Changed)]);
    }
}
