// minit - PID 1 for minibash-linux (v0.2)
//
// A small, dependency-free init written in Rust. It does the things a Bash
// PID 1 cannot do safely:
//   * reaps every child (including re-parented orphans) via waitpid(-1)
//   * handles signals for a clean shutdown (sync + unmount + reboot(2))
//   * supervises services declared in the bdb database and restarts crashes
//
// The database (bdb) stays the single source of truth. `bashsvc` is a thin
// client: it writes the desired state into bdb and pokes us with SIGUSR1.

use std::collections::HashMap;
use std::ffi::CString;
use std::fs::{self, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::os::raw::{c_char, c_int, c_ulong, c_void};
use std::os::unix::process::CommandExt;
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicU8, Ordering};
use std::sync::{Mutex, MutexGuard};
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

const BDB_PATH: &str = "/var/bdb";
const SERVICE_PATH: &str = "/bin:/usr/bin:/sbin:/usr/sbin:/services";
const LOG_DIR: &str = "/var/log/minibash";
const HOSTNAME: &str = "minibash";

// ----------------------------------------------------------------------------
// libc bindings (no external crates: declare exactly what we use)
// ----------------------------------------------------------------------------
mod sys {
    use super::*;

    // reboot(2) magic command numbers (linux/reboot.h)
    pub const RB_AUTOBOOT: c_int = 0x0123_4567; // restart
    pub const RB_POWER_OFF: c_int = 0x4321_fedc; // power off

    // signals (linux/x86)
    pub const SIGKILL: c_int = 9;
    pub const SIGUSR1: c_int = 10;
    pub const SIGUSR2: c_int = 12;
    pub const SIGTERM: c_int = 15;
    pub const SIGINT: c_int = 2;

    pub type SigHandler = extern "C" fn(c_int);

    extern "C" {
        pub fn mount(
            source: *const c_char,
            target: *const c_char,
            fstype: *const c_char,
            flags: c_ulong,
            data: *const c_void,
        ) -> c_int;
        pub fn umount2(target: *const c_char, flags: c_int) -> c_int;
        pub fn sethostname(name: *const c_char, len: usize) -> c_int;
        pub fn reboot(howto: c_int) -> c_int;
        pub fn sync();
        pub fn kill(pid: c_int, sig: c_int) -> c_int;
        pub fn waitpid(pid: c_int, status: *mut c_int, options: c_int) -> c_int;
        pub fn setsid() -> c_int;
        pub fn ioctl(fd: c_int, request: c_ulong, ...) -> c_int;
        pub fn signal(signum: c_int, handler: SigHandler) -> *const c_void;
    }
}

// ----------------------------------------------------------------------------
// Global state
// ----------------------------------------------------------------------------

// 0 = running, 1 = power off requested, 2 = reboot requested
static SHUTDOWN: AtomicU8 = AtomicU8::new(0);
// poked by SIGUSR1 to force an immediate reconcile
static RELOAD: AtomicBool = AtomicBool::new(false);

struct Unit {
    name: String,
    pid: c_int,
    restart: bool,
}

// Small linear store (a handful of services) so the whole thing can live in a
// `const` Mutex::new() static and stay compatible with the older rustc on the
// Debian builder (no OnceLock / no HashMap-in-static).
struct Supervisor {
    units: Vec<Unit>,
    console_pid: c_int,
}

impl Supervisor {
    const fn new() -> Self {
        Supervisor {
            units: Vec::new(),
            console_pid: 0,
        }
    }
    fn has(&self, name: &str) -> bool {
        self.units.iter().any(|u| u.name == name)
    }
    fn pid_of(&self, name: &str) -> Option<c_int> {
        self.units.iter().find(|u| u.name == name).map(|u| u.pid)
    }
    fn insert(&mut self, unit: Unit) {
        self.units.retain(|u| u.name != unit.name);
        self.units.push(unit);
    }
    // remove the unit owning `pid`, returning (name, restart)
    fn take_by_pid(&mut self, pid: c_int) -> Option<(String, bool)> {
        let i = self.units.iter().position(|u| u.pid == pid)?;
        let u = self.units.remove(i);
        Some((u.name, u.restart))
    }
    fn all_pids(&self) -> Vec<c_int> {
        self.units.iter().map(|u| u.pid).collect()
    }
}

static SUP: Mutex<Supervisor> = Mutex::new(Supervisor::new());

// Lock the supervisor, recovering the data even if a thread panicked while
// holding it. For PID 1 we never want a poisoned mutex to cascade into more
// panics and take the whole init down.
fn sup_lock() -> MutexGuard<'static, Supervisor> {
    SUP.lock().unwrap_or_else(|e| e.into_inner())
}

#[derive(Clone)]
struct Service {
    name: String,
    command: String,
    restart: bool,
    desired: String,
}

// ----------------------------------------------------------------------------
// Logging
// ----------------------------------------------------------------------------
fn log(msg: &str) {
    // stdout is the console; keep it simple and unbuffered enough.
    println!("[minit] {msg}");
}

// ----------------------------------------------------------------------------
// Early boot
// ----------------------------------------------------------------------------
fn cstr(s: &str) -> CString {
    CString::new(s).unwrap_or_else(|_| CString::new("").unwrap())
}

fn do_mount(source: &str, target: &str, fstype: &str) {
    let _ = fs::create_dir_all(target);
    let s = cstr(source);
    let t = cstr(target);
    let f = cstr(fstype);
    unsafe {
        sys::mount(s.as_ptr(), t.as_ptr(), f.as_ptr(), 0, std::ptr::null());
    }
}

fn mount_all() {
    for d in [
        "/proc",
        "/sys",
        "/dev",
        "/run",
        "/tmp",
        "/var/log",
        BDB_PATH,
        LOG_DIR,
        "/run/minibash",
    ] {
        let _ = fs::create_dir_all(d);
    }
    do_mount("proc", "/proc", "proc");
    do_mount("sysfs", "/sys", "sysfs");
    do_mount("devtmpfs", "/dev", "devtmpfs");
    // devpts is required for pseudo-terminals (foot/any terminal emulator):
    // without it PTY allocation fails with "failed to open PTY".
    do_mount("devpts", "/dev/pts", "devpts");
    // /dev/shm (POSIX shared memory) is required by Wayland/Mesa/foot for their
    // shared buffers and keymap fds; without it sway fails with
    // "error marshalling arg for keymap: dup failed". Needs 1777 so the
    // non-root desktop user can create shm files.
    do_mount("tmpfs", "/dev/shm", "tmpfs");
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = fs::set_permissions("/dev/shm", fs::Permissions::from_mode(0o1777));
    }
    do_mount("tmpfs", "/run", "tmpfs");
    do_mount("tmpfs", "/tmp", "tmpfs");
    // recreate runtime dirs that may now live on the fresh tmpfs mounts
    let _ = fs::create_dir_all("/run/minibash");
    let _ = fs::create_dir_all(LOG_DIR);
}

fn set_hostname() {
    let h = cstr(HOSTNAME);
    unsafe {
        sys::sethostname(h.as_ptr(), HOSTNAME.len());
    }
    let _ = fs::write("/proc/sys/kernel/hostname", HOSTNAME);
}

fn run_quiet(args: &[&str]) -> bool {
    Command::new(args[0])
        .args(&args[1..])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

fn network_up() {
    // loopback is always useful
    if !run_quiet(&["/bin/busybox", "ip", "link", "set", "lo", "up"]) {
        run_quiet(&["/bin/busybox", "ifconfig", "lo", "127.0.0.1", "up"]);
    }
    // Best-effort: QEMU user-mode networking hands out 10.0.2.15 / gw 10.0.2.2.
    // If there is no NIC (no eth0) these simply fail and we carry on.
    if run_quiet(&["/bin/busybox", "ip", "link", "set", "eth0", "up"]) {
        run_quiet(&["/bin/busybox", "ip", "addr", "add", "10.0.2.15/24", "dev", "eth0"]);
        run_quiet(&["/bin/busybox", "ip", "route", "add", "default", "via", "10.0.2.2"]);
    } else {
        run_quiet(&["/bin/busybox", "ifconfig", "eth0", "10.0.2.15", "netmask", "255.255.255.0", "up"]);
        run_quiet(&["/bin/busybox", "route", "add", "default", "gw", "10.0.2.2"]);
    }
}

fn apply_keymap() {
    let keymap = match kernel_arg("minibash.keymap") {
        Some(value) => value,
        None => return,
    };
    let keymap = keymap.trim();
    if keymap.is_empty() || keymap == "us" || keymap == "qwerty" {
        log(&format!("keyboard keymap: {keymap}"));
        return;
    }

    let map_path = match keymap {
        "fr" | "azerty" | "fr-azerty" => "/etc/keymaps/fr.bmap",
        other => {
            log(&format!("unknown keyboard keymap '{other}', keeping kernel default"));
            return;
        }
    };

    match fs::File::open(map_path) {
        Ok(file) => {
            let status = Command::new("/bin/loadkmap")
                .stdin(Stdio::from(file))
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status();
            if status.map(|s| s.success()).unwrap_or(false) {
                log(&format!("keyboard keymap loaded: {keymap}"));
            } else {
                log(&format!("keyboard keymap failed: {keymap}"));
            }
        }
        Err(e) => log(&format!("keyboard keymap missing {map_path}: {e}")),
    }
}

fn load_storage_modules() {
    let module_base = match fs::read_dir("/lib/modules") {
        Ok(mut entries) => match entries.find_map(|e| e.ok()) {
            Some(entry) => entry.path(),
            None => return,
        },
        Err(_) => return,
    };
    let base = module_base.to_string_lossy().to_string();
    for module in [
        "scsi_mod",
        "sd_mod",
        "usbcore",
        "xhci-hcd",
        "xhci-pci",
        "usb-storage",
        "uas",
        "simpledrm",
        "drm",
        "drm_kms_helper",
        "virtio_gpu",
        "i915",
        "amdgpu",
        "nouveau",
        "usbhid",
        "hid_generic",
    ] {
        let _ = run_quiet(&["/bin/modprobe", module]);
    }
    for rel in [
        "kernel/drivers/scsi/scsi_mod.ko",
        "kernel/drivers/scsi/sd_mod.ko",
        "kernel/drivers/usb/core/usbcore.ko",
        "kernel/drivers/usb/host/xhci-hcd.ko",
        "kernel/drivers/usb/host/xhci-pci.ko",
        "kernel/drivers/usb/storage/usb-storage.ko",
        "kernel/drivers/usb/storage/uas.ko",
    ] {
        let path = format!("{base}/{rel}");
        if fs::metadata(&path).is_ok() {
            let _ = run_quiet(&["/bin/insmod", &path]);
        }
    }
    thread::sleep(Duration::from_millis(800));
}

// first of the candidate paths that exists on disk (handles /bin vs /usr/bin)
fn first_exe(candidates: &[&str]) -> String {
    for c in candidates {
        if fs::metadata(c).is_ok() {
            return (*c).to_string();
        }
    }
    candidates[0].to_string()
}

fn kernel_arg(name: &str) -> Option<String> {
    let mut cmdline = String::new();
    fs::File::open("/proc/cmdline").ok()?.read_to_string(&mut cmdline).ok()?;
    for tok in cmdline.split_whitespace() {
        if let Some(v) = tok.strip_prefix(&format!("{name}=")) {
            return Some(v.to_string());
        }
    }
    None
}

fn console_tty() -> String {
    if let Some(tty) = kernel_arg("minibash.tty") {
        return format!("/dev/{}", tty.trim_start_matches("/dev/"));
    }

    let mut cmdline = String::new();
    if fs::File::open("/proc/cmdline")
        .and_then(|mut f| f.read_to_string(&mut cmdline))
        .is_ok()
    {
        let mut last_console = "";
        for tok in cmdline.split_whitespace() {
            if let Some(v) = tok.strip_prefix("console=") {
                last_console = v.split(',').next().unwrap_or(v);
            }
        }
        if last_console.starts_with("ttyS") {
            return format!("/dev/{last_console}");
        }
    }

    "/dev/tty1".to_string()
}

fn desktop_autostart_disabled() -> bool {
    matches!(
        kernel_arg("minibash.desktop").as_deref(),
        Some("off") | Some("debug") | Some("shell")
    )
}

fn try_mount(dev: &str, target: &str, fstype: &str) -> bool {
    let d = cstr(dev);
    let t = cstr(target);
    let f = cstr(fstype);
    0 == unsafe { sys::mount(d.as_ptr(), t.as_ptr(), f.as_ptr(), 0, std::ptr::null()) }
}

// Mount a persistent disk over /var/bdb if one is attached (QEMU virtio-blk
// shows up as /dev/vda). Best-effort: with no disk, or if it cannot be mounted,
// we fall back to the volatile ramdisk. A blank disk is formatted ext2 first.
fn mount_persistent() -> bool {
    let dev = "/dev/vda";
    if fs::metadata(dev).is_err() {
        return false;
    }
    let _ = fs::create_dir_all(BDB_PATH);
    if try_mount(dev, BDB_PATH, "ext4") || try_mount(dev, BDB_PATH, "ext2") {
        log("mounted persistent disk /dev/vda at /var/bdb");
        return true;
    }
    log("formatting fresh disk /dev/vda (ext2)");
    run_quiet(&["/bin/busybox", "mke2fs", "-q", "-F", dev]);
    if try_mount(dev, BDB_PATH, "ext4") || try_mount(dev, BDB_PATH, "ext2") {
        log("mounted formatted disk /dev/vda at /var/bdb");
        return true;
    }
    log("could not mount /dev/vda; database will be volatile");
    false
}

fn seed_db(persistent: bool) {
    let have = fs::metadata(format!("{BDB_PATH}/tables/services")).is_ok();
    if persistent && have {
        log("using existing database on persistent disk");
        return;
    }
    if !persistent {
        // A reused kernel may carry a stale embedded /var/bdb on the ramdisk;
        // with no real disk to shadow it, force a clean seed every boot.
        let _ = fs::remove_dir_all(format!("{BDB_PATH}/tables"));
    }
    log("seeding service database");
    let _ = fs::create_dir_all(BDB_PATH);
    let cp = first_exe(&["/bin/cp", "/usr/bin/cp"]);
    run_quiet(&[&cp, "-R", "/etc/minibash/bdb/.", BDB_PATH]);
}

// ----------------------------------------------------------------------------
// bdb access, in-process
// ----------------------------------------------------------------------------
// minit reads and writes the bdb tables directly in Rust. The alternative -
// forking /bin/bdb for every status update and log line - spawns `base64` once
// per field and serialises everything on bdb's global lock; under TCG emulation
// that storm of processes stalls the supervisor. Doing it in-process keeps the
// lock held for microseconds and never blocks a worker thread on a fork.
//
// We honour bdb's own lock convention (mkdir of $BDB_PATH/.lock) so the `bdb`
// CLI used by bashsvc and the operator stays mutually exclusive with us.

fn b64encode(s: &str) -> String {
    const T: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let b = s.as_bytes();
    let mut out = String::new();
    let mut i = 0;
    while i + 3 <= b.len() {
        let n = ((b[i] as u32) << 16) | ((b[i + 1] as u32) << 8) | (b[i + 2] as u32);
        out.push(T[((n >> 18) & 63) as usize] as char);
        out.push(T[((n >> 12) & 63) as usize] as char);
        out.push(T[((n >> 6) & 63) as usize] as char);
        out.push(T[(n & 63) as usize] as char);
        i += 3;
    }
    match b.len() - i {
        1 => {
            let n = (b[i] as u32) << 16;
            out.push(T[((n >> 18) & 63) as usize] as char);
            out.push(T[((n >> 12) & 63) as usize] as char);
            out.push_str("==");
        }
        2 => {
            let n = ((b[i] as u32) << 16) | ((b[i + 1] as u32) << 8);
            out.push(T[((n >> 18) & 63) as usize] as char);
            out.push(T[((n >> 12) & 63) as usize] as char);
            out.push(T[((n >> 6) & 63) as usize] as char);
            out.push('=');
        }
        _ => {}
    }
    out
}

fn db_lock() -> bool {
    let lock = format!("{BDB_PATH}/.lock");
    for _ in 0..50 {
        if fs::create_dir(&lock).is_ok() {
            return true;
        }
        thread::sleep(Duration::from_millis(100));
    }
    false
}

fn db_unlock() {
    let _ = fs::remove_dir(format!("{BDB_PATH}/.lock"));
}

// Update specific columns (by index) of the services row whose name matches.
// Columns: 0 name 1 command 2 autostart 3 restart 4 desired 5 status 6 pid 7 desc
fn set_service_fields(name: &str, updates: &[(usize, &str)]) {
    if !db_lock() {
        return;
    }
    let path = format!("{BDB_PATH}/tables/services/data.tsv");
    if let Ok(raw) = fs::read_to_string(&path) {
        let want = b64encode(name);
        let mut out = String::new();
        let mut changed = false;
        for line in raw.lines() {
            let mut fields: Vec<String> = line.split('\t').map(|s| s.to_string()).collect();
            if fields.len() >= 8 && fields[0] == want {
                for (idx, val) in updates {
                    if *idx < fields.len() {
                        fields[*idx] = b64encode(val);
                    }
                }
                changed = true;
            }
            out.push_str(&fields.join("\t"));
            out.push('\n');
        }
        if changed {
            let tmp = format!("{BDB_PATH}/tables/services/.data.tmp");
            if fs::write(&tmp, out).is_ok() {
                let _ = fs::rename(&tmp, &path);
            }
        }
    }
    db_unlock();
}

fn append_log(service: &str, line: &str) {
    if !db_lock() {
        return;
    }
    let path = format!("{BDB_PATH}/tables/logs/data.tsv");
    let row = format!(
        "{}\t{}\t{}\n",
        b64encode(&now_ts()),
        b64encode(service),
        b64encode(line)
    );
    if let Ok(mut f) = OpenOptions::new().create(true).append(true).open(&path) {
        let _ = f.write_all(row.as_bytes());
    }
    db_unlock();
}

// Minimal base64 decoder (no crates), so the hot reconcile loop can read the
// services table directly.
fn b64decode(input: &str) -> Option<String> {
    let mut out: Vec<u8> = Vec::new();
    let mut quartet = [0u8; 4];
    let mut n = 0;
    for b in input.bytes() {
        let v = match b {
            b'A'..=b'Z' => b - b'A',
            b'a'..=b'z' => b - b'a' + 26,
            b'0'..=b'9' => b - b'0' + 52,
            b'+' => 62,
            b'/' => 63,
            b'=' => 64,
            b'\n' | b'\r' | b' ' => continue,
            _ => return None,
        };
        quartet[n] = v;
        n += 1;
        if n == 4 {
            out.push((quartet[0] << 2) | (quartet[1] >> 4));
            if quartet[2] != 64 {
                out.push((quartet[1] << 4) | (quartet[2] >> 2));
            }
            if quartet[3] != 64 {
                out.push((quartet[2] << 6) | quartet[3]);
            }
            n = 0;
        }
    }
    String::from_utf8(out).ok()
}

// Read the services table straight from disk (base64 TSV), decoding in-process.
fn read_services() -> Vec<Service> {
    let raw = match fs::read_to_string(format!("{BDB_PATH}/tables/services/data.tsv")) {
        Ok(s) => s,
        Err(_) => return Vec::new(),
    };
    let mut out = Vec::new();
    for line in raw.lines() {
        if line.is_empty() {
            continue;
        }
        let fields: Vec<&str> = line.split('\t').collect();
        if fields.len() < 8 {
            continue;
        }
        // columns: name command autostart restart desired status pid description
        let dec: Option<Vec<String>> = fields.iter().map(|f| b64decode(f)).collect();
        let f = match dec {
            Some(v) => v,
            None => continue,
        };
        let desired = if f[0] == "desktopd" && desktop_autostart_disabled() {
            "down".to_string()
        } else {
            f[4].clone()
        };
        out.push(Service {
            name: f[0].clone(),
            command: f[1].clone(),
            restart: f[3] == "true",
            desired,
        });
    }
    out
}

// ----------------------------------------------------------------------------
// Supervision
// ----------------------------------------------------------------------------
fn start_service(svc: &Service) {
    let _ = fs::create_dir_all(LOG_DIR);
    let logp = format!("{LOG_DIR}/{}.log", svc.name);
    let file = match OpenOptions::new().create(true).append(true).open(&logp) {
        Ok(f) => f,
        Err(e) => {
            log(&format!("cannot open log for {}: {e}", svc.name));
            return;
        }
    };
    let errfile = match file.try_clone() {
        Ok(f) => f,
        Err(_) => return,
    };

    log(&format!("start {} -> {}", svc.name, svc.command));

    // Hold the supervisor lock across spawn+insert so the reaper cannot race
    // a fast-exiting child before we have registered its pid.
    let mut guard = sup_lock();
    let mut cmd = Command::new(&svc.command);
    cmd.env("BDB_PATH", BDB_PATH)
        .env("PATH", SERVICE_PATH)
        .env("SERVICE_NAME", &svc.name)
        .stdin(Stdio::null())
        .stdout(Stdio::from(file))
        .stderr(Stdio::from(errfile));
    unsafe {
        cmd.pre_exec(|| {
            sys::setsid();
            Ok(())
        });
    }
    let child = cmd.spawn();

    match child {
        Ok(c) => {
            let pid = c.id() as c_int;
            guard.insert(Unit {
                name: svc.name.clone(),
                pid,
                restart: svc.restart,
            });
            drop(guard);
            // c is dropped here; std does NOT reap on drop, our reaper does.
            set_service_fields(&svc.name, &[(5, "running"), (6, &pid.to_string())]);
        }
        Err(e) => {
            drop(guard);
            log(&format!("failed to start {}: {e}", svc.name));
            set_service_fields(&svc.name, &[(5, "failed")]);
        }
    }
}

fn stop_service(name: &str) {
    let guard = sup_lock();
    if let Some(pid) = guard.pid_of(name) {
        drop(guard);
        log(&format!("stop {name} (pid {pid})"));
        unsafe { sys::kill(pid, sys::SIGTERM) };
        // the reaper will clear the maps and update bdb when it dies
    }
}

fn start_console() {
    let tty_path = console_tty();
    log(&format!("opening console shell on {tty_path}"));
    // The console runs /bin/login, which authenticates against the bdb users
    // table and then execs the user's shell. login loops, so a logout returns
    // to the prompt; minit only respawns it if the login process itself dies.
    let login = first_exe(&["/bin/login", "/sbin/login"]);
    let tty = match OpenOptions::new().read(true).write(true).open(&tty_path) {
        Ok(f) => f,
        Err(e) => {
            log(&format!("cannot open {tty_path}: {e}; falling back to /dev/console"));
            match OpenOptions::new().read(true).write(true).open("/dev/console") {
                Ok(f) => f,
                Err(e) => {
                    log(&format!("cannot open /dev/console: {e}"));
                    return;
                }
            }
        }
    };
    let tty_in = match tty.try_clone() {
        Ok(f) => f,
        Err(e) => {
            log(&format!("cannot clone console fd: {e}"));
            return;
        }
    };
    let tty_out = match tty.try_clone() {
        Ok(f) => f,
        Err(e) => {
            log(&format!("cannot clone console fd: {e}"));
            return;
        }
    };
    let mut guard = sup_lock();
    let mut cmd = Command::new(&login);
    cmd.env("PATH", SERVICE_PATH)
        .env("BDB_PATH", BDB_PATH)
        .env("HOSTNAME", HOSTNAME)
        .stdin(Stdio::from(tty_in))
        .stdout(Stdio::from(tty_out))
        .stderr(Stdio::from(tty));
    unsafe {
        cmd.pre_exec(|| {
            sys::setsid();
            // TIOCSCTTY: make the opened tty the controlling terminal.
            let _ = sys::ioctl(0, 0x540E, 0);
            Ok(())
        });
    }
    let child = cmd.spawn();
    match child {
        Ok(c) => {
            guard.console_pid = c.id() as c_int;
        }
        Err(e) => {
            drop(guard);
            log(&format!("cannot open console: {e}"));
        }
    }
}

fn reconcile() {
    if SHUTDOWN.load(Ordering::SeqCst) != 0 {
        return;
    }
    for svc in read_services() {
        let want_up = svc.desired == "up";
        let have = sup_lock().has(&svc.name);
        if want_up && !have {
            start_service(&svc);
        } else if !want_up && have {
            stop_service(&svc.name);
        }
    }
    // keep an interactive console available
    let need_console = sup_lock().console_pid == 0;
    if need_console && SHUTDOWN.load(Ordering::SeqCst) == 0 {
        start_console();
    }
}

fn describe_status(status: c_int) -> String {
    let sig = status & 0x7f;
    if sig == 0 {
        format!("exit {}", (status >> 8) & 0xff)
    } else {
        format!("signal {sig}")
    }
}

fn handle_reap(pid: c_int, status: c_int) {
    let mut guard = sup_lock();

    if pid == guard.console_pid {
        guard.console_pid = 0;
        drop(guard);
        log("console exited; reopening");
        RELOAD.store(true, Ordering::SeqCst);
        return;
    }

    if let Some((name, restart)) = guard.take_by_pid(pid) {
        drop(guard);
        log(&format!("service {name} exited ({})", describe_status(status)));
        set_service_fields(&name, &[(5, "exited"), (6, "0")]);
        if !restart {
            // one-shot or stopped on purpose: do not let reconcile respawn it
            set_service_fields(&name, &[(4, "down")]);
        } else {
            // crashed long-running service: reconcile will bring it back
            RELOAD.store(true, Ordering::SeqCst);
        }
    }
    // else: a re-parented orphan we never tracked; already reaped, ignore.
}

fn reaper_loop() {
    loop {
        let mut status: c_int = 0;
        let pid = unsafe { sys::waitpid(-1, &mut status, 0) };
        if pid <= 0 {
            // -1 with ECHILD (no children yet) or EINTR: back off briefly
            thread::sleep(Duration::from_millis(200));
            continue;
        }
        handle_reap(pid, status);
    }
}

fn reconcile_loop() {
    loop {
        reconcile();
        // sleep ~1s but wake early on an explicit reload poke
        for _ in 0..10 {
            if RELOAD.swap(false, Ordering::SeqCst) || SHUTDOWN.load(Ordering::SeqCst) != 0 {
                break;
            }
            thread::sleep(Duration::from_millis(100));
        }
    }
}

// ----------------------------------------------------------------------------
// Log shipping: mirror service log files into the bdb `logs` table
// ----------------------------------------------------------------------------
fn now_ts() -> String {
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    secs.to_string()
}

fn ship_logs(offsets: &mut HashMap<String, u64>) {
    let entries = match fs::read_dir(LOG_DIR) {
        Ok(e) => e,
        Err(_) => return,
    };
    for entry in entries.flatten() {
        let path = entry.path();
        let is_log = path.extension().map(|e| e == "log").unwrap_or(false);
        if !is_log {
            continue;
        }
        let service = match path.file_stem().and_then(|s| s.to_str()) {
            Some(s) => s.to_string(),
            None => continue,
        };
        let key = path.to_string_lossy().into_owned();
        let mut off = *offsets.get(&key).unwrap_or(&0);

        let mut file = match OpenOptions::new().read(true).open(&path) {
            Ok(f) => f,
            Err(_) => continue,
        };
        let len = file.metadata().map(|m| m.len()).unwrap_or(0);
        if len < off {
            off = 0; // file was rotated/truncated
        }
        if len == off {
            continue;
        }
        if file.seek(SeekFrom::Start(off)).is_err() {
            continue;
        }
        let mut buf = Vec::new();
        if file.read_to_end(&mut buf).is_err() {
            continue;
        }
        // only consume up to the last full line
        let last_nl = buf.iter().rposition(|&b| b == b'\n');
        let consume = match last_nl {
            Some(p) => p + 1,
            None => 0,
        };
        if consume == 0 {
            continue;
        }
        let text = String::from_utf8_lossy(&buf[..consume]);
        for line in text.lines() {
            if line.is_empty() {
                continue;
            }
            append_log(&service, line);
        }
        offsets.insert(key, off + consume as u64);
    }
}

fn log_shipper_loop() {
    let mut offsets: HashMap<String, u64> = HashMap::new();
    loop {
        ship_logs(&mut offsets);
        thread::sleep(Duration::from_secs(1));
    }
}

// ----------------------------------------------------------------------------
// Signals & shutdown
// ----------------------------------------------------------------------------
extern "C" fn on_signal(sig: c_int) {
    match sig {
        sys::SIGINT | sys::SIGTERM => SHUTDOWN.store(1, Ordering::SeqCst),
        sys::SIGUSR2 => SHUTDOWN.store(2, Ordering::SeqCst),
        sys::SIGUSR1 => RELOAD.store(true, Ordering::SeqCst),
        _ => {}
    }
}

fn install_signals() {
    unsafe {
        sys::signal(sys::SIGINT, on_signal);
        sys::signal(sys::SIGTERM, on_signal);
        sys::signal(sys::SIGUSR1, on_signal);
        sys::signal(sys::SIGUSR2, on_signal);
    }
}

fn do_shutdown(mode: u8) {
    if mode == 2 {
        log("reboot requested");
    } else {
        log("power off requested");
    }

    // collect every pid we know about
    let pids: Vec<c_int> = {
        let g = sup_lock();
        let mut v = g.all_pids();
        if g.console_pid > 0 {
            v.push(g.console_pid);
        }
        v
    };

    log("stopping services");
    for pid in &pids {
        unsafe { sys::kill(*pid, sys::SIGTERM) };
    }
    thread::sleep(Duration::from_secs(2));
    for pid in &pids {
        unsafe { sys::kill(*pid, sys::SIGKILL) };
    }

    unsafe { sys::sync() };
    for m in ["/run", "/tmp", "/sys", "/proc"] {
        let c = cstr(m);
        unsafe { sys::umount2(c.as_ptr(), 0) };
    }
    unsafe { sys::sync() };

    let howto = if mode == 2 {
        sys::RB_AUTOBOOT
    } else {
        sys::RB_POWER_OFF
    };
    log("calling reboot(2)");
    unsafe { sys::reboot(howto) };

    // should not return; if it does, idle so the kernel does not panic
    log("reboot(2) returned; halting");
    loop {
        thread::sleep(Duration::from_secs(3600));
    }
}

// ----------------------------------------------------------------------------
// main
// ----------------------------------------------------------------------------
fn main() {
    log("booting minibash linux");
    mount_all();
    apply_keymap();
    load_storage_modules();
    set_hostname();
    network_up();
    let persistent = mount_persistent();
    seed_db(persistent);

    // Rust boot summary helper (prints to the console)
    let _ = Command::new("/bin/bdbboot").status();

    install_signals();

    // Reaper first so every child (console + services) is reaped from now on.
    let _ = thread::Builder::new()
        .name("reaper".into())
        .spawn(|| loop {
            if std::panic::catch_unwind(reaper_loop).is_err() {
                thread::sleep(Duration::from_millis(200));
            }
        });

    // Open the interactive console immediately, like a getty, so the operator
    // gets a shell without waiting on (possibly slow) service startup. The
    // reconcile loop only *re-opens* it if it later exits.
    start_console();
    log("ready");

    // background workers; isolate panics so a worker thread can never take
    // down PID 1.
    let _ = thread::Builder::new()
        .name("reconcile".into())
        .spawn(|| loop {
            if std::panic::catch_unwind(reconcile_loop).is_err() {
                thread::sleep(Duration::from_millis(200));
            }
        });
    let _ = thread::Builder::new()
        .name("logship".into())
        .spawn(|| loop {
            if std::panic::catch_unwind(log_shipper_loop).is_err() {
                thread::sleep(Duration::from_millis(500));
            }
        });

    // main thread waits for a shutdown request
    loop {
        let mode = SHUTDOWN.load(Ordering::SeqCst);
        if mode != 0 {
            do_shutdown(mode);
            break;
        }
        thread::sleep(Duration::from_millis(200));
    }
}
