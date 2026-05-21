# Echo — Protobuf and GraphQL schemas

This package holds the wire-format contracts shared between services.

- **`*.proto`** — gRPC service contracts between `core-go` (client) and `ml-py` (server).
  Generated code is written to `gen/` and is `.gitignore`'d; regenerate with
  `make proto-gen` (added when the proto pipeline lands).
- **`schema.graphql`** — the single GraphQL schema exposed to clients. Lives at
  `services/core-go/http/graphql/schema.graphql` once the gateway is wired up
  (T-CORE-* in M2); this directory will hold a copy + tooling.

## Conventions

- **Field names use `snake_case`** per the Protobuf style guide.
- **GraphQL field names use `camelCase`** per `AGENTS.md`.
- **Breaking changes to a `.proto` are forbidden after V1**: only field additions,
  never renumbering or removal. Enforced via `buf` in CI once that lands.
- **All RPCs are versioned in their package name** (`v1`, `v2`, ...). Never reuse
  a package name across breaking versions.

## Acceptance: T-INFRA-001 / T-ML-002

The three service contracts (`TraitScoringService`, `PortraitGenService`,
`ReflectionGenService`) are defined here. Generated Go and Python clients land
when the proto pipeline is implemented; until then services use hand-written
stubs that match these definitions.
