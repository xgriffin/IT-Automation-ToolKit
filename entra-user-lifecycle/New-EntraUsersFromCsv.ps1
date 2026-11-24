#Requires -Version 7.0
#Requires -Modules Microsoft.Graph.Authentication, Microsoft.Graph.Users, Microsoft.Graph.Groups, Microsoft.Graph.Identity.DirectoryManagement

<#
.SYNOPSIS
    Bulk-onboards new hires into Microsoft Entra ID from a CSV file.

.DESCRIPTION
    For each row in the CSV, this script:
      1. Builds a UPN (first.last@domain) and makes sure it isn't already taken
      2. Creates the user with a random temporary password (must change at first sign-in)
      3. Sets department, job title, office location and usage location
      4. Assigns the user's manager
      5. Adds the user to the listed security / M365 groups
      6. Assigns a license by SKU part number (e.g. O365_BUSINESS_PREMIUM)

    Every action is logged, and a results CSV is written at the end containing the
    temporary passwords so they can be handed off securely (then delete the file).

    Supports -WhatIf so you can dry-run the whole batch without changing anything.

.PARAMETER CsvPath
    Path to the new-hire CSV. See sample-new-hires.csv for the expected columns.

.PARAMETER Domain
    The verified domain to build UPNs with, e.g. contoso.com

.PARAMETER OutputFolder
    Where the log and results files are written. Defaults to .\output

.EXAMPLE
    .\New-EntraUsersFromCsv.ps1 -CsvPath .\sample-new-hires.csv -Domain contoso.com -WhatIf

.EXAMPLE
    .\New-EntraUsersFromCsv.ps1 -CsvPath .\new-hires.csv -Domain contoso.com
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$CsvPath,

    [Parameter(Mandatory)]
    [string]$Domain,

    [string]$OutputFolder = (Join-Path $PSScriptRoot 'output')
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'LifecycleHelpers.ps1')

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
New-Item -ItemType Directory -Path $OutputFolder -Force -WhatIf:$false | Out-Null
$script:LogFile = Join-Path $OutputFolder "onboarding-$timestamp.log"
$resultsFile    = Join-Path $OutputFolder "onboarding-results-$timestamp.csv"

$requiredColumns = 'FirstName', 'LastName', 'Department', 'JobTitle', 'UsageLocation'
$rows = @(Import-Csv -Path $CsvPath)
if (-not $rows.Count) { throw "No rows found in $CsvPath" }
$missing = $requiredColumns | Where-Object { $_ -notin $rows[0].PSObject.Properties.Name }
if ($missing) { throw "CSV is missing required column(s): $($missing -join ', ')" }

Connect-LifecycleGraph -Scopes 'User.ReadWrite.All', 'Group.ReadWrite.All', 'Directory.Read.All'

# Cache license SKUs once instead of looking them up for every user
$skuLookup = @{}
Get-MgSubscribedSku -All | ForEach-Object { $skuLookup[$_.SkuPartNumber] = $_ }

$results = foreach ($row in $rows) {
    $displayName = "$($row.FirstName) $($row.LastName)"
    $result = [ordered]@{
        DisplayName       = $displayName
        UserPrincipalName = $null
        TempPassword      = $null
        Status            = 'Pending'
        Notes             = [System.Collections.Generic.List[string]]::new()
    }

    try {
        $upn = Get-AvailableUpn -FirstName $row.FirstName -LastName $row.LastName -Domain $Domain
        $result.UserPrincipalName = $upn

        if (-not $PSCmdlet.ShouldProcess($upn, 'Create Entra ID user')) {
            $result.Status = 'WhatIf'
            $result.Notes = ''
            [pscustomobject]$result
            continue
        }

        $tempPassword = New-TempPassword
        $userParams = @{
            AccountEnabled    = $true
            DisplayName       = $displayName
            GivenName         = $row.FirstName
            Surname           = $row.LastName
            UserPrincipalName = $upn
            MailNickname      = $upn.Split('@')[0]
            Department        = $row.Department
            JobTitle          = $row.JobTitle
            UsageLocation     = $row.UsageLocation   # required before a license can be assigned
            PasswordProfile   = @{
                Password                      = $tempPassword
                ForceChangePasswordNextSignIn = $true
            }
        }
        if ($row.OfficeLocation) { $userParams.OfficeLocation = $row.OfficeLocation }

        $user = New-MgUser @userParams
        $result.TempPassword = $tempPassword
        Write-Log "Created $upn ($($user.Id))"

        # Manager
        if ($row.ManagerUpn) {
            try {
                $manager = Get-MgUser -UserId $row.ManagerUpn
                Set-MgUserManagerByRef -UserId $user.Id -BodyParameter @{
                    '@odata.id' = "https://graph.microsoft.com/v1.0/users/$($manager.Id)"
                }
                Write-Log "  Manager set to $($row.ManagerUpn)"
            }
            catch {
                $result.Notes.Add("Manager not set: $($_.Exception.Message)")
                Write-Log "  Could not set manager $($row.ManagerUpn): $($_.Exception.Message)" -Level WARN
            }
        }

        # Groups (semicolon-separated display names)
        foreach ($groupName in (Split-ListValue $row.Groups)) {
            try {
                $group = Get-MgGroup -Filter "displayName eq '$($groupName.Replace("'", "''"))'" -Top 1
                if (-not $group) { throw "group not found" }
                New-MgGroupMember -GroupId $group.Id -DirectoryObjectId $user.Id
                Write-Log "  Added to group '$groupName'"
            }
            catch {
                $result.Notes.Add("Group '$groupName' failed")
                Write-Log "  Could not add to group '$groupName': $($_.Exception.Message)" -Level WARN
            }
        }

        # License
        if ($row.LicenseSku) {
            $sku = $skuLookup[$row.LicenseSku]
            if (-not $sku) {
                $result.Notes.Add("License SKU '$($row.LicenseSku)' not found in tenant")
                Write-Log "  License SKU '$($row.LicenseSku)' not found in tenant" -Level WARN
            }
            elseif (($sku.PrepaidUnits.Enabled - $sku.ConsumedUnits) -lt 1) {
                $result.Notes.Add("No free '$($row.LicenseSku)' licenses")
                Write-Log "  No available '$($row.LicenseSku)' licenses" -Level WARN
            }
            else {
                Set-MgUserLicense -UserId $user.Id -AddLicenses @(@{ SkuId = $sku.SkuId }) -RemoveLicenses @() | Out-Null
                $sku.ConsumedUnits++   # keep the cached count accurate for the rest of the batch
                Write-Log "  Assigned license $($row.LicenseSku)"
            }
        }

        $result.Status = if ($result.Notes.Count) { 'CreatedWithWarnings' } else { 'Created' }
    }
    catch {
        $result.Status = 'Failed'
        $result.Notes.Add($_.Exception.Message)
        Write-Log "FAILED for $displayName : $($_.Exception.Message)" -Level ERROR
    }

    $result.Notes = $result.Notes -join '; '
    [pscustomobject]$result
}

$results | Export-Csv -Path $resultsFile -NoTypeInformation -WhatIf:$false
$results | Format-Table DisplayName, UserPrincipalName, Status, Notes -AutoSize

Write-Log "Done. $(@($results | Where-Object Status -like 'Created*').Count) created, $(@($results | Where-Object Status -eq 'Failed').Count) failed."
Write-Log "Results: $resultsFile"
if (-not $WhatIfPreference) {
    Write-Warning "The results file contains temporary passwords. Hand them off securely, then delete it."
}
