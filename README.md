# create-subscription

A GitHub Actions workflow that creates **one Azure subscription** (EA or MCA) and
places it directly into the management group you name. PowerShell 7 and the
`Az.Accounts` module only: no Azure CLI, no Terraform, no state, no secrets.

| File | What it is |
|---|---|
| `.github/workflows/create-subscription.yml` | The workflow. Manual dispatch only. |
| `scripts/New-AzureSubscription.ps1` | The whole job: preflight, create, place in the management group, verify. Run by the workflow, or by hand. |
| `scripts/Grant-SubscriptionCreatorRole.ps1` | One-time setup helper: grants the service principal the billing role. Run locally, as a billing owner. |

What it does, in order:

1. **Sign in** with a GitHub OIDC token (no client secret anywhere).
2. **Preflight, read-only**: the billing scope is readable and what agreement type it is, which billing roles the identity holds, the target management group exists, **the alias name is free**, and whether the display name collides.
3. **Create** the subscription alias, with the management group in the same call.
4. **Poll** until provisioning completes.
5. **Verify** the subscription is under the target management group, and place it explicitly if the alias call did not.

> **It creates a subscription; it does not manage one.** There is no state, so
> nothing detects drift and re-running does not converge. Adopt the subscription
> into your infrastructure-as-code afterwards by its id if you need that.

---

## What you need

| | Requirement |
|---|---|
| **Runner** | GitHub-hosted `ubuntu-latest` (PowerShell 7 preinstalled; `Az.Accounts` is installed for the current user if missing). Self-hosted runners need PowerShell 7 and outbound access to PSGallery or a pre-installed `Az.Accounts`. |
| **Service principal** | An Entra app registration with a **federated credential** for this repository (step 2). |
| **Billing role on the SP** | EA: `SubscriptionCreator` on the enrollment account. MCA: `Azure subscription creator` on the invoice section (step 3). |
| **Azure RBAC on the SP** | `Management Group Contributor` on the target management group, or on a parent of every group you will target (step 4). |
| **You, once** | Owner on the billing account / enrollment to grant the billing role; sufficient rights on the management group to assign the RBAC role. |
| **Repo variables** | `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `BILLING_SCOPE` (step 5). |

---

## Setup, once

### Step 1: create the service principal

Azure portal, **Entra ID > App registrations > New registration**:

- Name: `github-subscription-creator` (anything you like)
- Supported account types: **single tenant**
- Redirect URI: leave blank
- Register, then note the **Application (client) ID** and **Directory (tenant) ID**

Also note the **Object ID** of the *enterprise application* (**Entra ID > Enterprise
applications > your app**). Step 3 can look it up, but having it removes the need for
any Microsoft Graph permission.

### Step 2: add the federated credential (OIDC, no secrets)

First ask GitHub which subject format this repository presents. It is a per-repository
setting, and repositories created recently default to the *immutable* form:

```bash
gh api repos/<org>/<repo>/actions/oidc/customization/sub --jq .sub_claim_prefix
```

| Prefix returned | Format |
|---|---|
| `repo:<org>/<repo>` | classic |
| `repo:<org>@<owner-id>/<repo>@<repo-id>` | immutable |

In the app registration, **Certificates & secrets > Federated credentials > Add credential**:

- **Classic prefix**: choose *GitHub Actions deploying Azure resources*. Organization =
  `<org>`, Repository = `<repo>`, Entity type = **Branch**, Branch = your default branch
  (`main`), Name = `gh-branch-main`.
- **Immutable prefix** (contains `@`): the same *GitHub Actions* form, filling the
  **Organization ID** and **Repository ID** fields as well. Both numbers are in the
  prefix (`repo:<org>@<org-id>/<repo>@<repo-id>`), or individually:
  `gh api orgs/<org> --jq .id` (a personal account: `gh api users/<user> --jq .id`) and
  `gh api repos/<org>/<repo> --jq .id`. If your portal does not show the ID fields,
  choose *Other issuer* instead: issuer `https://token.actions.githubusercontent.com`,
  subject `<prefix>:ref:refs/heads/main`, audience `api://AzureADTokenExchange`.

After saving, the credential's subject shown in the portal must equal the prefix plus
`:ref:refs/heads/main`, byte for byte. On GitHub Enterprise **Server** the issuer is
`https://<your-ghes-host>/_services/token`; GitHub Enterprise Cloud uses the issuer above.

A `workflow_dispatch` run on the default branch with no environment presents exactly
`<prefix>:ref:refs/heads/main`. Do not use a wildcard subject: Entra rejects them. If
you later attach a GitHub Environment to the job, the subject becomes
`<prefix>:environment:<name>` and needs a second credential; this workflow uses none.

### Step 3: grant the billing role

This is the step that decides whether creation works, and the usual cause of a `403`.

```powershell
Connect-AzAccount -Tenant <your-tenant-guid>

./scripts/Grant-SubscriptionCreatorRole.ps1 `
    -BillingScope '<your billing scope, see below>' `
    -ApplicationId '<the client id from step 1>'
```

Your billing scope is one of these shapes:

| Agreement | Scope | Role granted |
|---|---|---|
| **EA** | `/providers/Microsoft.Billing/billingAccounts/{enrollmentNumber}/enrollmentAccounts/{enrollmentAccountId}` | `SubscriptionCreator` |
| **MCA** | `/providers/Microsoft.Billing/billingAccounts/{ba}/billingProfiles/{bp}/invoiceSections/{is}` | `Azure subscription creator` |

Find it in the portal under **Cost Management + Billing > Billing scopes**; on the
invoice section or enrollment account, **Properties** shows the ids.

You must be signed in as an **owner on the billing account** for this step. A
subscription-level Owner is not enough: billing roles are a separate system from Azure
RBAC.

> **Some billing accounts refuse billing-role writes over the API.** Common on EA and
> seen on MCA, even when you hold owner at the billing account, billing profile and
> invoice section. It is an Azure-side restriction, not something more access fixes.
> The script then prints the exact portal path: **Cost Management + Billing > your
> invoice section or enrollment account > Access control (IAM) > Add > role
> "Azure subscription creator" (MCA) / "Subscription creator" (EA) > your service
> principal**. That route works.

### Step 4: give the service principal access to the management group

The identity needs write access on the target management group to place the
subscription there. On the management group that is the parent of everything you will
target: **Management groups > your group > Access control (IAM) > Add role assignment >
`Management Group Contributor` > your service principal**.

`Management Group Contributor` is enough to place a subscription. Grant `Owner` only if
the same identity will also deploy resources inside the subscriptions.

### Step 5: set three repository variables

**Settings > Secrets and variables > Actions > Variables**, or:

```bash
gh variable set AZURE_CLIENT_ID -R <org>/<repo> -b "<client-id>"
gh variable set AZURE_TENANT_ID -R <org>/<repo> -b "<tenant-id>"
gh variable set BILLING_SCOPE   -R <org>/<repo> -b "<billing-scope>"
```

| Variable | Value |
|---|---|
| `AZURE_CLIENT_ID` | Application (client) ID from step 1 |
| `AZURE_TENANT_ID` | Directory (tenant) ID from step 1 |
| `BILLING_SCOPE` | The billing scope from step 3. Can be overridden per run. |
| `AZURE_SUBSCRIPTION_ID` | Optional. Any existing subscription, only to give the PowerShell session a context. |

**Variables, not secrets.** Client and tenant ids are public identifiers and the billing
scope is a resource path. There is no client secret anywhere; that is the point of OIDC.

---

## Using it

**Actions > create-subscription > Run workflow.**

| Input | Notes |
|---|---|
| `display_name` | **Required.** What you will see in the portal. |
| `management_group_id` | **Required.** The management group **id** (for example `landingzones`), not its display name. Must already exist. |
| `mode` | `preflight` (default, read-only) or `create`. |
| `confirm` | Type `create-subscription`. Required when `mode=create`, ignored otherwise. |
| `billing_scope` | Leave blank to use the `BILLING_SCOPE` variable. |
| `alias_name` | Leave blank to derive it from the display name. **Permanent**: see below. |
| `workload` | `Production` or `DevTest` (DevTest needs an eligible billing scope). |
| `tags` | `key=value,key=value` |

### Always run `preflight` first

It is read-only and costs nothing. It proves the OIDC sign-in, the billing scope, the
roles the identity holds, the management group, and that the alias name is free. Then
re-run with `mode=create` and the confirmation phrase.

Runs are serialised (`concurrency` group): two at once against the same billing scope
get throttled and can race on the alias name.

### Running it locally

Identical behaviour, useful for debugging:

```powershell
Connect-AzAccount -Tenant <tenant-guid>

./scripts/New-AzureSubscription.ps1 `
    -DisplayName 'Payments UK (dev)' `
    -BillingScope '/providers/Microsoft.Billing/billingAccounts/12345678/enrollmentAccounts/98765' `
    -ManagementGroupId 'landingzones' `
    -PreflightOnly
```

Drop `-PreflightOnly` to create it. Locally it uses your own sign-in, so your
permissions apply, not the service principal's. To test what the *service principal*
can do, use the workflow.

---

## The alias trap: read this once

A subscription **alias** is a tenant-level, immutable name binding that **outlives the
subscription it created**. Cancel the subscription and the alias remains. Reuse that
alias name later and Azure **silently returns the old, cancelled subscription** with
HTTP 200: no error, no warning. You notice when deployments target a dead subscription.

The preflight refuses to proceed if the alias already exists. To reuse the name, free
it first (this does not delete or cancel the subscription it points to):

```powershell
Invoke-AzRestMethod -Method DELETE `
  -Path '/providers/Microsoft.Subscription/aliases/<alias-name>?api-version=2021-10-01'
```

A subscription can be *cancelled* but never truly deleted, and a cancelled subscription
still counts against EA/MCA quota until it ages out. Do not create test subscriptions
casually.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `The action actions/checkout@... is not allowed` | The organization or enterprise restricts Actions | The workflow's only action, `actions/checkout`, is created by GitHub and pinned to a full commit SHA, so it passes "GitHub + verified creators" and "require full-length SHA pins" policies. If yours allowlists specific actions instead, allow `actions/checkout`. |
| `AADSTS700213` / no matching federated identity | The OIDC subject does not match the federated credential | Step 2. The error shows the subject GitHub sent; make the credential match it byte for byte (classic vs immutable prefix, org, repo, branch). Run from the default branch with no environment. |
| `HTTP 403` on create | The service principal lacks the billing role | Step 3. If the API refuses the grant, use the portal route. |
| `HTTP 400` on create | Wrong billing scope shape, or the billing account is out of subscription quota | Check the scope; check quota in the portal. |
| `management group '<x>' does not exist` | The display name was used instead of the id | Use the id (lowercase, no spaces). |
| `alias ... ALREADY EXISTS` | The alias trap above | Pick another `alias_name`, or free the alias. |
| Created but **not placed** in the management group | The identity cannot write to the target group | Step 4. The subscription exists in the tenant root: move it, then fix the role. |
| `HTTP 429` | Billing API throttling | Wait a few minutes. Do not run two at once. |
| Preflight cannot read the billing scope | Normal on many EA enrollments | Read and create are separate permissions; try `mode=create`. |
