# TODO

- Make nixbot-deploy run --dry in parallel.
  - Fix: The nixbot owned repo clone in fresh dir, so we can eval in parallel
  - Fix: GH workflow, allow on PRs while maintaining review security
  - Fix: Separate staging keys with read only tf state and platform keys
  - Fix: Multiple env keys support
    - Auto selected based on env with nix so rest of the code paths are the same
      intuitive and simple.
    - Design at top level - choices:
      - Different dirs are auto selected
      - File suffixes, same dir.
