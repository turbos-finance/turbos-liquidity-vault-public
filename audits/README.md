# Audit evidence - Turbos Liquidity Vault

Audit PDFs retain their original authors' copyright and terms. The repository's MIT
license applies to Turbos-owned source and documentation; it does not relicense third-party reports.

Original reports are preserved: [MoveBit](movebit-vault-2024.pdf) and
[OtterSec](ottersec-vault-2024.pdf).

| Report | Review period | Reviewed revision(s) | Reported result |
|---|---|---|---|
| MoveBit | 2024-04-04 through 2024-04-08; cover dated 2024-04-22 | `edb2c6d52c3fd068be9c60e573fa322f341e1932`, `bdcf75f76d8dbeb849ad3189cc0743aebda08f8b`, `dfcccaec31f0a18a6bdbdccd928e22a06db5115e`, `0a6d72c85c03474dcfea9fa4272fdbe45e6d3ab3` | 3 major fixed; 2 informational acknowledged |
| OtterSec | 2024-05-01 through 2024-05-22; report dated 2024-05-24 | `5ed709644441c794eea8ebb1fa2c900d6f84d8a5` | 2 medium, 1 low, 6 informational findings |

All cited revisions and the fix commits below are available in this repository's history.
OtterSec names Michal Bochnak, Bartlomiej Wierzbinski and Robert Chen. MoveBit identifies
the firm, without individual reviewer names. Scope, architecture and methodology are
in each original report; the architecture is also summarized in the root README.

| OtterSec finding | Reported patch commit |
|---|---|
| OS-TBF-ADV-00 | `971cfd9d02ef33bad180d64b697be9e7a4c717a3` |
| OS-TBF-ADV-01 | `9333ce4f8e2d548ea4c46b7f08ac03f7d43b0244` |
| OS-TBF-ADV-02 | `971cfd9d02ef33bad180d64b697be9e7a4c717a3` |
| OS-TBF-SUG-00 | Follow-up commit `d8150840fa65eb5fa26bc45013b9abc59632b9ce` explicitly names this finding |

The PDF records dispositions and patches for the remaining suggestions. A complete
per-finding fix/test matrix is still required; absence from this table does not mean
resolved or unresolved.

## Deployed-source delta

The deployed v8 revision is `5a2996c38c7be786ec3cf943a7b3f5358b17b79d`.
Compared with `971cfd9...`, `config`, `router` and `vault` contain 96 insertions and
4 deletions. Later fixes and features need a documented delta review; these historical
reports do not establish that the latest deployed code was audited in full.
