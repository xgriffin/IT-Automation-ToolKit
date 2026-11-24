# Entra ID User Lifecycle Automation

PowerShell scripts that automate onboarding and offboarding in **Microsoft Entra ID** (formerly Azure AD) and Microsoft 365, using the **Microsoft Graph PowerShell SDK**.

Doing onboarding by hand means clicking through the Entra admin center for every hire. It takes 10–15 minutes per person, and it's easy to miss a group or a license. These scripts do a whole batch from one CSV, log every step, and can dry-run with `-WhatIf` first.

## What's included

| Script | What it does |
|---|---|
| `New-EntraUsersFromCsv.ps1` | Creates users from a CSV: UPN generation with duplicate handling, temporary password, profile fields, manager, group memberships, license assignment |
| `Disable-EntraUser.ps1` | Offboards users: saves an access snapshot, blocks sign-in, revokes sessions, removes groups and licenses |
| `LifecycleHelpers.ps1` | Shared functions: logging, Graph connection, UPN cleanup (accents, apostrophes), secure password generation |
| `sample-new-hires.csv` | Example input file |

## Features
- **Safe by default.** Both scripts support `-WhatIf`, and offboarding asks for confirmation (`ConfirmImpact = High`).
- **Handles real-world names.** `María-José O'Brien` becomes `mariajose.obrien@contoso.com`. If that UPN already exists, the script tries `mariajose.obrien2@…`.
- **License-aware.** It checks that free seats exist before assigning, and it sets `UsageLocation`, which Microsoft requires before a license can be assigned.
- **Reversible offboarding.** Before removing anything, the script saves each user's groups, licenses and manager to a JSON snapshot.
- **Knows the edge cases.** It skips dynamic and on-prem-synced groups, which can't be edited through Graph, and it flags group-based licensing instead of failing.
- **Audit trail.** Every run writes a timestamped log to `.\output`.

## Requirements
- PowerShell 7+
- Microsoft Graph PowerShell SDK:
  ```powershell
  Install-Module Microsoft.Graph -Scope CurrentUser
  ```
- An account with the **User Administrator** role, plus **Groups Administrator** and **License Administrator** (or equivalent). You'll be asked to consent to `User.ReadWrite.All`, `Group.ReadWrite.All` and `Directory.Read.All`.

## Usage

### Onboarding
```powershell
# Dry run: shows what would happen, changes nothing
.\New-EntraUsersFromCsv.ps1 -CsvPath .\sample-new-hires.csv -Domain contoso.com -WhatIf

# Real run
.\New-EntraUsersFromCsv.ps1 -CsvPath .\new-hires.csv -Domain contoso.com
```

CSV columns:

| Column | Required | Notes |
|---|---|---|
| FirstName, LastName | ✅ | Used for the display name and UPN |
| Department, JobTitle | ✅ | |
| UsageLocation | ✅ | Two-letter country code, e.g. `US` |
| OfficeLocation | | |
| ManagerUpn | | Manager's UPN |
| Groups | | Semicolon-separated group display names |
| LicenseSku | | SKU part number, e.g. `O365_BUSINESS_PREMIUM`. List yours with `Get-MgSubscribedSku \| Select SkuPartNumber` |

> ⚠️ The results CSV contains temporary passwords. Hand them off securely, then delete the file. `output/` is in `.gitignore`.

### Offboarding
```powershell
.\Disable-EntraUser.ps1 -UserPrincipalName jordan.reyes@contoso.com -WhatIf
.\Disable-EntraUser.ps1 -UserPrincipalName jordan.reyes@contoso.com

# Keep licenses (e.g. mailbox under legal hold)
.\Disable-EntraUser.ps1 -UserPrincipalName jordan.reyes@contoso.com -KeepLicenses

# Batch from a CSV with a UserPrincipalName column
Import-Csv .\leavers.csv | Select-Object -ExpandProperty UserPrincipalName | .\Disable-EntraUser.ps1
```

## Testing safely
Don't test against production. A free [Microsoft 365 Developer Program](https://developer.microsoft.com/microsoft-365/dev-program) tenant, if you qualify, or a trial tenant works well.

## Possible next steps
- Convert the mailbox to a shared mailbox and set an auto-reply (needs the `ExchangeOnlineManagement` module)
- Trigger onboarding automatically from an HR form or ticket (Power Automate, n8n or Jira)
- Email the manager a welcome summary
- Run unattended with app-only (certificate) authentication
