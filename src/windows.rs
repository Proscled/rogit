//! The current user's registry on Windows, for RoGit's PATH entry and its login entry: read and written directly, as
//! installers do, rather than through PowerShell or reg.exe.

use std::ptr;
use windows_sys::Win32::Foundation::{ERROR_FILE_NOT_FOUND, ERROR_SUCCESS, HANDLE_FLAG_INHERIT, SetHandleInformation};
use windows_sys::Win32::System::Console::{GetStdHandle, STD_ERROR_HANDLE, STD_INPUT_HANDLE, STD_OUTPUT_HANDLE};
use windows_sys::Win32::System::Registry::{
    HKEY, HKEY_CURRENT_USER, KEY_READ, KEY_WRITE, REG_EXPAND_SZ, REG_OPTION_NON_VOLATILE, REG_SZ, RegCloseKey, RegCreateKeyExW,
    RegDeleteValueW, RegQueryValueExW, RegSetValueExW,
};
use windows_sys::Win32::UI::WindowsAndMessaging::{HWND_BROADCAST, SMTO_ABORTIFHUNG, SendMessageTimeoutW, WM_SETTINGCHANGE};

const ENVIRONMENT: &str = "Environment";
const RUN: &str = r"Software\Microsoft\Windows\CurrentVersion\Run";

/// Stops programs this one starts from getting its input and output too. Windows hands a new program every handle
/// that can be inherited, so RoGit left running in the background would keep the installer's output open, and
/// anything reading that output would wait for RoGit to stop.
pub fn keep_own_output() {
    for which in [STD_INPUT_HANDLE, STD_OUTPUT_HANDLE, STD_ERROR_HANDLE] {
        // Fails harmlessly when there's no such handle.
        unsafe { SetHandleInformation(GetStdHandle(which), HANDLE_FLAG_INHERIT, 0) };
    }
}

fn wide(text: &str) -> Vec<u16> {
    text.encode_utf16().chain(Some(0)).collect()
}

/// A key of the current user's registry, closed when dropped.
struct Key(HKEY);

impl Key {
    /// Creates the key if it isn't there yet: a new Windows account has no Run key until something starts at login.
    fn open(path: &str) -> Result<Key, String> {
        let mut key: HKEY = ptr::null_mut();
        let name = wide(path);
        let status = unsafe {
            RegCreateKeyExW(
                HKEY_CURRENT_USER,
                name.as_ptr(),
                0,
                ptr::null(),
                REG_OPTION_NON_VOLATILE,
                KEY_READ | KEY_WRITE,
                ptr::null(),
                &mut key,
                ptr::null_mut(),
            )
        };
        if status != ERROR_SUCCESS {
            return Err(format!("Couldn't open HKEY_CURRENT_USER\\{path} (error {status})."));
        }
        Ok(Key(key))
    }

    /// A text value as it's stored (%USERPROFILE% and the like not expanded), if there is one.
    fn get(&self, name: &str) -> Result<Option<String>, String> {
        let name = wide(name);
        let (mut kind, mut size) = (0u32, 0u32);
        let status = unsafe { RegQueryValueExW(self.0, name.as_ptr(), ptr::null(), &mut kind, ptr::null_mut(), &mut size) };
        if status == ERROR_FILE_NOT_FOUND {
            return Ok(None);
        }
        if status != ERROR_SUCCESS {
            return Err(format!("Couldn't read the registry (error {status})."));
        }
        let mut data = vec![0u16; size as usize / 2 + 1];
        let mut size = (data.len() * 2) as u32;
        let status = unsafe { RegQueryValueExW(self.0, name.as_ptr(), ptr::null(), &mut kind, data.as_mut_ptr().cast(), &mut size) };
        if status != ERROR_SUCCESS {
            return Err(format!("Couldn't read the registry (error {status})."));
        }
        let text = String::from_utf16_lossy(&data[..(size as usize / 2).min(data.len())]);
        Ok(Some(text.trim_end_matches('\0').to_owned()))
    }

    fn set(&self, name: &str, value: &str, kind: u32) -> Result<(), String> {
        let (name, data) = (wide(name), wide(value));
        let status = unsafe { RegSetValueExW(self.0, name.as_ptr(), 0, kind, data.as_ptr().cast(), (data.len() * 2) as u32) };
        if status != ERROR_SUCCESS {
            return Err(format!("Couldn't write to the registry (error {status})."));
        }
        Ok(())
    }

    fn delete(&self, name: &str) -> Result<(), String> {
        let name = wide(name);
        match unsafe { RegDeleteValueW(self.0, name.as_ptr()) } {
            ERROR_SUCCESS | ERROR_FILE_NOT_FOUND => Ok(()),
            status => Err(format!("Couldn't write to the registry (error {status}).")),
        }
    }
}

impl Drop for Key {
    fn drop(&mut self) {
        unsafe { RegCloseKey(self.0) };
    }
}

/// Puts `folder` first on the user's PATH, or takes it off. The other entries stay as they're stored. Returns whether
/// PATH changed.
pub fn set_on_path(folder: &str, on: bool) -> Result<bool, String> {
    let key = Key::open(ENVIRONMENT)?;
    let saved = key.get("Path")?.unwrap_or_default();
    let others: Vec<&str> = saved.split(';').filter(|entry| !entry.is_empty() && !entry.eq_ignore_ascii_case(folder)).collect();
    let was_on = others.len() != saved.split(';').filter(|entry| !entry.is_empty()).count();
    if was_on == on {
        return Ok(false);
    }
    let entries: Vec<&str> = if on { std::iter::once(folder).chain(others).collect() } else { others };
    key.set("Path", &entries.join(";"), REG_EXPAND_SZ)?;
    // Programs started from now on (Explorer's new terminals included) pick up the new PATH.
    let environment = wide("Environment");
    let mut result = 0usize;
    unsafe { SendMessageTimeoutW(HWND_BROADCAST, WM_SETTINGCHANGE, 0, environment.as_ptr() as isize, SMTO_ABORTIFHUNG, 5000, &mut result) };
    Ok(true)
}

/// Starts `program` whenever the user logs in, or stops that (`None`).
pub fn set_login_entry(program: Option<&str>) -> Result<(), String> {
    let key = Key::open(RUN)?;
    match program {
        Some(program) => key.set("RoGit", &format!("\"{program}\""), REG_SZ),
        None => key.delete("RoGit"),
    }
}
