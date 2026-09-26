# crewai on pvl-a1

On 2026-09-26, `pvl-a1` gained the open-source self-hosted
[CrewAI](https://github.com/crewAIInc/crewAI) framework and its `crewai` CLI.
The package is added to `hosts/pvl-a1/packages.nix` in the `# AI` block.

## Why the nixpkgs package was sufficient

- nixpkgs is already pinned to `nixos-26.05`, which provides the top-level
  `crewai` package at version 1.14.4 (MIT) with `meta.mainProgram = "crewai"`.
  The framework and CLI are the same Python distribution, so no repo package
  unit under `pkgs/ext/` or overlay was needed.
- The host already runs Ollama plus a llama-router for local LLM backends.
  CrewAI's models are selected at runtime (LiteLLM), so the host-local backend
  is reachable through runtime environment configuration. No secrets or API keys
  are added to or hardcoded in the Nix configuration; backend selection and any
  credentials stay user/runtime owned.
- The CLI works directly from the package store path, so no Python environment
  wrapper or extra runtime tooling is required for the base install.

## Closure note

The nixpkgs closure is large (~1.7 GiB) because it pulls ChromaDB,
LanceDB/PyArrow, LiteLLM, and the embedding/ML stack. This is a notable but
intentional addition to `environment.systemPackages`, not a build failure.

## Validation

```console
nix build nixpkgs#crewai --no-link --print-out-paths
# -> /nix/store/b23x8c44434203w0c90m1walx4qhiadz-python3.13-crewai-1.14.4

<(store-path)/bin/crewai --help   # exit 0, lists the crewai command groups
<(store-path)/bin/crewai --version # -> crewai, version 1.14.4

nix eval .#nixosConfigurations.pvl-a1.config.system.build.toplevel.drvPath --raw
# -> /nix/store/2ippa0afg55zacprwnf6kmq0i169n7dp-nixos-system-pvl-a1-26.05.20260922.1bc55b9.drv

nix run .#lint
```

The CLI prints benign LiteLLM warnings about the optional Bedrock/SageMaker
(`botocore`) extras being absent; these do not affect local LLM usage.
