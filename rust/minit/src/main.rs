// minit - PID 1 for Altitude Linux (v0.4)
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
use std::io::{Read, Seek, SeekFrom};
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
const HOSTNAME: &str = "altitude";

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
    status: String,
}

#[derive(Clone)]
struct Dependency {
    service: String,
    relation: String,
    target: String,
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
    // The kernel's request_module() (auto-loading e.g. the iwlwifi opmode) execs
    // this path; default /sbin/modprobe may be absent in our rootfs, so point it
    // at one we know exists.
    let _ = fs::write("/proc/sys/kernel/modprobe", "/bin/modprobe");
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
        "iwlwifi",
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
    if let Some(mode) = kernel_arg("minibash.desktop") {
        return matches!(mode.as_str(), "off" | "debug" | "shell");
    }
    registry_value("/system/desktop/enabled").as_deref() == Some("false")
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
// forking /bin/bdb for every status update and log line serialises everything
// on bdb's global lock; under TCG emulation that process churn stalls the supervisor. Doing it in-process keeps the
// lock held for microseconds and never blocks a worker thread on a fork.
//
// We honour bdb's own lock convention (mkdir of $BDB_PATH/.lock) so the `bdb`
// CLI used by bashsvc and the operator stays mutually exclusive with us.

fn db_lock() -> bool {
    let lock = format!("{BDB_PATH}/.lock");
    for _ in 0..50 {
        if fs::create_dir(&lock).is_ok() {
            let boot_id = fs::read_to_string("/proc/sys/kernel/random/boot_id")
                .unwrap_or_default();
            let owner = format!("{lock}/owner");
            if fs::write(&owner, format!("{} {}\n", std::process::id(), boot_id.trim()))
                .is_ok()
            {
                return true;
            }
            let _ = fs::remove_dir(&lock);
        }
        thread::sleep(Duration::from_millis(100));
    }
    false
}

fn db_unlock() {
    let lock = format!("{BDB_PATH}/.lock");
    let _ = fs::remove_file(format!("{lock}/owner"));
    let _ = fs::remove_dir(lock);
}

// Update specific columns (by index) of the services row whose name matches.
// Columns: 0 name 1 command 2 autostart 3 restart 4 desired 5 status 6 pid 7 desc
fn set_service_fields(name: &str, updates: &[(usize, &str)]) {
    if !db_lock() {
        return;
    }
    let path = format!("{BDB_PATH}/tables/services/data.bdb");
    if let Some(mut rows) = read_bdb_rows(&path, 8) {
        let mut changed = false;
        for fields in rows.iter_mut() {
            if fields.len() >= 8 && fields[0] == name {
                for (idx, val) in updates {
                    if *idx < fields.len() {
                        fields[*idx] = (*val).to_string();
                    }
                }
                changed = true;
            }
        }
        if changed {
            let _ = write_bdb_rows(&path, 8, &rows);
        }
    }
    db_unlock();
}

fn append_log(service: &str, line: &str) {
    if !db_lock() {
        return;
    }
    let path = format!("{BDB_PATH}/tables/logs/data.bdb");
    let mut rows = read_bdb_rows(&path, 3).unwrap_or_default();
    rows.push(vec![now_ts(), service.to_string(), line.to_string()]);
    if rows.len() > 4096 {
        rows.drain(0..rows.len() - 4096);
    }
    let _ = write_bdb_rows(&path, 3, &rows);
    db_unlock();
}

fn read_u32(buf: &[u8], off: &mut usize) -> Option<u32> {
    let bytes = buf.get(*off..*off + 4)?;
    *off += 4;
    Some(u32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]))
}

fn read_bdb_rows(path: &str, expected_cols: usize) -> Option<Vec<Vec<String>>> {
    let buf = fs::read(path).ok()?;
    let mut off = 0usize;
    if buf.get(0..4)? != b"BDB1" {
        return None;
    }
    off += 4;
    let version = read_u32(&buf, &mut off)?;
    let cols = read_u32(&buf, &mut off)? as usize;
    let rows = read_u32(&buf, &mut off)? as usize;
    if version != 1 || cols != expected_cols {
        return None;
    }
    let mut out = Vec::with_capacity(rows);
    for _ in 0..rows {
        let mut row = Vec::with_capacity(cols);
        for _ in 0..cols {
            let len = read_u32(&buf, &mut off)? as usize;
            let bytes = buf.get(off..off + len)?;
            off += len;
            row.push(String::from_utf8_lossy(bytes).into_owned());
        }
        out.push(row);
    }
    Some(out)
}

fn write_u32(out: &mut Vec<u8>, value: u32) {
    out.extend_from_slice(&value.to_le_bytes());
}

fn write_bdb_rows(path: &str, cols: usize, rows: &[Vec<String>]) -> std::io::Result<()> {
    let mut out = Vec::new();
    out.extend_from_slice(b"BDB1");
    write_u32(&mut out, 1);
    write_u32(&mut out, cols as u32);
    write_u32(&mut out, rows.len() as u32);
    for row in rows {
        for idx in 0..cols {
            let value = row.get(idx).map(String::as_str).unwrap_or("");
            write_u32(&mut out, value.len() as u32);
            out.extend_from_slice(value.as_bytes());
        }
    }
    let tmp = format!("{path}.tmp");
    fs::write(&tmp, out)?;
    fs::rename(tmp, path)
}

// Read the services table straight from native bdb.
fn read_services() -> Vec<Service> {
    let rows = match read_bdb_rows(&format!("{BDB_PATH}/tables/services/data.bdb"), 8) {
        Some(rows) => rows,
        None => return Vec::new(),
    };
    let mut out = Vec::new();
    for f in rows {
        if f.len() < 8 { continue; }
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
            status: f[5].clone(),
        });
    }
    out
}

fn registry_value(path: &str) -> Option<String> {
    read_bdb_rows(&format!("{BDB_PATH}/tables/registry/data.bdb"), 5)?
        .into_iter()
        .find(|fields| fields.len() >= 5 && fields[0] == path)
        .map(|fields| fields[2].clone())
}

fn read_dependencies() -> Vec<Dependency> {
    let rows = match read_bdb_rows(
        &format!("{BDB_PATH}/tables/service_dependencies/data.bdb"),
        4,
    ) {
        Some(rows) => rows,
        None => return Vec::new(),
    };
    rows.into_iter()
        .filter(|f| f.len() >= 4)
        .filter(|f| matches!(f[2].as_str(), "requires" | "after" | "before"))
        .map(|f| Dependency {
            service: f[1].clone(),
            relation: f[2].clone(),
            target: f[3].clone(),
        })
        .collect()
}

fn ordered_services(
    services: &[Service],
    dependencies: &[Dependency],
) -> (Vec<Service>, Vec<String>) {
    let mut indegree: HashMap<String, usize> = HashMap::new();
    let mut edges: HashMap<String, Vec<String>> = HashMap::new();
    for svc in services {
        indegree.insert(svc.name.clone(), 0);
        edges.insert(svc.name.clone(), Vec::new());
    }
    for dep in dependencies {
        if !indegree.contains_key(&dep.service) || !indegree.contains_key(&dep.target) {
            continue;
        }
        let (from, to) = if dep.relation == "before" {
            (&dep.service, &dep.target)
        } else {
            (&dep.target, &dep.service)
        };
        let targets = edges.get_mut(from).unwrap();
        if !targets.contains(to) {
            targets.push(to.clone());
            *indegree.get_mut(to).unwrap() += 1;
        }
    }

    let mut ready: Vec<String> = services
        .iter()
        .filter(|svc| indegree.get(&svc.name) == Some(&0))
        .map(|svc| svc.name.clone())
        .collect();
    let mut names = Vec::new();
    while !ready.is_empty() {
        let name = ready.remove(0);
        names.push(name.clone());
        if let Some(targets) = edges.get(&name) {
            for target in targets {
                let degree = indegree.get_mut(target).unwrap();
                *degree -= 1;
                if *degree == 0 {
                    ready.push(target.clone());
                }
            }
        }
    }
    let cyclic: Vec<String> = services
        .iter()
        .filter(|svc| !names.contains(&svc.name))
        .map(|svc| svc.name.clone())
        .collect();
    let by_name: HashMap<String, Service> = services
        .iter()
        .cloned()
        .map(|svc| (svc.name.clone(), svc))
        .collect();
    let ordered = names
        .into_iter()
        .filter_map(|name| by_name.get(&name).cloned())
        .collect();
    (ordered, cyclic)
}

fn required_targets<'a>(name: &str, dependencies: &'a [Dependency]) -> Vec<&'a str> {
    dependencies
        .iter()
        .filter(|dep| dep.service == name && dep.relation == "requires")
        .map(|dep| dep.target.as_str())
        .collect()
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
    let services = read_services();
    let dependencies = read_dependencies();
    let desired: HashMap<String, String> = services
        .iter()
        .map(|svc| (svc.name.clone(), svc.desired.clone()))
        .collect();
    let (ordered, cyclic) = ordered_services(&services, &dependencies);

    // Stop in reverse dependency order: consumers before their providers.
    for svc in ordered.iter().rev() {
        let required_down = required_targets(&svc.name, &dependencies).iter().any(|target| {
            desired.get(*target).map(String::as_str) != Some("up")
        });
        let should_stop = svc.desired != "up" || required_down;
        let have = sup_lock().has(&svc.name);
        if should_stop && have {
            stop_service(&svc.name);
        }
        if required_down && svc.desired == "up" && svc.status != "blocked" {
            set_service_fields(&svc.name, &[(5, "blocked"), (6, "0")]);
        }
    }

    for name in &cyclic {
        if sup_lock().has(name) {
            stop_service(name);
        }
        set_service_fields(name, &[(5, "blocked"), (6, "0")]);
        log(&format!("dependency cycle blocks {name}"));
    }

    // Start in topological order. A hard requirement must already be running.
    for svc in &ordered {
        if svc.desired != "up" {
            continue;
        }
        let missing = required_targets(&svc.name, &dependencies)
            .into_iter()
            .find(|target| !sup_lock().has(target));
        if let Some(target) = missing {
            if svc.status != "blocked" {
                set_service_fields(&svc.name, &[(5, "blocked"), (6, "0")]);
            }
            log(&format!("{} blocked: requires {}", svc.name, target));
            continue;
        }
        if !sup_lock().has(&svc.name) {
            start_service(svc);
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
    log("booting Altitude Linux");
    mount_all();
    apply_keymap();
    load_storage_modules();
    set_hostname();
    network_up();
    // Disk-root install (root= on the SSD/HDD): /var/bdb already lives on the
    // persistent root, so skip the RAM-model persistence dance entirely —
    // mounting a ramfs over it here would shadow the real data.
    let persistent = if kernel_arg("minibash.root").as_deref() == Some("disk") {
        log("disk-root mode: /var/bdb is on the persistent root");
        true
    } else {
        mount_persistent()
    };
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

#[cfg(test)]
mod tests {
    use super::*;

    fn service(name: &str) -> Service {
        Service {
            name: name.to_string(),
            command: format!("/services/{name}.sh"),
            restart: true,
            desired: "up".to_string(),
            status: "stopped".to_string(),
        }
    }

    fn dependency(service: &str, relation: &str, target: &str) -> Dependency {
        Dependency {
            service: service.to_string(),
            relation: relation.to_string(),
            target: target.to_string(),
        }
    }

    #[test]
    fn orders_requirements_and_after_before_edges() {
        let services = vec![service("graphical"), service("dbus"), service("displayd")];
        let deps = vec![
            dependency("graphical", "requires", "dbus"),
            dependency("displayd", "after", "graphical"),
        ];
        let (ordered, cyclic) = ordered_services(&services, &deps);
        let names: Vec<&str> = ordered.iter().map(|svc| svc.name.as_str()).collect();
        assert_eq!(names, vec!["dbus", "graphical", "displayd"]);
        assert!(cyclic.is_empty());
    }

    #[test]
    fn reports_dependency_cycles() {
        let services = vec![service("a"), service("b")];
        let deps = vec![
            dependency("a", "after", "b"),
            dependency("b", "after", "a"),
        ];
        let (ordered, cyclic) = ordered_services(&services, &deps);
        assert!(ordered.is_empty());
        assert_eq!(cyclic, vec!["a", "b"]);
    }
}
