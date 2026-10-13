# This file must fail evaluation: TOML parse errors deliberately throw.
(import ../../../rust-closures.nix).plan {src = ./invalid;}
