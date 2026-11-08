//! Never compiled: `lib.rs` points `launcher` at the launcher's own folder with `#[path]`.
//!
//! horizon-mixins reads every crate in the workspace and doesn't follow that `#[path]`: it looks for
//! this file, and without one every native mod fails to build (E_INVALID_PATH).
