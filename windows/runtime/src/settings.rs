use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};
use std::{
    fs,
    path::{Path, PathBuf},
};

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(default)]
pub struct HostSettings {
    pub version: u32,
    pub sharing: bool,
    pub port: u16,
    pub fps: u32,
    pub bitrate_mbps: u32,
    pub max_width: u32,
    pub max_height: u32,
    pub allow_input: bool,
    pub synthetic: bool,
}
impl Default for HostSettings {
    fn default() -> Self {
        Self {
            version: 1,
            sharing: false,
            port: 7373,
            fps: 60,
            bitrate_mbps: 20,
            max_width: 1920,
            max_height: 1080,
            allow_input: true,
            synthetic: false,
        }
    }
}
impl HostSettings {
    pub fn validate(&self) -> Result<()> {
        if self.version != 1 {
            bail!("Unsupported settings version; the original file was preserved");
        }
        if self.port == 0
            || !(1..=240).contains(&self.fps)
            || !(2..=220).contains(&self.bitrate_mbps)
            || !(64..=7680).contains(&self.max_width)
            || !(64..=4320).contains(&self.max_height)
            || !self.max_width.is_multiple_of(2)
            || !self.max_height.is_multiple_of(2)
        {
            bail!("Invalid port, frame rate, bitrate, or even video dimensions");
        }
        Ok(())
    }
    pub fn load() -> Result<Self> {
        load_json(&data_dir()?.join("Host/settings.json"))
    }
    pub fn save(&self) -> Result<()> {
        self.validate()?;
        save_json(&data_dir()?.join("Host/settings.json"), self)
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, Default)]
#[serde(default)]
pub struct SavedComputer {
    pub name: String,
    pub address: String,
    pub pairing_id: String,
    pub protected_token: Vec<u8>,
    pub stats: bool,
    pub local_cursor: bool,
    pub swap_modifiers: bool,
}

pub fn data_dir() -> Result<PathBuf> {
    // An override isolates automated tests from the person's saved credentials and settings.
    if let Some(path) = std::env::var_os("LIGHTRAY_DATA_DIR") {
        return Ok(PathBuf::from(path));
    }
    Ok(
        PathBuf::from(std::env::var_os("LOCALAPPDATA").context("LOCALAPPDATA is unavailable")?)
            .join("Lightray"),
    )
}
pub fn load_json<T: for<'a> Deserialize<'a> + Default>(path: &Path) -> Result<T> {
    match fs::read(path) {
        Ok(bytes) => {
            serde_json::from_slice(&bytes).with_context(|| format!("Read {}", path.display()))
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(T::default()),
        Err(error) => Err(error.into()),
    }
}
pub fn save_json<T: Serialize>(path: &Path, value: &T) -> Result<()> {
    fs::create_dir_all(path.parent().context("Missing settings directory")?)?;
    let temporary = path.with_extension("tmp");
    fs::write(&temporary, serde_json::to_vec_pretty(value)?)?;
    fs::rename(temporary, path)?;
    Ok(())
}

pub fn protected_secret(name: &str, create: impl FnOnce() -> Vec<u8>) -> Result<Vec<u8>> {
    use std::{
        io::Write,
        time::{Duration, Instant},
    };
    let path = data_dir()?.join("Host").join(name);
    fs::create_dir_all(path.parent().unwrap())?;
    if !path.exists() {
        let secret = create();
        let protected = lightray_windows::protect(&secret)?;
        match fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&path)
        {
            Ok(mut file) => {
                file.write_all(&protected)?;
                file.sync_all()?;
                return Ok(secret);
            }
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {}
            Err(error) => return Err(error.into()),
        }
    }
    // A concurrent settings UI or agent may still be finishing exclusive initialization.
    let deadline = Instant::now() + Duration::from_secs(2);
    loop {
        let protected = fs::read(&path)?;
        if !protected.is_empty() {
            return lightray_windows::unprotect(&protected);
        }
        if Instant::now() >= deadline {
            bail!("The stored secret is incomplete; the file was preserved");
        }
        std::thread::sleep(Duration::from_millis(10));
    }
}

pub fn computers() -> Result<Vec<SavedComputer>> {
    load_json(&data_dir()?.join("Client/computers.json"))
}
pub fn remember(computer: SavedComputer) -> Result<()> {
    if computer.name.len() > 256 || computer.address.len() > 1024 {
        bail!("Computer name or address is too long");
    }
    let mut entries = computers()?;
    entries.retain(|entry| entry.pairing_id != computer.pairing_id);
    if entries.len() >= 100 {
        bail!("Saved computer limit reached");
    }
    entries.push(computer);
    save_json(&data_dir()?.join("Client/computers.json"), &entries)
}
pub fn forget(pairing_id: &str) -> Result<()> {
    let mut entries = computers()?;
    entries.retain(|entry| entry.pairing_id != pairing_id);
    save_json(&data_dir()?.join("Client/computers.json"), &entries)
}

pub fn log(message: &str) {
    use std::io::Write;
    if let Ok(directory) = data_dir() {
        let directory = directory.join("Logs");
        let _ = fs::create_dir_all(&directory);
        let path = directory.join("host.log");
        if fs::metadata(&path).is_ok_and(|value| value.len() > 4 * 1024 * 1024) {
            let _ = fs::rename(&path, directory.join("host.previous.log"));
        }
        if let Ok(mut file) = fs::OpenOptions::new().create(true).append(true).open(path) {
            let seconds = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or_default()
                .as_secs();
            let _ = writeln!(file, "{seconds} {message}");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn settings_reject_invalid_and_future_values() {
        let mut settings = HostSettings::default();
        assert!(settings.validate().is_ok());
        settings.version = 2;
        assert!(settings.validate().is_err());
        settings.version = 1;
        settings.port = 0;
        assert!(settings.validate().is_err());
        settings.port = 7373;
        settings.max_height = 1081;
        assert!(settings.validate().is_err());
    }
}
