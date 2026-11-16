# Four eyes and approvals

The four-eyes principle: no change reaches production on the say-so of one person. In Azure DevOps
that takes two independent controls, and this playbook puts both under version control.

| Control | Guards | Where |
| --- | --- | --- |
| **Branch policy** on main (required reviewer, build validation) | the **code**: nobody merges their own change unreviewed | repository settings |
| **Approval check** with *requester cannot approve* on the environment | the **deployment**: nobody releases their own run unapproved | `approval` in `environments/<group>.json` |
| **Branch control** with *verify branch protection* on the environment | that the run comes from the **reviewed** branch, not a feature branch | `branchControl` in `environments/<group>.json` |

Without branch control, an approver approves a run without knowing whether the code was reviewed.
Without the approval, a reviewed change goes out the moment it merges, whoever merged it. Together
they mean: reviewed code, from main, released by someone other than the person who started it.

## Why checks on environments, not steps in the YAML

A `ManualValidation` task or an approval stage in the pipeline file can be removed by whoever edits
the pipeline file - in a branch, in the same pull request that changes the code. A check on an
environment lives outside the pipeline: every deployment job that targets the environment hits it,
whatever its YAML says. That is why every gate in this playbook is an environment check, and why
the [remove pipeline](../pipelines/remove.yml) approves through a deployment job on a dedicated
`RemoveAll` environment instead of a task in its own file.

The one exception is the cleanup review, a `ManualValidation` task: there the person reviews a
report, which an environment approval cannot show.

## Requester cannot approve

`requesterCannotBeApprover: true` is the box *Approvers can't approve their own runs*. The
requester is the person the run is *requested for*: whoever queued it by hand, or for a CI run the
person whose push or pull request completion triggered it.

`Test-Configuration.ps1` enforces it for every environment of a group with
`"policy": { "requireFourEyes": true }`, unless the environment has a written `policyExemption`.

### Orchestration changes who the requester is

When a pipeline queues another pipeline with the job access token - as
[deploy all](orchestrating-an-environment.md#deploy-all) does - the queued run is requested for the
build service identity, not for the person who started deploy all. *Requester cannot approve* then
compares the approver with the build service, so the person who started deploy all could approve
the deployment it triggered.

> UNVERIFIED in the tests (the fake cannot show it): check in your organisation which identity a run
> queued through the REST API with `System.AccessToken` is requested for.

The playbook's answer: **deploy all and redeploy are switched off for production**
(`"deployAll": false`, `"redeploy": false` in `system.json`, and prod is not offered in the
pipelines). Production deploys through the normal component pipelines, triggered by a merge or
queued by a person, where the requester is a person. If you do orchestrate an environment with
approvals (acc in the sample), make sure the people who may start the orchestrator are not the only
approvers.

## Minimum approvers and groups

- `approvers` lists users and groups. **A group counts as one approver**: any one member approves
  on behalf of the group.
- `minRequiredApprovers` is how many of the listed approvers must approve. With one group and
  `1`, any one member is enough. With two groups and `2`, two approvals are needed; with disjoint
  groups that means a database administrator *and* a production approver, as on
  `shop - prod - Data` in the sample.
- A higher minimum than the number of listed approvers can never be met; the configuration check
  refuses it.
- `executionOrder: inSequence` makes the approvals happen in the listed order, for example the expert
  first, the release manager second.

> UNVERIFIED: how Azure DevOps counts one person who is a member of both listed groups. Do not rely on
> group membership alone to guarantee two different people; keep the groups disjoint.

### An expert plus a second person

Some changes are risky enough that one specific kind of expert must do or review them and a second
person must check - in the source, deploying a firewall change. As an environment:

```json
{
  "name": "shop - prod - Network",
  "approval": {
    "enabled": true,
    "approvers": ["[shop]\\Network Experts", "[shop]\\Production Approvers"],
    "minRequiredApprovers": 2,
    "executionOrder": "inSequence",
    "requesterCannotBeApprover": true,
    "instructions": "A network expert reviews the rule changes first; then a production approver."
  }
}
```

and a component with `"environmentSuffix": "Network"`. The source enforced this rule by agreement;
as a check it holds even when nobody remembers the agreement.

## Exclusive lock

`exclusiveLock` lets one run at a time use the environment; later runs wait. It stops two releases,
or a release and a teardown, from interleaving. Whether a waiting run waits its turn or is
superseded by a newer one is set in the pipeline (`lockBehavior: sequential` or `runLatest`), not on
the environment.

## Who guards the guards

The checks are now code. Whoever can change `environments/*.json` on main can change who approves
production. So:

1. **Protect the branch** of this configuration with a required reviewer from a group that is not
   the group asking for the change. Changes to `prod.json` get the same four eyes as a production
   release.
2. **Restrict who may run** `pipelines/environments.yml` and who has the Administrator role on the
   environments: the apply identity, plus a small break-glass group (`security.administrators`).
3. **Detect hand edits.** The nightly `-Check` run fails as soon as someone changes a check in the
   portal. The next apply reverts it; either way it is visible.

## Emergencies

Do not remove an approval to get a fix out at night: add an on-call approver to the group, or ask
one. If a check must go, change the configuration in a reviewed pull request, so the change and its
reversal are in the history. A check removed in the portal shows up in the next drift check.
