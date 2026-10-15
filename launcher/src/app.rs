//! The launcher window.

use crate::tasks::{self, Event, Paths, Runner, Settings};
use eframe::egui::{self, Color32, RichText};
use std::collections::VecDeque;
use std::path::PathBuf;
use std::sync::mpsc::{Receiver, channel};
use std::time::{Duration, Instant, SystemTime};

const ERROR: Color32 = Color32::from_rgb(230, 110, 90);
const GOOD: Color32 = Color32::from_rgb(120, 200, 120);
const LOG_LINES: usize = 4000;

#[derive(PartialEq, Clone, Copy)]
enum Task {
    Build,
    Steam,
}

pub struct LauncherApp {
    paths: Paths,
    settings: Settings,
    discs: Vec<PathBuf>,
    free: Option<u64>,
    runner: Runner,
    rx: Receiver<Event>,
    running: Option<Task>,
    started: Instant,
    step: String,
    progress: Option<f32>,
    log: VecDeque<String>,
    result: Option<Result<String, String>>,
    show_log: bool,
    error: Option<String>,
}

impl LauncherApp {
    pub fn new(_ctx: egui::Context) -> Self {
        let paths = Paths::new();
        let mut settings = Settings::load(&paths);
        let discs = tasks::scan_discs();
        // The disc used last time, or the first Saints Row disc found.
        if !PathBuf::from(&settings.iso).is_file() {
            settings.iso = discs.first().map(|p| p.to_string_lossy().into_owned()).unwrap_or_default();
        }
        let (tx, rx) = channel();
        let free = tasks::free_space(&paths.data);
        Self {
            paths,
            settings,
            discs,
            free,
            runner: Runner::new(tx),
            rx,
            running: None,
            started: Instant::now(),
            step: String::new(),
            progress: None,
            log: VecDeque::new(),
            result: None,
            show_log: false,
            error: None,
        }
    }

    fn iso(&self) -> Option<PathBuf> {
        let text = self.settings.iso.trim().trim_matches('"');
        (!text.is_empty()).then(|| PathBuf::from(text))
    }

    fn start(&mut self, task: Task) {
        let iso = self.iso();
        if task == Task::Build {
            match &iso {
                Some(p) if !p.is_file() => {
                    self.error = Some(format!("{} is not a file.", p.display()));
                    return;
                }
                None if !self.paths.game_files() => {
                    self.error = Some("Choose your Saints Row disc image first.".into());
                    return;
                }
                _ => {}
            }
        }
        self.settings.save(&self.paths);
        self.error = None;
        self.result = None;
        self.log.clear();
        self.step = match task {
            Task::Build => "Getting the latest scripts and patches".into(),
            Task::Steam => "Adding Saints Reborn to Steam".into(),
        };
        self.progress = None;
        self.running = Some(task);
        self.started = Instant::now();
        let paths = self.paths.clone();
        let add_to_steam = self.settings.add_to_steam;
        let log = paths.log();
        match task {
            Task::Build => self.runner.spawn(log, move |r| tasks::build(r, &paths, iso, add_to_steam)),
            Task::Steam => self.runner.spawn(log, move |r| tasks::add_to_steam(r, &paths)),
        }
    }

    /// Takes in what the running task printed.
    fn pump(&mut self) {
        while let Ok(event) = self.rx.try_recv() {
            match event {
                Event::Line(line) => {
                    if let Some(step) = line.strip_prefix("==> ") {
                        self.step = step.to_string();
                        self.progress = None;
                    } else if let Some(p) = ninja_progress(&line) {
                        self.progress = Some(p);
                    }
                    self.log.push_back(line);
                    while self.log.len() > LOG_LINES {
                        self.log.pop_front();
                    }
                }
                Event::Finished(result) => {
                    self.running = None;
                    self.progress = None;
                    if matches!(&result, Err(e) if e != "Cancelled") {
                        self.show_log = true;
                    }
                    self.result = Some(result);
                    self.free = tasks::free_space(&self.paths.data);
                }
            }
        }
    }

    fn game_panel(&mut self, ui: &mut egui::Ui) {
        egui::Frame::group(ui.style()).inner_margin(12.0).show(ui, |ui| {
            ui.set_width(ui.available_width());
            if self.paths.built() {
                let when = std::fs::metadata(self.paths.game())
                    .and_then(|m| m.modified())
                    .map(local_time)
                    .unwrap_or_default();
                ui.label(RichText::new(format!("✔ Ready to play (built {when})")).color(GOOD).strong());
                ui.label(
                    RichText::new(
                        "Start it from Steam (\"Saints Reborn\" in the library) so the handheld's controls \
                         reach it. Update gets the latest fixes and rebuilds only what changed.",
                    )
                    .weak(),
                );
            } else {
                ui.label(RichText::new("○ Not built yet").strong());
                ui.label(
                    RichText::new(
                        "The first build can take an hour or more on a handheld and needs about 40 GB free. \
                         Keep it plugged in.",
                    )
                    .weak(),
                );
            }
        });
    }

    fn disc_picker(&mut self, ui: &mut egui::Ui) {
        ui.label(if self.paths.game_files() {
            "Your Saints Row (Xbox 360) disc image (optional: the game files are already extracted)"
        } else {
            "Your Saints Row (Xbox 360) disc image"
        });
        ui.horizontal(|ui| {
            let width = ui.available_width() - 100.0;
            ui.add(
                egui::TextEdit::singleline(&mut self.settings.iso)
                    .hint_text("Saints Row .iso file")
                    .desired_width(width),
            );
            if ui.button("Browse...").clicked() {
                let mut dialog = rfd::FileDialog::new()
                    .set_title("Select your Saints Row disc image")
                    .add_filter("Disc image", &["iso", "ISO"]);
                if let Some(dir) = self.iso().and_then(|p| p.parent().map(PathBuf::from)).filter(|d| d.is_dir()) {
                    dialog = dialog.set_directory(dir);
                }
                if let Some(p) = dialog.pick_file() {
                    self.settings.iso = p.to_string_lossy().into_owned();
                }
            }
        });
        let others: Vec<String> = self
            .discs
            .iter()
            .map(|p| p.to_string_lossy().into_owned())
            .filter(|p| *p != self.settings.iso)
            .collect();
        if !others.is_empty() {
            ui.horizontal_wrapped(|ui| {
                ui.label(RichText::new("Found:").weak());
                for p in others.iter().take(4) {
                    let name = PathBuf::from(p).file_name().unwrap_or_default().to_string_lossy().into_owned();
                    if ui.small_button(name).on_hover_text(p).clicked() {
                        self.settings.iso = p.clone();
                    }
                }
            });
        }
    }

    fn buttons(&mut self, ui: &mut egui::Ui) {
        let built = self.paths.built();
        ui.horizontal(|ui| {
            let big = |text: &str| egui::Button::new(RichText::new(text).strong().size(16.0)).min_size([130.0, 36.0].into());
            if self.running.is_some() {
                if ui.add(big("Cancel")).clicked() {
                    self.runner.stop();
                    self.step = "Cancelling...".into();
                }
            } else {
                if ui
                    .add(big(if built { "Update" } else { "Build" }))
                    .on_hover_text("Gets the latest scripts and patches, then builds what changed")
                    .clicked()
                {
                    self.start(Task::Build);
                }
                if ui
                    .add_enabled(built, big("Play"))
                    .on_hover_text("Starts the game here; from Steam the handheld's controls work")
                    .clicked()
                {
                    if let Err(e) = tasks::play(&self.paths) {
                        self.error = Some(e);
                    }
                }
                if ui
                    .add_enabled(built, big("Add to Steam"))
                    .on_hover_text("Adds the game to the Steam library with its artwork (Steam restarts)")
                    .clicked()
                {
                    self.start(Task::Steam);
                }
            }
            ui.toggle_value(&mut self.show_log, "Details");
            if ui.small_button("Project page").clicked() {
                tasks::open(tasks::PROJECT_PAGE);
            }
        });
    }

    fn status(&mut self, ui: &mut egui::Ui) {
        if self.running.is_some() {
            ui.horizontal_wrapped(|ui| {
                ui.label(RichText::new(&self.step).strong());
                ui.label(RichText::new(elapsed(self.started.elapsed())).weak());
            });
            let bar = match self.progress {
                Some(p) => egui::ProgressBar::new(p).show_percentage(),
                None => egui::ProgressBar::new(0.0).animate(true),
            };
            ui.add(bar);
        }
        match &self.result {
            Some(Ok(done)) => {
                ui.label(RichText::new(done).color(GOOD).strong());
            }
            Some(Err(e)) if e == "Cancelled" => {
                ui.label("Cancelled. Press the button again to go on; finished steps are skipped.");
            }
            Some(Err(e)) => {
                ui.colored_label(ERROR, e);
                ui.label(
                    RichText::new(format!(
                        "Fix the problem and press the button again; finished steps are skipped. The full log is {}.",
                        self.paths.log().display()
                    ))
                    .weak(),
                );
            }
            None => {}
        }
        if let Some(e) = &self.error {
            ui.colored_label(ERROR, e);
        }
    }
}

impl eframe::App for LauncherApp {
    fn ui(&mut self, ui: &mut egui::Ui, _frame: &mut eframe::Frame) {
        self.pump();
        let ctx = ui.ctx().clone();
        if self.running.is_some() {
            ctx.request_repaint_after(Duration::from_millis(100));
        }
        egui::CentralPanel::default().show_inside(ui, |ui| {
            ui.add_space(6.0);
            ui.horizontal(|ui| {
                ui.heading(RichText::new("Saints Reborn").size(28.0).strong());
                ui.label(RichText::new("for ARM64 handhelds").weak());
            });
            ui.label(
                RichText::new(
                    "Builds Saints Row (Xbox 360) on this device from your own disc, then plays it or adds it \
                     to Steam. Nothing from the game is downloaded.",
                )
                .weak(),
            );
            ui.add_space(10.0);
            self.game_panel(ui);
            ui.add_space(10.0);
            ui.add_enabled_ui(self.running.is_none(), |ui| {
                self.disc_picker(ui);
                ui.add_space(6.0);
                if let Some(free) = self.free {
                    let text = format!(
                        "{} free in {}",
                        tasks::gigabytes(free),
                        self.paths.data.display()
                    );
                    if !self.paths.built() && free < tasks::BUILD_SPACE {
                        ui.colored_label(ERROR, format!("{text}: the first build needs about 40 GB."));
                    } else {
                        ui.label(RichText::new(text).weak());
                    }
                }
                ui.checkbox(&mut self.settings.add_to_steam, "Add to Steam with artwork when the build is done");
            });
            ui.add_space(10.0);
            self.buttons(ui);
            ui.add_space(8.0);
            self.status(ui);
            if self.show_log {
                ui.add_space(6.0);
                egui::ScrollArea::vertical().auto_shrink(false).stick_to_bottom(true).show(ui, |ui| {
                    for line in &self.log {
                        ui.label(RichText::new(line).monospace().size(11.0));
                    }
                });
            }
        });
    }
}

impl Drop for LauncherApp {
    fn drop(&mut self) {
        // Closing the window stops a build; the next one goes on from there.
        self.runner.stop();
    }
}

/// The share of a ninja build done, from its "[N/M] ..." lines.
fn ninja_progress(line: &str) -> Option<f32> {
    let rest = line.strip_prefix('[')?;
    let (counts, _) = rest.split_once(']')?;
    let (done, total) = counts.split_once('/')?;
    let (done, total): (f32, f32) = (done.trim().parse().ok()?, total.trim().parse().ok()?);
    (total > 0.0).then(|| (done / total).clamp(0.0, 1.0))
}

fn elapsed(d: Duration) -> String {
    let minutes = d.as_secs() / 60;
    match minutes {
        0 => "under a minute so far".into(),
        1..60 => format!("{minutes} min so far"),
        _ => format!("{} h {:02} min so far", minutes / 60, minutes % 60),
    }
}

fn local_time(t: SystemTime) -> String {
    let Ok(since) = t.duration_since(SystemTime::UNIX_EPOCH) else { return String::new() };
    let secs = since.as_secs() as libc::time_t;
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    if unsafe { libc::localtime_r(&secs, &mut tm) }.is_null() {
        return String::new();
    }
    format!("{:04}-{:02}-{:02} {:02}:{:02}", tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday, tm.tm_hour, tm.tm_min)
}

#[cfg(test)]
mod tests {
    use super::{elapsed, ninja_progress};
    use std::time::Duration;

    #[test]
    fn reads_ninja_progress() {
        assert_eq!(ninja_progress("[17/34] Building CXX object a.o"), Some(0.5));
        assert_eq!(ninja_progress("[0/0] Re-running CMake..."), None);
        assert_eq!(ninja_progress("==> Toolchain"), None);
        assert_eq!(ninja_progress("[warning] something"), None);
    }

    #[test]
    fn says_how_long() {
        assert_eq!(elapsed(Duration::from_secs(59)), "under a minute so far");
        assert_eq!(elapsed(Duration::from_secs(12 * 60 + 5)), "12 min so far");
        assert_eq!(elapsed(Duration::from_secs(65 * 60)), "1 h 05 min so far");
    }
}
