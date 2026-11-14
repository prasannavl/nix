# Graphiti core compatibility

The package's lightweight unit tests use dependency doubles. The `run.py` manual
qualification entrypoint runs both those tests and the real-core suite, in
separate processes so doubles cannot mask a broken real-client contract. It
fails if any direct dependency differs from `requirements.txt`; it never skips
missing dependencies. Run it before promoting a wrapper or Graphiti image
update:

```sh
python -m venv tmp/graphiti-contract-venv
tmp/graphiti-contract-venv/bin/python -m pip install \
  -r pkgs/support/zep-graphiti/tests/requirements.txt
GRAPHITI_TELEMETRY_ENABLED=false \
  tmp/graphiti-contract-venv/bin/python \
  pkgs/support/zep-graphiti/tests/run.py
```

On NixOS, binary NumPy wheels also need the compiler runtime available through
`LD_LIBRARY_PATH` in this temporary Python environment. Use the runtime exported
by the local Nix development environment.

## Manual qualification gate

Run the pinned-venv command above explicitly before promotion, following the
existing `tests/requirements.txt` dependency policy. The combined gate runs **23
tests: 7 lightweight and 16 real-core contracts**.

The ordinary package `checkPhase` remains dependency-light and does **not** run
the core suite. Root flake checks do not run the real-core suite either. A
successful ordinary package build or root flake check is not core-contract
acceptance. This port adds no Graphiti Nix dependency graph or CI machinery.

## Inference bindings

- Chat retains `OPENAI_API_KEY` (default `ollama`), `OPENAI_BASE_URL`,
  `MODEL_NAME` and `SMALL_MODEL_NAME`.
- Set **both** `EMBEDDING_API_KEY` and `EMBEDDING_BASE_URL` to non-blank values
  for an independent embedding binding. `EMBEDDING_MODEL_NAME` remains
  independent (default `nomic-embed-text`).
- When **both** new variables are absent, existing public callers keep the
  previous shared chat key/base, including upstream defaults. A partial or blank
  pair fails before constructing either client: it must not silently send the
  chat key to a new embedding endpoint.
- New callers should always supply the explicit pair, even when both clients use
  the same server. Compatibility fallback is not endpoint discovery or failover.

## Release qualification

`../release.json` owns the reviewed full image and its actual core version.
Consumers that pin an image should assert that it matches the record exposed by
`pkgs.zep-graphiti.graphitiRelease`. This package does not select or evaluate a
host deployment. The suite checks the installed core and the requirements pin
against the same record; changing only the record's core target fails these
tests in the old environment.

For the next update, inspect the final image's actual library version, review
API and data changes, adapt the wrapper, then update the host image, release
record and test dependency pins together. Recreate the isolated test environment
and pass these tests before deployment acceptance. Remaining pins match the
candidate server lock; its Dockerfile upgrades core after resolving that lock.
An image tag alone does not prove the Python API version.

Rollback restores the prior paired host image and wrapper generation. This new
record describes the new pair only: it does not relabel the historical image
0.22.0, whose actual installed core was 0.13.2.

Tests load real Graphiti classes, prompt schemas, superclass dispatch and retry
logic. Binding tests send real chat/embed HTTP requests to ephemeral loopback
servers and assert distinct paths, credentials, model IDs and client options;
legacy shared bindings and defaults are covered too. Only the Graphiti database
constructor is replaced for those tests. Other dispatch tests use synthetic
OpenAI `ChatCompletion` models. No live inference, Neo4j, telemetry, credentials
or graph writes are needed. The suite also checks historical Neo4j record
decoding, index creation queries and the private bulk property hook.

This does not prove extraction quality, Cypher execution, index readiness or
existing-data preservation on a running Neo4j server. Validate those separately
after deployment, and use an authorized disposable graph for ingestion and
MiroFish simulation acceptance. Keep Neo4j major upgrades as a separate phase.
