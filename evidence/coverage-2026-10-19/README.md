# Current-public-suite coverage — vault

Regenerated **19 October 2026** against public source/test commit `fac7f744e52095ec32d1b2ce1a6c494970052a71` (source tree SHA-256 `0aef36adbf83f91d768207fad7d1d92c7e0cee874749c16da723c0438154d2ca`). Deployed package `0x0ca0dbe2da5ea7c7b0d0d0796e7918413f9328c4e4bf72e2f6bcd8bf3c993c45`, version 8.

**Unfiltered unit tests: 16/16 passed, zero failures. Coverage tracing: 13/16 tests only — PARTIAL, not full-suite coverage.**

The latest public source/tests are measured here, not an older source anchor plus a historical patch. Full tracing still overflows the stock CLI's stack on both macOS arm64 and isolated Linux aarch64, even with a 512-MiB Rust thread-stack setting. [Diagnostic summary](tracing-limitations.json). This report does not hide that failure or label the filtered run complete.

## Measured production coverage

- Lines: **4.4%** (95/2160).
- CFG-edge branches: **6.74%** (41/608).
- Functions: **10.8%**.
- Explicit trace filter: `security_acl_tests|turbos_assets_manage::vault::test_`.

| Production file | Lines hit/found | CFG edges hit/found | Functions hit/found |
|---|---:|---:|---:|
| sources/acl.move | 19/42 | 13/38 | 4/8 |
| sources/config.move | 49/95 | 15/29 | 9/17 |
| sources/rewarder.move | 0/160 | 0/81 | 0/17 |
| sources/router.move | 8/266 | 0/0 | 4/32 |
| sources/vault.move | 19/1597 | 13/460 | 2/102 |

## Evidence and methodology

[Full unfiltered test log](full-tests.log), [filtered trace log](traced-tests.log), [run scope/trace-count checks](run.json), [production coverage JSON](production-coverage.json), [production-only LCOV](production-lcov.info), [raw test-build LCOV](raw-lcov.info), [instruction summary](instruction-summary.log), [LCOV-generation log](lcov-generation.log), [source/test hashes](source-hashes.json), [normal function inventory](normal-build-functions.json), [normal-bytecode comparison](normal-bytecode.json), [official CLI provenance](release-download.json).

Production code excludes dependencies, test modules, inline tests and test-only helpers using the normal non-test build's function inventory. Instrumented line denominators are validated against official Sui LCOV before exclusions; zero-hit lines/functions remain included. Branches use official Sui CFG-successor edges, including unconditional edges, not a decision-only metric. Only workspace paths are normalized in public artifacts; source bytes and coverage counts are unchanged.

The normal-build root bytecode still matches the recorded immutable mainnet-module hashes. This is not a fresh chain fetch, a dependency-bytecode audit, a production fix or a mainnet upgrade.

## Reproduce the current partial report

Use Node.js 22+ and the checksum-verified official tracing-enabled Sui **1.66.2-a9a6825eaf62**, available from https://github.com/MystenLabs/sui/releases/tag/mainnet-v1.66.2. At the public repository root:

```sh
SUI_BINARY=/path/to/tracing/sui node tools/coverage-current.mjs /tmp/turbos-vault-coverage-current --documented-partial
```

The destination must not exist. This first builds normal bytecode and runs **all 16 tests without a filter**, then explicitly captures the documented subset for coverage. It uses disposable source copies and an empty isolated CLI configuration, checks source/test hashes and per-test trace completeness for the selected subset, and never signs or submits a transaction. No old test overlay is applied.

Without `--documented-partial`, the tool attempts full tracing and **fails rather than reporting success** if the runtime crashes or any trace/test is missing. Running on Linux alone did not resolve the stock CLI's overflow.

## Remaining work

Full-suite line/branch capture is still unresolved. Passing all tests does not prove exhaustive authorization/invariant testing; uncovered production functions/lines are listed in the JSON. These are real gaps/tool limitations, not a declaration of compliance closure. Historical snapshots are retained.
