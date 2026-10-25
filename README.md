# RoGit

Branches for your Roblox places' assets: maps, models, UI, meshes and terrain. Make a branch, build in it, review
what changed, and merge it back into your game, like Git for everything Rojo doesn't sync. Scripts stay with Rojo.

RoGit has two pieces, like Rojo: the `rogit` terminal tool and the RoGit Studio plugin. It runs on macOS and
Windows. Everything stays on your computer; there's no account, API key or cloud.

## Install

With [Rokit](https://github.com/rojo-rbx/rokit), in your project folder:

```sh
rokit add <github-user>/rogit
rogit plugin install
```

Or from source: `cargo install --path .` in this folder.

## Set up

1. Run `rogit serve` in your project folder (next to `default.project.json`), for example in VS Code's terminal.
2. Open your game's start place in Studio and open the RoGit panel (Plugins → RoGit).
3. Click **Init**. RoGit writes `rogit.toml` (commit it), creates `.rogit/` (kept out of Git), and gives every
   object a small hidden ID attribute so it can follow it between branches. Save the place afterwards.

## Use

**In main** (your game's start place):

- **New branch**: copies main as it is, unsaved edits included, into `.rogit/branches/<name>.rbxl` and opens it.
- **Merge**: shows what the branch's last commit changed, laid out like the Explorer. Something changed on both
  sides is a conflict: pick *Keep main* or *Use branch*. The merge is one undo step. Merge again later and only
  the newer commits come in.
- **Pin** and **Archive** in a branch's `···` menu. Archive deletes the branch file (and closes it in Studio).
  RoGit offers it right after a merge.

**In a branch**, the panel works like VS Code's Source Control:

- **Changes** lists everything not committed yet, and updates within about half a second of an edit. Click one to
  see what changed and select it in Studio.
- **+** stages a change and **−** unstages it. **Commit** commits the staged changes, or all of them when none are
  staged. Pulls and reverts end with a commit of their own.
- **Discard** (on a change while the mouse is over it, or **Discard all**) puts changes back the way the last
  commit had them. Ctrl+Z brings them back.
- **Pull from main** brings main's newer changes into the branch (keep main open in Studio). Commit your own work
  first.
- Every refresh of the changes also autosaves a copy. If Studio closes before you save, the branch offers to
  restore the unsaved work when it opens again.

**The graph**, in both, shows main and every branch: when branches were made, commits, merges, pulls, reverts and
archives. Click a commit, merge or pull to see what it changed; open a commit in its branch to revert to it.

## What RoGit tracks

Everything saved in the place, except:

- scripts, and any Folder with a script inside it;
- whatever Rojo syncs (the `$path` entries in `default.project.json`);
- Studio's own camera and the `RBX_` attributes Roblox keeps for itself.

From the terminal, `rogit diff <branch>` prints a branch's changes (`--json` for tools).

## Support

RoGit is free and open source. If it helps you, you can support it through GitHub Sponsors.

## License

[MPL-2.0](LICENSE)
