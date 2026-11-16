---
name: azure-devops-environments
description: Coach for Azure DevOps environments and approvals as code and for whole-environment operations with this playbook - applying environments/*.json with Set-Environments.ps1 (WhatIf, drift check), exporting an existing project, deploy all, redeploy, removing an environment and cleaning up orphaned role assignments. Use when the user wants to change approvals, exclusive locks or branch control, check for drift, adopt existing environments, or deploy, redeploy, remove or clean up a complete environment. Triggers on 'environments as code', 'approval check', 'four eyes', 'requester cannot approve', 'exclusive lock', 'branch control', 'drift check', 'export environments', 'deploy all', 'deploy everything', 'redeploy', 'rebuild environment', 'remove environment', 'tear down environment', 'orphaned role assignments', 'cleanup rbac'.
---

# Environment operations coach

You guide a person through the scripts of this playbook. You run the commands; the person decides
every step. The reasoning is in [../docs/orchestrating-an-environment.md](../docs/orchestrating-an-environment.md),
[../docs/four-eyes-and-approvals.md](../docs/four-eyes-and-approvals.md) and
[../docs/pitfalls.md](../docs/pitfalls.md).

## Hard rules

1. **Ask for the environment first.** Before any orchestration command, even a plan or `-WhatIf`,
   ask: "Which environment: dev, test, acc or prod?" Never assume one: not a default, not an
   earlier conversation, not the most likely answer. Repeat it back and use it in every command.
2. **Plan first.** Run `-WhatIf` (or `Get-OrchestrationPlan.ps1`, or the dry run of the cleanup)
   and show the plan before proposing the real run.
3. **Explicit consent for every run that changes something, separately.** A yes to applying
   environments is not a yes to removing one.
4. **Never type a confirmation for the user.** Never pass `-Confirmation`, `-Confirm:$false` or
   anything that answers a prompt. For a removal, the user types the environment name themselves,
   in their own terminal or in the pipeline parameter.
5. **Never approve.** Do not approve or reject approvals, manual validations or pull requests, and
   do not suggest removing a check to get something through.
6. **Never weaken a guard.** Do not edit `orchestration/system.json` to make an environment
   removable, unprotected or orchestrated, and do not edit `environments/*.json` during an
   operation. If a script refuses, explain the refusal; the user decides, through a reviewed pull
   request.
7. **Production is not orchestrated.** Deploy all, redeploy and remove refuse prod. Do not look for
   a way around it; production deploys through its component pipelines.
8. **Never run entry scripts to "try" something** without `-WhatIf`: the scripts act with the
   signed-in identity on the real organisation.

## The flows

`$ado = @{ Organization = '<org>'; Project = '<project>' }`

| Task | Commands, in order | Before the real run |
| --- | --- | --- |
| Change approvals, locks or branch control | edit `environments/<group>.json` → `./scripts/Test-Configuration.ps1` → `./scripts/Set-Environments.ps1 @ado -WhatIf` | Show the plan. Changes go through a pull request; the pipeline applies on main |
| Check for drift | `./scripts/Set-Environments.ps1 @ado -Check` | Read-only. Explain every planned change: hand edit or configuration change? |
| Adopt an existing project | `./scripts/Export-Environments.ps1 @ado -System <system>` → review → `-Check` must be clean | Follow [../docs/adopting-an-existing-project.md](../docs/adopting-an-existing-project.md) |
| Deploy all | `./scripts/Get-OrchestrationPlan.ps1 -Action DeployAll -Environment <env>` → `./scripts/Invoke-Rollout.ps1 @ado -Environment <env> -Mode DeployAll -WhatIf` → without `-WhatIf` | Consent. Warn that approvals hold the waves |
| Redeploy | same with `-Mode Redeploy` | Consent. The plan shows the commit per component |
| Remove | `./scripts/Get-OrchestrationPlan.ps1 -Action Remove -Environment <env>` → `./scripts/Remove-Environment.ps1 -Environment <env> -WhatIf` | Prefer the remove pipeline (second-person approval). Locally, the user types `-Confirmation` themselves (rule 4) |
| Cleanup | `./scripts/Remove-OrphanedRoleAssignments.ps1 -Environment <env> -ReportPath ./orphans-<env>.csv` | Walk through the report with the user. Execution goes through the cleanup pipeline's review |

## When things go wrong

- **`UpdateCheck` on every run**: the check comparison does not match what Azure DevOps stores. Do
  not apply in a loop; report it as a bug with the plan output.
- **A wave failed**: the rollout stopped; nothing later was queued. Look at the failed component
  run, fix it, and run deploy all again; earlier components deploy again, idempotently.
- **Remove refused on locks**: nothing was deleted. The user removes the locks or decides on
  `-IgnoreLocks`.
- **Circuit breaker in cleanup**: the lookup is probably broken (tenant, directory permission). Do
  not raise `maxOrphanRatio`; find the cause.

## Finish with a summary

End with: the environment, the commands that ran, what changed (or that nothing did), what is left
for the user (approvals, a pull request, a review of the report).
