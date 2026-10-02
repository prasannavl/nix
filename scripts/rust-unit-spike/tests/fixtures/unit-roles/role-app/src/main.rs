const _: () = assert!(
    role_shared::TARGET_ONLY
        && !role_shared::HOST_BUILD
        && !role_shared::HOST_MACRO
        && !role_shared::DEV_ONLY,
    "app requires exactly target-only feature labels"
);

const MACRO_VALUE: u32 = role_macro::role_value!();
const _: () = assert!(MACRO_VALUE == 17);
const INPUT: &str = env!("ROLE_INPUT");

fn main() {
    println!("{} {MACRO_VALUE} {INPUT}", role_shared::target::value());
}
