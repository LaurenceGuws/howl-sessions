//! Small app-private preferences, never credentials or live connection state.
//! Saving a profile never attaches a terminal. A successful disk replacement
//! precedes UI changes; malformed/unsupported files are preserved for recovery.
use crate::App;
use serde::{Deserialize, Serialize};
use slint::ComponentHandle;
use std::{
    cell::RefCell,
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    net::Ipv4Addr,
    path::{Path, PathBuf},
    rc::Rc,
};

const MAX_PROFILES: usize = 16;
const MAX_FILE_BYTES: u64 = 64 * 1024;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Profile {
    pub(crate) id: u32,
    pub(crate) name: String,
    pub(crate) endpoint: String,
    pub(crate) visible: bool,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Preferences {
    version: u32,
    servers: Vec<Profile>,
    next_id: u32,
    font_size: Option<f32>,
}

impl Default for Preferences {
    fn default() -> Self {
        Self {
            version: 1,
            servers: Vec::new(),
            next_id: 1,
            font_size: None,
        }
    }
}

impl Preferences {
    fn validate(&self) -> Result<(), String> {
        if self.version != 1 {
            return Err("Unsupported settings version".into());
        }
        if self.servers.len() > MAX_PROFILES {
            return Err(format!("At most {MAX_PROFILES} servers can be saved"));
        }
        if self.next_id == 0 || self.next_id > i32::MAX as u32 {
            return Err("Invalid next server identity".into());
        }
        if self
            .font_size
            .is_some_and(|size| !size.is_finite() || !(8.0..=48.0).contains(&size))
        {
            return Err("Terminal font size must be between 8 and 48".into());
        }
        for (i, server) in self.servers.iter().enumerate() {
            validate_profile(server)?;
            if server.id == 0
                || server.id >= self.next_id
                || self.servers[..i].iter().any(|other| other.id == server.id)
            {
                return Err("Invalid or duplicate server identity".into());
            }
            if self.servers[..i]
                .iter()
                .any(|other| other.endpoint == server.endpoint)
            {
                return Err("That endpoint is already saved".into());
            }
        }
        Ok(())
    }
}

impl Preferences {
    fn upsert(&mut self, id: &str, name: &str, endpoint: &str) -> Result<(), String> {
        let name = name.trim().to_owned();
        let endpoint = endpoint.trim().to_owned();
        if id.is_empty() {
            if self.servers.len() == MAX_PROFILES {
                return Err(format!("At most {MAX_PROFILES} servers can be saved"));
            }
            let next_id = self
                .next_id
                .checked_add(1)
                .filter(|id| *id <= i32::MAX as u32)
                .ok_or("Server identity space exhausted")?;
            self.servers.push(Profile {
                id: self.next_id,
                name,
                endpoint,
                visible: true,
            });
            self.next_id = next_id;
        } else {
            let index = self.index(id)?;
            self.servers[index].name = name;
            self.servers[index].endpoint = endpoint;
        }
        self.validate()
    }

    fn index(&self, id: &str) -> Result<usize, String> {
        let id = id.parse::<u32>().map_err(|_| "Invalid server identity")?;
        self.servers
            .iter()
            .position(|server| server.id == id)
            .ok_or_else(|| "That server no longer exists".into())
    }
}

fn validate_profile(profile: &Profile) -> Result<(), String> {
    if profile.name.is_empty()
        || profile.name.len() > 64
        || profile.name.chars().any(char::is_control)
    {
        return Err("Server name must contain 1–64 bytes without control characters".into());
    }
    let endpoint = &profile.endpoint;
    if endpoint.len() > 1024 || endpoint.chars().any(char::is_control) {
        return Err("Server endpoint is too long or contains control characters".into());
    }
    if let Some(path) = endpoint.strip_prefix("unix:") {
        if path.starts_with('/') && path.len() < 108 {
            return Ok(());
        }
        return Err("Use unix:/absolute/socket/path (at most 107 bytes)".into());
    }
    if let Some(address) = endpoint.strip_prefix("tcp://")
        && let Some((host, port)) = address.rsplit_once(':')
        && let Ok(ip) = host.parse::<Ipv4Addr>()
        && !ip.is_unspecified()
        && let Ok(port) = port.parse::<u16>()
        && port != 0
    {
        return Ok(());
    }
    Err("Use tcp://IPv4:port or unix:/absolute/socket/path".into())
}

#[cfg(not(target_os = "ios"))]
pub(crate) fn desktop_path() -> Result<PathBuf, String> {
    if let Some(path) = std::env::var_os("XDG_CONFIG_HOME").filter(|p| !p.is_empty()) {
        let path = PathBuf::from(path);
        if !path.is_absolute() {
            return Err("XDG_CONFIG_HOME must be an absolute path".into());
        }
        return Ok(path.join("howl-sessions/settings.json"));
    }
    std::env::var_os("HOME")
        .filter(|home| !home.is_empty())
        .map(|home| PathBuf::from(home).join(".config/howl-sessions/settings.json"))
        .ok_or_else(|| "HOME is unavailable; settings cannot be saved".into())
}

fn read(path: &Path) -> Result<Preferences, String> {
    let file = match File::open(path) {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return Ok(Preferences::default());
        }
        Err(error) => return Err(format!("Cannot read {}: {error}", path.display())),
    };
    let mut bytes = Vec::new();
    file.take(MAX_FILE_BYTES + 1)
        .read_to_end(&mut bytes)
        .map_err(|error| format!("Cannot read {}: {error}", path.display()))?;
    if bytes.len() as u64 > MAX_FILE_BYTES {
        return Err(format!("Settings file exceeds 64 KiB: {}", path.display()));
    }
    let preferences: Preferences = serde_json::from_slice(&bytes)
        .map_err(|error| format!("Invalid settings in {}: {error}", path.display()))?;
    preferences
        .validate()
        .map_err(|error| format!("Invalid settings in {}: {error}", path.display()))?;
    Ok(preferences)
}

fn write(path: &Path, preferences: &Preferences) -> Result<(), String> {
    preferences.validate()?;
    let bytes = serde_json::to_vec_pretty(preferences).map_err(|error| error.to_string())?;
    if bytes.len() as u64 > MAX_FILE_BYTES {
        return Err("Settings exceed 64 KiB".into());
    }
    let directory = path
        .parent()
        .ok_or("Settings file has no parent directory")?;
    let mut builder = fs::DirBuilder::new();
    builder.recursive(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        builder.mode(0o700);
    }
    builder
        .create(directory)
        .map_err(|error| format!("Cannot create {}: {error}", directory.display()))?;
    let temporary = path.with_extension(format!("json.{}.tmp", std::process::id()));
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options
        .open(&temporary)
        .map_err(|error| format!("Cannot create {}: {error}", temporary.display()))?;
    let result = (|| {
        file.write_all(&bytes)?;
        file.sync_all()?;
        fs::rename(&temporary, path)
    })();
    if let Err(error) = result {
        let _ = fs::remove_file(&temporary); // Only this call's newly created file.
        return Err(format!("Cannot save {}: {error}", path.display()));
    }
    Ok(())
}

struct Store {
    path: Result<PathBuf, String>,
    preferences: Preferences,
    load_error: Option<String>,
}

impl Store {
    fn new(path: Result<PathBuf, String>) -> Self {
        match path
            .as_ref()
            .map_err(Clone::clone)
            .and_then(|path| read(path))
        {
            Ok(preferences) => Self {
                path,
                preferences,
                load_error: None,
            },
            Err(error) => Self {
                path,
                preferences: Preferences::default(),
                load_error: Some(error),
            },
        }
    }

    fn save(&mut self, preferences: Preferences) -> Result<(), String> {
        if let Some(error) = &self.load_error {
            return Err(format!(
                "{error}. Correct the settings file and reopen the app before saving."
            ));
        }
        write(self.path.as_ref().map_err(Clone::clone)?, &preferences)?;
        self.preferences = preferences;
        Ok(())
    }
}

/// Sessions owns the merged profile/catalog UI model. Settings only owns the
/// durable configuration and notifies it after successful saves. Removing,
/// editing or hiding a profile never disconnects the active terminal.
pub(crate) fn attach(
    app: &App,
    path: Result<PathBuf, String>,
    on_profiles: impl Fn(&[Profile]) + 'static,
) {
    let store = Rc::new(RefCell::new(Store::new(path)));
    let on_profiles = Rc::new(on_profiles);
    let default_font_size = app.get_terminal_font_size();
    if let Some(size) = store.borrow().preferences.font_size {
        app.set_terminal_font_size(size);
    }
    on_profiles(&store.borrow().preferences.servers);
    if let Some(error) = &store.borrow().load_error {
        app.set_settings_error(error.clone().into());
    }

    let state = store.clone();
    let changed = on_profiles.clone();
    let weak = app.as_weak();
    app.on_save_server(move |id, name, endpoint| {
        let Some(app) = weak.upgrade() else {
            return;
        };
        let mut store = state.borrow_mut();
        let mut next = store.preferences.clone();
        match next
            .upsert(&id, &name, &endpoint)
            .and_then(|()| store.save(next))
        {
            Ok(()) => {
                changed(&store.preferences.servers);
                app.set_settings_error("".into());
            }
            Err(error) => app.set_settings_error(error.into()),
        }
    });

    let state = store.clone();
    let changed = on_profiles.clone();
    let weak = app.as_weak();
    app.on_remove_server(move |id| {
        let Some(app) = weak.upgrade() else {
            return;
        };
        let mut store = state.borrow_mut();
        let mut next = store.preferences.clone();
        let result = next.index(&id).and_then(|index| {
            next.servers.remove(index);
            store.save(next)
        });
        match result {
            Ok(()) => {
                changed(&store.preferences.servers);
                app.set_settings_error("".into());
            }
            Err(error) => app.set_settings_error(error.into()),
        }
    });

    let state = store.clone();
    let weak = app.as_weak();
    app.on_toggle_server(move |id| {
        let Some(app) = weak.upgrade() else {
            return;
        };
        let mut store = state.borrow_mut();
        let mut next = store.preferences.clone();
        let result = next.index(&id).and_then(|index| {
            next.servers[index].visible = !next.servers[index].visible;
            store.save(next)
        });
        match result {
            Ok(()) => {
                on_profiles(&store.preferences.servers);
                app.set_settings_error("".into());
            }
            Err(error) => app.set_settings_error(error.into()),
        }
    });

    let weak = app.as_weak();
    app.on_save_font_size(move |size| {
        let Some(app) = weak.upgrade() else {
            return;
        };
        let mut store = store.borrow_mut();
        let mut next = store.preferences.clone();
        next.font_size = Some(size);
        match store.save(next) {
            Ok(()) => app.set_settings_error("".into()),
            Err(error) => {
                app.set_terminal_font_size(
                    store.preferences.font_size.unwrap_or(default_font_size),
                );
                app.set_settings_error(error.into());
            }
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};
    static NEXT: AtomicU64 = AtomicU64::new(0);

    fn directory() -> PathBuf {
        let directory = std::env::temp_dir().join(format!(
            "howl-settings-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&directory).unwrap();
        directory
    }

    #[test]
    fn endpoints_match_numeric_transport_and_reject_credentials() {
        for endpoint in ["tcp://127.0.0.1:43179", "unix:/run/user/1000/howl.sock"] {
            assert!(
                validate_profile(&Profile {
                    id: 1,
                    visible: true,
                    name: "Home".into(),
                    endpoint: endpoint.into()
                })
                .is_ok()
            );
        }
        for endpoint in [
            "tcp://localhost:80",
            "tcp://0.0.0.0:80",
            "tcp://1.2.3.4:0",
            "tcp://user:secret@1.2.3.4:80",
            "unix:relative",
            "https://1.2.3.4",
            "tcp://1.2.3.4:80\n",
        ] {
            assert!(
                validate_profile(&Profile {
                    id: 1,
                    visible: true,
                    name: "Home".into(),
                    endpoint: endpoint.into()
                })
                .is_err(),
                "{endpoint}"
            );
        }
    }

    #[test]
    fn round_trip_replace_and_private_mode() {
        let directory = directory();
        let path = directory.join("settings.json");
        assert_eq!(read(&path).unwrap(), Preferences::default());
        let mut preferences = Preferences::default();
        preferences.servers.push(Profile {
            id: 1,
            visible: true,
            name: "Home".into(),
            endpoint: "tcp://127.0.0.1:43179".into(),
        });
        preferences.next_id = 2;
        write(&path, &preferences).unwrap();
        preferences.font_size = Some(24.0);
        preferences.servers[0].visible = false;
        write(&path, &preferences).unwrap();
        assert_eq!(read(&path).unwrap(), preferences);
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(
                fs::metadata(&path).unwrap().permissions().mode() & 0o777,
                0o600
            );
        }
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn malformed_and_oversized_files_are_not_overwritten() {
        let directory = directory();
        let path = directory.join("settings.json");
        for bytes in [b"{broken".to_vec(), vec![b' '; MAX_FILE_BYTES as usize + 1]] {
            fs::write(&path, &bytes).unwrap();
            let mut store = Store::new(Ok(path.clone()));
            assert!(store.save(Preferences::default()).is_err());
            assert_eq!(fs::read(&path).unwrap(), bytes);
        }
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn bounds_versions_and_duplicate_endpoints_are_rejected() {
        let mut p = Preferences {
            version: 2,
            ..Preferences::default()
        };
        assert!(p.validate().is_err());
        p.version = 1;
        p.font_size = Some(f32::NAN);
        assert!(p.validate().is_err());
        p.font_size = None;
        p.next_id = 0;
        assert!(p.validate().is_err());
        p.next_id = 2;
        p.servers = vec![
            Profile {
                id: 1,
                visible: true,
                name: "Home".into(),
                endpoint: "tcp://127.0.0.1:80".into()
            };
            2
        ];
        assert!(p.validate().is_err());
        p.servers.resize(MAX_PROFILES + 1, p.servers[0].clone());
        assert!(p.validate().is_err());
    }
    #[test]
    fn profile_identity_survives_edits_visibility_and_removal() {
        let mut p = Preferences::default();
        p.upsert("", "Home", "tcp://127.0.0.1:80").unwrap();
        p.upsert("", "Phone", "tcp://127.0.0.1:81").unwrap();
        p.servers[0].visible = false;
        p.upsert("1", "Renamed", "tcp://127.0.0.1:82").unwrap();
        assert!(!p.servers[0].visible);
        assert_eq!(p.servers[0].id, 1);
        p.servers.remove(0);
        p.upsert("", "New", "tcp://127.0.0.1:83").unwrap();
        assert_eq!(p.servers.iter().map(|s| s.id).collect::<Vec<_>>(), [2, 3]);
        assert!(p.index("1").is_err());
    }
    #[test]
    fn failed_save_preserves_previous_preferences_and_file() {
        let directory = directory();
        let path = directory.join("settings.json");
        let initial = Preferences::default();
        write(&path, &initial).unwrap();
        let mut store = Store::new(Ok(path.clone()));
        // A conflicting temporary file must not be overwritten or removed.
        let temporary = path.with_extension(format!("json.{}.tmp", std::process::id()));
        fs::write(&temporary, b"someone else's file").unwrap();
        let mut changed = initial.clone();
        changed.font_size = Some(22.0);
        assert!(store.save(changed).is_err());
        assert_eq!(store.preferences, initial);
        assert_eq!(read(&path).unwrap(), initial);
        assert_eq!(fs::read(&temporary).unwrap(), b"someone else's file");
        fs::remove_dir_all(directory).unwrap();
    }
    #[test]
    fn duplicate_ids_and_stale_next_id_are_rejected() {
        let mut p = Preferences::default();
        p.upsert("", "One", "tcp://127.0.0.1:1").unwrap();
        p.upsert("", "Two", "tcp://127.0.0.1:2").unwrap();
        p.servers[1].id = p.servers[0].id;
        assert!(p.validate().is_err());
        p.servers[1].id = 2;
        p.next_id = 2;
        assert!(p.validate().is_err());
        p.next_id = 3;
        assert!(p.validate().is_ok());
    }

    #[test]
    fn font_size_is_finite_and_bounded_without_silent_correction() {
        let mut p = Preferences::default();
        for size in [f32::NAN, f32::INFINITY, f32::NEG_INFINITY, 7.99, 48.01] {
            p.font_size = Some(size);
            assert!(p.validate().is_err());
        }
        for size in [8.0, 18.0, 48.0] {
            p.font_size = Some(size);
            assert!(p.validate().is_ok());
        }
    }
}
