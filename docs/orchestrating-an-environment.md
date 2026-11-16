# Orchestrating an environment

Four operations on a complete environment, all driven by
[`orchestration/system.json`](../orchestration/system.json):

| Operation | Does | Script | Pipeline |
| --- | --- | --- | --- |
| [Deploy all](#deploy-all) | Deploys every component from its branch, in dependency order | `Invoke-Rollout.ps1 -Mode DeployAll` | [deploy-all.yml](../pipelines/deploy-all.yml) |
| [Redeploy](#redeploy) | Deploys every component again at the commit that last deployed successfully | `Invoke-Rollout.ps1 -Mode Redeploy` | [redeploy.yml](../pipelines/redeploy.yml) |
| [Remove](#remove) | Deletes the resource groups, dependents first | `Remove-Environment.ps1` | [remove.yml](../pipelines/remove.yml) |
| [Cleanup](#cleanup) | Finds and deletes orphaned role assignments | `Remove-OrphanedRoleAssignments.ps1` | [cleanup.yml](../pipelines/cleanup.yml) |

Each one is off for an environment unless `system.json` switches it on, and all of them support
`-WhatIf`. `Get-OrchestrationPlan.ps1` prints the plan of deploy all, redeploy and remove offline.

## The dependency graph

```text
 wave 1   network
 wave 2   monitoring   messaging   data
 wave 3   gateway (messaging, monitoring)    payments-fn (data, messaging)
 wave 4   orders-api (data, messaging, gateway)    web-ui (gateway)
```

A wave holds every component whose dependencies are all in earlier waves. Deploy all runs the waves
top down; remove runs the components bottom up. The graph lives in one file, so "what does the
environment consist of, and in what order" has one answer.

## Deploy all

```powershell
./scripts/Invoke-Rollout.ps1 -Organization my-org -Project my-project -Environment test -Mode DeployAll -WhatIf
./scripts/Invoke-Rollout.ps1 -Organization my-org -Project my-project -Environment test -Mode DeployAll
```

1. Checks that deploy all is enabled for the environment and that every component pipeline exists -
   before queuing anything.
2. Queues the pipelines of wave 1 with the branch of each component and
   `templateParameters.environment = test`.
3. Polls until every run of the wave has completed. All succeeded: next wave. Any run failed, was
   cancelled or did not complete within `-TimeoutMinutes`: stop, and start no later wave.

The component pipelines do the deploying, in their own deployment jobs bound to their own
environments ([orders-api.yml](../pipelines/components/orders-api.yml),
[deploy-component.yml](../pipelines/templates/deploy-component.yml)). Orchestration never bypasses
a check: an approval on `shop - acc` stops the wave until someone approves. That is also why the
orchestrator needs nothing more than permission to queue the pipelines.

**A component pipeline must accept a template parameter `environment`** and, when it is set, deploy
to that environment only. The samples use `all` (the default for CI: dev, test, acc, prod in order)
and a single environment name.

### Why one orchestrator instead of a chain

The source chained the pipelines: the first one tags its run, the pipelines that depend on it
declare it as a resource with a tag trigger, and so on
([example](../pipelines/examples/tag-chain-downstream.yml)). That needs no waiting job and no token
that queues runs, but the dependency graph is spread over every pipeline file, a component with two
dependencies is triggered by each of them separately, and nothing tells you when the environment is
complete. The orchestrator keeps the graph in one file, stops at the first failure and ends with one
result. The cost is an agent that waits; give the job a long enough timeout.

## Redeploy

```powershell
./scripts/Invoke-Rollout.ps1 -Organization my-org -Project my-project -Environment dev -Mode Redeploy
```

Same waves, but each component is queued at the **exact commit** of its last successful deployment
to the environment. That comes from the deployment history of the Azure DevOps environment (the
records a deployment job leaves behind) and the run that made it (branch and commit). Use it to:

- rebuild an environment after [remove](#remove), with the versions it had;
- undo configuration drift in the resources by deploying the same versions again;
- prove that the deployment is repeatable.

A component that never deployed successfully to the environment stops the redeploy before anything
is queued: use deploy all first. Deleting an Azure DevOps environment deletes its history, which is
one more reason `Set-Environments.ps1` never deletes environments by default.

> The source's "redeploy" was different: a weekly schedule that removed short-lived environments at
> night and deployed them again from main, so they never drifted far and never ran for nothing over
> the weekend. You can do the same with this playbook: schedule [remove.yml](../pipelines/remove.yml)
> and then [deploy-all.yml](../pipelines/deploy-all.yml) or [redeploy.yml](../pipelines/redeploy.yml).
> Note that scheduled runs cannot type a confirmation; a scheduled teardown needs its own
> pipeline with the confirmation built in and the approval check removed from its gate - a
> deliberate decision for dev only.

> UNVERIFIED: the deployment record fields (`definition.id`, `owner.id`, `result`, `finishTime`)
> and pinning a run to a commit with `resources.repositories.self.version` follow the REST
> documentation; the tests use a fake with that shape.

## Remove

```powershell
./scripts/Remove-Environment.ps1 -Environment dev -WhatIf
./scripts/Remove-Environment.ps1 -Environment dev -Confirmation dev
./scripts/Remove-Environment.ps1 -Environment dev -Components messaging -Confirmation dev
```

Tearing an environment down is the most destructive thing in this playbook, so it has the most
guards. In order:

1. **Configured**: the environment is in `system.json` with `"remove": true`.
2. **Not protected**: `"protected": true` is never removable; the configuration check refuses
   `protected` together with `remove`.
3. **Not production-like**: names with `prod`, `prd`, `production` or `live` as a separate word are
   refused even when the configuration allows them. A copy-pasted configuration does not become a
   production teardown.
4. **Typed confirmation**: `-Confirmation` must be exactly the environment name, case-sensitive.
   Not needed for `-WhatIf`.
5. **Locks**: any management lock on any of the resource groups stops the removal **before the
   first deletion**, so a lock never leaves an environment half removed. `-IgnoreLocks` deletes the
   locks first.
6. **Order**: dependents first (web and APIs, then gateway and functions, then data, messaging and
   monitoring, then the network). With `-Components`, everything that depends on them goes too.
7. **Approval** (in the pipeline): a deployment job on `shop - <env> - RemoveAll`, whose approval
   check has *requester cannot approve*. A second person approves the teardown.

Guards 1-3 and 5 also apply with `-WhatIf`, so the pipeline's Plan stage fails on them before
anyone is asked to approve. A resource group that is already gone is reported as `AlreadyGone`, so
an interrupted removal can be run again.

The script deletes resource groups only. It leaves alone what lives outside them: Entra ID
applications, role assignments at subscription level, DNS records in a shared zone, Azure DevOps
environments. Clean those up separately, or keep them, as the [cleanup](#cleanup) does for role
assignments.

## Cleanup

```powershell
./scripts/Remove-OrphanedRoleAssignments.ps1 -Environment test -ReportPath ./orphans-test.csv
./scripts/Remove-OrphanedRoleAssignments.ps1 -Environment test -Execute -ApprovedReport ./orphans-test.csv
```

Environments that are removed and rebuilt leave **orphaned role assignments** behind: assignments
whose managed identity or service principal was deleted with its resource. They show up as
"Identity not found", clutter access reviews and count towards the role assignment limit of the
subscription.

The script scans the resource groups that match `cleanup.resourceGroupPattern` and is a **dry run
unless `-Execute`**. The safety nets:

1. **Two-step detection.** The Azure CLI shows an empty principal name both for a deleted principal
   and when the caller cannot read the directory. Every candidate is therefore looked up by ID; only
   "does not exist" counts. Any other lookup error stops the run.
2. **Grace period.** Assignments younger than `minimumAgeDays` are reported as `TooRecent`: a new
   identity can take a while to replicate.
3. **Protected roles.** Owner and User Access Administrator are reported as `ProtectedRole`, never
   deleted.
4. **Circuit breaker.** When more than `maxOrphanRatio` of the assignments look orphaned (from
   `minimumAssignmentsForRatioCheck` assignments up), the lookup is probably broken - wrong tenant,
   missing permission - and the script stops, **also in a dry run**, so a misleading report is never
   reviewed and approved.
5. **Approved report.** With `-ApprovedReport`, only the assignments in the reviewed CSV are deleted,
   and only if they are still orphaned. An empty report deletes nothing.
6. **Locks.** A resource group with a lock is skipped, unless `-RemoveLocksTemporarily`; then the
   locks are deleted and always restored afterwards, also when a deletion fails.

The [cleanup pipeline](../pipelines/cleanup.yml) runs the dry run, publishes the CSV, waits for a
person to review it (`ManualValidation`) and then executes with the reviewed report.

> The source had two cleanups: a simple one that deleted every assignment without a principal name,
> without a dry run, and a careful one with the safety nets above. This playbook keeps only the
> careful one, and adds the breaker in dry runs and the empty-report rule.
