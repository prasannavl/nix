# Open WebUI Ollama Host Alias Firewall 2026-04

`pvl-a1` and `pvl-x2` use the same basic Open WebUI plus Ollama Podman Compose
layout: Open WebUI talks to Ollama through a host alias
(`host.containers.internal` in repo config, `host.docker.internal` in Open
WebUI's persisted config defaults), while Ollama is published on host port
`11434`.

The important host-specific difference was firewall policy, not Compose
networking. `pvl-x2` already opened TCP `11434` through
`services.podman-compose...exposedPorts.<name>.openFirewall = true;`, while
`pvl-a1` did not.

Observed behavior:

- On `pvl-a1`, `open-webui` could resolve both host aliases but timed out
  reaching `169.254.1.2:11434`.
- On `pvl-x2`, Ollama was receiving successful requests from Open WebUI with the
  same basic host-alias pattern.

Durable fix for this pattern on `pvl-a1`: open the published Ollama port in the
host firewall by setting `openFirewall = true` on the exposed Ollama port.
