# Shared helper functions for the onboarding and offboarding scripts.
# Dot-source this file:  . .\LifecycleHelpers.ps1

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )
    $line = "{0} [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    switch ($Level) {
        'WARN'  { Write-Warning $Message }
        'ERROR' { Write-Host $line -ForegroundColor Red }
        default { Write-Host $line }
    }
    if ($script:LogFile) { Add-Content -Path $script:LogFile -Value $line -WhatIf:$false }
}

function Connect-LifecycleGraph {
    param([Parameter(Mandatory)][string[]]$Scopes)
    $context = Get-MgContext
    $missing = if ($context) { $Scopes | Where-Object { $_ -notin $context.Scopes } } else { $Scopes }
    if ($missing) {
        Write-Log "Connecting to Microsoft Graph (scopes: $($Scopes -join ', '))"
        Connect-MgGraph -Scopes $Scopes -NoWelcome
    }
    Write-Log "Connected to tenant $((Get-MgContext).TenantId) as $((Get-MgContext).Account)"
}

function ConvertTo-UpnPart {
    # "María-José O'Brien" -> "mariajose", "obrien"
    param([Parameter(Mandatory)][string]$Value)
    $normalized = $Value.Normalize([Text.NormalizationForm]::FormD)
    $ascii = -join ($normalized.ToCharArray() | Where-Object {
        [Globalization.CharUnicodeInfo]::GetUnicodeCategory($_) -ne 'NonSpacingMark'
    })
    ($ascii -replace '[^a-zA-Z0-9]', '').ToLower()
}

function Get-AvailableUpn {
    # Returns first.last@domain, or first.last2@domain, first.last3@domain ... if taken
    param(
        [Parameter(Mandatory)][string]$FirstName,
        [Parameter(Mandatory)][string]$LastName,
        [Parameter(Mandatory)][string]$Domain
    )
    $base = "{0}.{1}" -f (ConvertTo-UpnPart $FirstName), (ConvertTo-UpnPart $LastName)
    $candidate = "$base@$Domain"
    $n = 2
    while (Get-MgUser -Filter "userPrincipalName eq '$candidate'" -ErrorAction SilentlyContinue) {
        $candidate = "$base$n@$Domain"
        $n++
    }
    $candidate
}

function New-TempPassword {
    # 16 chars from an unambiguous set, guaranteed to include upper, lower, digit and symbol.
    param([int]$Length = 16)
    $sets = @(
        'ABCDEFGHJKLMNPQRSTUVWXYZ',
        'abcdefghijkmnopqrstuvwxyz',
        '23456789',
        '!@#$%*?-'
    )
    $all = -join $sets
    $chars = [System.Collections.Generic.List[char]]::new()
    foreach ($set in $sets) { $chars.Add($set[[Security.Cryptography.RandomNumberGenerator]::GetInt32($set.Length)]) }
    while ($chars.Count -lt $Length) { $chars.Add($all[[Security.Cryptography.RandomNumberGenerator]::GetInt32($all.Length)]) }
    # Shuffle so the guaranteed characters aren't always at the front
    -join ($chars | Sort-Object { [Security.Cryptography.RandomNumberGenerator]::GetInt32([int]::MaxValue) })
}

function Split-ListValue {
    # "IT Staff; VPN Users;" -> @('IT Staff', 'VPN Users')
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return @() }
    @($Value -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}
