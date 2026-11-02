//! Gives the Windows programs what Windows shows about a program (its name, version and icon, in Task Manager, the
//! Startup apps list and a file's Properties) and a manifest. A program without them looks more like malware to
//! Microsoft Defender.

use std::env;

const MANIFEST: &str = r#"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<assembly xmlns="urn:schemas-microsoft-com:asm.v1" manifestVersion="1.0">
  <assemblyIdentity type="win32" name="RoGit" version="VERSION"/>
  <trustInfo xmlns="urn:schemas-microsoft-com:asm.v3">
    <security>
      <requestedPrivileges>
        <requestedExecutionLevel level="asInvoker" uiAccess="false"/>
      </requestedPrivileges>
    </security>
  </trustInfo>
  <compatibility xmlns="urn:schemas-microsoft-com:compatibility.v1">
    <application>
      <!-- Windows 10 and 11 -->
      <supportedOS Id="{8e0f7a12-bfb3-4fe8-b9a5-48fd50a15a9a}"/>
    </application>
  </compatibility>
  <application xmlns="urn:schemas-microsoft-com:asm.v3">
    <windowsSettings>
      <longPathAware xmlns="http://schemas.microsoft.com/SMI/2016/WindowsSettings">true</longPathAware>
    </windowsSettings>
  </application>
</assembly>
"#;

fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-changed=windows/rogit.ico");
    if env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("windows") {
        return;
    }
    let version = env::var("CARGO_PKG_VERSION").unwrap();
    let manifest = MANIFEST.replace("VERSION", &format!("{version}.0"));
    let comments = format!("{} {}", env::var("CARGO_PKG_DESCRIPTION").unwrap(), env::var("CARGO_PKG_REPOSITORY").unwrap());
    for (binary, description) in [("rogit", "RoGit"), ("rogit-background", "RoGit (background)")] {
        let mut resource = winresource::WindowsResource::new();
        resource
            .set("ProductName", "RoGit")
            .set("FileDescription", description)
            .set("CompanyName", "RoGit")
            .set("LegalCopyright", "RoGit contributors, MPL-2.0")
            .set("Comments", &comments)
            .set("InternalName", binary)
            .set("OriginalFilename", &format!("{binary}.exe"))
            .set_icon("windows/rogit.ico")
            .set_manifest(&manifest);
        if let Err(e) = resource.compile_for(binary) {
            // Building on Windows needs them; checking the Windows code from another computer doesn't.
            if cfg!(windows) {
                panic!("Couldn't give {binary}.exe its Windows details: {e}");
            }
            println!("cargo:warning=Left out {binary}.exe's Windows details: {e}");
        }
    }
}
