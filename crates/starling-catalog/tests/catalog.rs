//! What the catalog decides by itself: no network here.
use serde_json::json;
use starling_catalog::browser::{Kind, Project, SourceId};
use starling_catalog::{caution, installed_projects, is_native_mod, is_shader_pack, shader_hits};
use std::io::Write;
use std::path::PathBuf;

fn folder(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("starling-catalog-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

fn zip_with(path: &PathBuf, names: &[&str]) {
    let mut zip = zip::ZipWriter::new(std::fs::File::create(path).unwrap());
    for name in names {
        zip.start_file(*name, zip::write::SimpleFileOptions::default())
            .unwrap();
        zip.write_all(b"x").unwrap();
    }
    zip.finish().unwrap();
}

fn project(kind: Kind, source: SourceId, game_versions: &[&str], loaders: &[&str]) -> Project {
    Project {
        source,
        id: "id".into(),
        slug: "slug".into(),
        title: "Title".into(),
        summary: String::new(),
        author: String::new(),
        downloads: 0,
        page: String::new(),
        icon: None,
        license: String::new(),
        kind,
        game_versions: game_versions.iter().map(|v| v.to_string()).collect(),
        loaders: loaders.iter().map(|l| l.to_string()).collect(),
    }
}

#[test]
fn a_shader_search_answer_becomes_shader_packs() {
    let found = json!({"hits": [
        {
            "project_id": "abc",
            "slug": "complementary",
            "title": "Complementary",
            "description": "Shaders",
            "author": "EminGT",
            "downloads": 12,
            "icon_url": "",
            "versions": ["1.21"],
            "categories": ["iris", "optifine"]
        },
        {"slug": "no-id"}
    ]});
    let hits = shader_hits(&found);
    assert_eq!(hits.len(), 1);
    let hit = &hits[0];
    assert_eq!(hit.kind, Kind::Shader);
    assert_eq!(hit.source, SourceId::Modrinth);
    assert_eq!(hit.id, "abc");
    assert_eq!(hit.page, "https://modrinth.com/shader/complementary");
    assert_eq!(hit.icon, None);
    assert_eq!(hit.game_versions, ["1.21"]);
}

#[test]
fn an_answer_with_no_hits_is_empty() {
    assert!(shader_hits(&json!({})).is_empty());
}

#[test]
fn a_modrinth_shader_pack_carries_no_caution() {
    let pack = project(Kind::Shader, SourceId::Modrinth, &[], &["iris"]);
    assert_eq!(caution(&pack), None);
}

#[test]
fn an_older_resource_pack_says_so_and_a_current_one_does_not() {
    let old = project(Kind::ResourcePack, SourceId::Modrinth, &["1.20.1"], &[]);
    assert!(caution(&old).is_some_and(|why| why.contains("1.20.1")));
    let current = project(
        Kind::ResourcePack,
        SourceId::Modrinth,
        &[starling_catalog::browser::GAME],
        &[],
    );
    assert_eq!(caution(&current), None);
}

#[test]
fn a_modrinth_project_is_never_a_native_mod() {
    assert!(!is_native_mod(&project(
        Kind::Mod,
        SourceId::Modrinth,
        &[],
        &[]
    )));
}

#[test]
fn a_shader_pack_has_a_shaders_folder_at_its_top_or_in_its_one_folder() {
    let dir = folder("shader-zip");
    let zip = dir.join("pack.zip");
    zip_with(&zip, &["shaders/final.fsh"]);
    assert_eq!(is_shader_pack(&zip), Ok(true));
    zip_with(&zip, &["BSL/shaders/final.fsh"]);
    assert_eq!(is_shader_pack(&zip), Ok(true));
    zip_with(&zip, &["assets/minecraft/shaders/core.json"]);
    assert_eq!(is_shader_pack(&zip), Ok(false));
    zip_with(&zip, &["pack.mcmeta"]);
    assert_eq!(is_shader_pack(&zip), Ok(false));
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn nothing_installed_is_an_empty_list() {
    let dir = folder("empty");
    assert!(installed_projects(&dir).is_empty());
    std::fs::remove_dir_all(dir).unwrap();
}
