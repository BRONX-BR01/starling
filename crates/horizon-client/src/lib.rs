//! Gameplay and startup, above the reusable client library.
<<<<<<< HEAD
// The Android hooks (android.rs) call into the activity through JNI and the C library.
#![cfg_attr(not(target_os = "android"), forbid(unsafe_code))]
||||||| 31f83499b6
#![forbid(unsafe_code)]
=======
// No `#![recursion_limit]` or other inner attribute horizon-mixins doesn't know here: the
// launcher's horizon-mixins then rejects every native mod targeting this crate (#8169).
#![forbid(unsafe_code)]
>>>>>>> c98a51a664
extern crate self as horizon_client;
pub use horizon_client_lib::*;
#[cfg(target_os = "android")]
pub mod android;
pub mod entry;
pub mod game;
pub mod mod_api;

pub mod diagnostics;
pub mod performance;
