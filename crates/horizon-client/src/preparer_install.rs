//! Commit prepared resources without deleting the last installation before the rename succeeds.
use std::{fs, path::Path};

pub(super) fn activate(made: &Path, destination: &Path) -> Result<(), String> {
    if made == destination {
        return Ok(());
    }
    let parent = destination
        .parent()
        .ok_or("Resource folder has no parent")?;
    let name = destination
        .file_name()
        .ok_or("Resource folder has no name")?
        .to_string_lossy();
    let backup = parent.join(format!(".{name}.starling-previous"));
    fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    // Recover a stop between moving the old folder and publishing the new one.
    if backup.exists() && !destination.exists() {
        fs::rename(&backup, destination)
            .map_err(|e| format!("Cannot restore previous resources: {e}"))?;
    }
    if backup.exists() {
        fs::remove_dir_all(&backup)
            .map_err(|e| format!("Cannot retire previous resource backup: {e}"))?;
    }
    let previous = destination.exists();
    if previous {
        fs::rename(destination, &backup)
            .map_err(|e| format!("Cannot preserve previous resources: {e}"))?;
    }
    if let Err(error) = fs::rename(made, destination) {
        if previous && let Err(restore) = fs::rename(&backup, destination) {
            return Err(format!(
                "Cannot activate resources: {error}; previous resources remain at {} (restore failed: {restore})",
                backup.display()
            ));
        }
        return Err(format!(
            "Cannot activate resources: {error}; previous resources preserved"
        ));
    }
    if previous && let Err(error) = fs::remove_dir_all(&backup) {
        log::warn!("Resources installed; old resource backup could not be removed: {error}");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    fn root() -> std::path::PathBuf {
        let path = std::env::temp_dir().join(format!(
            "starling-resource-swap-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&path).unwrap();
        path
    }
    #[test]
    fn failed_publish_restores_old_resources_and_a_retry_replaces_them() {
        let dir = root();
        let target = dir.join("resources");
        let made = dir.join("prepared");
        fs::create_dir(&target).unwrap();
        fs::write(target.join("kept"), "old resources").unwrap();
        assert!(activate(&made, &target).is_err());
        assert_eq!(
            fs::read_to_string(target.join("kept")).unwrap(),
            "old resources"
        );
        fs::create_dir(&made).unwrap();
        fs::write(made.join("ready"), "new resources").unwrap();
        activate(&made, &target).unwrap();
        assert_eq!(
            fs::read_to_string(target.join("ready")).unwrap(),
            "new resources"
        );
        assert!(!made.exists());
        assert!(!dir.join(".resources.starling-previous").exists());
        fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn interrupted_swap_restores_before_a_failed_retry() {
        let dir = root();
        let target = dir.join("resources");
        let backup = dir.join(".resources.starling-previous");
        fs::create_dir(&backup).unwrap();
        fs::write(backup.join("kept"), "last working resources").unwrap();
        assert!(activate(&dir.join("missing"), &target).is_err());
        assert_eq!(
            fs::read_to_string(target.join("kept")).unwrap(),
            "last working resources"
        );
        fs::remove_dir_all(dir).unwrap();
    }
}
