# TODO

- Make nixbot-deploy run --dry in parallel.
  - The nixbot owned repo clone in fresh dir, so we can eval in parallel. This
    is needed for PR dry runs, instead of just master.
  - GH workflow, allow on PRs while maintaining review security
  - Separate staging keys with read only tf state and platform keys
  - Needs: Multiple env secrets support
- Multiple env secrets support
  - Auto selected based on env with nix so rest of the code paths are the same
    intuitive and simple.
  - Design at top level - choices:
    - Different dirs are auto selected
    - File suffixes, same dir.
- Security: Split cloudflare dns / platform / apps keys to target specific
  access and reduce blast radius. Currently, it's a single key scoped with the
  needs of all 3.
