# RoGit

Branches for your Roblox places' assets: maps, models, UI, meshes and terrain. Scripts stay with Rojo and Git.

RoGit has two pieces, like Rojo: the `rogit` terminal tool and the RoGit Studio plugin.

## Setup

```sh
rogit plugin install   # puts the RoGit plugin in Studio
rogit serve            # run in your project folder, next to default.project.json
```

Open your game's start place in Studio, open the RoGit panel (Plugins → RoGit) and click **Init**. Init:

- writes `rogit.toml` (commit it) and creates `.rogit/` (kept out of Git);
- gives every object a short hidden ID attribute, `RoGitId`. It skips scripts, Folders that contain a script, and everything Rojo syncs. Save main afterwards to keep the IDs.

## Status

Build step 1 of 6: `rogit serve`, the plugin connecting, and Init. Branches, review and merge come next.

## License

[MPL-2.0](LICENSE)
