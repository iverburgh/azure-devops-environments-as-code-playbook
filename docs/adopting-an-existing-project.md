# Adopting an existing project

Most projects already have environments, created by the first deployment job that named them and
configured by hand since. Do not start by writing JSON from memory and applying it: the first
apply would replace hand-made checks with whatever you remembered. Export first, so the first apply
changes nothing, and then change things through pull requests.

## 1. Export

```powershell
az login
./scripts/Export-Environments.ps1 -Organization my-org -Project my-project -System shop
```

Every environment named `shop - <group>` or `shop - <group> - <suffix>` goes into
`exported/<group>.json` (git-ignored). `-Group dev,test` limits the export; existing files are only
overwritten with `-Force`.

The export contains what `Set-Environments.ps1` manages: exclusive lock, branch control and
approval checks, with approvers as e-mail addresses (users) or display names (groups). It warns about
checks it does not manage - business hours, required template, Azure Function, REST API - and leaves
them out. They stay on the environments untouched.

Environments that do not follow the naming convention are not exported. Rename them (a rename in
Azure DevOps keeps the deployment history), or leave them unmanaged.

## 2. Review

Go through each file and decide, environment by environment, whether what you see is what you want:

- **Approvals that are missing** on environments that need them, typically prod.
- **Approvers that are people** instead of groups: one person leaving the company should not block
  production. Replace them with a group.
- **`requesterCannotBeApprover: false`** on production. See
  [four eyes and approvals](four-eyes-and-approvals.md).
- **Branch control that allows `*`**, or allows main without `verifyBranchProtection`.
- **Two exclusive locks or two approvals** on one environment, from manual additions over the years.
  The export keeps the first; the apply will remove the other.

Write down what you want to change, but do not change it yet.

## 3. Add what Azure DevOps does not store

The export cannot know two things, because they are not settings of an environment:

- **`policy`**: the rules your groups should follow, for example `"requireFourEyes": true` for
  prod. Add them, run `./scripts/Test-Configuration.ps1`, and either fix the environments it
  complains about or give them a written `policyExemption`.
- **`security`**: who gets the Administrator role on *new* environments. Existing environments keep
  their roles.

## 4. Move and verify: no drift

Move the files into `environments/`, then compare them with Azure DevOps:

```powershell
./scripts/Test-Configuration.ps1
./scripts/Set-Environments.ps1 -Organization my-org -Project my-project -Check
```

`-Check` must report **no changes**. If it reports something, the export and the apply disagree
about a setting - a default that differs, a timeout - and that has to be understood before going
on. Fix the file, not Azure DevOps, until `-Check` is clean. Commit this state on its own: it
documents what was there.

## 5. Change through pull requests

Now make the changes from step 2, one pull request at a time, with the plan of
`Set-Environments.ps1 -WhatIf` in the pull request (the [environments pipeline](../pipelines/environments.yml)
runs it). The first one is usually the four-eyes rule on production.

From here on:

- the [environments pipeline](../pipelines/environments.yml) applies on every merge to main;
- the nightly `-Check` reports hand edits;
- people who need a change make a pull request instead of asking an administrator.

## 6. Optional: clean up environments nobody defines

Environments that are not in any file are left alone by default. Once everything that matters is
defined, list the leftovers with a dry run, limited by a name filter:

```powershell
./scripts/Set-Environments.ps1 -Organization my-org -Project my-project -RemoveUndefined -RemoveFilter 'shop - *' -WhatIf
```

Deleting an environment deletes its deployment history, which [redeploy](orchestrating-an-environment.md#redeploy)
needs. Delete only environments you are sure are dead, and keep the filter narrow.

## Bringing the orchestration along

For [deploy all, redeploy, remove and cleanup](orchestrating-an-environment.md), describe the
components in `orchestration/system.json`: one entry per pipeline that deploys a part of the
environment, with its resource group and its dependencies. Then:

1. Run `./scripts/Get-OrchestrationPlan.ps1 -Action DeployAll -Environment dev` and check the waves
   with the people who know the system: the order is the most valuable and most wrong part.
2. Give each component pipeline the `environment` template parameter.
3. Start with deploy all `-WhatIf` and redeploy `-WhatIf` on dev. Only switch on `remove` for an
   environment once a full deploy all from nothing has worked there.
