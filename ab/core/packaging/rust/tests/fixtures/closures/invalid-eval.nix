# This file must fail evaluation: TOML parse errors deliberately throw.
(import ../../../closures.nix).plan {src = ./invalid;}
