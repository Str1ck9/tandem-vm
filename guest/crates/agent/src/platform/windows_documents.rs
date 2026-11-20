//! Opening shared Mac documents in a chosen Windows program, and saying which file types a program opens.
//!
//! The agent runs with the administrator's rights (it sets the clock and maps drives). A program it
//! started itself would inherit those rights, and would not see the user's drive letters, which
//! Windows keeps apart for the elevated and the normal side of one user. So the agent hands the steps
//! to a copy of itself that runs with the user's normal rights:
//!
//! * the steps go into a file in `spool\` next to the agent's program file, where only administrators
//!   can write, so no other program can make the launcher start something;
//! * a scheduled task ("Tandem Launcher", run as the signed-in user with limited rights, as many at
//!   once as are asked for) starts `tandem-agent.exe --run-requests`, which carries the steps out;
//! * the outcome comes back in a file under the user's own `%LOCALAPPDATA%\Tandem\results`.
//!
//! An agent that is not elevated (a standard user) carries the steps out itself.
//!
//! Run in a Windows 11 ARM64 guest on 2026-11-15.

use super::super::{encode_launch_steps, parse_launch_steps, shared_document_path, LaunchStep, ProgramInfo};
use super::{mapped_drives, run_quiet, to_wide, CREATE_NO_WINDOW};
use link_proto::document_status as status;
use std::path::PathBuf;
use std::process::Command;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::Mutex;
use std::time::{Duration, Instant};
use windows_sys::Win32::Foundation::{CloseHandle, HANDLE};
use windows_sys::Win32::Security::{GetTokenInformation, TokenElevation, TOKEN_ELEVATION, TOKEN_QUERY};
use windows_sys::Win32::System::Threading::{GetCurrentProcess, OpenProcessToken};
use windows_sys::Win32::UI::Shell::ShellExecuteW;

const LAUNCHER_TASK: &str = "Tandem Launcher";
/// How long a document may take to become reachable (the share is mounted a little after sign-in).
const REACH_TIMEOUT: Duration = Duration::from_secs(25);
/// How long the launcher may take in all.
const LAUNCH_TIMEOUT: Duration = Duration::from_secs(45);

pub fn documents_available() -> bool { true }

fn is_elevated() -> bool {
    unsafe {
        let mut token: HANDLE = std::ptr::null_mut();
        if OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) == 0 { return false; }
        let mut elevation = TOKEN_ELEVATION { TokenIsElevated: 0 };
        let mut size = 0u32;
        let ok = GetTokenInformation(token, TokenElevation, &mut elevation as *mut _ as *mut _, std::mem::size_of::<TOKEN_ELEVATION>() as u32, &mut size);
        CloseHandle(token);
        ok != 0 && elevation.TokenIsElevated != 0
    }
}

fn spool_dir() -> Option<PathBuf> {
    Some(std::env::current_exe().ok()?.parent()?.join("spool"))
}

fn results_dir() -> PathBuf {
    PathBuf::from(std::env::var("LOCALAPPDATA").unwrap_or_else(|_| r"C:\Users\Public".into())).join("Tandem").join("results")
}

// MARK: What a program is and which files it opens

/// Where a program's file is and which file name extensions it opens. For a store app the extensions
/// come from its package; for a classic program from the registry (its `SupportedTypes`, and every
/// file type whose "open" command names the program). Takes a second or two.
pub fn program_info(id: &str) -> ProgramInfo {
    const SCRIPT: &str = r#"[Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = 'SilentlyContinue'
$id = $env:TANDEM_PROGRAM_ID
$target = ''
$item = (New-Object -ComObject Shell.Application).NameSpace('shell:AppsFolder').Items() | Where-Object { $_.Path -eq $id } | Select-Object -First 1
if ($item) { $target = [string]$item.ExtendedProperty('System.Link.TargetParsingPath') }
if ($id.ToLower().EndsWith('.lnk') -and (Test-Path -LiteralPath $id)) { $target = (New-Object -ComObject WScript.Shell).CreateShortcut($id).TargetPath }
# A classic program's id is often its own path, with the folder it is installed under given by number;
# the shell gives the same form back as the link's target.
$candidate = if ($target) { $target } else { $id }
if ($candidate) {
  $folders = @{
    '{6D809377-6AF0-444B-8957-A3773F02200E}' = $env:ProgramW6432
    '{7C5A40EF-A0FB-4BFC-874A-C0F2E0B9FA8E}' = ${env:ProgramFiles(x86)}
    '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}' = (Join-Path $env:WINDIR 'System32')
    '{D65231B0-B2F1-4857-A4CE-A8E7C6EA7D27}' = (Join-Path $env:WINDIR 'SysWOW64')
    '{F38BF404-1D43-42F2-9305-67DE0B28FC23}' = $env:WINDIR
  }
  if ($candidate -match '^(\{[0-9A-Fa-f-]{36}\})\\(.+)$' -and $folders[$Matches[1].ToUpper()]) { $target = Join-Path $folders[$Matches[1].ToUpper()] $Matches[2] }
  elseif (-not $target -and $id -match '^[A-Za-z]:\\.+\.exe$') { $target = $id }
}
if ($target -and -not (Test-Path -LiteralPath $target)) { $target = '' }
"target`t$target"
$exts = New-Object System.Collections.Generic.HashSet[string]
if ($id -match '^([^!\\]+_[a-z0-9]{13})!') {
  $family = $Matches[1]
  $pkg = Get-AppxPackage | Where-Object { $_.PackageFamilyName -eq $family } | Select-Object -First 1
  if ($pkg) {
    $manifest = Get-AppxPackageManifest $pkg
    foreach ($e in $manifest.Package.Applications.Application.Extensions.Extension) {
      if ($e.Category -eq 'windows.fileTypeAssociation') {
        foreach ($t in $e.FileTypeAssociation.SupportedFileTypes.FileType) {
          $s = if ($t -is [string]) { $t } else { $t.'#text' }
          if ($s) { [void]$exts.Add($s.ToLower()) }
        }
      }
    }
    # A store app's icon is a picture file in its package; the largest plain one serves as a Dock icon.
    $node = $manifest.Package.Applications.Application | Where-Object { $id.EndsWith('!' + $_.Id) } | Select-Object -First 1
    if (-not $node) { $node = @($manifest.Package.Applications.Application)[0] }
    $logo = $null
    foreach ($rel in @($node.VisualElements.Square44x44Logo, $node.VisualElements.Square150x150Logo)) {
      if (-not $rel -or $logo) { continue }
      $full = Join-Path $pkg.InstallLocation $rel
      $files = Get-ChildItem -LiteralPath (Split-Path $full) -Filter ([IO.Path]::GetFileNameWithoutExtension($full) + '*.png') | Where-Object { $_.Name -notmatch 'contrast' }
      $pick = $files | Where-Object { $_.Name -match 'targetsize-256' -and $_.Name -match 'altform-unplated' -and $_.Name -notmatch 'lightunplated' } | Select-Object -First 1
      if (-not $pick) { $pick = $files | Where-Object { $_.Name -match 'targetsize-256' -and $_.Name -notmatch 'lightunplated' } | Select-Object -First 1 }
      if (-not $pick) { $pick = $files | Sort-Object Length -Descending | Select-Object -First 1 }
      if ($pick) { $logo = $pick.FullName }
    }
    if ($logo) { "logo`t$logo" }
  }
}
if ($target) {
  $exe = Split-Path $target -Leaf
  $root = [Microsoft.Win32.Registry]::ClassesRoot
  $types = $root.OpenSubKey("Applications\$exe\SupportedTypes")
  if ($types) { foreach ($p in $types.GetValueNames()) { [void]$exts.Add($p.ToLower()) }; $types.Close() }
  $needle = $target.ToLower()
  $opens = @{}
  foreach ($key in $root.GetSubKeyNames()) {
    if (-not $key.StartsWith('.')) { continue }
    $sub = $root.OpenSubKey($key)
    if (-not $sub) { continue }
    $ids = @([string]$sub.GetValue(''))
    $with = $sub.OpenSubKey('OpenWithProgids')
    if ($with) { $ids += $with.GetValueNames(); $with.Close() }
    $sub.Close()
    foreach ($p in $ids) {
      if (-not $p) { continue }
      if (-not $opens.ContainsKey($p)) {
        $c = $root.OpenSubKey("$p\shell\open\command")
        $opens[$p] = if ($c) { ([string]$c.GetValue('')).ToLower().Contains($needle) } else { $false }
        if ($c) { $c.Close() }
      }
      if ($opens[$p]) { [void]$exts.Add($key.ToLower()); break }
    }
  }
}
foreach ($e in $exts) { "ext`t$e" }
"#;
    use std::os::windows::process::CommandExt;
    let output = Command::new("powershell").args(["-NoProfile", "-NonInteractive", "-Command", SCRIPT])
        .env("TANDEM_PROGRAM_ID", id).creation_flags(CREATE_NO_WINDOW).output();
    let text = output.map(|o| String::from_utf8_lossy(&o.stdout).into_owned()).unwrap_or_default();
    let info = ProgramInfo::parse(&text);
    TARGETS.lock().unwrap().retain(|(known, _)| known != id);
    TARGETS.lock().unwrap().push((id.to_string(), info.target.clone()));
    info
}

/// Program files found so far, by program id (an empty path: a store app, started through the shell).
static TARGETS: Mutex<Vec<(String, String)>> = Mutex::new(Vec::new());

/// A program's file, when `program_info` has looked it up already.
pub(super) fn known_target(id: &str) -> Option<String> {
    TARGETS.lock().unwrap().iter().find(|(known, _)| known == id).map(|(_, target)| target.clone())
}

fn program_target(id: &str) -> String {
    if let Some((_, target)) = TARGETS.lock().unwrap().iter().find(|(known, _)| known == id) { return target.clone(); }
    program_info(id).target
}

// MARK: Opening documents

/// Where the shared Mac folders are for the signed-in user: the drive letter when one is mapped.
fn shares_root() -> Option<String> {
    mapped_drives().into_iter().next().map(|(letter, _)| letter)
}

/// Opens shared documents (`<share>/<path>`) in a program from the list, or, with an empty program
/// id, each in its default program. Returns once the program has been started.
pub fn open_documents(program: &str, documents: &[String]) -> Result<(), (u32, String)> {
    let root = shares_root().ok_or((status::UNREACHABLE, "No Mac folders are connected in Windows yet.".to_string()))?;
    let mut paths = Vec::new();
    for document in documents {
        paths.push(shared_document_path(&root, document)
            .ok_or((status::UNREACHABLE, format!("“{document}” is not a document in a shared folder.")))?);
    }
    let mut steps: Vec<LaunchStep> = paths.iter().map(|p| LaunchStep::Check(p.clone())).collect();
    if program.is_empty() {
        steps.extend(paths.iter().map(|p| LaunchStep::Open { target: p.clone(), parameters: String::new() }));
    } else {
        let exe = program_target(program);
        let target = if !exe.is_empty() { exe }
            else if program.to_lowercase().ends_with(".lnk") { program.to_string() }
            else { format!(r"shell:AppsFolder\{program}") };
        let parameters = paths.iter().map(|p| format!("\"{p}\"")).collect::<Vec<_>>().join(" ");
        steps.push(LaunchStep::Open { target, parameters });
    }
    if is_elevated() { hand_to_launcher(&steps) } else { perform(&steps) }
}

static REQUEST_NUMBER: AtomicU32 = AtomicU32::new(0);

fn hand_to_launcher(steps: &[LaunchStep]) -> Result<(), (u32, String)> {
    let failed = |what: &str| (status::FAILED, format!("The Tandem guest tools could not start the program ({what})."));
    let spool = spool_dir().ok_or_else(|| failed("no spool folder"))?;
    std::fs::create_dir_all(&spool).map_err(|e| failed(&format!("spool folder: {e}")))?;
    let results = results_dir();
    let _ = std::fs::create_dir_all(&results);
    let name = format!("{}-{}", std::process::id(), REQUEST_NUMBER.fetch_add(1, Ordering::Relaxed));
    let request = spool.join(format!("{name}.req"));
    let result = results.join(format!("{name}.res"));
    let _ = std::fs::remove_file(&result);
    std::fs::write(&request, encode_launch_steps(steps)).map_err(|e| failed(&format!("request file: {e}")))?;
    let outcome = (|| {
        ensure_launcher_task().map_err(|e| failed(&e))?;
        if run_quiet("schtasks", &["/run", "/tn", LAUNCHER_TASK]).is_none() { return Err(failed("the launcher task did not start")); }
        let deadline = Instant::now() + LAUNCH_TIMEOUT;
        loop {
            if let Ok(text) = std::fs::read_to_string(&result) {
                if text.ends_with('\n') { return parse_outcome(&text); }
            }
            if Instant::now() > deadline {
                return Err((status::FAILED, "Windows did not finish opening it. It may be showing a question about the file (for example a security warning for a program kept in a shared folder); look at the virtual machine.".to_string()));
            }
            std::thread::sleep(Duration::from_millis(100));
        }
    })();
    let _ = std::fs::remove_file(&request);
    let _ = std::fs::remove_file(&result);
    outcome
}

fn parse_outcome(text: &str) -> Result<(), (u32, String)> {
    let line = text.lines().next().unwrap_or("");
    if line == "ok" { return Ok(()); }
    let mut fields = line.splitn(3, '\t');
    let (_, code, message) = (fields.next(), fields.next(), fields.next());
    Err((code.and_then(|c| c.parse().ok()).unwrap_or(status::FAILED), message.unwrap_or("The program could not be started.").to_string()))
}

/// The task that starts the launcher with the user's normal rights. Made again whenever this program
/// file has moved (an update keeps the path, so normally once).
fn ensure_launcher_task() -> Result<(), String> {
    static READY: Mutex<bool> = Mutex::new(false);
    let mut ready = READY.lock().unwrap();
    if *ready { return Ok(()); }
    let exe = std::env::current_exe().map_err(|e| e.to_string())?;
    let escape = |text: &str| text.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;");
    // Run for whoever is signed in, with normal rights, as often at once as asked: a launcher that is
    // held up (Windows asking the user about a file) must not hold up the next request.
    let definition = format!(r#"<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>Tandem guest tools: starts programs the Mac asks for, with the user's normal rights.</Description></RegistrationInfo>
  <Principals><Principal id="Author"><GroupId>S-1-5-32-545</GroupId><RunLevel>LeastPrivilege</RunLevel></Principal></Principals>
  <Settings>
    <MultipleInstancesPolicy>Parallel</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <ExecutionTimeLimit>PT1H</ExecutionTimeLimit>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
  </Settings>
  <Actions Context="Author"><Exec><Command>{}</Command><Arguments>--run-requests</Arguments></Exec></Actions>
</Task>
"#, escape(&exe.display().to_string())).replace('\n', "\r\n");
    // Task Scheduler reads UTF-16 with a byte-order mark.
    let mut bytes: Vec<u8> = vec![0xFF, 0xFE];
    for unit in definition.encode_utf16() { bytes.extend_from_slice(&unit.to_le_bytes()); }
    let file = spool_dir().ok_or("no spool folder")?.join("launcher-task.xml");
    std::fs::write(&file, bytes).map_err(|e| format!("task definition: {e}"))?;
    let made = run_quiet("schtasks", &["/create", "/tn", LAUNCHER_TASK, "/xml", &file.display().to_string(), "/f"]);
    let _ = std::fs::remove_file(&file);
    made.ok_or_else(|| "the launcher task could not be made".to_string())?;
    *ready = true;
    Ok(())
}

/// Carries the steps out in this process.
fn perform(steps: &[LaunchStep]) -> Result<(), (u32, String)> {
    for step in steps {
        match step {
            LaunchStep::Check(path) => {
                let deadline = Instant::now() + REACH_TIMEOUT;
                while std::fs::metadata(path).is_err() {
                    if Instant::now() > deadline {
                        return Err((status::UNREACHABLE, format!("Windows cannot reach {path}. The shared Mac folder may not be connected.")));
                    }
                    std::thread::sleep(Duration::from_millis(500));
                }
            }
            LaunchStep::Open { target, parameters } => {
                let (verb, file, arguments) = (to_wide("open"), to_wide(target), to_wide(parameters));
                let arguments_pointer = if parameters.is_empty() { std::ptr::null() } else { arguments.as_ptr() };
                let code = unsafe { ShellExecuteW(std::ptr::null_mut(), verb.as_ptr(), file.as_ptr(), arguments_pointer, std::ptr::null(), 1) } as isize;
                if code <= 32 {
                    let why = match code {
                        2 | 3 => "the program was not found",
                        5 => "access was denied",
                        8 => "Windows is out of memory",
                        26..=31 => "no program is set up to open this kind of file",
                        _ => "Windows refused",
                    };
                    return Err((status::FAILED, format!("Windows could not open it: {why} (code {code}).")));
                }
            }
        }
    }
    Ok(())
}

/// `tandem-agent.exe --run-requests`: started by the launcher task with the user's normal rights.
/// Carries out every request in the spool that has no result yet, and leaves a result for each.
pub fn run_requests() {
    let Some(spool) = spool_dir() else { return };
    let results = results_dir();
    let _ = std::fs::create_dir_all(&results);
    let Ok(entries) = std::fs::read_dir(&spool) else { return };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().map(|e| e != "req").unwrap_or(true) { continue; }
        let Some(name) = path.file_stem().and_then(|n| n.to_str()) else { continue };
        let result = results.join(format!("{name}.res"));
        if result.exists() { continue; }
        // Several launchers may run at once; the one that makes this file carries the request out.
        let claim = results.join(format!("{name}.claim"));
        if std::fs::OpenOptions::new().write(true).create_new(true).open(&claim).is_err() { continue; }
        // A request nobody collected (the agent went away) is not carried out late.
        let fresh = entry.metadata().and_then(|m| m.modified()).ok()
            .and_then(|t| t.elapsed().ok()).map(|age| age < Duration::from_secs(60)).unwrap_or(false);
        if !fresh { continue; }
        let Ok(text) = std::fs::read_to_string(&path) else { continue };
        let line = match perform(&parse_launch_steps(&text)) {
            Ok(()) => "ok\n".to_string(),
            Err((code, message)) => format!("error\t{code}\t{}\n", message.replace(['\n', '\r', '\t'], " ")),
        };
        let _ = std::fs::write(&result, line);
        let _ = std::fs::remove_file(&claim);
    }
    // Claims left by a launcher that was ended half-way are of no use to anyone after an hour.
    if let Ok(entries) = std::fs::read_dir(&results) {
        for entry in entries.flatten() {
            let old = entry.metadata().and_then(|m| m.modified()).ok().and_then(|t| t.elapsed().ok())
                .map(|age| age > Duration::from_secs(3600)).unwrap_or(false);
            if old { let _ = std::fs::remove_file(entry.path()); }
        }
    }
}
