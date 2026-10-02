// The other host label may unify; target/dev labels must not.
pub const FEATURES_VALID: bool =
    role_shared::HOST_BUILD && !role_shared::TARGET_ONLY && !role_shared::DEV_ONLY;

const _: () = assert!(
    FEATURES_VALID,
    "build helper requires host-only feature labels"
);

pub const fn value() -> u32 {
    role_shared::host_build::value()
}
