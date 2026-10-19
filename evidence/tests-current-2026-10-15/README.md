> October 19 update: [regenerated current-tree report](../coverage-2026-10-19/README.md) includes a fresh full unfiltered test run and explicitly partial coverage tracing.

# Tests integrated into the current public checkout — 2026-10-15

**16 passed, 0 failed**. [Result](result.json), [full log](tests.log), [normal-bytecode check](normal-bytecode.json).

The 11 previously published ACL tests are directly in tests/security_acl_tests.move. Two existing lifecycle fixtures advance the config to version 4 with the existing authorized setter. The pre-existing local deposit test is included after the same fixture correction, full-withdrawal comment correction, and new zero-remaining-assets / bounded positive-output assertions.

These tests are now ordinary tracked source/test files in this repository, not only patches under tools/repro. Existing source-anchor overlay recipes remain for historical reproducibility; they are not the current-checkout test command.

## Run the current checkout

Install the recorded Sui 1.66.2-a9a6825eaf62 and Node.js 22+, then:

```sh
node tools/test-current.mjs /tmp/turbos-vault-current-tests
```

The destination must not exist. This copies THIS checkout's sources/tests to a disposable directory and pins the test framework to `a9a6825eaf6273cc819ee3bcf65fd4909f7624a9`, matching the CLI's test natives. Only that disposable manifest is adjusted; the producer Move.toml, Published.toml, and current MVR GitInfo are unchanged. No old test overlay is applied to the copied source. VM test gas limit is 1,000,000,000, not a mainnet gas payment. No keystore is read and no transaction is published.

A separate normal, non-test build matches all 5 module hashes previously read from the immutable deployed package. No production remediation was published or deployed; inline helpers are excluded from normal builds. No MVR metadata transaction is needed for this test-only follow-up.

## Limits

The older coverage report reflects the prior 15-test suite with partial tracing, not the new deposit case. No new line/branch percentage is asserted.

This is not evidence that every authorization check/invariant is covered. See the historical [authorization matrix](../AUTH-TEST-MATRIX.md) and dated [coverage report](../coverage-2026-10-14/README.md) for remaining gaps.
