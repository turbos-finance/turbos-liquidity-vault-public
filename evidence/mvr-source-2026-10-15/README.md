# Current-release source verification — 2026-10-15

Package: `0x0ca0dbe2da5ea7c7b0d0d0796e7918413f9328c4e4bf72e2f6bcd8bf3c993c45` (version 8).
Production source anchor: `5a2996c38c7be786ec3cf943a7b3f5358b17b79d`.

Only publication metadata and dependency configuration were changed. Existing public production sources and tests remain unchanged. Historical deployment toolchain information in Published.toml is preserved; verification was run with Sui 1.66.2-a9a6825eaf62.

## Reproduce without publishing a transaction

Use Sui 1.66.2, clone this public repository at this metadata commit, then run:

```sh
sui move build --build-env mainnet --silence-warnings --no-lint
sui client verify-source --build-env mainnet --silence-warnings --no-lint
```

Both commands are read-only with respect to the chain. The client must be configured for mainnet; no funded account or signing key is required. Framework dependencies are pinned to immutable HTTPS commits; no private repository or sibling checkout is required.

Result: official source verification passed; all **5/5 root module BCS blobs** match deployed bytes exactly, without normalization or exceptions. See [verification.json](verification.json), [verify-source.log](verify-source.log), and [bytecode.json](bytecode.json). This checks root source and dependency storage-ID linkage, not all dependency source bytecode (no --verify-deps).

## MVR integration status

The current-version GitInfo must be updated to this metadata commit by the PackageInfo owner. Until that transaction is executed and a fresh-cache `mvr add @turbos/vault/8` consumer build passes, this report is not a completed public MVR-consumer validation. Historical GitInfo backfill is outside this update.

Tests and coverage remain documented in the October 14 evidence. This metadata update neither adds tests nor claims complete authorization/invariant coverage or audit closure. No unpublished Fun production changes are included.
