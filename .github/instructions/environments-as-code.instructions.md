---
applyTo: 'scripts/**, lib/**, tests/**, environments/**, orchestration/**, schemas/**, pipelines/**, skill/**, docs/**'
---

# Azure DevOps environments as code

- Never call Azure DevOps or Azure directly. All side effects go through `Invoke-AzDevOps`
  (`lib/AzureDevOps.ps1`) and `Invoke-AzCli` (`lib/AzureCli.ps1`). Every `az` call passes
  `--subscription` or a full resource ID; never rely on, or change, the default subscription.
- Every entry script that changes something uses `[CmdletBinding(SupportsShouldProcess)]` and
  checks `$PSCmdlet.ShouldProcess` per change, so `-WhatIf` writes nothing. Destructive scripts use
  `ConfirmImpact = 'High'`.
- `Set-Environments.ps1` is idempotent: a second run plans nothing. When you change what is sent for
  a check, change its signature in `lib/Environments.ps1` and the fake in `tests/FakeAzureDevOps.ps1`
  together, and keep the "second run changes nothing" test green. It never deletes an environment
  unless `-RemoveUndefined` and `-RemoveFilter` are both passed; do not loosen that.
- `-Environment` has no default on the orchestration scripts and must stay mandatory. Do not add
  defaults or infer the environment.
- Never weaken the remove guards in `lib/Orchestration.ps1`: configured `remove`, not `protected`,
  no production-like name, case-sensitive typed confirmation. Never pass `-Confirm:$false` or a
  typed `-Confirmation` from an agent, never approve a run or a manual validation, and never use
  them in examples meant for an agent.
- Cleanup is a dry run unless `-Execute`. Keep the two-step principal lookup, the grace period, the
  protected roles, the circuit breaker (also in dry runs) and the approved-report intersection.
- Deploy all and redeploy stay off for protected and production environments: a queued run changes
  the requester, which defeats *requester cannot approve*.
- Configuration lives in `environments/<group>.json` and `orchestration/system.json` and must
  validate against `schemas/`. When you add a key, update the schema, `lib/Config.ps1`, the docs
  (`docs/configuration.md`) and a test together.
- Tests: Pester 5 under `tests`, against the in-memory fakes. Mocks go in the root `BeforeAll`;
  there is no root-level `BeforeEach`. Never sleep in a test: pass `-Sleep` and `-Now`. Never run an
  entry script outside the tests to "try it": the wrappers are not mocked there. After a change run
  `Invoke-Pester ./tests` and `./scripts/Test-Configuration.ps1`.
- Functions emit items one by one; callers wrap results in `@()`. Under `Set-StrictMode -Version
  Latest`, read optional keys with `Get-OptionalValue`, never with `.key` on a hashtable that may not
  have it.
- Pipelines pass parameters to scripts through `env:`, never by inlining `${{ parameters.x }}` into
  a script. Mark anything not verified against a real organisation as UNVERIFIED.
- Use only placeholder identifiers: `00000000-0000-0000-0000-0000000000NN` GUIDs, `my-org` /
  `my-project`, the sample system `shop`, `example.com` addresses. Well-known Azure DevOps check
  type IDs are allowed. `./tools/Test-NoInternalReferences.ps1` and
  `./tools/Test-DocumentationLinks.ps1` must pass.
