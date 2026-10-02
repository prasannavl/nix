const _: () = assert!(
    role_shared::DEV_ONLY && !role_shared::HOST_BUILD && !role_shared::HOST_MACRO,
    "dev helper requires dev feature and no host feature labels"
);

pub const fn value() -> u32 {
    role_shared::dev::value()
}
