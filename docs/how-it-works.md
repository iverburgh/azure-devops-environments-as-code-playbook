# How it works

## Two halves

```text
 environments/*.json ──► Set-Environments.ps1 ──► Azure DevOps environments + checks
        ▲                  -WhatIf / -Check          (exclusive lock, branch control, approval)
        └──────────────── Export-Environments.ps1 ◄──┘
                                                          ▲ every deployment job binds to one
 orchestration/system.json ──► Invoke-Rollout.ps1 ──► component pipelines ──► Azure resources
   components, dependencies,     deploy all / redeploy     (queued wave by wave)
   subscriptions, permissions  ► Remove-Environment.ps1 ─────────────────────► az group delete
                               ► Remove-OrphanedRoleAssignments.ps1 ─────────► az role assignment delete
```

- **Environments as code** describes the Azure DevOps environments and the checks that guard them.
  Every deployment job binds to one of these environments, so the checks are where "only main may
  deploy to prod", "one run at a time" and "someone else approves" are enforced.
- **Orchestration** describes the system: its components, the pipeline that deploys each of them,
  their resource groups and dependencies. From that it derives the order to deploy a complete
  environment in (deploy all, redeploy) and the order to tear it down in (remove), and it scopes
  the cleanup.

The two meet in one place: a component deploys to `<system> - <env>` or, with an
`environmentSuffix`, to `<system> - <env> - <suffix>`. `Test-Configuration.ps1` checks that every
such environment is defined.

## One wrapper per side effect

| Wrapper | File | Used for |
| --- | --- | --- |
| `Invoke-AzDevOps` | [lib/AzureDevOps.ps1](../lib/AzureDevOps.ps1) | Every Azure DevOps REST call: environments, checks, identities, security roles, pipelines, runs, deployment records |
| `Invoke-AzCli` | [lib/AzureCli.ps1](../lib/AzureCli.ps1) | Every Azure call: resource groups, locks, role assignments, directory lookups |

Nothing else talks to the outside world. The tests replace both with in-memory fakes
([FakeAzureDevOps.ps1](../tests/FakeAzureDevOps.ps1), [FakeAzure.ps1](../tests/FakeAzure.ps1)) that
keep state, record every write and fail like the real thing where it matters (unknown identity,
directory lookup errors, locked resource groups).

`Invoke-AzDevOps` calls the REST API with `Invoke-RestMethod` rather than `az devops invoke`: the
checks API is still in preview, `az devops invoke` needs an area/resource mapping for every route,
and plain HTTP makes paging (continuation tokens) and the request body explicit. Credentials, in
this order: `AZURE_DEVOPS_EXT_PAT`, then `SYSTEM_ACCESSTOKEN`, then a token for the signed-in Azure
CLI identity (resource `499b84ac-1321-427f-aa17-267ca6975798`, the well-known application ID of
Azure DevOps).

## Plan, then apply

`Set-Environments.ps1` never changes anything while it is still comparing:

1. **Read** the configuration ([lib/Config.ps1](../lib/Config.ps1)): schema first, then the rules
   the schema cannot express. Any problem stops the run before a single call to Azure DevOps.
2. **Resolve** every approver and administrator name to an identity ID, once each. An unknown or
   ambiguous name stops the run.
3. **Plan** ([lib/Environments.ps1](../lib/Environments.ps1), `Get-EnvironmentPlan`): read the
   environments and their checks and emit one item per difference: `CreateEnvironment`,
   `UpdateEnvironment`, `AddCheck`, `UpdateCheck`, `DeleteCheck`, `DeleteEnvironment` - plus
   `Unmanaged` for checks of other types, which are reported and left alone.
4. **Apply** (`Invoke-EnvironmentPlan`) every item through `ShouldProcess`, so `-WhatIf` and
   `-Confirm` work per item.

`-Check` stops after step 3 and exits 1 when the plan has changes. That makes drift visible in CI.

### Comparing checks

A check returned by the API carries fields the playbook did not send: links, creation dates, the
approvers' display names and descriptors, defaults. Comparing whole objects would report drift on
every run. Instead `Get-CheckSignature` reduces a check to a canonical string of exactly what the
playbook manages:

| Check | Signature |
| --- | --- |
| Exclusive lock | timeout |
| Branch control | allowed branches (split, trimmed, sorted, unique), verify branch protection, timeout |
| Approval | approver IDs (sorted, lower case), minimum approvers, requester cannot approve, execution order, instructions, timeout |

The desired and the actual check are equal exactly when their signatures are equal. That is what
makes the second run plan nothing.

The API has been seen returning `executionOrder` as a number as well as a name, and
`ensureProtectionOfBranch` as the string `"true"`; both are normalised before comparing.

### What is not managed

- **Other check types** (business hours, required template, invoke REST API, Azure Monitor) are
  never touched or deleted, so you can add them by hand or with another tool. They show up as
  `Unmanaged` in the plan, and `Export-Environments.ps1` warns about them.
- **Security on existing environments.** The configured administrators get the Administrator role
  once, when the environment is created, and the creator's own role can be removed then. Role
  changes on existing environments are not detected.
- **Deleting environments**, unless you ask for it with `-RemoveUndefined -RemoveFilter '<pattern>'`.
  Both are required, and only environments inside a configured group can match. Deleting an
  environment deletes its deployment history, which [redeploy](orchestrating-an-environment.md#redeploy)
  relies on.

## Orchestration

[lib/Orchestration.ps1](../lib/Orchestration.ps1) works offline on `system.json`:

- `Get-DependencyWave` sorts the components topologically into waves: a wave holds every component
  whose dependencies are all in earlier waves. A cycle is an error.
- `Get-DeploymentPlan` lists the components wave by wave with the Azure DevOps environment and
  resource group of each.
- `Get-RemovalPlan` reverses that: dependents first. With `-Components` it adds everything that
  depends on the named components, because removing a database under a running API is not a
  partial removal but a broken environment.
- `Assert-EnvironmentAction` is the gate for every action: the environment exists, the action is
  enabled for it, and remove is refused for protected environments and production-like names.

[lib/Rollout.ps1](../lib/Rollout.ps1) queues runs through the pipelines API and polls them;
[lib/Removal.ps1](../lib/Removal.ps1) deletes resource groups; [lib/Cleanup.ps1](../lib/Cleanup.ps1)
finds and deletes orphaned role assignments. [Orchestrating an environment](orchestrating-an-environment.md)
describes each of them.

## Tests

Pester 5 under [`tests/`](../tests), one file per area:

| File | Covers |
| --- | --- |
| `Configuration.Tests.ps1` | Schema and rule failures, group policy and exemptions, cross-file consistency |
| `SetEnvironments.Tests.ps1` | Create, update, delete of checks, idempotency (second run writes nothing), `-WhatIf`, `-Check` exit codes, unmanaged checks, `-RemoveUndefined` guards, security on create |
| `Export.Tests.ps1` | Export, and the round trip: export, then `-Check` reports no drift |
| `Orchestration.Tests.ps1` | Waves, removal order, component closure, cycles, the environment gate and production-like names |
| `Rollout.Tests.ps1` | Deploy all and redeploy wave by wave, pinned versions, stop on failure and timeout, `-WhatIf` |
| `Removal.Tests.ps1` | Prod guard, typed confirmation, lock preflight, reverse order, `-WhatIf` |
| `Cleanup.Tests.ps1` | Dry run, two-step detection, grace period, protected roles, circuit breaker, approved report, locks restored |

Mocks live in the root `BeforeAll` of each file and forward to the fakes. The entry scripts are run
in-process, so the tests cover parameter handling and exit codes as well.

## Where this comes from

The design generalises an implementation that has run in a real multi-environment platform. That
source has environments as JSON with an exclusive lock and branch control, an apply script with a
dry-run mode and an opt-in delete with a name filter, a removal pipeline with an approval stage on a
dedicated `RemoveAll` environment, and a guarded cleanup of orphaned role assignments.

This playbook adds, as recommendations beyond the source:

- **approvals as code** - in the source, approvals were configured by hand;
- **group policy with written exemptions** (`requireFourEyes`, `requireBranchControl`,
  `requireExclusiveLock`, `policyExemption`);
- **drift detection** (`-Check`) and **export** for adoption;
- **deploy all as one orchestrator** reading a dependency graph - the source chained pipelines with
  build tags and resource triggers ([example](../pipelines/examples/tag-chain-downstream.yml));
- **redeploy of the last good versions** from the deployment history - the source's redeploy was a
  weekly schedule that rebuilt short-lived environments from main;
- **a lock preflight, a production-like name guard and a typed confirmation** on removal;
- **a breaker that also stops a dry run**, and an approved report that, when empty, deletes nothing.
