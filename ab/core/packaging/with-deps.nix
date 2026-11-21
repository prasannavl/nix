{callPackage}: dependencies: build:
build (builtins.mapAttrs (
    _name: dependency:
      if builtins.isPath dependency
      then callPackage dependency {}
      else dependency
  )
  dependencies)
