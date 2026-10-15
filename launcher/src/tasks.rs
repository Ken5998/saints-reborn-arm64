//! What the launcher does outside its window: where things are, the disc
//! images it finds, and the commands it runs (git, this repository's
//! scripts, the game), whose output comes back to the window line by line.

use std::fs;
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicI32, Ordering};
use std::sync::mpsc::Sender;
use std::sync::{Arc, Mutex};

/// This repository: the launcher builds with its scripts and patches, as a
/// git clone it keeps up to date in the data folder.
pub const REPOSITORY: &str = "https://github.com/Ken5998/saints-reborn-arm64";
pub const PROJECT_PAGE: &str = "https://github.com/Ken5998/saints-reborn-arm64";

/// Free space the first build needs: the build tools, the SDK, the game files
/// from the disc, the recompiled code and its objects.
pub const BUILD_SPACE: u64 = 40 << 30;

/// Everything lives in one folder, the one scripts/build.sh uses by default,
/// so a game built from the command line is found too.
#[derive(Clone)]
pub struct Paths {
    pub data: PathBuf,
}

impl Paths {
    pub fn new() -> Self {
        let share = std::env::var_os("XDG_DATA_HOME")
            .filter(|v| !v.is_empty())
            .map(PathBuf::from)
            .unwrap_or_else(|| home().join(".local/share"));
        Self { data: share.join("SaintsReborn-arm64") }
    }
    pub fn overlay(&self) -> PathBuf {
        self.data.join("overlay")
    }
    pub fn dist(&self) -> PathBuf {
        self.data.join("SaintsReborn/dist")
    }
    pub fn game(&self) -> PathBuf {
        self.dist().join("saintsrow")
    }
    pub fn game_files(&self) -> bool {
        self.dist().join("game/default.xex").is_file()
    }
    pub fn built(&self) -> bool {
        self.game().is_file()
    }
    pub fn log(&self) -> PathBuf {
        self.data.join("launcher.log")
    }
    fn settings(&self) -> PathBuf {
        self.data.join("launcher.conf")
    }
}

pub fn home() -> PathBuf {
    std::env::var_os("HOME").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("/"))
}

/// What the window remembers between runs.
pub struct Settings {
    pub iso: String,
    pub add_to_steam: bool,
}

impl Settings {
    pub fn load(paths: &Paths) -> Self {
        let mut s = Settings { iso: String::new(), add_to_steam: true };
        for line in fs::read_to_string(paths.settings()).unwrap_or_default().lines() {
            match line.split_once('=') {
                Some(("iso", v)) => s.iso = v.to_string(),
                Some(("add_to_steam", v)) => s.add_to_steam = v != "0",
                _ => {}
            }
        }
        s
    }
    pub fn save(&self, paths: &Paths) {
        let _ = fs::create_dir_all(&paths.data);
        let _ = fs::write(
            paths.settings(),
            format!("iso={}\nadd_to_steam={}\n", self.iso, if self.add_to_steam { 1 } else { 0 }),
        );
    }
}

/// Free bytes on the file system that holds `path` (or its closest parent).
pub fn free_space(path: &Path) -> Option<u64> {
    let mut p = path.to_path_buf();
    while !p.exists() {
        p = p.parent()?.to_path_buf();
    }
    let c = std::ffi::CString::new(p.as_os_str().as_encoded_bytes()).ok()?;
    let mut st: libc::statvfs = unsafe { std::mem::zeroed() };
    (unsafe { libc::statvfs(c.as_ptr(), &mut st) } == 0).then(|| st.f_bavail as u64 * st.f_frsize as u64)
}

pub fn gigabytes(bytes: u64) -> String {
    format!("{:.1} GB", bytes as f64 / (1u64 << 30) as f64)
}

/// Disc images in the usual places: the home folder, Downloads, ROM folders
/// and SD cards. Saints Row first, then the newest.
pub fn scan_discs() -> Vec<PathBuf> {
    let home = home();
    let mut roots: Vec<(PathBuf, u32)> = vec![(home.clone(), 1)];
    for sub in ["Downloads", "Desktop", "Documents", "Games", "ROMs", "roms", "Emulation"] {
        roots.push((home.join(sub), 3));
    }
    if let Ok(user) = std::env::var("USER") {
        if let Ok(cards) = fs::read_dir(Path::new("/run/media").join(user)) {
            roots.extend(cards.flatten().map(|c| (c.path(), 3)));
        }
    }
    let mut found: Vec<(PathBuf, std::time::SystemTime)> = Vec::new();
    fn walk(dir: &Path, depth: u32, found: &mut Vec<(PathBuf, std::time::SystemTime)>) {
        let Ok(entries) = fs::read_dir(dir) else { return };
        for e in entries.flatten() {
            let name = e.file_name().to_string_lossy().to_lowercase();
            if name.starts_with('.') {
                continue;
            }
            let Ok(kind) = e.file_type() else { continue };
            if kind.is_dir() && depth > 0 {
                walk(&e.path(), depth - 1, found);
            } else if kind.is_file() && name.ends_with(".iso") {
                if let Ok(m) = e.metadata() {
                    // A Saints Row disc is about 7 GB.
                    if m.len() > 1 << 30 {
                        found.push((e.path(), m.modified().unwrap_or(std::time::UNIX_EPOCH)));
                    }
                }
            }
        }
    }
    for (root, depth) in roots {
        walk(&root, depth, &mut found);
    }
    found.sort_by_key(|(p, t)| {
        let name = p.file_name().unwrap_or_default().to_string_lossy().to_lowercase();
        (!name.contains("saints"), std::cmp::Reverse(*t))
    });
    found.dedup_by(|a, b| a.0 == b.0);
    found.into_iter().map(|(p, _)| p).collect()
}

/// What a running task sends to the window.
pub enum Event {
    Line(String),
    Finished(Result<String, String>),
}

/// Runs one task at a time in the background and stops it on request.
pub struct Runner {
    pub tx: Sender<Event>,
    pub cancel: Arc<AtomicBool>,
    /// Process group of the command that runs now (0 = none).
    group: Arc<AtomicI32>,
    log: Arc<Mutex<Option<fs::File>>>,
}

impl Runner {
    pub fn new(tx: Sender<Event>) -> Self {
        Self {
            tx,
            cancel: Arc::new(AtomicBool::new(false)),
            group: Arc::new(AtomicI32::new(0)),
            log: Arc::new(Mutex::new(None)),
        }
    }

    pub fn stop(&self) {
        self.cancel.store(true, Ordering::Relaxed);
        let group = self.group.load(Ordering::Relaxed);
        if group > 0 {
            unsafe { libc::kill(-group, libc::SIGTERM) };
        }
    }

    fn clone_handle(&self) -> Runner {
        Runner { tx: self.tx.clone(), cancel: self.cancel.clone(), group: self.group.clone(), log: self.log.clone() }
    }

    fn line(&self, text: impl Into<String>) {
        let text = text.into();
        if let Some(f) = self.log.lock().unwrap().as_mut() {
            let _ = writeln!(f, "{text}");
        }
        let _ = self.tx.send(Event::Line(text));
    }

    /// Runs `work` on a new thread with a fresh log file; its result ends the task.
    pub fn spawn(&self, log: PathBuf, work: impl FnOnce(&Runner) -> Result<String, String> + Send + 'static) {
        self.cancel.store(false, Ordering::Relaxed);
        if let Some(parent) = log.parent() {
            let _ = fs::create_dir_all(parent);
        }
        *self.log.lock().unwrap() = fs::File::create(&log).ok();
        let r = self.clone_handle();
        std::thread::spawn(move || {
            let result = work(&r);
            if let Err(e) = &result {
                r.line(format!("ERROR: {e}"));
            }
            *r.log.lock().unwrap() = None;
            let _ = r.tx.send(Event::Finished(result));
        });
    }

    /// Runs a command in its own process group, passing on every line it
    /// prints; Err when it fails or the task was cancelled.
    pub fn run(&self, cmd: &mut Command) -> Result<(), String> {
        if self.cancel.load(Ordering::Relaxed) {
            return Err("Cancelled".into());
        }
        self.line(format!("$ {}", describe(cmd)));
        let mut child = cmd
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .process_group(0)
            .spawn()
            .map_err(|e| format!("could not start {}: {e}", cmd.get_program().to_string_lossy()))?;
        self.group.store(child.id() as i32, Ordering::Relaxed);
        let (done_tx, done_rx) = std::sync::mpsc::channel();
        let mut readers = 0;
        for stream in [child.stdout.take().map(|s| Box::new(s) as Box<dyn Read + Send>),
                       child.stderr.take().map(|s| Box::new(s) as Box<dyn Read + Send>)]
            .into_iter()
            .flatten()
        {
            let r = self.clone_handle();
            let done = done_tx.clone();
            std::thread::spawn(move || {
                forward_lines(BufReader::new(stream), &r);
                let _ = done.send(());
            });
            readers += 1;
        }
        let status = child.wait().map_err(|e| e.to_string());
        // The last lines, but not for long: a program the command started in
        // the background may keep its output open.
        let until = std::time::Instant::now() + std::time::Duration::from_secs(5);
        for _ in 0..readers {
            let left = until.saturating_duration_since(std::time::Instant::now());
            if done_rx.recv_timeout(left).is_err() {
                break;
            }
        }
        self.group.store(0, Ordering::Relaxed);
        if self.cancel.load(Ordering::Relaxed) {
            return Err("Cancelled".into());
        }
        match status? {
            s if s.success() => Ok(()),
            s => Err(format!("{} failed ({s})", cmd.get_program().to_string_lossy())),
        }
    }
}

/// Passes on each line a command prints. Progress lines end in \r (curl,
/// ninja on a terminal), so those end a line too.
fn forward_lines(reader: impl BufRead, r: &Runner) {
    let mut line = Vec::new();
    let flush = |line: &mut Vec<u8>| {
        if !line.is_empty() {
            r.line(String::from_utf8_lossy(line).into_owned());
            line.clear();
        }
    };
    for byte in reader.bytes() {
        match byte {
            Ok(b'\n' | b'\r') => flush(&mut line),
            Ok(b) => line.push(b),
            Err(_) => break,
        }
    }
    flush(&mut line);
}

fn describe(cmd: &Command) -> String {
    std::iter::once(cmd.get_program())
        .chain(cmd.get_args())
        .map(|a| a.to_string_lossy().into_owned())
        .collect::<Vec<_>>()
        .join(" ")
}

/// Clones this repository into the data folder, or brings the clone up to
/// date with main. Offline, an existing clone is used as it is.
pub fn update_overlay(r: &Runner, paths: &Paths) -> Result<(), String> {
    let overlay = paths.overlay();
    if overlay.join(".git").is_dir() {
        let fetched = r.run(Command::new("git").arg("-C").arg(&overlay).args(["fetch", "--depth", "50", "origin", "main"]));
        match fetched {
            Ok(()) => r.run(Command::new("git").arg("-C").arg(&overlay).args(["reset", "--hard", "-q", "FETCH_HEAD"]))?,
            Err(e) if e == "Cancelled" => return Err(e),
            Err(_) => r.line("Could not reach GitHub: building with the scripts already here."),
        }
    } else {
        fs::create_dir_all(&paths.data).map_err(|e| e.to_string())?;
        let _ = fs::remove_dir_all(&overlay);
        r.run(Command::new("git").args(["clone", "-q", "--depth", "50", REPOSITORY]).arg(&overlay))?;
    }
    let head = Command::new("git").arg("-C").arg(&overlay).args(["log", "-1", "--format=%h %s"]).output();
    if let Ok(out) = head {
        r.line(format!("Scripts and patches: {}", String::from_utf8_lossy(&out.stdout).trim()));
    }
    Ok(())
}

/// The whole build: scripts/build.sh with the disc image, or with "-" to
/// reuse the game files already extracted.
pub fn build(r: &Runner, paths: &Paths, iso: Option<PathBuf>, add_to_steam: bool) -> Result<String, String> {
    update_overlay(r, paths)?;
    let disc = iso.map(|p| p.into_os_string()).unwrap_or_else(|| "-".into());
    r.run(
        Command::new("bash")
            .arg(paths.overlay().join("scripts/build.sh"))
            .arg(disc)
            .arg(&paths.data)
            .env("SR_ADD_TO_STEAM", if add_to_steam { "1" } else { "0" }),
    )?;
    Ok(if add_to_steam {
        "Saints Reborn is ready. Start it from Steam for the handheld's controls.".into()
    } else {
        "Saints Reborn is ready.".into()
    })
}

pub fn add_to_steam(r: &Runner, paths: &Paths) -> Result<String, String> {
    if !paths.overlay().join("scripts/add-to-steam.sh").is_file() {
        update_overlay(r, paths)?;
    }
    r.run(Command::new("bash").arg(paths.overlay().join("scripts/add-to-steam.sh")).arg(&paths.data))?;
    Ok("Saints Reborn is in your Steam library.".into())
}

/// Starts the game on its own, so it keeps running when the launcher closes.
pub fn play(paths: &Paths) -> Result<(), String> {
    Command::new(paths.game())
        .current_dir(paths.dist())
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .process_group(0)
        .spawn()
        .map(|_| ())
        .map_err(|e| format!("Could not start the game: {e}"))
}

pub fn open(url: &str) {
    let _ = Command::new("xdg-open").arg(url).stdout(Stdio::null()).stderr(Stdio::null()).spawn();
}
