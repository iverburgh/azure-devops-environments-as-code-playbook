# Configuration reference

Two kinds of files, each with a JSON schema in [`schemas/`](../schemas). Editors that understand
`$schema` give completion and validation; `./scripts/Test-Configuration.ps1` validates both kinds,
plus the rules below, offline.

## environments/&lt;group&gt;.json

One file per environment group: a stage of the system such as `dev` or `prod`. A group has a base
environment `<system> - <group>` and any number of suffixed variants `<system> - <group> - <suffix>`
for parts that need different checks, such as `shop - prod - Data` for the databases or
`shop - dev - RemoveAll` for the teardown gate.

```json
{
  "$schema": "../schemas/environments.schema.json",
  "system": "shop",
  "group": "prod",
  "policy": { "requireFourEyes": true, "requireBranchControl": true, "requireExclusiveLock": true },
  "security": { "administrators": ["[shop]\\Release Administrators"], "removeCreatorRole": true },
  "environments": [
    {
      "name": "shop - prod",
      "description": "Production.",
      "exclusiveLock": { "enabled": true },
      "branchControl": { "enabled": true, "allowedBranches": ["refs/heads/main"], "verifyBranchProtection": true },
      "approval": {
        "enabled": true,
        "approvers": ["[shop]\\Production Approvers"],
        "minRequiredApprovers": 1,
        "requesterCannotBeApprover": true,
        "instructions": "Check the change and the acceptance result.",
        "timeoutMinutes": 4320
      }
    }
  ]
}
```

### Top level

| Key | Required | Meaning |
| --- | --- | --- |
| `system` | yes | Prefix of every environment name. The same in every file |
| `group` | yes | The group name; no hyphens, because ` - ` separates the parts of a name |
| `policy` | no | Rules every environment of the group must follow, see [below](#policy-and-exemptions) |
| `security.administrators` | no | Users or groups that get the Administrator role on a **new** environment |
| `security.removeCreatorRole` | no | Remove the role Azure DevOps gives the identity that created the environment (usually the pipeline's identity) |
| `environments` | yes | The environments of the group |

### Per environment

| Key | Meaning |
| --- | --- |
| `name` | `<system> - <group>` or `<system> - <group> - <suffix>`. Names are unique, ignoring case |
| `description` | Managed only when present; leave it out to keep whatever is set |
| `policyExemption` | Why this environment does not follow the group policy (at least 10 characters). Reviewed like code |
| `exclusiveLock` | `enabled`, optional `timeoutMinutes`. One run at a time; later runs wait |
| `branchControl` | `enabled`, `allowedBranches` (full refs, wildcards like `refs/heads/release/*`, or `*`), `verifyBranchProtection` (the branch must have a branch policy), optional `timeoutMinutes` |
| `approval` | `enabled`, `approvers`, `minRequiredApprovers`, `requesterCannotBeApprover`, optional `executionOrder` (`anyOrder` or `inSequence`), `instructions`, `timeoutMinutes` |

A managed check that is absent or has `"enabled": false` **must not exist**: `Set-Environments.ps1`
deletes it. Checks of other types (business hours, required template, ...) are left alone.

Approvers are users by e-mail address (`alice@example.com`) or groups by their full name
(`[shop]\Production Approvers` for a project group, `[my-org]\Release Managers` for an organisation
group). They are resolved to identity IDs at apply time; an unknown or ambiguous name stops the run
before anything is written.

### Policy and exemptions

| Policy | Every environment of the group needs |
| --- | --- |
| `requireFourEyes` | an `approval` with `requesterCannotBeApprover: true` |
| `requireBranchControl` | a `branchControl` |
| `requireExclusiveLock` | an `exclusiveLock` |

An environment that must deviate states why in `policyExemption`; the sample does that for
`shop - prod - Diagnostics`, which runs read-only queries with a reader service connection. The
exemption is visible in the pull request, so the deviation gets reviewed instead of slipping in.

### Rules beyond the schema

- every file uses the same `system`; a `group` appears in one file only;
- names follow the convention and are unique, ignoring case;
- branch control that is enabled has at least one branch;
- an approval that is enabled has approvers, and no more required approvers than listed approvers -
  **a group counts as one approver**, however many members it has (see
  [Four eyes and approvals](four-eyes-and-approvals.md#minimum-approvers-and-groups));
- the group policy holds, unless an environment has a `policyExemption`.

## orchestration/system.json

The system as orchestration sees it.

```json
{
  "$schema": "../schemas/system.schema.json",
  "system": "shop",
  "defaultBranch": "refs/heads/main",
  "environments": {
    "dev":  { "subscriptionId": "00000000-0000-0000-0000-000000000011", "deployAll": true, "redeploy": true, "remove": true },
    "prod": { "subscriptionId": "00000000-0000-0000-0000-000000000014", "protected": true }
  },
  "components": [
    { "name": "network", "pipeline": "shop-network", "resourceGroup": "rg-shop-{env}-network", "dependsOn": [] },
    { "name": "data", "pipeline": "shop-data", "environmentSuffix": "Data", "resourceGroup": "rg-shop-{env}-data", "dependsOn": ["network"] }
  ],
  "cleanup": {
    "resourceGroupPattern": "rg-shop-{env}-*",
    "protectedRoleNames": ["Owner", "User Access Administrator"],
    "minimumAgeDays": 7,
    "maxOrphanRatio": 0.5,
    "minimumAssignmentsForRatioCheck": 20
  }
}
```

### Environments

| Key | Default | Meaning |
| --- | --- | --- |
| `subscriptionId` | required | Every Azure CLI call passes it; the default subscription is never used |
| `protected` | `false` | Never removable, whatever else says so |
| `deployAll` | `false` | Allows `Invoke-Rollout.ps1 -Mode DeployAll` |
| `redeploy` | `false` | Allows `Invoke-Rollout.ps1 -Mode Redeploy` |
| `remove` | `false` | Allows `Remove-Environment.ps1`. Not allowed together with `protected` |

Every action is off unless switched on. On top of that, removal is refused for names that look like
production (`prod`, `prd`, `production`, `live` as a separate word), even if the configuration
allows it.

### Components

| Key | Meaning |
| --- | --- |
| `name` | Unique name, used by `-Components` and `dependsOn` |
| `pipeline` | Name of the Azure DevOps pipeline that deploys the component. It must accept a template parameter `environment` |
| `branch` | Branch to deploy from in deploy all; default `defaultBranch` |
| `environmentSuffix` | Deploys to `<system> - <env> - <suffix>` instead of `<system> - <env>` |
| `resourceGroup` | Resource group of the component; `{env}` is replaced. Removal deletes it |
| `dependsOn` | Components that must be deployed first (and removed last). No cycles |

Rules: names are unique, dependencies exist, no cycles, and for every environment: a
`environments/<env>.json` exists, every component's Azure DevOps environment is defined in it, and
a removable environment has its `<system> - <env> - RemoveAll` gate.

### Cleanup

| Key | Default | Meaning |
| --- | --- | --- |
| `resourceGroupPattern` | required | Which resource groups to scan; `{env}` is replaced, `*` is a wildcard |
| `protectedRoleNames` | Owner, User Access Administrator | Reported, never deleted |
| `minimumAgeDays` | 7 | Assignments younger than this are left alone |
| `maxOrphanRatio` | 0.5 | Circuit breaker: stop when a larger share of the assignments looks orphaned |
| `minimumAssignmentsForRatioCheck` | 20 | Below this number the ratio is not meaningful and not checked |
