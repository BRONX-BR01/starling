/// The other lasers' pass, then the downfall's, the planet killer's, the crystal bloom's and the sinkhole's.
const PASS_OWN: [&str; 5] = [include_str!("../data/shaders/strike.wgsl"), include_str!("../data/gen/pass_downfall.wgsl"), include_str!("../data/gen/pass_planetkiller.wgsl"), include_str!("../data/gen/pass_crystalbloom.wgsl"), include_str!("../data/gen/pass_sinkhole.wgsl")];
/// The Payload's at QUALITY FULL and FAST.
const PASS_PAYLOAD: [&str; 2] = [include_str!("../data/gen/pass_payload_false.wgsl"), include_str!("../data/gen/pass_payload_true.wgsl")];
/// The Nuke's at QUALITY FULL and FAST.
const PASS_NUKE: [&str; 2] = [include_str!("../data/gen/pass_nuke_false.wgsl"), include_str!("../data/gen/pass_nuke_true.wgsl")];
/// The Rod from God's at QUALITY FULL and FAST.
const PASS_ROD: [&str; 2] = [include_str!("../data/gen/pass_rod_false.wgsl"), include_str!("../data/gen/pass_rod_true.wgsl")];
/// The Supercell's at QUALITY FULL and FAST.
const PASS_SUPERCELL: [&str; 2] = [include_str!("../data/gen/pass_supercell_false.wgsl"), include_str!("../data/gen/pass_supercell_true.wgsl")];
/// The Hurricane's at QUALITY FULL and FAST.
const PASS_HURRICANE: [&str; 2] = [include_str!("../data/gen/pass_hurricane_false.wgsl"), include_str!("../data/gen/pass_hurricane_true.wgsl")];
/// The Supervolcano's at QUALITY FULL and FAST.
const PASS_VOLCANO: [&str; 2] = [include_str!("../data/gen/pass_volcano_false.wgsl"), include_str!("../data/gen/pass_volcano_true.wgsl")];
/// The Tsunami's at QUALITY FULL and FAST.
const PASS_TSUNAMI: [&str; 2] = [include_str!("../data/gen/pass_tsunami_false.wgsl"), include_str!("../data/gen/pass_tsunami_true.wgsl")];
/// The Sky Breaks' at QUALITY FULL and FAST.
const PASS_SKYBREAK: [&str; 2] = [include_str!("../data/gen/pass_skybreak_false.wgsl"), include_str!("../data/gen/pass_skybreak_true.wgsl")];
/// The Carpet Bomb's at QUALITY FULL and FAST.
const PASS_CARPET: [&str; 2] = [include_str!("../data/gen/pass_carpet_false.wgsl"), include_str!("../data/gen/pass_carpet_true.wgsl")];
/// The Fold's (no half-size stage: its cost is the warp, drawn whole).
const PASS_FOLD: &str = include_str!("../data/gen/pass_fold.wgsl");
