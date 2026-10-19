# Turbos Liquidity Vault - deployed source

Mainnet package version 8:
`0x0ca0dbe2da5ea7c7b0d0d0796e7918413f9328c4e4bf72e2f6bcd8bf3c993c45`.
Original package: `0x0a0d6e83196f523bb0623187d789ce602d1f63b3e7baa02b580df7ff0ccd17e0`.

The deployed source revision is
[`5a2996c38c7be786ec3cf943a7b3f5358b17b79d`](https://github.com/turbos-finance/turbos-liquidity-vault-public/tree/5a2996c38c7be786ec3cf943a7b3f5358b17b79d).
Contract sources and existing tests are unchanged. The audit revisions and fix commits
in its history are also publicly available. Uncommitted development files are excluded.

See [source provenance](evidence/source-provenance.json), [build verification](evidence/build-verification.json),
[audit evidence](audits/README.md), and [security contact](SECURITY.md).

## Architecture

`config` and `acl` govern package version and operator roles. `vault` manages shares,
positions, deposits, withdrawals and rebalance. `rewarder` handles reward accounting.
`router` provides composable entry points. Vaults depend on Turbos CLMM objects.
Setting a strategy's nonzero status also freezes withdrawals; this is a full freeze.

## Reproduction

Use Sui CLI 1.49.2 and the framework revision `25804c243d07` recorded in `Move.lock`.
Resolve TurbosCLMM from the public interface repository using HTTPS:
`https://github.com/turbos-finance/turbos-sui-move-interface.git`, path `clmm`, revision
`2d4b90af960d82f9ea0652747059d78d843a958c` (mainnet-v0.1.4).
The original manifest uses an SSH Git URL; an HTTPS substitution changes dependency
transport only. Pin `published-at` to v8 and the named address to the original package.

```sh
sui move build
sui move test
sui client verify-source
```

The 2026-09-29 verification matched all modules and the CLMM linkage. Sui 1.49.2 also
reported absent linkage entries for system packages `0x3` and `0xb` on the modern node.
This is retained as a qualified result, not an unconditional PASS. A fresh verification
with a compatible node/toolchain is still needed. Coverage reports remain outstanding.

## Current-release metadata verification (2026-10-15)

See [verified build configuration and official source-verification evidence](evidence/mvr-source-2026-10-15/README.md). This update does not change production functions. MVR GitInfo update and a fresh-cache registry-consumer run are separate follow-ups.

## Public MVR consumer result (2026-10-15)

The owner executed the current-version GitInfo update. The official MVR add and a real-import consumer build both passed using a new empty cache for the validation run. See [consumer logs, manifest, lockfile and results](evidence/mvr-consumer-2026-10-15/README.md). This supersedes the earlier metadata-update-pending status, without changing the source commit recorded in MVR.

## Tests in the current checkout (2026-10-15)

The reviewed test changes are now directly tracked in the source/tests tree: **16 passed, 0 failed**. Run `node tools/test-current.mjs NEW_DISPOSABLE_DIRECTORY`. See [current test code, run instructions and results](evidence/tests-current-2026-10-15/README.md). Production bytecode and MVR source links are unchanged. Historical tools/repro overlays and coverage reports retain their original scope.

## Current coverage snapshot (2026-10-19)

All **16/16** current public tests passed unfiltered. Coverage remains **partial (13/16 traced tests)** because full tracing still overflows the stock CLI on macOS and Linux. See [current scope, reports, logs and reproduction](evidence/coverage-2026-10-19/README.md). No production code was changed.
