# Endpoint Health Report

A PowerShell script that checks Windows PCs for the common problems behind help desk tickets and security gaps. It produces a **color-coded HTML report** and a CSV, with the worst machines at the top.

Instead of finding out a PC has 2% disk space or hasn't rebooted in 60 days when the user calls, you get a morning report that shows it first.

## What it checks

| Check | WARN | FAIL |
|---|---|---|
| Free disk space (worst fixed drive) | ≤ 20% | ≤ 10% |
| Uptime since last reboot | ≥ 14 days | ≥ 30 days |
| Pending reboot (Windows Update, servicing, file renames) | pending | |
| Microsoft Defender real-time protection | signatures > 3 days old, or status unavailable | real-time protection off |
| BitLocker on the OS drive | unknown | off |
| Days since the last installed update | ≥ 35 days | ≥ 60 days |

All thresholds are parameters, so you can adjust them without editing the script. It also records the OS version and build and total RAM, for inventory.

## Requirements
- Windows PowerShell 5.1 (built into Windows 10/11) or PowerShell 7
- **Run as administrator** for BitLocker status
- For remote machines: PowerShell Remoting enabled on the targets (`Enable-PSRemoting`, usually set through Group Policy in a domain)

## Usage
```powershell
# Check this PC
.\Get-EndpointHealth.ps1

# Check several PCs
.\Get-EndpointHealth.ps1 -ComputerName PC-SHIP-01, PC-QA-02, PC-OFFICE-07

# Check a list from a file (one name per line, # for comments)
.\Get-EndpointHealth.ps1 -ComputerListPath .\computers.txt

# Stricter disk thresholds
.\Get-EndpointHealth.ps1 -ComputerListPath .\computers.txt -DiskWarnPercent 25 -DiskFailPercent 15
```

The report is written to `.\output\endpoint-health-<date>.html`, along with a CSV. Machines that couldn't be reached are listed at the bottom instead of stopping the run.

## How it's built
- **Collection is separate from judgement.** A script block gathers raw facts on each endpoint, either locally or through `Invoke-Command`. Ratings are applied afterwards on the machine running the report. That keeps remote work light and makes the rating logic easy to test or change.
- **Errors are handled per machine.** One offline PC doesn't stop the run.
- **Output is HTML-encoded**, so a strange computer name can't break the report.

## Scheduling it
Run it daily with Task Scheduler and email the HTML report, or save it to a shared folder:
```powershell
$action  = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -File C:\Scripts\Get-EndpointHealth.ps1 -ComputerListPath C:\Scripts\computers.txt -OutputFolder \\server\it\reports'
$trigger = New-ScheduledTaskTrigger -Daily -At 6:30am
Register-ScheduledTask -TaskName 'Endpoint Health Report' -Action $action -Trigger $trigger -User 'DOMAIN\svc-reports' -Password (Read-Host 'Service account password')
```

## Ideas for extending it
- Post FAIL machines to a Teams or Slack channel through a webhook
- Open a ticket automatically for each FAIL
- Add checks for local admin group members, firewall profile status, and installed software versions
- Pull the computer list from Active Directory: `Get-ADComputer -Filter 'Enabled -eq $true' -SearchBase 'OU=Workstations,...'`
