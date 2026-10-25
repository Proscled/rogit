# Releasing

## Once

1. Create the GitHub repository (public, so Pages and releases are free) and push `main`.
2. In the repository's **Settings → Pages**, set **Source** to **GitHub Actions**. Then run the **Site** workflow
   once from the Actions tab. It publishes `site/` to `https://<owner>.github.io/<repo>/`, with the repository's
   names filled in, and again on every push to `main` that changes `site/`.
3. Replace `<github-user>` in `README.md` with the owner.

## Each release

1. Set `version` in `Cargo.toml`, run `cargo build` so `Cargo.lock` follows, and commit.
2. Tag the commit and push both:

   ```sh
   git tag v0.2.0
   git push origin main v0.2.0
   ```

3. The **Release** workflow checks the tag matches `Cargo.toml`, runs the tests, builds for Apple silicon, Intel Macs
   and Windows, and attaches `rogit-macos-aarch64.zip`, `rogit-macos-x86_64.zip` and `rogit-windows-x86_64.zip` to
   the release. The install scripts always fetch the latest release, so people update by running the install command
   again.

The **CI** workflow runs both install scripts on every push, against that commit's build, so a broken installer
shows up before a release.
