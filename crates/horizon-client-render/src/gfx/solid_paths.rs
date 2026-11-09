// Copyright (c) 2026 Ludovic Marie and the Horizon contributors.
// SPDX-License-Identifier: MIT
// Adapted from Vasysik/horizon-android; see THIRD_PARTY_NOTICES.md and LICENSE.
//! Solid terrain through cheaper shaders on Adreno's Vulkan, in the frames whose instances prove
//! they draw the same pixels. Vasysik's Android fork measured them on an Adreno 710. The frames
//! of shader packs and of occlusion culling keep the usual pipelines, and so does a device that
//! refuses these.
use super::adreno::TerrainModule;

/// One solid pass's pipeline for both kinds of section draw.
pub(super) struct Pass {
    sections: wgpu::RenderPipeline,
    /// None without flat draws.
    flat: Option<wgpu::RenderPipeline>,
}

impl Pass {
    fn new(
        terrain: &TerrainModule<'_>,
        (layout, flat_layout): (&wgpu::PipelineLayout, Option<&wgpu::PipelineLayout>),
        buffers: &[Option<wgpu::VertexBufferLayout<'_>>],
        (label, flat_label): (&str, &str),
        (vertex, flat_vertex): (&str, &str),
        fragment: &str,
    ) -> Option<Self> {
        let back = Some(wgpu::Face::Back);
        let sections =
            terrain.pipeline(layout, label, vertex, fragment, buffers, back, true, None)?;
        let flat = match flat_layout {
            Some(layout) => Some(terrain.pipeline(
                layout,
                flat_label,
                flat_vertex,
                fragment,
                // Without the origin buffer.
                &buffers[..1],
                back,
                true,
                None,
            )?),
            None => None,
        };
        Some(Self { sections, flat })
    }
    fn get(&self, flat: bool) -> Option<&wgpu::RenderPipeline> {
        if flat {
            self.flat.as_ref()
        } else {
            Some(&self.sections)
        }
    }
}

/// What a frame's solid passes draw through in place of the usual pipelines.
#[derive(Clone, Copy, Default)]
pub(super) struct FramePasses<'a> {
    cutout: Option<&'a Pass>,
}

impl FramePasses<'_> {
    pub fn cutout(&self, flat: bool) -> Option<&wgpu::RenderPipeline> {
        self.cutout.and_then(|pass| pass.get(flat))
    }
}

pub(super) struct SolidPaths {
    /// The cutout pass without `faded` (terrain.wgsl's `fs_cutout_static`): 21.770/22.101 ms of
    /// GPU time against 20.988/21.247 ms in the fork's measurement, in a tablet's 16-chunk scene.
    static_cutout: Pass,
    pub static_cutout_on: bool,
}

impl SolidPaths {
    /// `flat_bindings`: the flat draws' bind group 1, where they exist.
    pub fn new(
        terrain: &TerrainModule<'_>,
        bindings: &wgpu::BindGroupLayout,
        layout: &wgpu::PipelineLayout,
        flat_bindings: Option<&wgpu::BindGroupLayout>,
        buffers: &[Option<wgpu::VertexBufferLayout<'_>>],
    ) -> Option<Self> {
        let flat_layout = flat_bindings.map(|flat| {
            terrain
                .kept
                .create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
                    label: Some("Flat terrain layout"),
                    bind_group_layouts: &[Some(bindings), Some(flat)],
                    ..Default::default()
                })
        });
        let layouts = (layout, flat_layout.as_ref());
        Some(Self {
            static_cutout: Pass::new(
                terrain,
                layouts,
                buffers,
                (
                    "Terrain cutout without fades",
                    "Terrain cutout without fades (flat)",
                ),
                ("vs_terrain_cutout", "vs_terrain_flat_cutout"),
                "fs_cutout_static",
            )?,
            static_cutout_on: true,
        })
    }

    /// The passes `origins`, the frame's instances, allow.
    pub fn for_frame(&self, origins: &[[f32; 4]]) -> FramePasses<'_> {
        let unfaded = origins.iter().all(|origin| unfaded(origin[3]));
        FramePasses {
            cutout: (self.static_cutout_on && unfaded).then_some(&self.static_cutout),
        }
    }
}

/// A fade's code is what a negative `w` holds (terrain.wgsl's `fade_code`).
fn unfaded(w: f32) -> bool {
    w >= 0.0
}

#[cfg(test)]
mod tests;
