use std::{env, fs, path::PathBuf};

const _: () = assert!(
    role_build_helper::FEATURES_VALID,
    "build script requires host-only shared feature labels"
);
const _: () = assert!(role_build_helper::value() == 11);

fn main() {
    println!("cargo:rerun-if-changed=input.txt");
    let manifest_dir =
        PathBuf::from(env::var_os("CARGO_MANIFEST_DIR").expect("manifest directory"));
    let input = fs::read_to_string(manifest_dir.join("input.txt")).expect("checked-in input.txt");
    assert_eq!(input, "role-input-v1\n", "unexpected fixture input");
    println!("cargo:rustc-env=ROLE_INPUT={}", input.trim_end());
}
