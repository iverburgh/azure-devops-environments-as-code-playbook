# Getting started

## Requirements

| Tool | Version | For |
| --- | --- | --- |
| PowerShell | 7.2 or later | Everything |
| Pester | 5.5 or later | The tests |
| Azure CLI | recent | Real runs only: signing in to Azure DevOps without a PAT, removal and cleanup. The tests never call it |

```powershell
Install-Module Pester -MinimumVersion 5.5 -Scope CurrentUser -Force -SkipPublisherCheck
```

## 1. Run the tests

```powershell
Invoke-Pester ./tests -Output Detailed
```

Every test runs against an in-memory fake of the Azure DevOps REST API
([`tests/FakeAzureDevOps.ps1`](../tests/FakeAzureDevOps.ps1)) and of the Azure CLI
([`tests/FakeAzure.ps1`](../tests/FakeAzure.ps1)). No account, no network, a few seconds.

## 2. Validate the configuration

```powershell
./scripts/Test-Configuration.ps1
```

Checks `environments/*.json` and `orchestration/system.json` against their JSON schemas and against
the rules a schema cannot express: names follow `<system> - <group>[ - <suffix>]`, the group policy
holds (four eyes, branch control, exclusive lock) unless an environment has a written exemption,
approvals have enough approvers, the component graph has no cycles, every environment a component
deploys to exists, and every removable environment has its `RemoveAll` approval gate. It is offline
and belongs in CI.

## 3. See the orchestration plans

Also offline:

```powershell
./scripts/Get-OrchestrationPlan.ps1 -Action DeployAll -Environment test
./scripts/Get-OrchestrationPlan.ps1 -Action Remove -Environment dev
./scripts/Get-OrchestrationPlan.ps1 -Action Remove -Environment dev -Components messaging
```

The first prints the waves in which `deploy all` queues the component pipelines; the second the
order in which `remove` deletes resource groups (dependents first); the third shows that removing
one component also removes everything that depends on it.

## 4. Adapt the configuration

| File | What to change |
| --- | --- |
| [`environments/<group>.json`](../environments/prod.json) | `system`, the environment names, the approver groups, the allowed branches. One file per environment group; see [Configuration](configuration.md) |
| [`orchestration/system.json`](../orchestration/system.json) | Subscriptions, which environment allows deploy all, redeploy and remove, your components with their pipelines, resource groups and dependencies |
| [`pipelines/`](../pipelines) | Service connection names, pools, the deploy step in [`templates/deploy-component.yml`](../pipelines/templates/deploy-component.yml) |

If the project already has environments, export them first instead of writing the files by hand:
[Adopting an existing project](adopting-an-existing-project.md).

## 5. First real run: WhatIf

Sign in with a personal access token (scopes in
[Running in a pipeline](running-in-a-pipeline.md#personal-access-token)) or with `az login`:

```powershell
$env:AZURE_DEVOPS_EXT_PAT = '<pat>'   # or: az login
./scripts/Set-Environments.ps1 -Organization my-org -Project my-project -WhatIf
```

`-WhatIf` resolves the approver names, reads the environments and their checks, and prints the plan.
It writes nothing. Then apply, and run it once more to see that the second run plans nothing:

```powershell
./scripts/Set-Environments.ps1 -Organization my-org -Project my-project
./scripts/Set-Environments.ps1 -Organization my-org -Project my-project -Check   # exit 0: no drift
```

## 6. In a pipeline

Register [`pipelines/environments.yml`](../pipelines/environments.yml): it validates and shows the
plan on pull requests, applies on main and checks for drift every night. Then the component
pipelines and the orchestration pipelines. [Running in a pipeline](running-in-a-pipeline.md)
explains the identities and permissions each of them needs.
