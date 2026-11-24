#Requires -Version 7.0
#Requires -Modules Microsoft.Graph.Authentication, Microsoft.Graph.Users, Microsoft.Graph.Groups, Microsoft.Graph.Users.Actions

<#
.SYNOPSIS
    Offboards one or more departing users in Microsoft Entra ID.

.DESCRIPTION
    For each user, this script:
      1. Exports a "before" snapshot (groups, licenses, manager) so access can be restored if needed
      2. Blocks sign-in
      3. Revokes all active sessions / refresh tokens (signs them out everywhere)
      4. Removes the user from all assigned (non-dynamic) groups
      5. Removes all direct license assignments (optional, see -KeepLicenses)

    Mailbox conversion / forwarding is intentionally left out because it needs the
    Exchange Online module. See the README for the next steps.

    Supports -WhatIf for a dry run.

.PARAMETER UserPrincipalName
    One or more UPNs to offboard. Accepts pipeline input.

.PARAMETER KeepLicenses
    Leave licenses in place (e.g. if the mailbox must stay licensed during a litigation hold).

.EXAMPLE
    .\Disable-EntraUser.ps1 -UserPrincipalName jane.doe@contoso.com -WhatIf

.EXAMPLE
    Import-Csv .\leavers.csv | Select-Object -ExpandProperty UserPrincipalName | .\Disable-EntraUser.ps1
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory, ValueFromPipeline)]
    [string[]]$UserPrincipalName,

    [switch]$KeepLicenses,

    [string]$OutputFolder = (Join-Path $PSScriptRoot 'output')
)

begin {
    $ErrorActionPreference = 'Stop'
    . (Join-Path $PSScriptRoot 'LifecycleHelpers.ps1')

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    New-Item -ItemType Directory -Path $OutputFolder -Force -WhatIf:$false | Out-Null
    $script:LogFile = Join-Path $OutputFolder "offboarding-$timestamp.log"

    Connect-LifecycleGraph -Scopes 'User.ReadWrite.All', 'Group.ReadWrite.All', 'Directory.Read.All'
    $operator = (Get-MgContext).Account
}

process {
    foreach ($upn in $UserPrincipalName) {
        try {
            $user = Get-MgUser -UserId $upn -Property Id, DisplayName, UserPrincipalName, AccountEnabled
        }
        catch {
            Write-Log "User $upn not found: $($_.Exception.Message)" -Level ERROR
            continue
        }

        if (-not $PSCmdlet.ShouldProcess($upn, 'Disable account, revoke sessions, remove groups and licenses')) {
            continue
        }

        Write-Log "Offboarding $($user.DisplayName) <$upn>"

        # 1. Snapshot current access before removing anything
        $groups = @(Get-MgUserMemberOf -UserId $user.Id -All |
            Where-Object { $_.AdditionalProperties['@odata.type'] -eq '#microsoft.graph.group' })
        $licenses = @(Get-MgUserLicenseDetail -UserId $user.Id)
        $manager = $null
        try { $manager = (Get-MgUserManager -UserId $user.Id).AdditionalProperties['userPrincipalName'] } catch { }

        $snapshot = [pscustomobject]@{
            UserPrincipalName = $upn
            DisplayName       = $user.DisplayName
            Manager           = $manager
            Groups            = $groups | ForEach-Object {
                [pscustomobject]@{
                    Id          = $_.Id
                    DisplayName = $_.AdditionalProperties['displayName']
                    Dynamic     = $_.AdditionalProperties['groupTypes'] -contains 'DynamicMembership'
                    OnPremSync  = [bool]$_.AdditionalProperties['onPremisesSyncEnabled']
                }
            }
            Licenses          = $licenses | Select-Object SkuId, SkuPartNumber
            OffboardedBy      = $operator
            OffboardedAt      = (Get-Date).ToString('o')
        }
        $snapshotFile = Join-Path $OutputFolder ("snapshot-{0}-{1}.json" -f $upn.Split('@')[0], $timestamp)
        $snapshot | ConvertTo-Json -Depth 5 | Set-Content -Path $snapshotFile -WhatIf:$false
        Write-Log "  Saved access snapshot to $snapshotFile"

        # 2. Block sign-in
        Update-MgUser -UserId $user.Id -AccountEnabled:$false
        Write-Log "  Sign-in blocked"

        # 3. Kill existing sessions
        Revoke-MgUserSignInSession -UserId $user.Id | Out-Null
        Write-Log "  Sessions revoked"

        # 4. Group removal (dynamic and on-prem synced groups can't be edited here)
        foreach ($g in $snapshot.Groups) {
            if ($g.Dynamic -or $g.OnPremSync) {
                Write-Log "  Skipped '$($g.DisplayName)' (dynamic or synced from on-prem AD)" -Level WARN
                continue
            }
            try {
                Remove-MgGroupMemberByRef -GroupId $g.Id -DirectoryObjectId $user.Id
                Write-Log "  Removed from '$($g.DisplayName)'"
            }
            catch {
                Write-Log "  Could not remove from '$($g.DisplayName)': $($_.Exception.Message)" -Level WARN
            }
        }

        # 5. Licenses
        if ($KeepLicenses) {
            Write-Log "  Licenses kept (-KeepLicenses)"
        }
        elseif ($licenses.Count) {
            try {
                Set-MgUserLicense -UserId $user.Id -AddLicenses @() -RemoveLicenses @($licenses.SkuId) | Out-Null
                Write-Log "  Removed licenses: $($licenses.SkuPartNumber -join ', ')"
            }
            catch {
                # Usually means the license comes from group-based licensing
                Write-Log "  Could not remove licenses (group-based licensing?): $($_.Exception.Message)" -Level WARN
            }
        }

        Write-Log "  Done with $upn"
    }
}

end {
    Write-Log "Offboarding run complete. Log: $script:LogFile"
}
