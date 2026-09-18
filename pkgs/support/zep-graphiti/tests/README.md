# Graphiti core compatibility

The package's lightweight unit tests use dependency doubles. Run this separate
suite with the actual target library before promoting a Graphiti image update:

```sh
python -m venv tmp/graphiti-contract-venv
tmp/graphiti-contract-venv/bin/python -m pip install \
  -r pkgs/support/zep-graphiti/tests/requirements.txt
GRAPHITI_TELEMETRY_ENABLED=false \
  tmp/graphiti-contract-venv/bin/python \
  pkgs/support/zep-graphiti/tests/test_core_contract.py
```

On NixOS, binary NumPy wheels also need the compiler runtime available through
`LD_LIBRARY_PATH` in this temporary Python environment. Use the runtime exported
by the local Nix development environment.

`../release.json` owns the reviewed full image and its actual core version. The
host keeps an explicit image for updater discovery and asserts that it matches
this record exposed by `pkgs.zep-graphiti.graphitiRelease`. The suite checks the
installed core and the requirements pin against the same record. An image-only
update fails host evaluation; changing only the record's core target fails these
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
logic. The network completion is replaced with real OpenAI `ChatCompletion`
models, so the suite stays offline and does not write graph data. It also checks
historical Neo4j record decoding, index creation queries and the private bulk
property hook.

This does not prove extraction quality, Cypher execution, index readiness or
existing-data preservation on a running Neo4j server. Validate those separately
after deployment, and use an authorized disposable graph for ingestion and
MiroFish simulation acceptance. Keep Neo4j major upgrades as a separate phase.
