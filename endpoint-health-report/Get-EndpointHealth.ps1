<#
.SYNOPSIS
    Checks the health of Windows endpoints and produces a color-coded HTML report and a CSV.

.DESCRIPTION
    Collects, from the local machine or a list of remote computers:
      - OS version and build, uptime / last boot
      - Free space on every fixed drive
      - Pending reboot (Windows Update, Component Based Servicing, pending file renames)
      - Microsoft Defender: real-time protection on, signature age
      - BitLocker protection status on the OS drive
      - Days since the last installed update
      - Total RAM

    Each check is rated OK / WARN / FAIL against the thresholds in the param block, and the
    report sorts the worst machines to the top so you know where to start.

    Runs on the built-in Windows PowerShell 5.1 as well as PowerShell 7.
    Remote collection uses PowerShell Remoting (WinRM). Run as an admin for BitLocker data.

.PARAMETER ComputerName
    One or more computers. Defaults to the local machine.

.PARAMETER ComputerListPath
    Text file with one computer name per line (alternative to -ComputerName).

.EXAMPLE
    .\Get-EndpointHealth.ps1

.EXAMPLE
    .\Get-EndpointHealth.ps1 -ComputerListPath .\computers.txt -OutputFolder C:\Reports
#>
[CmdletBinding(DefaultParameterSetName = 'Names')]
param(
    [Parameter(ParameterSetName = 'Names')]
    [string[]]$ComputerName = @($env:COMPUTERNAME),

    [Parameter(ParameterSetName = 'File', Mandatory)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$ComputerListPath,

    [string]$OutputFolder = (Join-Path $PSScriptRoot 'output'),

    # Thresholds
    [int]$DiskWarnPercent       = 20,
    [int]$DiskFailPercent       = 10,
    [int]$UptimeWarnDays        = 14,
    [int]$UptimeFailDays        = 30,
    [int]$SignatureWarnDays     = 3,
    [int]$PatchWarnDays         = 35,
    [int]$PatchFailDays         = 60
)

# ------------------------------------------------------------------------------------------
# Runs ON the endpoint (locally or through Invoke-Command). Returns raw facts, no judgement.
# ------------------------------------------------------------------------------------------
$collector = {
    $ErrorActionPreference = 'SilentlyContinue'
    $os = Get-CimInstance Win32_OperatingSystem
    $cs = Get-CimInstance Win32_ComputerSystem

    $disks = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType = 3' | ForEach-Object {
        [pscustomobject]@{
            Drive       = $_.DeviceID
            SizeGB      = [math]::Round($_.Size / 1GB, 1)
            FreeGB      = [math]::Round($_.FreeSpace / 1GB, 1)
            FreePercent = if ($_.Size) { [math]::Round(($_.FreeSpace / $_.Size) * 100, 1) } else { 0 }
        }
    })

    $pendingReasons = @()
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $pendingReasons += 'Windows Update' }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $pendingReasons += 'Component Servicing' }
    $renames = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations).PendingFileRenameOperations
    if ($renames) { $pendingReasons += 'File Rename' }

    $defender = $null
    if (Get-Command Get-MpComputerStatus) {
        $mp = Get-MpComputerStatus
        if ($mp) {
            $defender = [pscustomobject]@{
                RealTime      = [bool]$mp.RealTimeProtectionEnabled
                SignatureDate = $mp.AntivirusSignatureLastUpdated
            }
        }
    }

    $bitlocker = 'Unknown'
    if (Get-Command Get-BitLockerVolume) {
        $bl = Get-BitLockerVolume -MountPoint $env:SystemDrive
        if ($bl) { $bitlocker = [string]$bl.ProtectionStatus }   # On / Off
    }

    $lastPatch = Get-HotFix | Where-Object InstalledOn | Sort-Object InstalledOn -Descending | Select-Object -First 1

    [pscustomobject]@{
        ComputerName  = $env:COMPUTERNAME
        OS            = $os.Caption
        Build         = $os.BuildNumber
        LastBoot      = $os.LastBootUpTime
        RamGB         = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
        Disks         = $disks
        PendingReboot = $pendingReasons
        Defender      = $defender
        BitLocker     = $bitlocker
        LastPatchId   = $lastPatch.HotFixID
        LastPatchDate = $lastPatch.InstalledOn
    }
}

# ------------------------------------------------------------------------------------------
# Runs on YOUR machine: turns raw facts into OK / WARN / FAIL ratings.
# ------------------------------------------------------------------------------------------
function Get-HealthRating {
    param([Parameter(Mandatory)]$Raw, [datetime]$Now = (Get-Date))

    $checks = [ordered]@{}
    $issues = New-Object System.Collections.Generic.List[string]

    # Uptime
    $uptimeDays = [math]::Round(($Now - [datetime]$Raw.LastBoot).TotalDays, 1)
    $checks.Uptime = if ($uptimeDays -ge $UptimeFailDays) { 'FAIL' } elseif ($uptimeDays -ge $UptimeWarnDays) { 'WARN' } else { 'OK' }
    if ($checks.Uptime -ne 'OK') { $issues.Add("Up $uptimeDays days") }

    # Disks (worst drive wins)
    $worstDisk = $Raw.Disks | Sort-Object FreePercent | Select-Object -First 1
    $checks.Disk = 'OK'
    if ($worstDisk) {
        if ($worstDisk.FreePercent -le $DiskFailPercent) { $checks.Disk = 'FAIL' }
        elseif ($worstDisk.FreePercent -le $DiskWarnPercent) { $checks.Disk = 'WARN' }
        if ($checks.Disk -ne 'OK') { $issues.Add("$($worstDisk.Drive) $($worstDisk.FreePercent)% free") }
    }

    # Pending reboot
    $checks.Reboot = if (@($Raw.PendingReboot).Count) { 'WARN' } else { 'OK' }
    if ($checks.Reboot -ne 'OK') { $issues.Add("Reboot pending ($(@($Raw.PendingReboot) -join ', '))") }

    # Defender
    if (-not $Raw.Defender) {
        $checks.Defender = 'WARN'; $issues.Add('Defender status unavailable (3rd-party AV?)')
    }
    elseif (-not $Raw.Defender.RealTime) {
        $checks.Defender = 'FAIL'; $issues.Add('Real-time protection OFF')
    }
    elseif (-not $Raw.Defender.SignatureDate) {
        $checks.Defender = 'WARN'; $issues.Add('AV signature date unknown')
    }
    else {
        $sigAge = [math]::Floor(($Now - [datetime]$Raw.Defender.SignatureDate).TotalDays)
        $checks.Defender = if ($sigAge -gt $SignatureWarnDays) { 'WARN' } else { 'OK' }
        if ($checks.Defender -ne 'OK') { $issues.Add("AV signatures $sigAge days old") }
    }

    # BitLocker
    $checks.BitLocker = switch ($Raw.BitLocker) { 'On' { 'OK' } 'Off' { 'FAIL' } default { 'WARN' } }
    if ($checks.BitLocker -ne 'OK') { $issues.Add("BitLocker: $($Raw.BitLocker)") }

    # Patching
    if ($Raw.LastPatchDate) {
        $patchAge = [math]::Floor(($Now - [datetime]$Raw.LastPatchDate).TotalDays)
        $checks.Patching = if ($patchAge -ge $PatchFailDays) { 'FAIL' } elseif ($patchAge -ge $PatchWarnDays) { 'WARN' } else { 'OK' }
        if ($checks.Patching -ne 'OK') { $issues.Add("Last update $patchAge days ago") }
    }
    else {
        $patchAge = $null
        $checks.Patching = 'WARN'; $issues.Add('No update history found')
    }

    $overall = if ($checks.Values -contains 'FAIL') { 'FAIL' } elseif ($checks.Values -contains 'WARN') { 'WARN' } else { 'OK' }

    [pscustomobject]@{
        ComputerName    = $Raw.ComputerName
        Overall         = $overall
        Issues          = ($issues -join '; ')
        OS              = "$($Raw.OS) ($($Raw.Build))"
        UptimeDays      = $uptimeDays
        RamGB           = $Raw.RamGB
        LowestDiskFree  = if ($worstDisk) { "$($worstDisk.Drive) $($worstDisk.FreePercent)% ($($worstDisk.FreeGB) GB)" } else { 'n/a' }
        PendingReboot   = [bool]@($Raw.PendingReboot).Count
        DefenderRT      = if ($Raw.Defender) { $Raw.Defender.RealTime } else { $null }
        BitLocker       = $Raw.BitLocker
        LastPatch       = if ($Raw.LastPatchDate) { "$($Raw.LastPatchId) ($patchAge days)" } else { 'n/a' }
        UptimeCheck     = $checks.Uptime
        DiskCheck       = $checks.Disk
        RebootCheck     = $checks.Reboot
        DefenderCheck   = $checks.Defender
        BitLockerCheck  = $checks.BitLocker
        PatchCheck      = $checks.Patching
    }
}

function ConvertTo-HealthHtml {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Rows, [object[]]$Unreachable = @())

    $enc = { param($s) [System.Net.WebUtility]::HtmlEncode([string]$s) }
    $cell = { param($rating, $text) "<td class='$($rating.ToLower())'>$(& $enc $text)</td>" }

    $counts = $Rows | Group-Object Overall -NoElement | ForEach-Object { "$($_.Name): $($_.Count)" }
    $body = foreach ($r in $Rows) {
        "<tr>" +
        "<td><b>$(& $enc $r.ComputerName)</b><br><small>$(& $enc $r.OS)</small></td>" +
        (& $cell $r.Overall $r.Overall) +
        (& $cell $r.UptimeCheck "$($r.UptimeDays) d") +
        (& $cell $r.DiskCheck $r.LowestDiskFree) +
        (& $cell $r.RebootCheck $(if ($r.PendingReboot) { 'Yes' } else { 'No' })) +
        (& $cell $r.DefenderCheck $(if ($null -eq $r.DefenderRT) { 'n/a' } elseif ($r.DefenderRT) { 'On' } else { 'Off' })) +
        (& $cell $r.BitLockerCheck $r.BitLocker) +
        (& $cell $r.PatchCheck $r.LastPatch) +
        "<td>$(& $enc $r.Issues)</td></tr>"
    }
    $unreachableHtml = ''
    if (@($Unreachable).Count) {
        $unreachableHtml = "<h2>Unreachable ($(@($Unreachable).Count))</h2><ul>" +
            (($Unreachable | ForEach-Object { "<li>$(& $enc $_.ComputerName): $(& $enc $_.Error)</li>" }) -join '') + "</ul>"
    }

@"
<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>Endpoint Health Report</title>
<style>
 body{font-family:Segoe UI,Arial,sans-serif;margin:24px;color:#222}
 h1{margin-bottom:4px} .sub{color:#666;margin-top:0}
 table{border-collapse:collapse;width:100%;font-size:14px}
 th,td{border:1px solid #ddd;padding:6px 8px;text-align:left;vertical-align:top}
 th{background:#f3f3f3} small{color:#666}
 td.ok{background:#e6f4ea} td.warn{background:#fff4d6} td.fail{background:#fde2e1;font-weight:600}
</style></head><body>
<h1>Endpoint Health Report</h1>
<p class="sub">Generated $(Get-Date -Format 'yyyy-MM-dd HH:mm') &middot; $(@($Rows).Count) computers &middot; $($counts -join ' &middot; ')</p>
<table><tr><th>Computer</th><th>Overall</th><th>Uptime</th><th>Lowest disk</th><th>Reboot pending</th><th>Defender RT</th><th>BitLocker</th><th>Last update</th><th>Issues</th></tr>
$($body -join "`n")
</table>
$unreachableHtml
</body></html>
"@
}

# ------------------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------------------
if ($MyInvocation.InvocationName -eq '.') { return }   # dot-sourced (e.g. by tests): load functions only

if ($PSCmdlet.ParameterSetName -eq 'File') {
    $ComputerName = Get-Content $ComputerListPath | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') }
}

$rawResults  = New-Object System.Collections.Generic.List[object]
$unreachable = New-Object System.Collections.Generic.List[object]

foreach ($computer in $ComputerName) {
    Write-Host "Checking $computer..."
    try {
        if ($computer -in @($env:COMPUTERNAME, 'localhost', '.')) {
            $rawResults.Add((& $collector))
        }
        else {
            $rawResults.Add((Invoke-Command -ComputerName $computer -ScriptBlock $collector -ErrorAction Stop))
        }
    }
    catch {
        Write-Warning "$computer unreachable: $($_.Exception.Message)"
        $unreachable.Add([pscustomobject]@{ ComputerName = $computer; Error = $_.Exception.Message })
    }
}

$severity = @{ FAIL = 0; WARN = 1; OK = 2 }
$rows = @($rawResults | ForEach-Object { Get-HealthRating -Raw $_ } |
    Sort-Object @{ Expression = { $severity[$_.Overall] } }, ComputerName)

New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null
$stamp    = Get-Date -Format 'yyyyMMdd-HHmm'
$csvPath  = Join-Path $OutputFolder "endpoint-health-$stamp.csv"
$htmlPath = Join-Path $OutputFolder "endpoint-health-$stamp.html"

if ($rows.Count) { $rows | Export-Csv -Path $csvPath -NoTypeInformation }
ConvertTo-HealthHtml -Rows $rows -Unreachable $unreachable | Set-Content -Path $htmlPath -Encoding UTF8

$rows | Format-Table ComputerName, Overall, Issues -AutoSize -Wrap
Write-Host "Report: $htmlPath"
