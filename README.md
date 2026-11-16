# Azure DevOps environments as code — approvals, four eyes and whole-environment operations

Azure DevOps environments with their exclusive locks, branch control and four-eyes approvals as
reviewed JSON, applied idempotently through the REST API with a plan, a `-WhatIf` and a nightly
drift check. On top of that: one dependency graph of the system that drives **deploy all**,
**redeploy**, **remove** and **cleanup** of a complete environment, each guarded against doing the
wrong thing to the wrong environment. PowerShell, tested against in-memory fakes of Azure DevOps and
Azure, with Azure Pipelines YAML and documentation that explains each decision.

```text
 environments/<group>.json ──► Test-Configuration ──► Set-Environments -WhatIf ──► apply ──► nightly -Check
   exclusive lock               schema + policy:        plan in the PR              main      drift = red build
   branch control               four eyes on prod
   approvals

 orchestration/system.json ──► Get-OrchestrationPlan
   components + dependsOn        wave 1 network
   per-environment switches      wave 2 monitoring · messaging · data         deploy all / redeploy: top down
                                 wave 3 gateway · payments-fn                 remove:                bottom up
                                 wave 4 orders-api · web-ui                   cleanup:  dry run ► review ► execute
```

## Why

Environments are where Azure DevOps puts the controls that matter for releases: who approves
production, that only reviewed code from main gets there, that two releases do not interleave. In
most projects those controls are clicked together in the portal, so:

- **nobody can review a change** to who approves production, and nobody notices a removed approval;
- **a new environment starts without checks** - a deployment job creates the environment it names;
- **four eyes is an agreement**, not a setting: "the expert deploys the firewall, someone else
  checks" holds until the evening it does not;
- **orchestration bypasses the requester**: a pipeline that queues other pipelines becomes the
  requester, and *approvers can't approve their own runs* quietly stops protecting anything;
- **a complete environment is folklore**: which pipelines, in which order, to build it from nothing,
  rebuild it with the versions it had, or tear it down without taking the wrong one with it;
- **teardown leaves litter**: orphaned role assignments of deleted identities, and a naive cleanup
  that deletes everything when the directory lookup fails.

This playbook covers those cases.

## What it shows

| Topic | Read | See it in code |
|---|---|---|
| Environments, locks, branch control and approvals as JSON | [configuration.md](docs/configuration.md) | [environments/](environments), [schema](schemas/environments.schema.json) |
| Plan, apply, idempotency, `-WhatIf` and drift detection | [how-it-works.md](docs/how-it-works.md) | [Set-Environments.ps1](scripts/Set-Environments.ps1), [Environments.ps1](lib/Environments.ps1) |
| The four-eyes principle with environment checks | [four-eyes-and-approvals.md](docs/four-eyes-and-approvals.md) | [prod.json](environments/prod.json), [Config.ps1](lib/Config.ps1) (policy) |
| Adopting an existing project: export first | [adopting-an-existing-project.md](docs/adopting-an-existing-project.md) | [Export-Environments.ps1](scripts/Export-Environments.ps1) |
| Deployment jobs bound to environments | [orchestrating-an-environment.md](docs/orchestrating-an-environment.md#deploy-all) | [deploy-component.yml](pipelines/templates/deploy-component.yml), [orders-api.yml](pipelines/components/orders-api.yml) |
| Deploy all in dependency order | [orchestrating-an-environment.md](docs/orchestrating-an-environment.md#deploy-all) | [Invoke-Rollout.ps1](scripts/Invoke-Rollout.ps1), [deploy-all.yml](pipelines/deploy-all.yml) |
| Redeploy the last good versions | [orchestrating-an-environment.md](docs/orchestrating-an-environment.md#redeploy) | [Rollout.ps1](lib/Rollout.ps1), [redeploy.yml](pipelines/redeploy.yml) |
| Removing an environment safely | [orchestrating-an-environment.md](docs/orchestrating-an-environment.md#remove) | [Remove-Environment.ps1](scripts/Remove-Environment.ps1), [remove.yml](pipelines/remove.yml) |
| Cleaning up orphaned role assignments | [orchestrating-an-environment.md](docs/orchestrating-an-environment.md#cleanup) | [Cleanup.ps1](lib/Cleanup.ps1), [cleanup.yml](pipelines/cleanup.yml) |
| Identities, permissions, PAT versus service connection | [running-in-a-pipeline.md](docs/running-in-a-pipeline.md) | [AzureDevOps.ps1](lib/AzureDevOps.ps1), [environments.yml](pipelines/environments.yml) |
| A Copilot skill that coaches the operations | [skill/SKILL.md](skill/SKILL.md) | |
| Wrappers, fakes and tests | [how-it-works.md](docs/how-it-works.md#tests) | [tests/](tests) |
| Lessons learned | [pitfalls.md](docs/pitfalls.md) | |

### What it deliberately does not do

- **Approve anything.** The scripts create approval checks; people approve. Nothing in this
  repository passes an approval or a typed confirmation on someone's behalf.
- **Orchestrate production.** Deploy all and redeploy are off for prod: a pipeline that queues
  other pipelines changes who the requester is. Production deploys through its own pipelines.
- **Remove protected or production-like environments.** Not with a switch, not with a confirmation.
- **Delete environments by default.** Their deployment history is the audit trail and what redeploy
  needs; deletion needs an explicit switch and a name filter.
- **Manage every kind of check.** Business hours, required template and invoke-function checks are
  left alone and reported, so they can coexist with this playbook.

## Quick start

Requirements: PowerShell 7.2+, Pester 5.5+. The Azure CLI only for real runs; the tests call
neither Azure DevOps nor Azure.

```powershell
git clone https://github.com/iverburgh/azure-devops-environments-as-code-playbook
cd azure-devops-environments-as-code-playbook

Invoke-Pester ./tests -Output Detailed               # everything, against the in-memory fakes
./scripts/Test-Configuration.ps1                     # validate environments/*.json and system.json offline
./scripts/Get-OrchestrationPlan.ps1 -Action DeployAll -Environment test
./scripts/Get-OrchestrationPlan.ps1 -Action Remove -Environment dev

# Against your own project, after az login and adapting environments/: writes nothing
./scripts/Set-Environments.ps1 -Organization my-org -Project my-project -WhatIf
```

Then follow [getting-started.md](docs/getting-started.md). Existing project? Start with
[adopting-an-existing-project.md](docs/adopting-an-existing-project.md).

## Layout

```text
environments/{dev,test,acc,prod}.json   one file per environment group: locks, branch control, approvals, policy
orchestration/system.json               environments and components of the sample "shop" system, with dependsOn
schemas/                                JSON schemas for both
scripts/
  Set-Environments.ps1                  create/update environments and checks: -WhatIf, -Check, opt-in deletion
  Export-Environments.ps1               export existing environments to JSON (adoption, drift review)
  Test-Configuration.ps1                offline validation: schema, four-eyes policy, dependency graph
  Get-OrchestrationPlan.ps1             print the waves or removal order
  Invoke-Rollout.ps1                    deploy all / redeploy: queue component pipelines wave by wave
  Remove-Environment.ps1                guarded teardown in reverse dependency order
  Remove-OrphanedRoleAssignments.ps1    orphaned role assignment cleanup, dry run by default
lib/                                    Invoke-AzDevOps and Invoke-AzCli: the only side effects; the logic
tests/                                  Pester 5 against in-memory fakes (FakeAzureDevOps.ps1, FakeAzure.ps1)
pipelines/
  environments.yml                      validate + plan on PR, apply on main, nightly drift check
  deploy-all.yml, redeploy.yml          orchestrate an environment
  remove.yml, cleanup.yml               teardown and cleanup with approvals
  templates/, components/               deployment jobs bound to the environments
  examples/                             the build-tag chain alternative to an orchestrator
skill/SKILL.md                          Copilot skill: the environment operations coach
docs/                                   the documentation above
tools/                                  leak check and documentation link check (CI)
.github/
  instructions/                         Copilot instructions for this repository
  workflows/ci.yml                      tests, configuration validation, leak check, link check
```

## Related playbooks

Each playbook stands on its own:

- [Azure App Configuration](https://github.com/iverburgh/azure-app-configuration-playbook) —
  configuration and feature flags as code, per environment - the same environments these pipelines
  deploy to.
- [Renovate on Azure DevOps](https://github.com/iverburgh/renovate-azure-devops-playbook) —
  automated dependency updates, whose pull requests meet the same branch policies as everything else.
- [Copilot on Azure DevOps](https://github.com/iverburgh/copilot-azure-devops-playbook) —
  instructions, skills and agents, like the coach in this repository.
- [Path filters on Azure DevOps](https://github.com/iverburgh/azure-devops-path-filter-playbook) —
  build and deploy only what a change touches; deploy all is the deliberate opposite.
- [Domain-Driven Design in .NET](https://github.com/iverburgh/ddd-dotnet-playbook) —
  bounded contexts that become the components and dependencies of `system.json`.
- [Entra ID app registrations as code](https://github.com/iverburgh/entra-app-registrations-as-code-playbook) —
  the same plan-WhatIf-apply approach for app registrations, and what remove leaves behind in Entra ID.
- [Circuit breakers on Azure Functions](https://github.com/iverburgh/azure-functions-circuit-breaker-playbook) —
  a breaker shared by every instance; here, a breaker that stops a cleanup gone wrong.
- [HTTP resilience in .NET](https://github.com/iverburgh/dotnet-http-resilience-playbook) —
  retries, timeouts and throttling, for the services the deploy-all waves bring up.
- [OpenTelemetry observability in .NET](https://github.com/iverburgh/dotnet-opentelemetry-observability-playbook) —
  the monitoring component of wave 2, and how to see that a freshly deployed environment works.
- [Azure SQL database as code](https://github.com/iverburgh/azure-sql-database-as-code-playbook) —
  the data component: schema and migrations deployed per environment, behind the `Data` approval.
- [Service Bus settlement in Azure Functions](https://github.com/iverburgh/azure-functions-service-bus-settlement-playbook) —
  the messaging component, and functions that settle every message deliberately.
- [Azure SQL disaster recovery](https://github.com/iverburgh/azure-sql-disaster-recovery-playbook) —
  a restore runbook with four eyes in production, for when redeploy cannot bring the data back.

## License

[MIT](LICENSE)
