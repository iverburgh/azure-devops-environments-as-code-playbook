# Running in a pipeline

Each script needs a different identity with different rights. Keep them apart: the identity that
may change approval checks should not also be able to delete resource groups.

| Pipeline | Talks to | Identity | Needs |
| --- | --- | --- | --- |
| [environments.yml](../pipelines/environments.yml) | Azure DevOps | service connection `sc-azure-devops-environments` (workload identity federation) | see [Applying environments](#applying-environments) |
| [deploy-all.yml](../pipelines/deploy-all.yml), [redeploy.yml](../pipelines/redeploy.yml) | Azure DevOps | job access token (`System.AccessToken`) | see [Orchestrating](#orchestrating-deploy-all-and-redeploy) |
| [remove.yml](../pipelines/remove.yml) | Azure | service connection `sc-shop-<env>` | Contributor on the environment's resource groups (or subscription) |
| [cleanup.yml](../pipelines/cleanup.yml) | Azure, Entra ID | service connection `sc-shop-<env>` | see [Cleanup](#cleanup) |

## How the scripts find credentials

[`lib/AzureDevOps.ps1`](../lib/AzureDevOps.ps1) is the only code that calls Azure DevOps. It uses,
in this order:

1. `AZURE_DEVOPS_EXT_PAT`: a [personal access token](#personal-access-token);
2. `SYSTEM_ACCESSTOKEN`: the job access token, only present when the pipeline maps it
   (`env: SYSTEM_ACCESSTOKEN: $(System.AccessToken)`);
3. the signed-in Azure CLI: a token for Azure DevOps (resource `499b84ac-1321-427f-aa17-267ca6975798`,
   the same in every tenant) for whoever is signed in - you after `az login`, or the service
   principal of an `AzureCLI@2` task.

[`lib/AzureCli.ps1`](../lib/AzureCli.ps1) runs `az` for Azure itself and uses whatever `az` is
signed in as.

In a pipeline, `-Organization` and `-Project` default to `System.CollectionUri` and
`System.TeamProject`, which every run sets.

## Applying environments

The [environments pipeline](../pipelines/environments.yml) signs in with a service connection that
uses **workload identity federation**: no secret to rotate, and an identity that is not tied to a
person. To let it manage environments:

1. Add its service principal (or managed identity) to the Azure DevOps organisation as a user,
   with a Basic access level.
2. Give it the **Creator** role in the security of *Environments* (project level), so it can create
   new ones.
3. Give it the **Administrator** role on every existing environment it manages. Environments it
   creates itself it administers already, unless `security.removeCreatorRole` is set - then the
   groups in `security.administrators` must include it.
4. Allow the pipeline to use the service connection, and restrict the service connection to this
   pipeline.

It reads identities to resolve approver names to IDs; an organisation user can do that.

> UNVERIFIED: the exact role needed to edit checks. In the portal, adding or editing checks on an
> environment needs the Administrator role on it; the playbook assumes the REST API requires the same.

Why not `System.AccessToken`? The build service identity would need the Administrator role on every
environment, and every pipeline in the project runs as that identity (at project scope) - including
the deployment pipelines the approvals are supposed to stop. A pipeline that can edit its own
approval checks has no approval checks.

## Orchestrating: deploy all and redeploy

`Invoke-Rollout.ps1` only reads pipelines, runs and deployment records and queues runs. The job
access token is enough, given to the script with `env: SYSTEM_ACCESSTOKEN: $(System.AccessToken)`.
The build service identity (`<project> Build Service (<organisation>)`) needs:

- **Queue builds** on each component pipeline (pipeline security);
- **Read** on the component pipelines and their runs;
- **User** (or Reader) on the environments, to read deployment records for redeploy.

Things that silently block it:

- *Limit job authorization scope to current project* is fine as long as all component pipelines are
  in the same project. With pipelines in other projects you need a different identity.
- *Protect access to repositories in YAML pipelines* and *Limit job authorization scope to
  referenced Azure DevOps repositories* can stop the queued runs from checking out their
  repositories. Give each component pipeline permission to its repository.
- The queued runs still need permission to use their own service connections and environments. The
  first run of a component in a new environment may wait for a "Permit" in the portal; that
  approval also stops the wave until it times out. Run each component once by hand in a new
  environment, or pre-authorise.

> UNVERIFIED: which identity a run queued with the job access token is *requested for*. See
> [four eyes and approvals](four-eyes-and-approvals.md#orchestration-changes-who-the-requester-is)
> for why it matters and why production is left out of deploy all.

The job waits while the component runs deploy, including while they wait for approvals. It holds an
agent for that time: give it `timeoutInMinutes` above `-TimeoutMinutes`, and consider a cheap agent
pool for orchestration jobs.

## Cleanup

`Remove-OrphanedRoleAssignments.ps1` needs, in the subscription of the environment (it lists the
resource groups, so Reader at subscription level):

- **Reader** to list the resource groups, their role assignments and locks;
- **User Access Administrator** or **Role Based Access Control Administrator** (ideally constrained
  to deleting assignments) to delete them, only for the `-Execute` stage;
- **Owner**, or a custom role with `Microsoft.Authorization/locks/*`, only with
  `-RemoveLocksTemporarily`;
- **directory read** in Entra ID (for example the *Directory Readers* role, or the Microsoft Graph
  application permission `Directory.Read.All`) to look up users, groups and service principals by ID.

Without directory read, every principal looks deleted. The two-step detection stops the run on any
lookup error other than "does not exist", and the circuit breaker stops it when too many look
orphaned - but grant the permission rather than relying on the safety nets.

Consider two service connections: a read-only one for the scan stage and one with delete rights for
the execute stage, which only runs after the manual review.

## Remove

`Remove-Environment.ps1` deletes resource groups. Its identity needs **Contributor** on the resource
groups, plus lock rights with `-IgnoreLocks`. Use one service connection per environment, scoped to
that environment's subscription or resource groups. Then even a mistake in the configuration cannot
remove another environment: the identity cannot see it. That is the guard that does not depend on
this playbook's code being right.

## Personal access token

For running the scripts from your own machine, `az login` is enough: the scripts use your
identity and your rights. A personal access token is for when `az login` is not available, or for
a quick test with fewer rights than you have.

```powershell
$env:AZURE_DEVOPS_EXT_PAT = Read-Host -AsSecureString 'PAT' | ConvertFrom-SecureString -AsPlainText
./scripts/Set-Environments.ps1 -Organization my-org -Project my-project -WhatIf
Remove-Item Env:AZURE_DEVOPS_EXT_PAT
```

Scopes, as narrow as possible:

| Script | Scopes |
| --- | --- |
| `Set-Environments.ps1 -WhatIf` / `-Check`, `Export-Environments.ps1` | Environment (Read), Identity (Read), Project and Team (Read) |
| `Set-Environments.ps1` (apply) | Environment (Read & manage), Identity (Read), Project and Team (Read), Security (Manage) for roles on new environments |
| `Invoke-Rollout.ps1` | Build (Read & execute), Environment (Read) |

> UNVERIFIED: these scopes follow the REST documentation and have not been tested one by one. If a
> call returns 401 or 403, the error message names the URL; widen the scope for that area only.

Do not use a personal access token in a pipeline. It is tied to a person, stops working when they
leave, and every run then acts with that person's rights and shows up in the audit log as them.
