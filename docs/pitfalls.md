# Pitfalls

Things that go wrong with environments, approvals and whole-environment operations, and what this
playbook does about them.

## Environments and checks

**A deployment job creates the environment it names.** Mistype `shop - prod` as `shop -prod` in a
pipeline and the first run can create a new, empty environment without any checks and deploy
straight through. Let pipelines pick the name from a parameter with fixed `values`, as
the [component template](../pipelines/templates/deploy-component.yml) does, and remove the Creator
role on environments from the build service and from Contributors, so that only the
[environments pipeline](../pipelines/environments.yml) creates them.

> UNVERIFIED: the exact behaviour when a pipeline names a non-existing environment and its identity
> lacks the Creator role (in our understanding: the run fails instead of creating it).

**Checks belong to one environment, not to a group of names.** `shop - prod` and
`shop - prod - Data` are unrelated as far as Azure DevOps is concerned. A new suffix without its
own entry in `prod.json` has no approval. The configuration check's `requireFourEyes` policy catches
it for every environment in the file, so add the environment to the file before the first pipeline
uses it.

**Hand edits in the portal.** They work, until the next apply reverts them without warning. The
nightly `-Check` makes them visible; the fix is a pull request, not a second hand edit.

**The plan shows `UpdateCheck` on every run.** A setting is stored differently from how it is sent,
so the comparison never matches. The comparison uses a normalised signature per check
([how it works](how-it-works.md#comparing-checks)); if you add a setting, add it to the signature
and to the fake, and add a test that a second run changes nothing.

**Checks this playbook does not manage are left alone.** Business hours, required template,
Azure Function and REST API checks are reported as `Unmanaged` and neither exported nor deleted. If
you rely on one, it is configured by hand - document it, or extend the playbook.

**A deleted environment takes its history along.** The deployment records disappear, and with them
what [redeploy](orchestrating-an-environment.md#redeploy) needs and the audit trail of what was
released when. `-RemoveUndefined` needs a `-RemoveFilter`, and still only within the configured
groups.

## Approvals

**A group is one approver.** Two approvals from one group need `minRequiredApprovers: 2` *and*
two entries; see [minimum approvers and groups](four-eyes-and-approvals.md#minimum-approvers-and-groups).

**The approver is a person who left.** The run waits until the check times out. Approvers should be
groups; the configuration check cannot see this, the review of the pull request can.

**Approvals time out.** The default timeout is 30 days in the portal; the samples use shorter
values. A run that waited too long fails; it does not deploy.

**The orchestrator is the requester.** Runs queued by deploy all are requested for the build service
identity, so *requester cannot approve* no longer stops the person who started it. See
[four eyes and approvals](four-eyes-and-approvals.md#orchestration-changes-who-the-requester-is).

**The approval is in the YAML.** A `ManualValidation` task or a stage with a condition can be removed
in the same pull request that changes the code. Gates belong on environments.

## Deploy all and redeploy

**A component pipeline ignores the `environment` parameter.** It then deploys wherever its own
triggers say, for example to every environment in turn. Test each pipeline once with a single
environment before adding it to `system.json`.

**Approvals hold the wave.** Deploy all to an environment with approvals stops at every deployment
that needs one, and the orchestrating job holds an agent while it waits. Approve promptly, or keep
orchestration for environments without approvals.

**A dependency that is not in the graph.** If orders-api needs the gateway but `dependsOn` does not
say so, they may deploy in the same wave and orders-api fails - or worse, deploys against the old
gateway. The order in `system.json` is only as good as the people who reviewed it.

**Redeploy of a component that never deployed.** There is nothing to redeploy; the script stops
before queuing anything. Use deploy all first.

**Redeploy does not roll back data.** It deploys the same code and infrastructure again. Database
migrations that already ran stay; a redeploy of an older version against a newer schema can fail.

## Remove

**Removing the wrong environment.** That is why remove is off unless configured, refused for
protected and production-like names, needs the environment name typed as confirmation, and is
approved by a second person in the pipeline. Scope the service connection to one environment, so
even a broken guard cannot reach another one.

**A lock half way.** Without the lock preflight, the first resource groups are deleted and the
removal fails at the first locked one, leaving an environment that is neither there nor gone. The
script checks all locks before deleting anything.

**Things outside the resource groups.** Entra ID applications, role assignments at subscription
level, DNS records in shared zones, Key Vaults in soft-delete (whose names stay taken until purged),
Azure DevOps environments. A redeploy after remove can fail on a soft-deleted Key Vault name; purge
it or enable recovery in the deployment.

**A scheduled teardown.** Schedules cannot answer a confirmation or an approval. Do not remove the
guards from the shared remove pipeline to make a schedule work; build a separate pipeline for that
one environment.

## Cleanup

**Every principal looks deleted.** When the identity cannot read the directory, every lookup fails.
The script treats only "does not exist" as orphaned, stops on other errors, and the circuit breaker
stops when too many look orphaned - also in a dry run.

**A brand-new identity looks deleted.** Replication takes time. Assignments younger than
`minimumAgeDays` are reported as `TooRecent`.

**The approved report is stale.** Between the review and the execution, an assignment can come back
into use. The execute stage deletes only assignments that are in the report *and* still orphaned.

**Deleting the assignment that keeps you in.** Owner and User Access Administrator are
`protectedRoleNames`: reported, never deleted.

## Tests

**Debugging an entry script outside the tests.** Outside Pester the wrappers are not mocked, so a
"quick try" calls the real Azure DevOps or Azure with whatever you are signed in as. Debug through
the tests, or with `-WhatIf` and a test organisation.

**StrictMode and empty collections.** `Set-StrictMode -Version Latest` throws on a missing hashtable
key read with `.key`, on `@()[0]` and on member enumeration over an empty collection. The lib uses
`Get-OptionalValue` and wraps results in `@()`.
