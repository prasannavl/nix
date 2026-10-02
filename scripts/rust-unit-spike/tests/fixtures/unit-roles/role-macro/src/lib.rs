use proc_macro::TokenStream;

// The build-host label may unify with the macro-host label.
const _: () = assert!(
    role_shared::HOST_MACRO && !role_shared::TARGET_ONLY && !role_shared::DEV_ONLY,
    "proc macro requires host-only feature labels"
);
const _: () = assert!(role_shared::host_macro::value() == 17);

#[proc_macro]
pub fn role_value(input: TokenStream) -> TokenStream {
    assert!(input.is_empty(), "role_value takes no input");
    "17u32".parse().expect("fixed constant tokens")
}
