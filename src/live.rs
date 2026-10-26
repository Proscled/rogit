//! A branch as it is in Studio right now, kept in memory by `rogit serve`. The plugin sends one full copy (with
//! Studio's session ID for every object), then only the objects that change. The changes list stays current in big
//! places without copying the whole place after every edit.

use crate::place;
use rbx_dom_weak::types::{Attributes, Ref, Variant};
use rbx_dom_weak::{Ustr, WeakDom};
use serde_json::Value;
use std::collections::HashMap;
use std::time::Instant;

pub struct Live {
    pub dom: WeakDom,
    /// Studio's session ID of each object -> the object here, and back.
    ids: HashMap<String, Ref>,
    refs: HashMap<Ref, String>,
    /// Whether every object got its ID. Without them, patches can't be placed and the plugin sends full copies.
    pub identified: bool,
    /// When this copy was last written to disk (the autosave; also as Unix seconds for the plugin), and whether it
    /// changed since.
    pub saved: Instant,
    pub saved_at: Option<u64>,
    pub changed: bool,
    /// How many changes weren't committed at the last refresh of the changes.
    pub uncommitted: usize,
}

/// A place as the bytes of an .rbxl file.
pub fn to_bytes(dom: &WeakDom) -> Result<Vec<u8>, String> {
    let mut bytes = Vec::new();
    let services = dom.root().children().to_vec();
    rbx_binary::to_writer(&mut bytes, dom, &services).map_err(|e| e.to_string())?;
    Ok(bytes)
}

/// A copy of a place in memory, for commits and discards that change one.
pub fn copy_of(dom: &WeakDom) -> Result<WeakDom, String> {
    rbx_binary::from_reader(&to_bytes(dom)?[..]).map_err(|e| e.to_string())
}

/// Objects in the order the plugin walks them: each one, then its children in order (depth first).
fn walk(dom: &WeakDom, root: Ref) -> Vec<Ref> {
    let mut out = Vec::new();
    let mut stack = vec![root];
    while let Some(r) = stack.pop() {
        out.push(r);
        if let Some(inst) = dom.get_by_ref(r) {
            stack.extend(inst.children().iter().rev().copied());
        }
    }
    out
}

impl Live {
    /// Takes a full copy. `manifest.services[].ids` lists "id|Class" for every object the plugin copied, in the order
    /// it walked them. Copies leave out a few runtime objects (TouchInterest), so entries without a match are skipped.
    pub fn new(dom: WeakDom, manifest: &Value) -> Live {
        let mut live =
            Live { dom, ids: HashMap::new(), refs: HashMap::new(), identified: false, saved: Instant::now(), saved_at: None, changed: false, uncommitted: 0 };
        live.identified = live.name_services(manifest).is_some();
        live
    }

    fn name_services(&mut self, manifest: &Value) -> Option<()> {
        for service in manifest["services"].as_array()? {
            let name = service["name"].as_str()?;
            let ids: Vec<&str> = service["ids"].as_array()?.iter().filter_map(Value::as_str).collect();
            let service_ref = self.service(name)?;
            let roots = self.dom.get_by_ref(service_ref)?.children().to_vec();
            let mut objects = Vec::new();
            for root in roots {
                objects.extend(walk(&self.dom, root));
            }
            if !self.name_all(&objects, &ids) {
                return None;
            }
        }
        Some(())
    }

    fn service(&self, name: &str) -> Option<Ref> {
        self.dom.root().children().iter().copied().find(|r| self.dom.get_by_ref(*r).is_some_and(|i| i.name == name))
    }

    /// Gives `objects` (in walk order) their IDs from `entries` ("id|Class", in the plugin's walk order, which may
    /// list extra objects that copies leave out). Returns whether every object got one.
    fn name_all(&mut self, objects: &[Ref], entries: &[&str]) -> bool {
        let mut entries = entries.iter().filter_map(|e| e.split_once('|'));
        for &object in objects {
            let class = self.dom.get_by_ref(object).map(|i| i.class.as_str().to_owned()).unwrap_or_default();
            let Some((id, _)) = entries.by_ref().find(|(_, c)| *c == class) else { return false };
            self.ids.insert(id.to_owned(), object);
            self.refs.insert(object, id.to_owned());
        }
        true
    }

    /// Forgets the IDs of an object and everything inside it, and returns them with the objects they named.
    fn forget(&mut self, root: Ref) -> HashMap<String, Ref> {
        let mut gone = HashMap::new();
        for r in walk(&self.dom, root) {
            if let Some(id) = self.refs.remove(&r) {
                self.ids.remove(&id);
                gone.insert(id, r);
            }
        }
        gone
    }

    fn find(&self, key: &str) -> Option<Ref> {
        match key.strip_prefix("service:") {
            Some(name) => self.service(name),
            None => self.ids.get(key).copied(),
        }
    }

    /// Applies what changed in Studio. `data` holds the changed objects (an rbxm, in the order of `upserts`); each
    /// upsert names the object (`id`), its parent, and the IDs inside it (`ids`, in walk order). `refs` restores
    /// references from changed objects to others in the same service, which copies of single objects lose.
    /// Returns false when something can't be placed; then the plugin sends a full copy instead.
    pub fn patch(&mut self, upserts: &[Value], data: Option<WeakDom>, removes: &[String], services: &[Value], refs: &[Value]) -> bool {
        if !self.identified {
            return false;
        }
        let mut data = data.unwrap_or_else(|| WeakDom::new(rbx_dom_weak::InstanceBuilder::new("Folder")));
        let roots = data.root().children().to_vec();
        if roots.len() != upserts.len() {
            return false;
        }
        // Old object -> its replacement, for references elsewhere that pointed at the old one.
        let mut moved: HashMap<Ref, Ref> = HashMap::new();
        for (upsert, root) in upserts.iter().zip(roots) {
            let Some(parent) = upsert["parent"].as_str().and_then(|p| self.find(p)) else { return false };
            let old = upsert["id"].as_str().and_then(|id| self.ids.get(id).copied());
            let gone = match old {
                Some(old) => {
                    let gone = self.forget(old);
                    self.dom.destroy(old);
                    gone
                }
                None => HashMap::new(),
            };
            data.transfer(root, &mut self.dom, parent);
            let entries: Vec<&str> = upsert["ids"].as_array().into_iter().flatten().filter_map(Value::as_str).collect();
            let objects = walk(&self.dom, root);
            if !self.name_all(&objects, &entries) {
                return false;
            }
            for object in objects {
                if let Some(before) = self.refs.get(&object).and_then(|id| gone.get(id)) {
                    moved.insert(*before, object);
                }
            }
        }
        for id in removes {
            if let Some(r) = self.ids.get(id).copied() {
                self.forget(r);
                self.dom.destroy(r);
            }
        }
        if !moved.is_empty() {
            let all: Vec<Ref> = self.dom.descendants().map(|i| i.referent()).collect();
            for r in all {
                let inst = self.dom.get_by_ref_mut(r).unwrap();
                for value in inst.properties.values_mut() {
                    if let Variant::Ref(target) = value {
                        if let Some(new) = moved.get(target) {
                            *target = *new;
                        }
                    }
                }
            }
        }
        for fixup in refs {
            let (Some(object), Some(property)) = (fixup["id"].as_str().and_then(|id| self.ids.get(id)), fixup["property"].as_str()) else {
                continue;
            };
            let target = fixup["target"].as_str().and_then(|t| self.ids.get(t)).copied().unwrap_or_else(Ref::none);
            let object = *object;
            if let Some(inst) = self.dom.get_by_ref_mut(object) {
                inst.properties.insert(Ustr::from(property), Variant::Ref(target));
            }
        }
        for service in services {
            let (Some(name), Some(class)) = (service["name"].as_str(), service["className"].as_str()) else { continue };
            let Some(service_ref) = self.service(name) else { continue };
            let mut values = Vec::new();
            for (property, encoded) in service["settings"].as_object().into_iter().flatten() {
                if let Some(value) = place::setting(class, property, encoded) {
                    values.push((Ustr::from(property.as_str()), value));
                }
            }
            let mut attributes = Attributes::new();
            for (key, encoded) in service["attributes"].as_object().into_iter().flatten() {
                if let Some(value) = place::attribute(encoded) {
                    attributes.insert(key.clone(), value);
                }
            }
            let inst = self.dom.get_by_ref_mut(service_ref).unwrap();
            for (property, value) in values {
                inst.properties.insert(property, value);
            }
            inst.properties.insert(Ustr::from("Attributes"), Variant::Attributes(attributes));
        }
        self.changed = true;
        true
    }

    /// A copy of this place, for commits, with its .rbxl bytes (the commit's file when everything is committed).
    pub fn copy(&self) -> Result<(WeakDom, Vec<u8>), String> {
        let bytes = to_bytes(&self.dom)?;
        let dom = rbx_binary::from_reader(&bytes[..]).map_err(|e| e.to_string())?;
        Ok((dom, bytes))
    }

    /// Objects with an ID; for checks.
    #[cfg(test)]
    fn named(&self) -> std::collections::HashSet<String> {
        self.ids.keys().cloned().collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use rbx_dom_weak::InstanceBuilder;
    use rbx_dom_weak::types::Color3;
    use serde_json::json;

    /// Workspace > (Gate, Shed > Roof), with Shed.PrimaryPart = Roof. IDs: gate 1, shed 2, roof 3.
    fn place() -> (WeakDom, Value) {
        let mut dom = WeakDom::new(InstanceBuilder::new("DataModel"));
        let workspace = dom.insert(dom.root_ref(), InstanceBuilder::new("Workspace").with_name("Workspace"));
        dom.insert(workspace, InstanceBuilder::new("Part").with_name("Gate"));
        let shed = dom.insert(workspace, InstanceBuilder::new("Model").with_name("Shed"));
        let roof = dom.insert(shed, InstanceBuilder::new("Part").with_name("Roof"));
        dom.get_by_ref_mut(shed).unwrap().properties.insert(Ustr::from("PrimaryPart"), Variant::Ref(roof));
        // The plugin also saw a TouchInterest under the gate, which copies leave out.
        let manifest = json!({ "services": [{ "name": "Workspace", "ids": ["1|Part", "9|TouchTransmitter", "2|Model", "3|Part"] }] });
        (dom, manifest)
    }

    fn find<'a>(dom: &'a WeakDom, name: &str) -> &'a rbx_dom_weak::Instance {
        dom.descendants().find(|i| i.name == name).unwrap()
    }

    #[test]
    fn takes_ids_and_skips_objects_copies_leave_out() {
        let (dom, manifest) = place();
        let live = Live::new(dom, &manifest);
        assert!(live.identified);
        assert_eq!(live.named(), ["1", "2", "3"].map(String::from).into());
    }

    #[test]
    fn replaces_a_changed_object_and_keeps_references_to_it() {
        let (dom, manifest) = place();
        let mut live = Live::new(dom, &manifest);
        // Studio sends a red copy of the roof.
        let mut data = WeakDom::new(InstanceBuilder::new("Folder"));
        data.insert(data.root_ref(), InstanceBuilder::new("Part").with_name("Roof").with_property("Color", Variant::Color3(Color3::new(1.0, 0.0, 0.0))));
        let upserts = [json!({ "id": "3", "parent": "2", "ids": ["3|Part"] })];
        assert!(live.patch(&upserts, Some(data), &[], &[], &[]));
        let roof = find(&live.dom, "Roof");
        assert_eq!(roof.properties.get(&Ustr::from("Color")), Some(&Variant::Color3(Color3::new(1.0, 0.0, 0.0))));
        // The shed's PrimaryPart now points at the new roof.
        let shed = find(&live.dom, "Shed");
        assert_eq!(shed.properties.get(&Ustr::from("PrimaryPart")), Some(&Variant::Ref(roof.referent())));
        assert_eq!(live.dom.descendants().filter(|i| i.name == "Roof").count(), 1);
    }

    #[test]
    fn adds_removes_and_asks_for_a_full_copy_when_lost() {
        let (dom, manifest) = place();
        let mut live = Live::new(dom, &manifest);
        let mut data = WeakDom::new(InstanceBuilder::new("Folder"));
        data.insert(data.root_ref(), InstanceBuilder::new("Part").with_name("Crate"));
        let upserts = [json!({ "id": "4", "parent": "service:Workspace", "ids": ["4|Part"] })];
        assert!(live.patch(&upserts, Some(data), &["1".to_owned()], &[], &[]));
        assert!(live.dom.descendants().any(|i| i.name == "Crate"));
        assert!(!live.dom.descendants().any(|i| i.name == "Gate"));
        // A parent RoGit never heard of: it can't place the object.
        let mut data = WeakDom::new(InstanceBuilder::new("Folder"));
        data.insert(data.root_ref(), InstanceBuilder::new("Part").with_name("Lost"));
        let lost = [json!({ "id": "5", "parent": "77", "ids": ["5|Part"] })];
        assert!(!live.patch(&lost, Some(data), &[], &[], &[]));
    }
}
