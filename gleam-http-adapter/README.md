# Necoherence HTTP adapter for Gleam

[Project overview](https://github.com/barineco/necoherence/blob/publish/README.md) | [日本語](README-ja.md)

This optional MIT package executes Necoherence network-effect commands with `gleam_httpc` on Erlang.
It depends on the core `necoherence` package at version 0.2.x.
The core provides the ledger and a caller-supplied host port without a dependency on an HTTP client.

```bash
gleam add necoherence_http_adapter
```

```gleam
import necoherence_http_adapter as http

pub fn ports() {
  http.host_port(http.default_ports())
}
```

The returned port supplies `semantic_signature_http.Binding` and composition runtime network owners.
The adapter also provides lower-level execution functions:

- `start`: begin an issued command
- `observe`: read the next observation
- `cancel`: request cancellation
- `close`: close an execution

Source development uses the network-effect comparison test package. Its direct path dependencies select both packages from this repository. The adapter's manifest declares the core's Hex version requirement.

```bash
cd ../comparison/network_effect/gleam_driver
gleam format --check
gleam build --warnings-as-errors
gleam test
```

After the core version is available on Hex, run `gleam export hex-tarball` from the adapter directory to build its publishable archive. Gleam resolves the declared Hex dependency before exporting the archive.

[MIT License](LICENSE)
