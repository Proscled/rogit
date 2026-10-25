//! Public Roblox game info: which place is an experience's start place. No login needed.

use serde_json::Value;
use std::collections::HashMap;
use std::time::Duration;

#[derive(Clone, Debug)]
pub struct Experience {
    pub name: String,
    pub start_place_id: u64,
}

pub struct Roblox {
    agent: ureq::Agent,
    cache: HashMap<u64, Experience>,
}

impl Roblox {
    pub fn new() -> Self {
        let agent = ureq::Agent::config_builder().timeout_global(Some(Duration::from_secs(10))).build().into();
        Roblox { agent, cache: HashMap::new() }
    }

    pub fn experience(&mut self, universe_id: u64) -> Result<Experience, String> {
        if let Some(found) = self.cache.get(&universe_id) {
            return Ok(found.clone());
        }
        // games.roblox.com answers "[TITLE UNAVAILABLE]" for some private games; this endpoint doesn't.
        let url = format!("https://develop.roblox.com/v1/universes/{universe_id}");
        let text = self
            .agent
            .get(&url)
            .call()
            .and_then(|mut res| res.body_mut().read_to_string())
            .map_err(|e| format!("Couldn't reach Roblox to look up this game ({e})."))?;
        let found = parse_experience(&text).ok_or("Roblox doesn't know this game. Publish it first.")?;
        self.cache.insert(universe_id, found.clone());
        Ok(found)
    }
}

fn parse_experience(text: &str) -> Option<Experience> {
    let game: Value = serde_json::from_str(text).ok()?;
    Some(Experience { name: game["name"].as_str()?.to_owned(), start_place_id: game["rootPlaceId"].as_u64()? })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_name_and_start_place() {
        let found = parse_experience(r#"{"id":1,"name":"Test","rootPlaceId":42,"privacyType":"Private"}"#).unwrap();
        assert_eq!((found.name.as_str(), found.start_place_id), ("Test", 42));
        assert!(parse_experience(r#"{"errors":[{"code":1,"message":"Not found"}]}"#).is_none());
    }
}
