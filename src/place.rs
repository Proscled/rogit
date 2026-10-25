//! Builds a place file from a plugin copy: one `<Service>.rbxm` per service (its children, in Roblox's own
//! binary format) plus a manifest with each service's settings and attributes.

use rbx_dom_weak::types::{
    Attributes, BrickColor, CFrame, Color3, ContentId, Enum, Matrix3, NumberRange, UDim, Variant, VariantType, Vector2,
    Vector3,
};
use rbx_dom_weak::{InstanceBuilder, WeakDom};
use rbx_reflection::DataType;
use serde_json::Value;
use std::fs;
use std::io::BufWriter;
use std::path::Path;

pub struct BuildReport {
    pub objects: usize,
    pub settings_skipped: usize,
}

pub fn property_type(class: &str, property: &str) -> Option<DataType<'static>> {
    let db = rbx_reflection_database::get().ok()?;
    let mut current = db.classes.get(class);
    while let Some(descriptor) = current {
        if let Some(found) = descriptor.properties.get(property) {
            return Some(found.data_type.clone());
        }
        current = descriptor.superclass.as_ref().and_then(|s| db.classes.get(&s[..]));
    }
    None
}

fn numbers(value: &Value, wanted: usize) -> Option<Vec<f32>> {
    let list: Vec<f32> = value.as_array()?.iter().filter_map(|x| x.as_f64()).map(|x| x as f32).collect();
    (list.len() >= wanted).then_some(list)
}

/// Converts a value the plugin encoded as `{"t": <Luau type>, "v": ...}` into the given property type.
fn to_variant(kind: VariantType, encoded: &Value) -> Option<Variant> {
    let v = &encoded["v"];
    Some(match kind {
        VariantType::Bool => Variant::Bool(v.as_bool()?),
        VariantType::Float32 => Variant::Float32(v.as_f64()? as f32),
        VariantType::Float64 => Variant::Float64(v.as_f64()?),
        VariantType::Int32 => Variant::Int32(v.as_f64()? as i32),
        VariantType::Int64 => Variant::Int64(v.as_f64()? as i64),
        VariantType::String => Variant::String(v.as_str()?.to_owned()),
        VariantType::Color3 => {
            let n = numbers(v, 3)?;
            Variant::Color3(Color3::new(n[0], n[1], n[2]))
        }
        VariantType::Vector3 => {
            let n = numbers(v, 3)?;
            Variant::Vector3(Vector3::new(n[0], n[1], n[2]))
        }
        VariantType::Vector2 => {
            let n = numbers(v, 2)?;
            Variant::Vector2(Vector2::new(n[0], n[1]))
        }
        VariantType::CFrame => {
            let n = numbers(v, 12)?;
            let rows = [Vector3::new(n[3], n[4], n[5]), Vector3::new(n[6], n[7], n[8]), Vector3::new(n[9], n[10], n[11])];
            Variant::CFrame(CFrame::new(Vector3::new(n[0], n[1], n[2]), Matrix3::new(rows[0], rows[1], rows[2])))
        }
        VariantType::UDim => {
            let n = numbers(v, 2)?;
            Variant::UDim(UDim::new(n[0], n[1] as i32))
        }
        VariantType::NumberRange => {
            let n = numbers(v, 2)?;
            Variant::NumberRange(NumberRange::new(n[0], n[1]))
        }
        VariantType::BrickColor => Variant::BrickColor(BrickColor::from_number(v.as_u64()? as u16)?),
        VariantType::ContentId => Variant::ContentId(ContentId::from(v.as_str()?)),
        _ => return None,
    })
}

fn setting(class: &str, name: &str, encoded: &Value) -> Option<Variant> {
    match property_type(class, name)? {
        DataType::Enum(_) => Some(Variant::Enum(Enum::from_u32(encoded["v"].as_u64()? as u32))),
        DataType::Value(kind) => to_variant(kind, encoded),
        _ => None,
    }
}

fn attribute(encoded: &Value) -> Option<Variant> {
    let kind = match encoded["t"].as_str()? {
        "boolean" => VariantType::Bool,
        "number" => VariantType::Float64,
        "string" => VariantType::String,
        "Color3" => VariantType::Color3,
        "Vector3" => VariantType::Vector3,
        "Vector2" => VariantType::Vector2,
        "UDim" => VariantType::UDim,
        "NumberRange" => VariantType::NumberRange,
        "BrickColor" => VariantType::BrickColor,
        "CFrame" => VariantType::CFrame,
        _ => return None,
    };
    to_variant(kind, encoded)
}

/// Writes a place file from the copy in `dir` (one `<Service>.rbxm` per service) and its manifest.
pub fn build(dir: &Path, manifest: &Value, out: &Path) -> Result<BuildReport, String> {
    let (dom, settings_skipped) = assemble(dir, manifest)?;
    let objects = dom.descendants().count() - 1;
    write(&dom, out)?;
    Ok(BuildReport { objects, settings_skipped })
}

/// Writes a place in memory to a place file.
pub fn write(dom: &WeakDom, out: &Path) -> Result<(), String> {
    let services = dom.root().children().to_vec();
    let file = fs::File::create(out).map_err(|e| format!("Couldn't create {}: {e}", out.display()))?;
    rbx_binary::to_writer(BufWriter::new(file), dom, &services).map_err(|e| format!("Couldn't write the place file: {e}"))
}

/// Reads a place file, for example a branch saved in Studio.
pub fn read(path: &Path) -> Result<WeakDom, String> {
    let bytes = fs::read(path).map_err(|e| format!("Couldn't read {}: {e}", path.display()))?;
    rbx_binary::from_reader(&bytes[..]).map_err(|e| format!("Couldn't read {}: {e}", path.display()))
}

/// Puts a copy back together as a place in memory. Returns it with the number of settings it couldn't use.
pub fn assemble(dir: &Path, manifest: &Value) -> Result<(WeakDom, usize), String> {
    let mut dom = WeakDom::new(InstanceBuilder::new("DataModel"));
    let root = dom.root_ref();
    let mut settings_skipped = 0;
    for service in manifest["services"].as_array().ok_or("The copy has no services.")? {
        let (Some(name), Some(class)) = (service["name"].as_str(), service["className"].as_str()) else {
            return Err("The copy lists a service without a name.".into());
        };
        let mut builder = InstanceBuilder::new(class).with_name(name);
        for (property, encoded) in service["settings"].as_object().into_iter().flatten() {
            match setting(class, property, encoded) {
                Some(value) => builder = builder.with_property(property.as_str(), value),
                None => settings_skipped += 1,
            }
        }
        let mut attributes = Attributes::new();
        for (key, encoded) in service["attributes"].as_object().into_iter().flatten() {
            if let Some(value) = attribute(encoded) {
                attributes.insert(key.clone(), value);
            }
        }
        builder = builder.with_property("Attributes", Variant::Attributes(attributes));
        // Plugins can't read this setting. Without it, Studio re-pivots every model when it opens the file.
        if class == "Workspace" {
            builder = builder.with_property("NeedsPivotMigration", Variant::Bool(false));
        }
        let service_ref = dom.insert(root, builder);
        let blob = fs::read(dir.join(format!("{name}.rbxm"))).unwrap_or_default();
        if blob.is_empty() {
            continue;
        }
        let mut children = rbx_binary::from_reader(&blob[..]).map_err(|e| format!("Couldn't read the copy of {name}: {e}"))?;
        for child in children.root().children().to_vec() {
            children.transfer(child, &mut dom, service_ref);
        }
    }
    Ok((dom, settings_skipped))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn builds_a_place_from_service_copies() {
        let dir = std::env::temp_dir().join(format!("rogit-place-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let mut copy = WeakDom::new(InstanceBuilder::new("DataModel"));
        let part = InstanceBuilder::new("Part").with_name("Crate").with_property("Anchored", Variant::Bool(true));
        let part = copy.insert(copy.root_ref(), part);
        rbx_binary::to_writer(fs::File::create(dir.join("Workspace.rbxm")).unwrap(), &copy, &[part]).unwrap();
        let manifest = json!({"services": [
            {"name": "Workspace", "className": "Workspace", "settings": {"Gravity": {"t": "number", "v": 98.1}},
             "attributes": {"Note": {"t": "string", "v": "hi"}}},
            {"name": "Lighting", "className": "Lighting", "settings": {"Ambient": {"t": "Color3", "v": [1, 0, 0]},
             "Unknown": {"t": "number", "v": 1}}}
        ]});
        let out = dir.join("branch.rbxl");
        let report = build(&dir, &manifest, &out).unwrap();
        assert_eq!((report.objects, report.settings_skipped), (3, 1));

        let place = rbx_binary::from_reader(&fs::read(&out).unwrap()[..]).unwrap();
        let workspace = place.get_by_ref(place.root().children()[0]).unwrap();
        assert_eq!(workspace.class.as_str(), "Workspace");
        assert_eq!(place.get_by_ref(workspace.children()[0]).unwrap().name, "Crate");
        assert!(workspace.properties.iter().any(|(k, v)| k.as_str() == "Gravity" && *v == Variant::Float32(98.1)));
        fs::remove_dir_all(dir).unwrap();
    }
}
