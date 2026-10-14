# First authorization/invariant test batch — Turbos Liquidity Vault

Pinned deployed source: `5a2996c38c7be786ec3cf943a7b3f5358b17b79d`.
[Results](tests-security-2026-10-14.json): **15 passed, 0 failed**.
[Full output](tests-security-2026-10-14.log), [before-overlay baseline](tests-before-overlay-2026-10-14.json).

## Explicit test changes

Runs against full public CLMM v22 instead of the interface-only dependency, which lacks test fixtures. Two legacy fixture setups advance GlobalConfig from initial version 1 to deployed code version 4 through the existing authorized setter. Adds 11 role, revocation, version and OperatorCap-ID tests. No production source change.

The source anchors and production functions are untouched in this repository. The test
patch/new files are versioned under tools/repro and applied only in a disposable test
checkout. Normal build mode never applies the overlay. No mainnet transaction is needed.

## Test mapping and remaining scope

| Control | Positive case | Negative case |
|---|---|---|
| Three ACL check functions | security_each_granted_role_passes_its_check | security_missing_{vault,reward,rebalance}_role_is_rejected |
| Reward-role revocation | check before revocation succeeds | security_revoked_reward_role_is_rejected |
| Rebalance-only separation | rebalance role check succeeds | security_rebalance_only_does_not_grant_vault_management |
| Config version / monotonic setter | fixtures use version 4 | security_future_version_blocks_acl_changes; security_version_cannot_move_backwards |
| OperatorCap ID, not its owner's EOA | security_operator_permissions_are_keyed_by_cap_id | security_operator_owner_address_does_not_inherit_cap_role |
| Legacy cap with zero roles | operator created with rebalance role | security_zeroed_operator_cap_cannot_rebalance |

The four existing tests exercise reward/Vault lifecycle and math. These new tests cover ACL
helpers and configuration entry points, not every strategy/rebalance/value-moving call site.
The full CLMM dependency is a test harness choice; production build reproduction retains
the original pinned interface recipe.

## Re-run

Install the pinned CLI from REPRODUCE-LATEST.md, then:

```bash
cd tools/repro
npm install --ignore-scripts
node reproduce.mjs /tmp/turbos-vault-security-tests test
```

The path must not exist. Framework native functions are aligned with the CLI; VM test
budget is 1,000,000,000, not a mainnet gas payment.

A separate official tracing-enabled CLI now supplies a
[production-only coverage report](coverage-2026-10-14/README.md). Its precise full/partial
tracing scope is disclosed there; this original passing test baseline remains unchanged.
The complete every-auth/every-invariant matrix is still required. R10 is not closed.
