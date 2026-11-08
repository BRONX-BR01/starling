<<<<<<< HEAD
//! Wavefront OBJ meshes, as NeoForge's OBJ model loader (`"loader": "neoforge:obj"`) gives mods'
//! blocks their shapes: vertices in block units, faces of three or four corners (more are fanned
//! into triangles), each face's material from the MTL file, whose `map_Kd` names a texture slot
//! of the model (`#planks`).
use crate::json::{Result, error};
use std::collections::HashMap;

/// One face of a mesh model: four corners in block units (a triangle repeats its last), their
/// unit-atlas UVs, and the texture slot it is drawn with (`#planks`).
#[derive(Clone, Debug, PartialEq)]
pub struct MeshFace {
    pub positions: [[f32; 3]; 4],
    pub uv: [[f32; 2]; 4],
    pub texture: String,
}

/// The texture slot each material of an MTL file names (`newmtl` then `map_Kd`).
pub fn materials(mtl: &str) -> HashMap<String, String> {
    let mut out = HashMap::new();
    let mut current = None;
    for line in mtl.lines() {
        let mut words = line.split_whitespace();
        match words.next() {
            Some("newmtl") => current = words.next().map(str::to_owned),
            Some("map_Kd") => {
                if let (Some(name), Some(texture)) = (&current, words.next()) {
                    out.insert(name.clone(), texture.to_owned());
                }
            }
            _ => {}
        }
    }
    out
}

/// The faces of a `neoforge:obj` model's mesh: its OBJ file (`<ns>:<path>.obj`, at
/// `assets/<ns>/<path>`) and the MTL naming its materials' slots, beside it or by identifier,
/// each read by `read` from its path (`assets/...`). A missing MTL leaves each material a slot of
/// its own name.
pub fn read_mesh(
    source: &crate::model::ObjSource,
    read: impl Fn(&str) -> Option<String>,
) -> Result<Vec<MeshFace>> {
    let path = |id: &str| {
        let (namespace, path) = id.split_once(':').unwrap_or(("minecraft", id));
        format!("assets/{namespace}/{path}")
    };
    let file = path(&source.model);
    let text = read(&file).ok_or_else(|| error("OBJ file not found"))?;
    let materials = material_library(&text)
        .and_then(|lib| match lib.contains(':') {
            true => read(&path(lib)),
            false => read(&match file.rsplit_once('/') {
                Some((dir, _)) => format!("{dir}/{lib}"),
                None => lib.to_owned(),
            }),
        })
        .map(|mtl| materials(&mtl))
        .unwrap_or_default();
    parse(&text, &materials, source.flip_v)
}

/// The `mtllib` an OBJ file names, if any.
pub fn material_library(obj: &str) -> Option<&str> {
    obj.lines()
        .find_map(|line| line.strip_prefix("mtllib "))
        .map(str::trim)
}

/// The faces of an OBJ file, their materials' slots from `materials` (a material it does not name
/// is a slot of its own name); `flip_v` turns the UVs' v upside down (OBJ's v grows upwards).
pub fn parse(
    obj: &str,
    materials: &HashMap<String, String>,
    flip_v: bool,
) -> Result<Vec<MeshFace>> {
    let number = |s: Option<&str>| -> Result<f32> {
        s.and_then(|s| s.parse::<f32>().ok())
            .filter(|v| v.is_finite())
            .ok_or_else(|| error("invalid OBJ number"))
    };
    let (mut vertices, mut uvs) = (Vec::new(), Vec::new());
    let mut texture = String::from("#missing");
    let mut faces = Vec::new();
    for line in obj.lines() {
        let mut words = line.split_whitespace();
        match words.next() {
            Some("v") => vertices.push([
                number(words.next())?,
                number(words.next())?,
                number(words.next())?,
            ]),
            Some("vt") => {
                let (u, v) = (number(words.next())?, number(words.next())?);
                uvs.push([u, if flip_v { 1.0 - v } else { v }]);
            }
            Some("usemtl") => {
                let name = words.next().unwrap_or_default();
                texture = match materials.get(name) {
                    Some(slot) => slot.clone(),
                    None => format!("#{name}"),
                };
            }
            Some("f") => {
                // v, v/vt, v/vt/vn or v//vn, 1-based (negative: from the end).
                let corner = |word: &str| -> Result<([f32; 3], [f32; 2])> {
                    let mut parts = word.split('/');
                    let index = |s: Option<&str>, len: usize| -> Option<usize> {
                        let i: i64 = s?.parse().ok()?;
                        let i = if i < 0 { len as i64 + i } else { i - 1 };
                        usize::try_from(i).ok().filter(|i| *i < len)
                    };
                    let v = index(parts.next(), vertices.len())
                        .ok_or_else(|| error("OBJ face names no vertex"))?;
                    let uv = index(parts.next(), uvs.len()).map_or([0.0, 0.0], |i| uvs[i]);
                    Ok((vertices[v], uv))
                };
                let corners = words.map(corner).collect::<Result<Vec<_>>>()?;
                if corners.len() < 3 {
                    continue;
                }
                // Quads as they are; triangles and larger polygons as a fan of triangles.
                let fans: Vec<[usize; 4]> = if corners.len() == 4 {
                    vec![[0, 1, 2, 3]]
                } else {
                    (1..corners.len() - 1)
                        .map(|i| [0, i, i + 1, i + 1])
                        .collect()
                };
                for fan in fans {
                    faces.push(MeshFace {
                        positions: fan.map(|i| corners[i].0),
                        uv: fan.map(|i| corners[i].1),
                        texture: texture.clone(),
                    });
                }
            }
            _ => {}
        }
    }
    Ok(faces)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn faces_take_their_materials_slots_and_triangles_become_quads() {
        let mtl = "newmtl axle\nmap_Kd #axis\n\nnewmtl plank\nmap_Kd #planks\n";
        let obj = "mtllib wheel.mtl\no Wheel\nv 0 0 0\nv 1 0 0\nv 1 1 0\nv 0 1 0\n\
                   vt 0 0\nvt 1 0\nvt 1 1\nvt 0 1\nusemtl axle\nf 1/1/1 2/2/1 3/3/1 4/4/1\n\
                   usemtl plank\nf 1/1 2/2 3/3\nusemtl other\nf -4 -3 -2 -1 1\n";
        assert_eq!(material_library(obj), Some("wheel.mtl"));
        let faces = parse(obj, &materials(mtl), true).unwrap();
        assert_eq!(faces.len(), 1 + 1 + 3);
        assert_eq!(faces[0].texture, "#axis");
        // v grows down in the atlas: flipped.
        assert_eq!(faces[0].uv[0], [0.0, 1.0]);
        assert_eq!(faces[0].positions[2], [1.0, 1.0, 0.0]);
        // A triangle repeats its last corner.
        assert_eq!(faces[1].texture, "#planks");
        assert_eq!(faces[1].positions[2], faces[1].positions[3]);
        // A material the MTL does not name is a slot of its own name; five corners, three faces.
        assert_eq!(faces[2].texture, "#other");
        assert!(parse("f 1 2 3\n", &HashMap::new(), false).is_err());
        // Read beside each other: the MTL in the OBJ's folder.
        let files = HashMap::from([
            ("assets/horizon/models/block/wheel.obj", obj),
            ("assets/horizon/models/block/wheel.mtl", mtl),
        ]);
        let source = crate::model::ObjSource {
            model: "horizon:models/block/wheel.obj".into(),
            flip_v: true,
        };
        let read = |path: &str| files.get(path).map(|s| s.to_string());
        assert_eq!(read_mesh(&source, read).unwrap(), faces);
        assert!(read_mesh(&source, |_| None).is_err());
    }

    #[test]
    fn a_mesh_bakes_with_its_models_slots_turned_as_the_blockstate_turns_it() {
        use crate::{bake::*, model::*, resolve::ModelLibrary};
        let mut model = CuboidModel::from_json(
            r#"{"loader":"neoforge:obj","model":"horizon:models/block/x.obj","flip_v":true,
                "textures":{"planks":"block/oak_planks"}}"#,
        )
        .unwrap();
        let source = model.obj.as_ref().unwrap();
        assert!(source.flip_v && source.model == "horizon:models/block/x.obj");
        // An OBJ model is the geometry, with no elements of its own.
        assert_eq!(model.elements.as_deref().map(<[_]>::len), Some(0));
        let obj = "v 0 0 0\nv 1 0 0\nv 1 1 0\nv 0 1 0\nvt 0 0\nvt 1 0\nvt 1 1\nvt 0 1\n\
                   usemtl plank\nf 1/1 2/2 3/3 4/4\nusemtl gone\nf 1 2 3\n";
        let mtl = materials("newmtl plank\nmap_Kd #planks\nnewmtl gone\nmap_Kd #absent\n");
        model.mesh = Some(std::sync::Arc::new(parse(obj, &mtl, true).unwrap()));
        let library = ModelLibrary::new(std::collections::BTreeMap::from([(
            "horizon:x".into(),
            model,
        )]))
        .unwrap();
        let resolved = library.resolve("horizon:x").unwrap();
        let turn = BlockModelTransform::new([0, 1, 0], false);
        let quads = bake_block_model(&resolved, turn).unwrap();
        assert_eq!(quads.len(), 2);
        assert_eq!(quads[0].material.sprite, "minecraft:block/oak_planks");
        assert_eq!(quads[1].material.sprite, "minecraft:missingno");
        // The face looks south (+z) in the file, turned with the block.
        assert_eq!(quads[0].facing, turn.direction(Direction::South));
        assert_ne!(quads[0].facing, Direction::South);
        assert_eq!(quads[0].cull, None);
||||||| 31f83499b6
=======
//! Wavefront OBJ and MTL text, as obj-loader models use them.
use std::collections::BTreeMap;

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ObjVertex {
    /// Block units.
    pub position: [f32; 3],
    /// Texture coordinates as written, 0..1 across the sprite.
    pub uv: [f32; 2],
}
/// One quad; a triangle repeats its last vertex.
#[derive(Clone, Debug, PartialEq)]
pub struct ObjFace {
    /// Empty before any `usemtl`.
    pub material: String,
    /// The `o` (else `g`) it belongs to, which a model's `visibility` names.
    pub object: String,
    pub vertices: [ObjVertex; 4],
}
#[derive(Clone, Debug, Default, PartialEq)]
pub struct ParsedObj {
    pub mtllib: Option<String>,
    pub faces: Vec<ObjFace>,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum MtlTexture {
    /// `map_Kd #name`: a texture slot of the model.
    Slot(String),
    /// `map_Kd namespace:path`: a sprite.
    Sprite(String),
}
/// A parsed OBJ with its materials.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct ObjModel {
    pub faces: Vec<ObjFace>,
    pub materials: BTreeMap<String, MtlTexture>,
}

pub fn parse_obj(text: &str) -> Result<ParsedObj, String> {
    let mut positions: Vec<[f32; 3]> = Vec::new();
    let mut uvs: Vec<[f32; 2]> = Vec::new();
    let mut parsed = ParsedObj::default();
    let mut material = String::new();
    let mut object = String::new();
    for (number, line) in text.lines().enumerate() {
        let mut words = line.split_whitespace();
        let Some(keyword) = words.next() else {
            continue;
        };
        let at = |message: &str| format!("line {}: {message}", number + 1);
        match keyword {
            _ if keyword.starts_with('#') => {}
            "v" => positions.push(floats::<3>(words).ok_or_else(|| at("bad vertex"))?),
            "vt" => {
                let mut words = words;
                let u = words.next().and_then(|w| w.parse().ok());
                let v = words.next().map_or(Some(0.0), |w| w.parse().ok());
                let (Some(u), Some(v)) = (u, v) else {
                    return Err(at("bad texture coordinate"));
                };
                uvs.push([u, v]);
            }
            "mtllib" => parsed.mtllib = words.next().map(str::to_owned),
            "usemtl" => material = words.next().unwrap_or("").to_owned(),
            "o" | "g" => object = words.next().unwrap_or("").to_owned(),
            "f" => {
                let mut corners = Vec::new();
                for word in words {
                    let mut parts = word.split('/');
                    let position = index(parts.next(), positions.len())
                        .ok_or_else(|| at("bad vertex index"))?;
                    let uv = match parts.next() {
                        None | Some("") => [0.0; 2],
                        some => {
                            uvs[index(some, uvs.len()).ok_or_else(|| at("bad texture index"))?]
                        }
                    };
                    corners.push(ObjVertex {
                        position: positions[position],
                        uv,
                    });
                }
                if corners.len() < 3 {
                    return Err(at("face needs three vertices"));
                }
                let mut push = |vertices: [ObjVertex; 4]| {
                    parsed.faces.push(ObjFace {
                        material: material.clone(),
                        object: object.clone(),
                        vertices,
                    });
                };
                if corners.len() <= 4 {
                    let last = corners[corners.len() - 1];
                    push(std::array::from_fn(|i| {
                        corners.get(i).copied().unwrap_or(last)
                    }));
                } else {
                    for i in 1..corners.len() - 1 {
                        push([corners[0], corners[i], corners[i + 1], corners[i + 1]]);
                    }
                }
            }
            _ => {}
        }
    }
    Ok(parsed)
}
fn floats<'a, const N: usize>(mut words: impl Iterator<Item = &'a str>) -> Option<[f32; N]> {
    let mut result = [0.0; N];
    for value in &mut result {
        *value = words.next()?.parse().ok()?;
    }
    Some(result)
}
/// A 1-based index, or a negative one counted from the end.
fn index(word: Option<&str>, len: usize) -> Option<usize> {
    let value: i64 = word?.parse().ok()?;
    let index = if value < 0 {
        len as i64 + value
    } else {
        value - 1
    };
    (0..len as i64).contains(&index).then_some(index as usize)
}

/// Material name to its `map_Kd`; other statements are ignored.
pub fn parse_mtl(text: &str) -> BTreeMap<String, MtlTexture> {
    let mut materials = BTreeMap::new();
    let mut current = None;
    for line in text.lines() {
        let mut words = line.split_whitespace();
        match words.next() {
            Some("newmtl") => current = words.next().map(str::to_owned),
            Some("map_Kd") => {
                let (Some(name), Some(value)) = (&current, words.last()) else {
                    continue;
                };
                let texture = match value.strip_prefix('#') {
                    Some(slot) => MtlTexture::Slot(slot.to_owned()),
                    None => MtlTexture::Sprite(value.to_owned()),
                };
                materials.insert(name.clone(), texture);
            }
            _ => {}
        }
    }
    materials
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn quads_triangles_and_negative_indices() {
        let text = "mtllib a.mtl\nv 0 0 0\nv 1 0 0\nv 1 1 0\nv 0 1 0\nvt 0 0\nvt 1 0\nvt 1 1\nvt 0 1\n\
                    usemtl first\nf 1/1/1 2/2/1 3/3/1 4/4/1\nusemtl second\nf -4//1 -3//1 -2//1\n";
        let parsed = parse_obj(text).unwrap();
        assert_eq!(parsed.mtllib.as_deref(), Some("a.mtl"));
        assert_eq!(parsed.faces.len(), 2);
        assert_eq!(parsed.faces[0].material, "first");
        assert_eq!(parsed.faces[0].vertices[2].uv, [1.0, 1.0]);
        let triangle = &parsed.faces[1];
        assert_eq!(triangle.material, "second");
        assert_eq!(triangle.vertices[0].position, [0.0, 0.0, 0.0]);
        assert_eq!(triangle.vertices[3], triangle.vertices[2]);
        assert_eq!(triangle.vertices[2].position, [1.0, 1.0, 0.0]);
    }
    #[test]
    fn bad_indices_are_errors() {
        assert!(parse_obj("v 0 0 0\nf 1 2 3\n").is_err());
        assert!(parse_obj("v 0 0 0\nv 1 0 0\nf 1 2\n").is_err());
    }
    #[test]
    fn mtl_maps_slots_and_sprites() {
        let materials =
            parse_mtl("newmtl a\nKd 1 1 1\nmap_Kd #top\nnewmtl b\nmap_Kd mod:block/x\nnewmtl c\n");
        assert_eq!(materials["a"], MtlTexture::Slot("top".into()));
        assert_eq!(materials["b"], MtlTexture::Sprite("mod:block/x".into()));
        assert!(!materials.contains_key("c"));
>>>>>>> c98a51a664
    }
}
