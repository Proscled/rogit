//! The current user's registry on Windows, for RoGit's PATH entry and its login entry: read and written directly, as
//! installers do, rather than through PowerShell or reg.exe. Also opening files the way Explorer does, and finding and
//! stopping programs without PowerShell or taskkill (Microsoft Defender counts a program that runs those against it).

use std::ptr;
use windows_sys::Wdk::System::Threading::{NtQueryInformationProcess, ProcessCommandLineInformation};
use windows_sys::Win32::Foundation::{
    CloseHandle, ERROR_FILE_NOT_FOUND, ERROR_SUCCESS, HANDLE, HANDLE_FLAG_INHERIT, INVALID_HANDLE_VALUE, SetHandleInformation,
    UNICODE_STRING, WAIT_OBJECT_0,
};
use windows_sys::Win32::System::Console::{GetStdHandle, STD_ERROR_HANDLE, STD_INPUT_HANDLE, STD_OUTPUT_HANDLE};
use windows_sys::Win32::System::Diagnostics::ToolHelp::{CreateToolhelp32Snapshot, PROCESSENTRY32W, Process32FirstW, Process32NextW, TH32CS_SNAPPROCESS};
use windows_sys::Win32::System::Registry::{
    HKEY, HKEY_CURRENT_USER, KEY_READ, KEY_WRITE, REG_EXPAND_SZ, REG_OPTION_NON_VOLATILE, REG_SZ, RegCloseKey, RegCreateKeyExW,
    RegDeleteValueW, RegQueryValueExW, RegSetValueExW,
};
use windows_sys::Win32::System::Threading::{
    OpenProcess, PROCESS_ACCESS_RIGHTS, PROCESS_QUERY_LIMITED_INFORMATION, PROCESS_SYNCHRONIZE, PROCESS_TERMINATE, TerminateProcess,
    WaitForSingleObject,
};
use windows_sys::Win32::UI::Shell::ShellExecuteW;
use windows_sys::Win32::UI::WindowsAndMessaging::{HWND_BROADCAST, SMTO_ABORTIFHUNG, SW_SHOWNORMAL, SendMessageTimeoutW, WM_SETTINGCHANGE};

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

/// Opens a file with the program Windows has for it, as double-clicking it does.
pub fn open_file(file: &std::path::Path) -> std::io::Result<()> {
    let path: Vec<u16> = std::os::windows::ffi::OsStrExt::encode_wide(file.as_os_str()).chain(Some(0)).collect();
    let result = unsafe { ShellExecuteW(ptr::null_mut(), ptr::null(), path.as_ptr(), ptr::null(), ptr::null(), SW_SHOWNORMAL) };
    // Anything above 32 means it opened; below is an error code.
    match result as usize {
        n if n > 32 => Ok(()),
        n => Err(std::io::Error::other(format!("Windows couldn't open {} (error {n}).", file.display()))),
    }
}

/// Every running program: its process id and file name, like `RobloxStudioBeta.exe`.
pub fn programs() -> Vec<(u32, String)> {
    let snapshot = unsafe { CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0) };
    if snapshot == INVALID_HANDLE_VALUE {
        return Vec::new();
    }
    let mut entry = PROCESSENTRY32W { dwSize: size_of::<PROCESSENTRY32W>() as u32, ..Default::default() };
    let mut found = Vec::new();
    let mut more = unsafe { Process32FirstW(snapshot, &mut entry) } != 0;
    while more {
        let name = &entry.szExeFile[..entry.szExeFile.iter().position(|&c| c == 0).unwrap_or(entry.szExeFile.len())];
        found.push((entry.th32ProcessID, String::from_utf16_lossy(name)));
        more = unsafe { Process32NextW(snapshot, &mut entry) } != 0;
    }
    unsafe { CloseHandle(snapshot) };
    found
}

/// The command line a program was started with, if Windows lets this one read it (it does for the user's own).
pub fn command_line(pid: u32) -> Option<String> {
    let process = Process::open(pid, PROCESS_QUERY_LIMITED_INFORMATION)?;
    let mut size = 0u32;
    unsafe { NtQueryInformationProcess(process.0, ProcessCommandLineInformation, ptr::null_mut(), 0, &mut size) };
    if size < size_of::<UNICODE_STRING>() as u32 {
        return None;
    }
    // A UNICODE_STRING, followed by the text it points to. u64s keep it aligned.
    let mut buffer = vec![0u64; (size as usize).div_ceil(8)];
    let status = unsafe { NtQueryInformationProcess(process.0, ProcessCommandLineInformation, buffer.as_mut_ptr().cast(), size, &mut size) };
    if status < 0 {
        return None;
    }
    let text = unsafe { &*buffer.as_ptr().cast::<UNICODE_STRING>() };
    if text.Buffer.is_null() {
        return Some(String::new());
    }
    Some(String::from_utf16_lossy(unsafe { std::slice::from_raw_parts(text.Buffer, text.Length as usize / 2) }))
}

/// Stops a program at once, as Task Manager's End task does, and waits up to two seconds for it to be gone. Returns
/// whether it stopped.
pub fn stop(pid: u32) -> bool {
    let Some(process) = Process::open(pid, PROCESS_TERMINATE | PROCESS_SYNCHRONIZE) else { return false };
    unsafe { TerminateProcess(process.0, 1) != 0 && WaitForSingleObject(process.0, 2000) == WAIT_OBJECT_0 }
}

/// A running program, closed when dropped.
struct Process(HANDLE);

impl Process {
    fn open(pid: u32, access: PROCESS_ACCESS_RIGHTS) -> Option<Process> {
        let handle = unsafe { OpenProcess(access, 0, pid) };
        (!handle.is_null()).then_some(Process(handle))
    }
}

impl Drop for Process {
    fn drop(&mut self) {
        unsafe { CloseHandle(self.0) };
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::process::{Command, Stdio};

    #[test]
    fn finds_and_stops_programs() {
        // Busy for half a minute unless it's stopped.
        let mut child = Command::new("ping").args(["-n", "30", "127.0.0.1"]).stdout(Stdio::null()).spawn().unwrap();
        let pid = child.id();
        assert!(programs().iter().any(|(id, name)| *id == pid && name.eq_ignore_ascii_case("PING.EXE")));
        assert!(command_line(pid).unwrap().ends_with("-n 30 127.0.0.1"));
        assert!(command_line(std::process::id()).unwrap().contains("rogit"));
        assert!(stop(pid));
        assert!(!child.wait().unwrap().success());
    }
}
