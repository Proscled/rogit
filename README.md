# RoGit

Branches for your Roblox places: maps, models, UI, meshes and terrain. Make a branch, build in it, see what changed,
and merge it back into your game, like Git. Scripts aren't part of branches; keep them however you like.

RoGit has two pieces: the Studio plugin, where you use it, and RoGit itself, which runs in the background on your
computer and keeps every game's branches. It runs on Windows and macOS. Everything stays on your computer; there's no
account, API key or cloud.

## Install

On Windows, in PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -c "irm https://proscled.github.io/rogit/install.ps1 | iex"
```

On macOS, in Terminal:

```sh
curl -fsSL https://proscled.github.io/rogit/install.sh | sh
```

The installer puts `rogit` in `%LOCALAPPDATA%\rogit\bin` (Windows) or `~/.rogit/bin` (macOS), installs the Studio
plugin, and starts RoGit in the background, from then on whenever you log in. `rogit update` updates it (the plugin
says when there's a new version) and `rogit uninstall` removes it; your branches stay. The
[install page](https://proscled.github.io/rogit/#install) also covers plain downloads and building from source.

## Set up a game

1. In Studio, open your game's start place and the RoGit panel (Plugins → RoGit).
2. Click **Init**. RoGit gives every object a small hidden ID attribute, so it can follow it between branches. Save
   the place afterwards.

That's all; do it once per game. RoGit keeps each game's branches in `%LOCALAPPDATA%\rogit\games` (`~/.rogit/games`
on macOS).

## Use

**In main** (your game's start place):

- **New branch**: copies main as it is, unsaved edits included, into a place file of its own and opens it.
- **Merge**: shows what the branch's last commit changed, laid out like the Explorer. Something changed on both
  sides is a conflict: pick *Keep main* or *Use branch*. The merge is one undo step. Merge again later and only
  the newer commits come in.
- **Pin** and **Archive** in a branch's `···` menu. Archive deletes the branch file (and closes it in Studio).
  RoGit offers it right after a merge.

**In a branch**, the panel is source control for your map:

- **Changes** lists everything not committed yet, and updates within about a quarter of a second of an edit, even
  in big places: after one full copy, RoGit only sends the objects that change. Click one to see what changed and
  select it in Studio.
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
- Studio's own camera and the `RBX_` attributes Roblox keeps for itself.

## From the terminal

- `rogit diff` lists every game's branches; `rogit diff <branch>` prints what a branch changed (`--json` for tools).
- `rogit update` updates RoGit and its plugin; `rogit uninstall` removes both (your branches stay).
- `rogit serve` runs RoGit yourself, if it isn't running in the background.
- `rogit autostart off` stops RoGit starting when you log in; `rogit autostart` turns it back on.

## Support

RoGit is free and open source. If it helps you, you can support it through GitHub Sponsors.

## License

[MPL-2.0](LICENSE)
