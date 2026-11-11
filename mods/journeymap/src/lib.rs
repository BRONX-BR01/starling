//! JourneyMap in Rust, as a Stink mod: full-screen map (key M or `/jm`) and waypoints.
mod app;
mod color;
mod grid;
mod overlay;
mod view;
mod waypoint;

wit_bindgen::generate!({
    path: "../../crates/horizon-mod-sdk/wit-stink",
    world: "horizon-mod",
});

use app::JourneyMap;
export!(JourneyMap);
