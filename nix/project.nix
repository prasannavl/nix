let
  ab = import ../ab;
in
  ab.core.project {
    projectRoot = ../.;
    treefmtConfig = ../treefmt.toml;
  }
