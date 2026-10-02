#[cfg(all(
    any(feature = "host-build", feature = "host-macro"),
    any(feature = "target-only", feature = "dev-only")
))]
compile_error!("role-shared: target/dev feature labels leaked into host features");

pub const TARGET_ONLY: bool = cfg!(feature = "target-only");
pub const HOST_BUILD: bool = cfg!(feature = "host-build");
pub const HOST_MACRO: bool = cfg!(feature = "host-macro");
pub const DEV_ONLY: bool = cfg!(feature = "dev-only");

pub const FEATURE_LABELS: &[&str] = &[
    #[cfg(feature = "target-only")]
    "target-only",
    #[cfg(feature = "host-build")]
    "host-build",
    #[cfg(feature = "host-macro")]
    "host-macro",
    #[cfg(feature = "dev-only")]
    "dev-only",
];

#[cfg(feature = "target-only")]
pub mod target {
    pub const fn value() -> u32 {
        7
    }
}

#[cfg(feature = "host-build")]
pub mod host_build {
    pub const fn value() -> u32 {
        11
    }
}

#[cfg(feature = "host-macro")]
pub mod host_macro {
    pub const fn value() -> u32 {
        17
    }
}

#[cfg(feature = "dev-only")]
pub mod dev {
    pub const fn value() -> u32 {
        23
    }
}
