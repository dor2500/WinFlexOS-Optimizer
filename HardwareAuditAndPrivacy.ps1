<#
Hardware Audit, Custom Optimization & Debloat Script
Compatibility: Windows 10 / Windows 11
Version: 6.1 (Full transparency engine: live per-action log, HTML change report on the Desktop,
         Ultra-Deep "Nuclear" background debloat, Security Hardening, Deep Cleanup, Undo from recorded state)
         6.1: fixed empty HTML report table, crash-safe UNDO journal (ProgramData\WinFlexOS\State),
              reverse-order UNDO for all change types, restore point check, Power Saver GUID,
              localized Ultimate Performance plan, background mode via 'irm | iex', safer debloat lists.

Usage examples:
  .\HardwareAuditAndPrivacy.ps1                        # interactive menu
  .\HardwareAuditAndPrivacy.ps1 -ProfileId 11          # Nuclear deep debloat (runs in a hidden background process)
  .\HardwareAuditAndPrivacy.ps1 -ProfileId 1,8,12      # combine profiles (Gaming + Privacy Shield + Deep Cleanup)
  .\HardwareAuditAndPrivacy.ps1 -ProfileId 7 -DryRun   # simulate: touches NOTHING, still produces the HTML report
  . .\HardwareAuditAndPrivacy.ps1 -LibraryOnly         # load the engine only (used by WinFlexSetupModern.ps1)
#>
[CmdletBinding()]
param(
    [string]$ProfileId = '',      # "1".."13" or a comma separated list, e.g. "1,8,12"
    [switch]$Silent,              # no prompts
    [switch]$NoPause,             # do not wait for a key at the end
    [switch]$DryRun,              # simulate everything, change nothing
    [switch]$Background,          # run the selected profile(s) in a hidden low-priority process
    [switch]$Worker,              # internal: this process IS the hidden background worker
    [switch]$OpenReport,          # open the HTML report when finished
    [switch]$LibraryOnly,         # only define functions (dot-source from another script)
    [string]$ReportDir = ''       # where to save the HTML report (default: Desktop)
)

$script:WFVersion = '6.1'
$script:RawBase   = 'https://raw.githubusercontent.com/dor2500/WinFlexOS-Optimizer/master'

# ==============================================================================
# 0. Administrator Privileges Check (+ relaunch under Windows PowerShell 5.1)
# ==============================================================================
function Test-WFAdmin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
$isAdmin = Test-WFAdmin
$script:isAdmin = $isAdmin

function Get-WFForwardArgs {
    # Rebuilds the bound parameters as a command line (used when relaunching).
    param($Bound)
    $fwd = @()
    foreach ($k in $Bound.Keys) {
        $v = $Bound[$k]
        if ($v -is [System.Management.Automation.SwitchParameter]) { if ($v.IsPresent) { $fwd += "-$k" } }
        else { $fwd += "-$k"; $fwd += ("'{0}'" -f ([string]$v -replace "'", "''")) }
    }
    return $fwd
}

# Checkpoint-Computer, Get-WindowsOptionalFeature and Appx cmdlets are only reliable in
# Windows PowerShell 5.1, so a PowerShell 7 run is handed over to powershell.exe.
$needRelaunch = (-not $LibraryOnly) -and (($PSVersionTable.PSEdition -eq 'Core') -or ((-not $DryRun) -and (-not $isAdmin)))
if ($needRelaunch) {
    $fwd = Get-WFForwardArgs $PSBoundParameters
    if ($isAdmin) { Write-Host "[!] Switching to Windows PowerShell 5.1 (required for restore points and Appx removal)..." -ForegroundColor Yellow }
    else { Write-Host "[!] Script requires Administrator privileges. Restarting elevated..." -ForegroundColor Yellow }
    try {
        if ($PSCommandPath) {
            $elevArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath)) + ($fwd | ForEach-Object { $_ -replace "^'(.*)'$", '"$1"' })
        } else {
            # Started via 'irm | iex': download again and forward the same parameters.
            $remoteCmd = "& ([scriptblock]::Create((irm '$($script:RawBase)/HardwareAuditAndPrivacy.ps1'))) $($fwd -join ' ')"
            $elevArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $remoteCmd)
        }
        if ($isAdmin) { Start-Process powershell.exe -ArgumentList $elevArgs -WindowStyle Normal -ErrorAction Stop }
        else { Start-Process powershell.exe -ArgumentList $elevArgs -Verb RunAs -WindowStyle Normal -ErrorAction Stop }
    } catch {
        Write-Host "[X] Could not elevate privileges. Please run PowerShell as Administrator manually." -ForegroundColor Red
    }
    # 'exit' would close the user's own console when started through 'irm | iex'.
    if ($PSCommandPath) { exit } else { return }
}

$script:IsLaptop = $false
$script:UserProfile = "1"

# ==============================================================================
# 0.6 Session state, live logging (every single action is printed + logged + reported)
# ==============================================================================
function New-WFSession {
    $script:WF = @{
        Actions = New-Object System.Collections.ArrayList
        Started = Get-Date
        Name = 'Manual run'
        ProfileNames = New-Object System.Collections.ArrayList
        DryRun = [bool]$DryRun
        Quiet = $false
        LogFile = $null
        LogWriter = $null
        Phase = ''
        PhaseStart = 0
        StepNo = 0
        BytesFreed = [long]0
        SnapBefore = $null
        SnapAfter = $null
        Forensic = $null
        RebootNeeded = $false
        TaskCache = $null
        AppxCache = $null
        ProvCache = $null
        FeatureCache = $null
        CapCache = $null
        IsWin11 = $false
        HW = @{}
        ReportPath = $null
        StatePath = $null
        RestoreDone = $false
        HostsBackedUp = $false
        BaseDone = $false
        IsUndo = $false
        RunStamp = (Get-Date -Format 'yyyyMMdd_HHmmss')
        JournalPath = $null
    }
}

function Get-WFStateDir {
    $dir = Join-Path $env:ProgramData 'WinFlexOS\State'
    try { New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null } catch {}
    return $dir
}

function Write-WFJournal {
    # Every undoable change is appended to a journal immediately, so UNDO still works
    # when a run is interrupted (Ctrl+C, crash, killed background worker).
    param($Rec)
    if (-not $script:WF.JournalPath -or $null -eq $Rec.Undo) { return }
    try {
        $line = ([ordered]@{ Id = $Rec.Id; Target = $Rec.Target; Action = $Rec.Action; Undo = $Rec.Undo } | ConvertTo-Json -Compress -Depth 6)
        [System.IO.File]::AppendAllText($script:WF.JournalPath, $line + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
    } catch {}
}
New-WFSession

function Get-WFTimeStamp { (Get-Date).ToString('HH:mm:ss') }

function Write-WFRaw {
    param([string]$Text, [string]$Color = 'Gray', [switch]$NoNewLine)
    if (-not $script:WF.Quiet) {
        try {
            if ($NoNewLine) { Write-Host $Text -ForegroundColor $Color -NoNewline } else { Write-Host $Text -ForegroundColor $Color }
        } catch {}
    }
    if ($script:WF.LogWriter) { try { $script:WF.LogWriter.WriteLine($Text) } catch {} }
}

function Open-WFLog {
    $dir = Join-Path $env:ProgramData 'WinFlexOS\Logs'
    try { New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null }
    catch { $dir = Join-Path $env:TEMP 'WinFlexOS\Logs'; New-Item -ItemType Directory -Path $dir -Force -ErrorAction SilentlyContinue | Out-Null }
    $path = Join-Path $dir ("run-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    try {
        $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
        $sw = New-Object System.IO.StreamWriter($fs, (New-Object System.Text.UTF8Encoding($false)))
        $sw.AutoFlush = $true
        $script:WF.LogWriter = $sw
        $script:WF.LogFile = $path
    } catch { $script:WF.LogFile = $null }
}

function Close-WFLog {
    if ($script:WF.LogWriter) { try { $script:WF.LogWriter.Dispose() } catch {}; $script:WF.LogWriter = $null }
}

function Write-WFBanner {
    param([string]$Title, [string]$Color = 'Magenta')
    Write-WFRaw ""
    Write-WFRaw "========================================================" $Color
    Write-WFRaw "   $Title" 'Yellow'
    Write-WFRaw "========================================================" $Color
}

function Format-WFBytes {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    return ('{0:N0} B' -f $Bytes)
}

function Format-WFVal {
    param($Value)
    if ($null -eq $Value) { return '(not set)' }
    if ($Value -is [byte[]]) { return ('hex:' + (($Value | ForEach-Object { $_.ToString('x2') }) -join ',')) }
    if ($Value -is [array]) { return ($Value -join ', ') }
    $s = [string]$Value
    if ($s -eq '') { return '(empty)' }
    return $s
}

function Add-WFAction {
    param(
        [string]$Category, [string]$Type, [string]$Target, [string]$Action,
        [string]$Before = '', [string]$After = '',
        [ValidateSet('Changed', 'Already', 'NotFound', 'Skipped', 'Failed', 'Info')][string]$Status = 'Changed',
        [string]$Detail = '', [string]$Revert = '', $Undo = $null
    )
    $rec = [pscustomobject]@{
        Id = $script:WF.Actions.Count + 1
        Time = Get-WFTimeStamp
        Phase = $script:WF.Phase
        Category = $Category
        Type = $Type
        Target = $Target
        Action = $Action
        Before = $Before
        After = $After
        Status = $Status
        Detail = $Detail
        Revert = $Revert
        Undo = $Undo
        Sim = ($script:WF.DryRun -and $Status -eq 'Changed')
    }
    [void]$script:WF.Actions.Add($rec)
    if ($Status -eq 'Changed' -and -not $script:WF.DryRun) { Write-WFJournal $rec }
    Write-WFLive $rec
    return $rec
}

function Write-WFLive {
    param($r)
    $label = switch ($r.Status) {
        'Changed'  { if ($r.Sim) { 'WOULD CHANGE' } else { 'CHANGED' } }
        'Already'  { 'ALREADY OK' }
        'NotFound' { 'NOT PRESENT' }
        'Skipped'  { 'SKIPPED' }
        'Failed'   { 'FAILED' }
        default    { 'INFO' }
    }
    $color = switch ($r.Status) {
        'Changed'  { 'Green' }
        'Already'  { 'Cyan' }
        'NotFound' { 'DarkGray' }
        'Skipped'  { 'Yellow' }
        'Failed'   { 'Red' }
        default    { 'Gray' }
    }
    $line = '[{0}] [{1,-8}] {2,-12} {3}' -f $r.Time, $r.Type.ToUpper(), $label, $r.Target
    if ($r.Action) { $line += '  -  ' + $r.Action }
    Write-WFRaw $line $color
    $pad = '                          '
    if (($r.Before -or $r.After) -and $r.Status -in @('Changed', 'Failed')) {
        Write-WFRaw ("{0}{1}  ->  {2}" -f $pad, $r.Before, $r.After) 'DarkGray'
    }
    if ($r.Detail -and $r.Status -in @('Changed', 'Failed', 'Skipped', 'Info')) {
        Write-WFRaw ("{0}{1}" -f $pad, $r.Detail) 'DarkGray'
    }
}

function Write-WFPhase {
    param([string]$Title)
    Close-WFPhase
    $script:WF.StepNo++
    $script:WF.Phase = $Title
    $script:WF.PhaseStart = $script:WF.Actions.Count
    Write-WFRaw ""
    Write-WFRaw ("--- [Step {0}] {1} ---" -f $script:WF.StepNo, $Title) 'Cyan'
}

function Close-WFPhase {
    if (-not $script:WF.Phase) { return }
    $slice = @($script:WF.Actions | Select-Object -Skip $script:WF.PhaseStart)
    $c = @($slice | Where-Object Status -eq 'Changed').Count
    $a = @($slice | Where-Object Status -eq 'Already').Count
    $n = @($slice | Where-Object Status -eq 'NotFound').Count
    $f = @($slice | Where-Object Status -eq 'Failed').Count
    Write-WFRaw ("    >> Step done: {0} changed | {1} already OK | {2} not present | {3} failed" -f $c, $a, $n, $f) 'DarkCyan'
    $script:WF.Phase = ''
}

function Write-WFNote {
    param([string]$Text, [string]$Color = 'DarkGray')
    Write-WFRaw ("    " + $Text) $Color
}

function Get-WFSnapshot {
    $s = [ordered]@{}
    try { $d = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction Stop; $s['FreeDiskGB'] = [math]::Round($d.FreeSpace / 1GB, 2) } catch {}
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $s['RamUsedGB'] = [math]::Round(($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / 1MB, 2)
    } catch {}
    try { $s['Processes'] = @(Get-Process -ErrorAction Stop).Count } catch {}
    try { $s['RunningServices'] = @(Get-Service -ErrorAction Stop | Where-Object { $_.Status -eq 'Running' }).Count } catch {}
    try {
        $cnt = 0
        foreach ($k in @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run')) {
            if (Test-Path -LiteralPath $k) {
                $p = Get-ItemProperty -LiteralPath $k -ErrorAction SilentlyContinue
                $cnt += @($p.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' }).Count
            }
        }
        $s['StartupEntries'] = $cnt
    } catch {}
    try { $s['EnabledTasks'] = @(Get-ScheduledTask -ErrorAction Stop | Where-Object { $_.State -ne 'Disabled' }).Count } catch {}
    try { $s['AppxApps'] = @(Get-AppxPackage -AllUsers -ErrorAction Stop | Where-Object { -not $_.IsFramework }).Count } catch {}
    return $s
}


# ==============================================================================
# 0.7 Action helpers. Every helper READS the current state first, changes only
#     when needed, VERIFIES the result, and records exactly what happened.
# ==============================================================================
function Get-WFRegDisplayPath {
    param([string]$Path)
    return ($Path -replace '^HKLM:\\?', 'HKLM\' -replace '^HKCU:\\?', 'HKCU\' -replace '^HKCR:\\?', 'HKCR\')
}

function ConvertTo-WFComparable {
    param($Value, [string]$Type)
    if ($null -eq $Value) { return $null }
    if ($Type -in @('DWord', 'QWord')) {
        try {
            $n = [int64]$Value
            if ($Type -eq 'DWord' -and $n -lt 0) { $n += 4294967296 }
            return $n
        } catch { return [string]$Value }
    }
    if ($Value -is [array]) { return ($Value -join ',') }
    return [string]$Value
}

function Format-WFPsLiteral {
    # Value as it must be written inside a PowerShell revert command.
    param($Value)
    if ($null -eq $Value) { return '$null' }
    if ($Value -is [byte[]]) { return ('([byte[]](' + (($Value | ForEach-Object { '0x' + $_.ToString('x2') }) -join ',') + '))') }
    if ($Value -is [array]) { return ('@(' + (($Value | ForEach-Object { "'" + ([string]$_ -replace "'", "''") + "'" }) -join ',') + ')') }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [uint32] -or $Value -is [uint64]) { return [string]$Value }
    return ("'" + ([string]$Value -replace "'", "''") + "'")
}

function Get-WFRegKind {
    param([string]$Path, [string]$Name)
    try { return [string](Get-Item -LiteralPath $Path -ErrorAction Stop).GetValueKind($Name) } catch { return $null }
}

function Test-WFRebootPath {
    param([string]$Path)
    return ($Path -match '(?i)^HKLM:\\SYSTEM\\|HKEY_LOCAL_MACHINE\\SYSTEM\\')
}

function Set-WFReg {
    param(
        [string]$Path, [string]$Name, $Value, [string]$Type = 'DWord',
        [string]$Desc = '', [string]$Category = 'Registry',
        [switch]$OnlyIfKeyExists, [switch]$Only11
    )
    $disp = (Get-WFRegDisplayPath $Path) + '  [' + $Name + ']'
    $actionTxt = if ($Desc) { $Desc } else { "Set $Name = $Value" }
    if ($Only11 -and -not $script:WF.IsWin11) {
        Add-WFAction -Category $Category -Type 'Registry' -Target $disp -Action $actionTxt -Status Skipped -Detail 'Only applies to Windows 11 (this PC runs Windows 10).' | Out-Null
        return
    }
    $keyExists = Test-Path -LiteralPath $Path
    if ($OnlyIfKeyExists -and -not $keyExists) {
        Add-WFAction -Category $Category -Type 'Registry' -Target $disp -Action $actionTxt -Status NotFound -Detail 'The software this setting belongs to is not installed.' | Out-Null
        return
    }
    $exists = $false; $before = $null
    if ($keyExists) {
        try { $prop = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop; $before = $prop.$Name; $exists = $true } catch {}
    }
    $cmpB = ConvertTo-WFComparable $before $Type
    $cmpA = ConvertTo-WFComparable $Value $Type
    if ($exists -and "$cmpB" -eq "$cmpA") {
        Add-WFAction -Category $Category -Type 'Registry' -Target $disp -Action $actionTxt -Before (Format-WFVal $before) -After (Format-WFVal $Value) -Status Already -Detail 'Already set to the desired value.' | Out-Null
        return
    }
    $oldKind = if ($exists) { Get-WFRegKind $Path $Name } else { $null }
    $restoreType = if ($oldKind -and $oldKind -ne 'Unknown' -and $oldKind -ne 'None') { $oldKind } else { $Type }
    $revert = if ($exists) { "New-ItemProperty -Path '$Path' -Name '$Name' -Value $(Format-WFPsLiteral $before) -PropertyType $restoreType -Force" } else { "Remove-ItemProperty -Path '$Path' -Name '$Name'" }
    $undo = @{ Kind = 'Registry'; Path = $Path; Name = $Name; Existed = $exists; Value = $before; Type = $restoreType; KeyCreated = (-not $keyExists) }
    if ($script:WF.DryRun) {
        Add-WFAction -Category $Category -Type 'Registry' -Target $disp -Action $actionTxt -Before (Format-WFVal $before) -After (Format-WFVal $Value) -Status Changed -Revert $revert | Out-Null
        return
    }
    try {
        if (-not $keyExists) { New-Item -Path $Path -Force -ErrorAction Stop | Out-Null }
        New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Type -Force -ErrorAction Stop | Out-Null
        $nowVal = (Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop).$Name
        if ("$(ConvertTo-WFComparable $nowVal $Type)" -ne "$cmpA") { throw "Value did not stick (read back: $(Format-WFVal $nowVal))" }
        if (Test-WFRebootPath $Path) { $script:WF.RebootNeeded = $true }
        Add-WFAction -Category $Category -Type 'Registry' -Target $disp -Action $actionTxt -Before (Format-WFVal $before) -After (Format-WFVal $nowVal) -Status Changed -Revert $revert -Undo $undo | Out-Null
    } catch {
        Add-WFAction -Category $Category -Type 'Registry' -Target $disp -Action $actionTxt -Before (Format-WFVal $before) -After (Format-WFVal $Value) -Status Failed -Detail $_.Exception.Message | Out-Null
    }
}

function Remove-WFRegValue {
    param([string]$Path, [string]$Name, [string]$Desc = '', [string]$Category = 'Registry')
    $disp = (Get-WFRegDisplayPath $Path) + '  [' + $Name + ']'
    $actionTxt = if ($Desc) { $Desc } else { "Remove value $Name" }
    $exists = $false; $before = $null
    if (Test-Path -LiteralPath $Path) {
        try { $prop = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop; $before = $prop.$Name; $exists = $true } catch {}
    }
    if (-not $exists) {
        Add-WFAction -Category $Category -Type 'Registry' -Target $disp -Action $actionTxt -Status NotFound -Detail 'Value does not exist - nothing to remove.' | Out-Null
        return
    }
    $kind = Get-WFRegKind $Path $Name
    if (-not $kind -or $kind -eq 'Unknown' -or $kind -eq 'None') { $kind = 'String' }
    $revert = "New-ItemProperty -Path '$Path' -Name '$Name' -Value $(Format-WFPsLiteral $before) -PropertyType $kind -Force"
    if ($script:WF.DryRun) {
        Add-WFAction -Category $Category -Type 'Registry' -Target $disp -Action $actionTxt -Before (Format-WFVal $before) -After '(removed)' -Status Changed -Revert $revert | Out-Null
        return
    }
    try {
        Remove-ItemProperty -LiteralPath $Path -Name $Name -Force -ErrorAction Stop
        if (Test-WFRebootPath $Path) { $script:WF.RebootNeeded = $true }
        Add-WFAction -Category $Category -Type 'Registry' -Target $disp -Action $actionTxt -Before (Format-WFVal $before) -After '(removed)' -Status Changed -Revert $revert -Undo @{ Kind = 'Registry'; Path = $Path; Name = $Name; Existed = $true; Value = $before; Type = $kind; KeyCreated = $false; Removed = $true } | Out-Null
    } catch {
        Add-WFAction -Category $Category -Type 'Registry' -Target $disp -Action $actionTxt -Before (Format-WFVal $before) -Status Failed -Detail $_.Exception.Message | Out-Null
    }
}

function Set-WFEnvVar {
    param([string]$Name, [string]$Value, [string]$Desc = '', [string]$Category = 'Privacy')
    $cur = [Environment]::GetEnvironmentVariable($Name, 'User')
    $target = "ENV (User)  $Name"
    $actionTxt = if ($Desc) { $Desc } else { "Set $Name=$Value" }
    if ($cur -eq $Value) { Add-WFAction -Category $Category -Type 'Registry' -Target $target -Action $actionTxt -Before (Format-WFVal $cur) -After $Value -Status Already | Out-Null; return }
    if ($script:WF.DryRun) { Add-WFAction -Category $Category -Type 'Registry' -Target $target -Action $actionTxt -Before (Format-WFVal $cur) -After $Value -Status Changed -Revert "[Environment]::SetEnvironmentVariable('$Name',`$null,'User')" | Out-Null; return }
    try {
        [Environment]::SetEnvironmentVariable($Name, $Value, 'User')
        Add-WFAction -Category $Category -Type 'Registry' -Target $target -Action $actionTxt -Before (Format-WFVal $cur) -After $Value -Status Changed -Revert "[Environment]::SetEnvironmentVariable('$Name',`$null,'User')" -Undo @{ Kind = 'Env'; Name = $Name; Existed = ($null -ne $cur); Value = $cur } | Out-Null
    } catch { Add-WFAction -Category $Category -Type 'Registry' -Target $target -Action $actionTxt -Status Failed -Detail $_.Exception.Message | Out-Null }
}

function Get-WFServiceStartMode {
    param([string]$Name)
    $mode = $null; $delayed = $false
    try {
        $k = "HKLM:\SYSTEM\CurrentControlSet\Services\$Name"
        $p = Get-ItemProperty -LiteralPath $k -ErrorAction Stop
        $start = [int]$p.Start
        $mode = switch ($start) { 0 { 'Boot' } 1 { 'System' } 2 { 'Automatic' } 3 { 'Manual' } 4 { 'Disabled' } default { "Start=$start" } }
        if ($start -eq 2 -and $p.DelayedAutostart -eq 1) { $delayed = $true; $mode = 'Automatic (Delayed)' }
    } catch {}
    return @{ Mode = $mode; Delayed = $delayed }
}

function Disable-WFService {
    param([string]$Name, [string]$Desc = '', [string]$Category = 'Services')
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc) {
        Add-WFAction -Category $Category -Type 'Service' -Target $Name -Action "Disable service  ($Desc)" -Status NotFound -Detail 'This service does not exist on this PC - nothing was disabled.' | Out-Null
        return
    }
    $disp = if ($svc.DisplayName) { $svc.DisplayName } else { $Name }
    $m = Get-WFServiceStartMode $Name
    $beforeTxt = "{0} / {1}" -f $svc.Status, $m.Mode
    $actionTxt = "Stop + disable service: $disp"
    if ($Desc) { $actionTxt += "  ($Desc)" }
    if ($m.Mode -eq 'Disabled' -and $svc.Status -eq 'Stopped') {
        Add-WFAction -Category $Category -Type 'Service' -Target $Name -Action $actionTxt -Before $beforeTxt -After $beforeTxt -Status Already -Detail 'Service was already stopped and disabled.' | Out-Null
        return
    }
    $startArg = switch ($m.Mode) { 'Automatic (Delayed)' { 'Automatic (Delayed)' } 'Automatic' { 'Automatic' } 'Manual' { 'Manual' } default { 'Manual' } }
    $revert = "Set-Service -Name '$Name' -StartupType $(if($startArg -like 'Automatic*'){'Automatic'}else{$startArg}); Start-Service -Name '$Name'"
    $undo = @{ Kind = 'Service'; Name = $Name; Mode = $m.Mode; WasRunning = ($svc.Status -eq 'Running') }
    if ($script:WF.DryRun) {
        Add-WFAction -Category $Category -Type 'Service' -Target $Name -Action $actionTxt -Before $beforeTxt -After 'Stopped / Disabled' -Status Changed -Revert $revert | Out-Null
        return
    }
    try {
        if ($svc.Status -ne 'Stopped') { Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue }
        $ok = $false
        try { Set-Service -Name $Name -StartupType Disabled -ErrorAction Stop; $ok = $true } catch {}
        if (-not $ok) { & sc.exe config $Name start= disabled 2>&1 | Out-Null }
        if ((Get-WFServiceStartMode $Name).Mode -ne 'Disabled') {
            try { Set-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Services\$Name" -Name Start -Value 4 -Type DWord -Force -ErrorAction Stop } catch {}
        }
        $svc2 = Get-Service -Name $Name -ErrorAction SilentlyContinue
        $m2 = Get-WFServiceStartMode $Name
        if ($m2.Mode -eq 'Disabled') {
            $det = if ($svc2 -and $svc2.Status -ne 'Stopped') { 'Disabled, but Windows did not allow stopping it now - it will stay off after the next restart.' } else { '' }
            if ($det) { $script:WF.RebootNeeded = $true }
            Add-WFAction -Category $Category -Type 'Service' -Target $Name -Action $actionTxt -Before $beforeTxt -After ("{0} / {1}" -f $svc2.Status, $m2.Mode) -Status Changed -Detail $det -Revert $revert -Undo $undo | Out-Null
        } else {
            Add-WFAction -Category $Category -Type 'Service' -Target $Name -Action $actionTxt -Before $beforeTxt -After ("{0} / {1}" -f $svc2.Status, $m2.Mode) -Status Failed -Detail 'Windows refused to disable this protected service.' | Out-Null
        }
    } catch {
        Add-WFAction -Category $Category -Type 'Service' -Target $Name -Action $actionTxt -Before $beforeTxt -Status Failed -Detail $_.Exception.Message | Out-Null
    }
}

function Get-WFTaskCache {
    if ($null -eq $script:WF.TaskCache) {
        $script:WF.TaskCache = @{}
        try {
            foreach ($t in (Get-ScheduledTask -ErrorAction Stop)) { $script:WF.TaskCache[($t.TaskPath + $t.TaskName).ToLower()] = $t }
        } catch {}
    }
    return $script:WF.TaskCache
}

function Disable-WFTask {
    param([string]$Path, [string]$Name, [string]$Desc = '', [string]$Category = 'Scheduled Tasks')
    $cache = Get-WFTaskCache
    $matches2 = @()
    if ($Name -match '[\*\?]') {
        $pat = ($Path + $Name).ToLower()
        $matches2 = @($cache.Keys | Where-Object { $_ -like $pat } | ForEach-Object { $cache[$_] })
    } elseif ($cache.ContainsKey(($Path + $Name).ToLower())) {
        $matches2 = @($cache[($Path + $Name).ToLower()])
    }
    if ($matches2.Count -eq 0) {
        Add-WFAction -Category $Category -Type 'Task' -Target ($Path + $Name) -Action "Disable scheduled task  ($Desc)" -Status NotFound -Detail 'This scheduled task does not exist on this PC - nothing was disabled.' | Out-Null
        return
    }
    foreach ($t in $matches2) {
        $full = $t.TaskPath + $t.TaskName
        $actionTxt = "Disable scheduled task"
        if ($Desc) { $actionTxt += "  ($Desc)" }
        $stateNow = [string]$t.State
        if ($stateNow -eq 'Disabled') {
            Add-WFAction -Category $Category -Type 'Task' -Target $full -Action $actionTxt -Before 'Disabled' -After 'Disabled' -Status Already -Detail 'Task was already disabled.' | Out-Null
            continue
        }
        $revert = "Enable-ScheduledTask -TaskPath '$($t.TaskPath)' -TaskName '$($t.TaskName)'"
        if ($script:WF.DryRun) {
            Add-WFAction -Category $Category -Type 'Task' -Target $full -Action $actionTxt -Before $stateNow -After 'Disabled' -Status Changed -Revert $revert | Out-Null
            continue
        }
        try {
            Disable-ScheduledTask -TaskPath $t.TaskPath -TaskName $t.TaskName -ErrorAction Stop | Out-Null
            $chk = Get-ScheduledTask -TaskPath $t.TaskPath -TaskName $t.TaskName -ErrorAction Stop
            if ([string]$chk.State -ne 'Disabled') { throw "Task state is still $($chk.State)" }
            $script:WF.TaskCache[$full.ToLower()] = $chk
            Add-WFAction -Category $Category -Type 'Task' -Target $full -Action $actionTxt -Before $stateNow -After 'Disabled' -Status Changed -Revert $revert -Undo @{ Kind = 'Task'; Path = $t.TaskPath; Name = $t.TaskName } | Out-Null
        } catch {
            Add-WFAction -Category $Category -Type 'Task' -Target $full -Action $actionTxt -Before $stateNow -Status Failed -Detail $_.Exception.Message | Out-Null
        }
    }
}

function Get-WFAppxCache {
    if ($null -eq $script:WF.AppxCache) {
        try { $script:WF.AppxCache = New-Object System.Collections.ArrayList; foreach ($p in (Get-AppxPackage -AllUsers -ErrorAction Stop)) { [void]$script:WF.AppxCache.Add($p) } } catch { $script:WF.AppxCache = New-Object System.Collections.ArrayList }
    }
    return $script:WF.AppxCache
}
function Get-WFProvCache {
    if ($null -eq $script:WF.ProvCache) {
        try { $script:WF.ProvCache = @(Get-AppxProvisionedPackage -Online -ErrorAction Stop) } catch { $script:WF.ProvCache = @() }
    }
    return $script:WF.ProvCache
}

$script:WFProtectedApps = @('Microsoft.WindowsStore', 'Microsoft.StorePurchaseApp', 'Microsoft.DesktopAppInstaller', 'Microsoft.WindowsTerminal',
    'Microsoft.WindowsNotepad', 'Microsoft.Paint', 'Microsoft.WindowsCalculator', 'Microsoft.Windows.Photos', 'Microsoft.SecHealthUI',
    'Microsoft.UI.Xaml*', 'Microsoft.VCLibs*', 'Microsoft.NET.*', 'Microsoft.WindowsAppRuntime*', 'Microsoft.AAD.BrokerPlugin', 'Microsoft.Windows.ShellExperienceHost',
    'Microsoft.Windows.StartMenuExperienceHost', 'Microsoft.LockApp', 'Microsoft.Windows.Search', 'MicrosoftWindows.Client.*', 'Windows.*', 'NcsiUwpApp',
    'Microsoft.WebMediaExtensions', 'Microsoft.HEIFImageExtension', 'Microsoft.VP9VideoExtensions', 'Microsoft.WebpImageExtension', 'Microsoft.ScreenSketch', 'Microsoft.MicrosoftEdge*')

function Remove-WFAppx {
    param([string]$Pattern, [string]$Desc = '', [string]$Category = 'Apps (UWP)')
    foreach ($prot in $script:WFProtectedApps) {
        if ($Pattern -like $prot -or ($prot -notmatch '\*' -and $Pattern -eq $prot)) {
            Add-WFAction -Category $Category -Type 'App' -Target $Pattern -Action "Remove app  ($Desc)" -Status Skipped -Detail 'Protected system component - never removed by this script.' | Out-Null
            return
        }
    }
    $cache = Get-WFAppxCache
    $found = @($cache | Where-Object { $_.Name -like $Pattern -and -not $_.IsFramework -and -not $_.NonRemovable })
    $prov = @(Get-WFProvCache | Where-Object { $_.DisplayName -like $Pattern })
    if ($found.Count -eq 0 -and $prov.Count -eq 0) {
        Add-WFAction -Category $Category -Type 'App' -Target $Pattern -Action "Remove app  ($Desc)" -Status NotFound -Detail 'This app is not installed on this PC - nothing was removed.' | Out-Null
        return
    }
    $seen = @{}
    foreach ($p in $found) {
        if ($seen.ContainsKey($p.PackageFullName)) { continue }
        $seen[$p.PackageFullName] = $true
        $actionTxt = "Uninstall app for all users" + $(if ($Desc) { "  ($Desc)" } else { '' })
        $revert = "winget install / Microsoft Store:  $($p.Name)"
        if ($script:WF.DryRun) {
            Add-WFAction -Category $Category -Type 'App' -Target $p.Name -Action $actionTxt -Before ("Installed v{0}" -f $p.Version) -After 'Removed' -Detail $p.PackageFullName -Status Changed -Revert $revert | Out-Null
            continue
        }
        try {
            Remove-AppxPackage -Package $p.PackageFullName -AllUsers -ErrorAction Stop
            $still = @(Get-AppxPackage -AllUsers -Name $p.Name -ErrorAction SilentlyContinue | Where-Object { $_.PackageFullName -eq $p.PackageFullName })
            if ($still.Count -gt 0) { throw 'Package is still registered after removal attempt.' }
            [void]$cache.Remove($p)
            Add-WFAction -Category $Category -Type 'App' -Target $p.Name -Action $actionTxt -Before ("Installed v{0}" -f $p.Version) -After 'Removed' -Detail $p.PackageFullName -Status Changed -Revert $revert | Out-Null
        } catch {
            Add-WFAction -Category $Category -Type 'App' -Target $p.Name -Action $actionTxt -Before ("Installed v{0}" -f $p.Version) -Status Failed -Detail $_.Exception.Message | Out-Null
        }
    }
    foreach ($pp in $prov) {
        $actionTxt = "Remove provisioned copy (stops reinstall for new users)"
        if ($script:WF.DryRun) {
            Add-WFAction -Category $Category -Type 'App' -Target ($pp.DisplayName + ' (provisioned)') -Action $actionTxt -Before 'Provisioned' -After 'Removed' -Detail $pp.PackageName -Status Changed | Out-Null
            continue
        }
        try {
            Remove-AppxProvisionedPackage -Online -PackageName $pp.PackageName -ErrorAction Stop | Out-Null
            Add-WFAction -Category $Category -Type 'App' -Target ($pp.DisplayName + ' (provisioned)') -Action $actionTxt -Before 'Provisioned' -After 'Removed' -Detail $pp.PackageName -Status Changed | Out-Null
        } catch {
            Add-WFAction -Category $Category -Type 'App' -Target ($pp.DisplayName + ' (provisioned)') -Action $actionTxt -Status Failed -Detail $_.Exception.Message | Out-Null
        }
    }
}

function Get-WFFolderStats {
    param([string]$Path, [string]$Filter = '*')
    $size = [long]0; $count = 0
    try {
        $items = Get-ChildItem -LiteralPath $Path -Filter $Filter -Recurse -File -Force -ErrorAction SilentlyContinue
        foreach ($i in $items) { $size += $i.Length; $count++ }
    } catch {}
    return @{ Size = $size; Count = $count }
}

function Clear-WFFolder {
    param([string]$Path, [string]$Desc = '', [string]$Filter = '*', [string]$Category = 'Cleanup', [string[]]$StopServices = @())
    $target = if ($Filter -ne '*') { Join-Path $Path $Filter } else { $Path }
    $actionTxt = "Delete files" + $(if ($Desc) { "  ($Desc)" } else { '' })
    $isPath = $false
    try { $isPath = Test-Path -LiteralPath $Path -ErrorAction SilentlyContinue } catch {}
    if (-not $isPath) {
        Add-WFAction -Category $Category -Type 'Files' -Target $target -Action $actionTxt -Status NotFound -Detail 'Folder does not exist - nothing to clean.' | Out-Null
        return
    }
    $b = Get-WFFolderStats -Path $Path -Filter $Filter
    if ($b.Count -eq 0) {
        Add-WFAction -Category $Category -Type 'Files' -Target $target -Action $actionTxt -Before '0 files' -After '0 files' -Status Already -Detail 'Already empty.' | Out-Null
        return
    }
    $beforeTxt = "{0} files, {1}" -f $b.Count, (Format-WFBytes $b.Size)
    if ($script:WF.DryRun) {
        Add-WFAction -Category $Category -Type 'Files' -Target $target -Action $actionTxt -Before $beforeTxt -After '0 files' -Detail ("Would free about {0}" -f (Format-WFBytes $b.Size)) -Status Changed | Out-Null
        return
    }
    $stopped = @()
    foreach ($s in $StopServices) {
        $sv = Get-Service -Name $s -ErrorAction SilentlyContinue
        if ($sv -and $sv.Status -eq 'Running') { Stop-Service -Name $s -Force -ErrorAction SilentlyContinue; $stopped += $s }
    }
    try {
        if ($Filter -ne '*') {
            Get-ChildItem -LiteralPath $Path -Filter $Filter -Force -ErrorAction SilentlyContinue | Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
        } else {
            Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue | Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
        }
    } catch {}
    foreach ($s in $stopped) { Start-Service -Name $s -ErrorAction SilentlyContinue }
    $a = Get-WFFolderStats -Path $Path -Filter $Filter
    $freed = [math]::Max(0, ($b.Size - $a.Size))
    $script:WF.BytesFreed += $freed
    $afterTxt = "{0} files, {1}" -f $a.Count, (Format-WFBytes $a.Size)
    if ($a.Count -ge $b.Count -and $freed -le 0) {
        Add-WFAction -Category $Category -Type 'Files' -Target $target -Action $actionTxt -Before $beforeTxt -After $afterTxt -Status Failed -Detail 'All files are currently in use by Windows or another program.' | Out-Null
    } else {
        $det = "Freed {0} ({1} files deleted)" -f (Format-WFBytes $freed), ($b.Count - $a.Count)
        if ($a.Count -gt 0) { $det += "; $($a.Count) file(s) in use were left alone" }
        Add-WFAction -Category $Category -Type 'Files' -Target $target -Action $actionTxt -Before $beforeTxt -After $afterTxt -Status Changed -Detail $det | Out-Null
    }
}

function Add-WFHostsBlock {
    param([string[]]$Domains, [string]$Desc = 'Block telemetry domain', [string]$Category = 'Network / Hosts')
    $hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    $content = ''
    try { $content = [System.IO.File]::ReadAllText($hostsPath) } catch {}
    $todo = @()
    foreach ($d in $Domains) {
        $rx = '(?im)^\s*(0\.0\.0\.0|127\.0\.0\.1)\s+' + [regex]::Escape($d) + '(\s|$)'
        if ($content -match $rx) {
            Add-WFAction -Category $Category -Type 'Hosts' -Target $d -Action $Desc -Before 'Not blocked' -After 'Already blocked' -Status Already | Out-Null
        } else { $todo += $d }
    }
    if ($todo.Count -eq 0) { return }
    if ($script:WF.DryRun) {
        foreach ($d in $todo) { Add-WFAction -Category $Category -Type 'Hosts' -Target $d -Action $Desc -Before 'Resolves normally' -After '0.0.0.0 (blocked)' -Status Changed -Revert "Remove the '$d' line from $hostsPath" | Out-Null }
        return
    }
    try {
        if (-not $script:WF.HostsBackedUp) {
            Copy-Item -LiteralPath $hostsPath -Destination ($hostsPath + '.winflex-backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss')) -Force -ErrorAction SilentlyContinue
            $script:WF.HostsBackedUp = $true
        }
        $sb = New-Object System.Text.StringBuilder
        if ($content -and -not $content.EndsWith("`n")) { [void]$sb.Append("`r`n") }
        [void]$sb.Append("# --- WinFlexOS telemetry block ($(Get-Date -Format 'yyyy-MM-dd HH:mm')) ---`r`n")
        foreach ($d in $todo) { [void]$sb.Append("0.0.0.0 $d`r`n") }
        [System.IO.File]::AppendAllText($hostsPath, $sb.ToString())
        & ipconfig.exe /flushdns 2>&1 | Out-Null
        foreach ($d in $todo) {
            Add-WFAction -Category $Category -Type 'Hosts' -Target $d -Action $Desc -Before 'Resolves normally' -After '0.0.0.0 (blocked)' -Status Changed -Revert "Remove the '$d' line from $hostsPath" -Undo @{ Kind = 'Hosts'; Domain = $d } | Out-Null
        }
    } catch {
        foreach ($d in $todo) { Add-WFAction -Category $Category -Type 'Hosts' -Target $d -Action $Desc -Status Failed -Detail $_.Exception.Message | Out-Null }
    }
}

function Disable-WFFeature {
    param([string]$Name, [string]$Desc = '', [string]$Category = 'Windows Features')
    if ($null -eq $script:WF.FeatureCache) {
        $script:WF.FeatureCache = @{}
        try { foreach ($f in (Get-WindowsOptionalFeature -Online -ErrorAction Stop)) { $script:WF.FeatureCache[$f.FeatureName] = [string]$f.State } } catch {}
    }
    $actionTxt = "Turn off Windows feature" + $(if ($Desc) { "  ($Desc)" } else { '' })
    if (-not $script:WF.FeatureCache.ContainsKey($Name)) {
        Add-WFAction -Category $Category -Type 'Feature' -Target $Name -Action $actionTxt -Status NotFound -Detail 'Feature does not exist on this Windows build - nothing was removed.' | Out-Null
        return
    }
    $st = $script:WF.FeatureCache[$Name]
    if ($st -ne 'Enabled') {
        Add-WFAction -Category $Category -Type 'Feature' -Target $Name -Action $actionTxt -Before $st -After $st -Status Already -Detail 'Feature is already off.' | Out-Null
        return
    }
    $revert = "Enable-WindowsOptionalFeature -Online -FeatureName $Name"
    if ($script:WF.DryRun) { Add-WFAction -Category $Category -Type 'Feature' -Target $Name -Action $actionTxt -Before 'Enabled' -After 'Disabled' -Status Changed -Revert $revert | Out-Null; return }
    try {
        $r = Disable-WindowsOptionalFeature -Online -FeatureName $Name -NoRestart -ErrorAction Stop
        if ($r.RestartNeeded) { $script:WF.RebootNeeded = $true }
        Add-WFAction -Category $Category -Type 'Feature' -Target $Name -Action $actionTxt -Before 'Enabled' -After 'Disabled' -Status Changed -Revert $revert -Undo @{ Kind = 'Feature'; Name = $Name } | Out-Null
    } catch { Add-WFAction -Category $Category -Type 'Feature' -Target $Name -Action $actionTxt -Status Failed -Detail $_.Exception.Message | Out-Null }
}

function Remove-WFCapability {
    param([string]$Pattern, [string]$Desc = '', [string]$Category = 'Windows Features')
    if ($null -eq $script:WF.CapCache) {
        try { $script:WF.CapCache = @(Get-WindowsCapability -Online -ErrorAction Stop) } catch { $script:WF.CapCache = @() }
    }
    $actionTxt = "Remove Windows capability" + $(if ($Desc) { "  ($Desc)" } else { '' })
    $hit = @($script:WF.CapCache | Where-Object { $_.Name -like $Pattern })
    if ($hit.Count -eq 0) {
        Add-WFAction -Category $Category -Type 'Feature' -Target $Pattern -Action $actionTxt -Status NotFound -Detail 'Capability does not exist on this Windows build - nothing was removed.' | Out-Null
        return
    }
    foreach ($c in $hit) {
        if ([string]$c.State -ne 'Installed') {
            Add-WFAction -Category $Category -Type 'Feature' -Target $c.Name -Action $actionTxt -Before ([string]$c.State) -After ([string]$c.State) -Status Already -Detail 'Capability is not installed.' | Out-Null
            continue
        }
        $revert = "Add-WindowsCapability -Online -Name '$($c.Name)'"
        if ($script:WF.DryRun) { Add-WFAction -Category $Category -Type 'Feature' -Target $c.Name -Action $actionTxt -Before 'Installed' -After 'Removed' -Status Changed -Revert $revert | Out-Null; continue }
        try {
            $r = Remove-WindowsCapability -Online -Name $c.Name -ErrorAction Stop
            if ($r.RestartNeeded) { $script:WF.RebootNeeded = $true }
            Add-WFAction -Category $Category -Type 'Feature' -Target $c.Name -Action $actionTxt -Before 'Installed' -After 'Removed' -Status Changed -Revert $revert -Undo @{ Kind = 'Capability'; Name = $c.Name } | Out-Null
        } catch { Add-WFAction -Category $Category -Type 'Feature' -Target $c.Name -Action $actionTxt -Status Failed -Detail $_.Exception.Message | Out-Null }
    }
}

function Invoke-WFNative {
    param([string]$File, [string[]]$Arguments)
    try {
        $out = & $File @Arguments 2>&1 | Out-String
        return @{ Code = $LASTEXITCODE; Output = $out.Trim() }
    } catch { return @{ Code = -1; Output = $_.Exception.Message } }
}

function Get-WFBcdValue {
    param([string]$Name)
    $o = (& bcdedit.exe /enum '{current}' 2>&1 | Out-String)
    foreach ($line in ($o -split "`r?`n")) {
        if ($line -match ('^\s*' + [regex]::Escape($Name) + '\s+(.+?)\s*$')) { return $matches[1] }
    }
    return $null
}

function Set-WFBcd {
    param([string]$Name, [string]$Value, [string]$Desc = '', [string]$Category = 'Boot / Latency')
    $before = Get-WFBcdValue $Name
    $target = "BCD  $Name"
    $actionTxt = if ($Desc) { $Desc } else { "bcdedit /set $Name $Value" }
    if ($before -and $before -ieq $Value) { Add-WFAction -Category $Category -Type 'Boot' -Target $target -Action $actionTxt -Before $before -After $Value -Status Already | Out-Null; return }
    $revert = "bcdedit /deletevalue $Name"
    if ($script:WF.DryRun) { Add-WFAction -Category $Category -Type 'Boot' -Target $target -Action $actionTxt -Before (Format-WFVal $before) -After $Value -Status Changed -Revert $revert | Out-Null; return }
    $r = Invoke-WFNative 'bcdedit.exe' @('/set', $Name, $Value)
    if ($r.Code -eq 0) { $script:WF.RebootNeeded = $true; Add-WFAction -Category $Category -Type 'Boot' -Target $target -Action $actionTxt -Before (Format-WFVal $before) -After $Value -Status Changed -Revert $revert -Undo @{ Kind = 'Bcd'; Name = $Name; Existed = [bool]$before; Value = $before } | Out-Null }
    else { Add-WFAction -Category $Category -Type 'Boot' -Target $target -Action $actionTxt -Status Failed -Detail $r.Output | Out-Null }
}

function Remove-WFBcd {
    param([string]$Name, [string]$Desc = '', [string]$Category = 'Boot / Latency')
    $before = Get-WFBcdValue $Name
    $target = "BCD  $Name"
    $actionTxt = if ($Desc) { $Desc } else { "bcdedit /deletevalue $Name" }
    if (-not $before) { Add-WFAction -Category $Category -Type 'Boot' -Target $target -Action $actionTxt -Status NotFound -Detail 'Boot value is not set - nothing to remove.' | Out-Null; return }
    $revert = "bcdedit /set $Name $before"
    if ($script:WF.DryRun) { Add-WFAction -Category $Category -Type 'Boot' -Target $target -Action $actionTxt -Before $before -After '(not set)' -Status Changed -Revert $revert | Out-Null; return }
    $r = Invoke-WFNative 'bcdedit.exe' @('/deletevalue', $Name)
    if ($r.Code -eq 0) { $script:WF.RebootNeeded = $true; Add-WFAction -Category $Category -Type 'Boot' -Target $target -Action $actionTxt -Before $before -After '(not set)' -Status Changed -Revert $revert -Undo @{ Kind = 'Bcd'; Name = $Name; Existed = $true; Value = $before } | Out-Null }
    else { Add-WFAction -Category $Category -Type 'Boot' -Target $target -Action $actionTxt -Status Failed -Detail $r.Output | Out-Null }
}

function Get-WFTcpGlobal {
    $h = @{}
    try { $t = Get-NetTCPSetting -SettingName Internet -ErrorAction Stop; $h['autotuninglevel'] = [string]$t.AutoTuningLevelLocal; $h['heuristics'] = [string]$t.ScalingHeuristics; $h['timestamps'] = [string]$t.Timestamps; $h['ecncapability'] = [string]$t.EcnCapability } catch {}
    try { $o = Get-NetOffloadGlobalSetting -ErrorAction Stop; $h['rss'] = [string]$o.ReceiveSideScaling } catch {}
    return $h
}

function Set-WFNetshTcp {
    param([string]$Setting, [string]$Value, [string]$Desc = '', [string]$Category = 'Network')
    $cur = Get-WFTcpGlobal
    $before = $cur[$Setting]
    $target = "TCP global  $Setting"
    $actionTxt = if ($Desc) { $Desc } else { "netsh int tcp set global $Setting=$Value" }
    if ($before -and $before -ieq $Value) { Add-WFAction -Category $Category -Type 'Network' -Target $target -Action $actionTxt -Before $before -After $Value -Status Already | Out-Null; return }
    $revert = if ($before) { "netsh int tcp set global $Setting=$before" } else { "netsh int tcp set global $Setting=default" }
    if ($script:WF.DryRun) { Add-WFAction -Category $Category -Type 'Network' -Target $target -Action $actionTxt -Before (Format-WFVal $before) -After $Value -Status Changed -Revert $revert | Out-Null; return }
    $r = Invoke-WFNative 'netsh.exe' @('int', 'tcp', 'set', 'global', "$Setting=$Value")
    $now = (Get-WFTcpGlobal)[$Setting]
    if ($r.Code -eq 0) { Add-WFAction -Category $Category -Type 'Network' -Target $target -Action $actionTxt -Before (Format-WFVal $before) -After (Format-WFVal $(if ($now) { $now } else { $Value })) -Status Changed -Revert $revert -Undo @{ Kind = 'Tcp'; Setting = $Setting; Value = $before } | Out-Null }
    else { Add-WFAction -Category $Category -Type 'Network' -Target $target -Action $actionTxt -Status Failed -Detail $r.Output | Out-Null }
}

function Get-WFActivePowerScheme {
    $o = (& powercfg.exe /getactivescheme 2>&1 | Out-String)
    if ($o -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\s*\((.+?)\)') { return @{ Guid = $matches[1].ToLower(); Name = $matches[2] } }
    if ($o -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') { return @{ Guid = $matches[1].ToLower(); Name = $matches[1] } }
    return @{ Guid = ''; Name = '(unknown)' }
}

function Set-WFPowerPlan {
    param([string]$Guid, [string]$Name, [string]$Desc = '', [string]$Category = 'Power')
    $cur = Get-WFActivePowerScheme
    $actionTxt = if ($Desc) { $Desc } else { "Activate power plan: $Name" }
    if ($cur.Guid -eq $Guid.ToLower()) { Add-WFAction -Category $Category -Type 'Power' -Target "Power plan" -Action $actionTxt -Before $cur.Name -After $cur.Name -Status Already | Out-Null; return $Guid }
    $revert = "powercfg -setactive $($cur.Guid)"
    if ($script:WF.DryRun) { Add-WFAction -Category $Category -Type 'Power' -Target "Power plan" -Action $actionTxt -Before $cur.Name -After $Name -Status Changed -Revert $revert | Out-Null; return $Guid }
    $r = Invoke-WFNative 'powercfg.exe' @('-setactive', $Guid)
    if ($r.Code -eq 0) { Add-WFAction -Category $Category -Type 'Power' -Target "Power plan" -Action $actionTxt -Before $cur.Name -After $Name -Status Changed -Revert $revert -Undo @{ Kind = 'Power'; Guid = $cur.Guid } | Out-Null }
    else { Add-WFAction -Category $Category -Type 'Power' -Target "Power plan" -Action $actionTxt -Status Failed -Detail $r.Output | Out-Null }
    return $Guid
}

function Get-WFPowerSchemeGuids {
    $list = (& powercfg.exe /list 2>&1 | Out-String)
    return @([regex]::Matches($list, '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}') | ForEach-Object { $_.Value.ToLower() })
}

function Get-WFUltimateGuid {
    # The duplicated plan gets a random GUID and a localized name (e.g. Hebrew Windows),
    # so the GUID we created is remembered in the registry instead of searching by name.
    $template = 'e9a42b02-d5df-448d-aa00-03f14749eb61'
    $memKey = 'HKLM:\SOFTWARE\WinFlexOS'
    $existing = Get-WFPowerSchemeGuids
    if ($existing -contains $template) { return $template }
    $saved = $null
    try { $saved = (Get-ItemProperty -LiteralPath $memKey -Name UltimateGuid -ErrorAction Stop).UltimateGuid } catch {}
    if ($saved -and ($existing -contains $saved.ToLower())) { return $saved }
    $list = (& powercfg.exe /list 2>&1 | Out-String)
    foreach ($line in ($list -split "`r?`n")) {
        if ($line -match '(?i)ultimate') { if ($line -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') { return $matches[1] } }
    }
    if ($script:WF.DryRun) { return $template }
    $o = (& powercfg.exe -duplicatescheme $template 2>&1 | Out-String)
    if ($o -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') {
        $g = $matches[1]
        try {
            if (-not (Test-Path -LiteralPath $memKey)) { New-Item -Path $memKey -Force -ErrorAction Stop | Out-Null }
            New-ItemProperty -LiteralPath $memKey -Name UltimateGuid -Value $g -PropertyType String -Force -ErrorAction Stop | Out-Null
        } catch {}
        Add-WFAction -Category 'Power' -Type 'Power' -Target 'Ultimate Performance plan' -Action 'Created the hidden Ultimate Performance power plan' -After $g -Status Changed -Revert "powercfg -delete $g" | Out-Null
        return $g
    }
    Add-WFAction -Category 'Power' -Type 'Power' -Target 'Ultimate Performance plan' -Action 'Create Ultimate Performance power plan' -Status Skipped -Detail 'This PC does not allow extra power plans (Modern Standby) - kept the current plan.' | Out-Null
    return $null
}

function Get-WFPowerValues {
    param([string]$Sub, [string]$Setting)
    $o = (& powercfg.exe /query SCHEME_CURRENT $Sub $Setting 2>&1 | Out-String)
    $hex = [regex]::Matches($o, '0x([0-9a-fA-F]{8})')
    if ($hex.Count -ge 2) {
        return @{ AC = [Convert]::ToInt64($hex[$hex.Count - 2].Groups[1].Value, 16); DC = [Convert]::ToInt64($hex[$hex.Count - 1].Groups[1].Value, 16) }
    }
    return $null
}

function Set-WFPowerSetting {
    param([string]$Sub, [string]$Setting, $AC, $DC, [string]$Label, [string]$Category = 'Power')
    $cur = Get-WFPowerValues $Sub $Setting
    $bTxt = if ($cur) { "AC=$($cur.AC) DC=$($cur.DC)" } else { '(unreadable)' }
    $parts = @(); if ($null -ne $AC) { $parts += "AC=$AC" }; if ($null -ne $DC) { $parts += "DC=$DC" }
    $aTxt = $parts -join ' '
    $same = $false
    if ($cur) { $same = (($null -eq $AC) -or ($cur.AC -eq $AC)) -and (($null -eq $DC) -or ($cur.DC -eq $DC)) }
    if ($same) { Add-WFAction -Category $Category -Type 'Power' -Target $Label -Action "Power setting" -Before $bTxt -After $bTxt -Status Already | Out-Null; return }
    $revert = if ($cur) { "powercfg /setacvalueindex SCHEME_CURRENT $Sub $Setting $($cur.AC); powercfg /setdcvalueindex SCHEME_CURRENT $Sub $Setting $($cur.DC)" } else { '' }
    if ($script:WF.DryRun) { Add-WFAction -Category $Category -Type 'Power' -Target $Label -Action "Power setting" -Before $bTxt -After $aTxt -Status Changed -Revert $revert | Out-Null; return }
    try {
        if ($null -ne $AC) { & powercfg.exe /setacvalueindex SCHEME_CURRENT $Sub $Setting $AC 2>&1 | Out-Null }
        if ($null -ne $DC) { & powercfg.exe /setdcvalueindex SCHEME_CURRENT $Sub $Setting $DC 2>&1 | Out-Null }
        & powercfg.exe /setactive SCHEME_CURRENT 2>&1 | Out-Null
        $undo = $null
        if ($cur) { $undo = @{ Kind = 'PowerSetting'; Sub = $Sub; Setting = $Setting; AC = $cur.AC; DC = $cur.DC } }
        Add-WFAction -Category $Category -Type 'Power' -Target $Label -Action "Power setting" -Before $bTxt -After $aTxt -Status Changed -Revert $revert -Undo $undo | Out-Null
    } catch { Add-WFAction -Category $Category -Type 'Power' -Target $Label -Action "Power setting" -Status Failed -Detail $_.Exception.Message | Out-Null }
}

function Invoke-WFOneShot {
    # For actions that have no readable "before" state (flush DNS, ReTrim, DISM cleanup...).
    param([string]$Category, [string]$Type, [string]$Target, [string]$Action, [scriptblock]$Script, [string]$OkDetail = '', [string]$Revert = '')
    if ($script:WF.DryRun) { Add-WFAction -Category $Category -Type $Type -Target $Target -Action $Action -Status Changed -Detail 'Would run now.' -Revert $Revert | Out-Null; return }
    try {
        $out = & $Script
        $det = $OkDetail
        if ($out) { $txt = ($out | Out-String).Trim(); if ($txt.Length -gt 300) { $txt = $txt.Substring(0, 300) + '...' }; if ($txt) { $det = (($OkDetail + ' ' + $txt).Trim()) } }
        Add-WFAction -Category $Category -Type $Type -Target $Target -Action $Action -Status Changed -Detail $det -Revert $Revert | Out-Null
    } catch { Add-WFAction -Category $Category -Type $Type -Target $Target -Action $Action -Status Failed -Detail $_.Exception.Message | Out-Null }
}

function Invoke-WFRestorePoint {
    param([string]$Label = 'WinFlexOS')
    # Returns $true when a restore point exists for this run.
    if ($script:WF.RestoreDone) { return $true }
    $script:WF.RestoreDone = $true
    Write-WFPhase "Safety net: System Restore Point"
    $name = "$Label - before changes ($(Get-Date -Format 'yyyy-MM-dd HH:mm'))"
    if ($script:WF.DryRun) { Add-WFAction -Category 'Safety' -Type 'System' -Target 'System Restore Point' -Action "Create restore point: $name" -Status Changed -Revert 'rstrui.exe' | Out-Null; return $true }
    if (-not (Get-Command Checkpoint-Computer -ErrorAction SilentlyContinue)) {
        Add-WFAction -Category 'Safety' -Type 'System' -Target 'System Restore Point' -Action 'Create restore point' -Status Failed -Detail 'Checkpoint-Computer is not available in this PowerShell edition.' | Out-Null
        return $false
    }
    try {
        $srOn = $false
        try { $srOn = ((Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' -Name RPSessionInterval -ErrorAction Stop).RPSessionInterval -ne 0) } catch {}
        if (-not $srOn) {
            Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction Stop | Out-Null
            Add-WFAction -Category 'Safety' -Type 'System' -Target "System Protection ($env:SystemDrive)" -Action 'Turned on System Restore so a restore point can be created' -After 'On' -Status Changed -Revert "Disable-ComputerRestore -Drive '$env:SystemDrive\'" | Out-Null
        }
        $freqKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
        $old = $null
        try { $old = (Get-ItemProperty -LiteralPath $freqKey -Name SystemRestorePointCreationFrequency -ErrorAction Stop).SystemRestorePointCreationFrequency } catch {}
        try { New-ItemProperty -LiteralPath $freqKey -Name SystemRestorePointCreationFrequency -Value 0 -PropertyType DWord -Force -ErrorAction SilentlyContinue | Out-Null } catch {}
        Checkpoint-Computer -Description $name -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
        try { if ($null -ne $old) { Set-ItemProperty -LiteralPath $freqKey -Name SystemRestorePointCreationFrequency -Value $old -ErrorAction SilentlyContinue } else { Remove-ItemProperty -LiteralPath $freqKey -Name SystemRestorePointCreationFrequency -ErrorAction SilentlyContinue } } catch {}
        Add-WFAction -Category 'Safety' -Type 'System' -Target 'System Restore Point' -Action "Created restore point: $name" -After 'Created' -Status Changed -Revert 'Run rstrui.exe and pick this restore point' | Out-Null
        return $true
    } catch {
        Add-WFAction -Category 'Safety' -Type 'System' -Target 'System Restore Point' -Action 'Create restore point' -Status Failed -Detail $_.Exception.Message | Out-Null
        return $false
    }
}


# ==============================================================================
# 0.8 HTML Report Generator & Undo Engine
# Generates a state-of-the-art interactive HTML dashboard directly on the Desktop.
# Fully self-contained (embedded CSS/JS, SVG icons, zero external CDN dependencies).
# ==============================================================================

function Export-WFState {
    param([string]$Path)
    try {
        $dir = Split-Path -Parent $Path
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null }
        $stateObj = [ordered]@{
            Version = $script:WFVersion
            Date = (Get-Date).ToString("o")
            ComputerName = $env:COMPUTERNAME
            UserName = $env:USERNAME
            Profiles = @($script:WF.ProfileNames)
            DryRun = $script:WF.DryRun
            IsUndo = $script:WF.IsUndo
            RunStamp = $script:WF.RunStamp
            Hardware = $script:WF.HW
            SnapBefore = $script:WF.SnapBefore
            SnapAfter = $script:WF.SnapAfter
            BytesFreed = $script:WF.BytesFreed
            Actions = @($script:WF.Actions | ForEach-Object {
                [ordered]@{
                    Id = $_.Id
                    Time = $_.Time
                    Category = $_.Category
                    Type = $_.Type
                    Target = $_.Target
                    Action = $_.Action
                    Before = $_.Before
                    After = $_.After
                    Status = $_.Status
                    Detail = $_.Detail
                    Revert = $_.Revert
                    Undo = $_.Undo
                }
            })
        }
        $json = $stateObj | ConvertTo-Json -Depth 6
        [System.IO.File]::WriteAllText($Path, $json, [System.Text.Encoding]::UTF8)
        $script:WF.StatePath = $Path
        # A second copy in ProgramData, so UNDO works even if the Desktop copy is deleted or ReportDir was used.
        if (-not $script:WF.DryRun) {
            $copy = Join-Path (Get-WFStateDir) ("run-{0}.json" -f $script:WF.RunStamp)
            try { [System.IO.File]::WriteAllText($copy, $json, [System.Text.Encoding]::UTF8) } catch {}
            # The run finished and its full state is saved - the crash journal is no longer needed.
            if ($script:WF.JournalPath -and (Test-Path -LiteralPath $copy)) { Remove-Item -LiteralPath $script:WF.JournalPath -Force -ErrorAction SilentlyContinue }
        }
    } catch {
        Write-WFNote "Failed to save state JSON: $($_.Exception.Message)" 'Red'
    }
}

function Export-WFHtmlReport {
    param([string]$OutPath = '', [string]$OutDir = '')

    if (-not $OutPath) {
        $dir = $OutDir
        if ($dir) {
            try { New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null } catch { $dir = '' }
        }
        if (-not $dir) {
            $dir = [Environment]::GetFolderPath('Desktop')
            if (-not $dir -or -not (Test-Path -LiteralPath $dir)) { $dir = $env:USERPROFILE }
        }
        $OutPath = Join-Path $dir "WinFlexOS_Optimization_Report_$($script:WF.RunStamp).html"
    }

    # Save state JSON alongside report
    $jsonPath = [System.IO.Path]::ChangeExtension($OutPath, '.json')
    Export-WFState -Path $jsonPath

    $dur = [math]::Round(((Get-Date) - $script:WF.Started).TotalSeconds, 1)
    $allActions = @($script:WF.Actions)

    $cntChanged  = @($allActions | Where-Object { $_.Status -eq 'Changed' }).Count
    $cntAlready  = @($allActions | Where-Object { $_.Status -eq 'Already' }).Count
    $cntNotFound = @($allActions | Where-Object { $_.Status -eq 'NotFound' }).Count
    $cntFailed   = @($allActions | Where-Object { $_.Status -eq 'Failed' }).Count
    $cntSkipped  = @($allActions | Where-Object { $_.Status -eq 'Skipped' }).Count
    $cntTotal    = $allActions.Count

    $freedFormatted = Format-WFBytes $script:WF.BytesFreed

    $enc = { param($s) [System.Net.WebUtility]::HtmlEncode([string]$s) }
    $profList = & $enc $(if ($script:WF.ProfileNames.Count -gt 0) { $script:WF.ProfileNames -join ', ' } else { 'Custom Run' })
    $modeTag = if ($script:WF.DryRun) { '<span class="badge badge-dry">DRY RUN (Simulation)</span>' } else { '<span class="badge badge-live">APPLIED LIVE</span>' }
    $hwOS = & $enc $script:WF.HW.OS; $hwCPU = & $enc $script:WF.HW.CPU; $hwRAM = & $enc $script:WF.HW.RAM; $hwGPU = & $enc $script:WF.HW.GPU
    $pcName = & $enc $env:COMPUTERNAME
    $rebootNote = if ($script:WF.RebootNeeded -and -not $script:WF.DryRun) { '<div class="notice">&#x26A0; מומלץ להפעיל מחדש את המחשב כדי להשלים חלק מהשינויים.</div>' } else { '' }
    $dryNote = if ($script:WF.DryRun) { '<div class="notice">הרצת ניסיון - לא שונה דבר במחשב. הדוח מציג מה היה קורה.' + $(if (-not $script:isAdmin) { ' (הורץ ללא הרשאות מנהל - חלק מהפריטים עשויים להופיע כ"לא קיים" למרות שהם קיימים.)' } else { '' }) + '</div>' } else { '' }

    # Encode JSON actions safely for client-side search & filtering.
    # -InputObject keeps a JSON array even when there is only one action.
    $safeActionsJson = (ConvertTo-Json -Compress -Depth 4 -InputObject @($allActions | ForEach-Object {
        @{
            id = $_.Id
            time = $_.Time
            cat = $_.Category
            type = $_.Type
            target = $_.Target
            action = $_.Action
            before = $_.Before
            after = $_.After
            status = $_.Status
            detail = $_.Detail
            revert = $_.Revert
            sim = $_.Sim
        }
    })) -replace '<', '\u003c' -replace '>', '\u003e' -replace '&', '\u0026'
    if (-not $safeActionsJson) { $safeActionsJson = '[]' }

    # Client-side JS lives in a literal here-string so PowerShell does not expand its ${...} placeholders.
    $jsCode = @'
        let currentFilter = 'ALL';

        // Every value comes from the PC (registry, file names, error messages) - escape before inserting as HTML.
        function esc(v) {
            if (v === null || v === undefined) return '';
            return String(v).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&#39;');
        }

        function getStatusBadge(status, sim) {
            if (status === 'Changed') {
                return sim ? '<span class="status-pill status-skipped">היה משתנה</span>' : '<span class="status-pill status-changed">&#x2714; שונה בהצלחה</span>';
            }
            if (status === 'Already') return '<span class="status-pill status-already">&#x2713; כבר היה תקין</span>';
            if (status === 'NotFound') return '<span class="status-pill status-notfound">&#x2298; לא קיים</span>';
            if (status === 'Failed') return '<span class="status-pill status-failed">&#x2718; נכשל</span>';
            if (status === 'Skipped') return '<span class="status-pill status-skipped">&#x25B6; דולג</span>';
            return '<span class="status-pill status-notfound">מידע</span>';
        }

        function matchesFilter(a) {
            if (currentFilter === 'ALL') return true;
            if (['Service', 'Registry', 'Task', 'App'].includes(currentFilter)) return a.type === currentFilter;
            return a.status === currentFilter;
        }

        function renderRows() {
            const tbody = document.getElementById('tableBody');
            const search = document.getElementById('searchInput').value.toLowerCase();
            const rows = [];

            for (const a of actions) {
                if (!matchesFilter(a)) continue;
                if (search) {
                    const haystack = [a.target, a.action, a.cat, a.detail, a.before, a.after, a.revert].join(' ').toLowerCase();
                    if (!haystack.includes(search)) continue;
                }

                let valFlow = '';
                if (a.before || a.after) {
                    const b = esc(a.before || '(ריק)'), af = esc(a.after || '(ריק)');
                    valFlow = `<div class="val-flow">
                        <span class="val-before" title="${b}">${b}</span>
                        <span class="val-arrow">&rarr;</span>
                        <span class="val-after" title="${af}">${af}</span>
                    </div>`;
                }

                let revertCode = a.revert ? `<div class="revert-code" title="${esc(a.revert)}">${esc(a.revert)}</div>` : `<span style="color: var(--text-muted);">-</span>`;
                if (a.detail) {
                    revertCode += `<div style="font-size: 11px; color: var(--text-muted); margin-top: 4px;">${esc(a.detail)}</div>`;
                }

                rows.push(`<tr>
                    <td style="color: var(--text-muted);">${esc(a.time)}</td>
                    <td><span style="font-size: 11px; font-weight: 700; color: var(--cyan-neon);">${esc(a.type)}</span></td>
                    <td>${getStatusBadge(a.status, a.sim)}</td>
                    <td><div class="target-name">${esc(a.target)}</div><div style="font-size: 11px; color: var(--text-muted);">${esc(a.cat)}</div></td>
                    <td><div class="action-desc">${esc(a.action)}</div></td>
                    <td>${valFlow}</td>
                    <td>${revertCode}</td>
                </tr>`);
            }

            tbody.innerHTML = rows.length ? rows.join('') :
                `<tr><td colspan="7" style="text-align: center; padding: 40px; color: var(--text-muted);">לא נמצאו פריטים התואמים לסינון או החיפוש.</td></tr>`;
        }

        function setFilter(filt) {
            currentFilter = filt;
            document.querySelectorAll('.filter-btn').forEach(b => b.classList.toggle('active', b.dataset.filter === filt));
            renderRows();
        }

        renderRows();
'@

    # Build HTML Content
    $html = @"
<!DOCTYPE html>
<html lang="he" dir="rtl">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>WinFlexOS - דוח אופטימיזציה ושינויים במערכת</title>
    <style>
        :root {
            --bg-base: #0a0b10;
            --bg-surface: #12141f;
            --bg-card: #181b2a;
            --bg-card-hover: #1f2336;
            --border: #262a40;
            --border-highlight: #3b4263;
            --text-primary: #f1f5f9;
            --text-secondary: #94a3b8;
            --text-muted: #64748b;
            --purple-neon: #a855f7;
            --purple-glow: rgba(168, 85, 247, 0.25);
            --cyan-neon: #00f2fe;
            --cyan-glow: rgba(0, 242, 254, 0.25);
            --green: #10b981;
            --green-glow: rgba(16, 185, 129, 0.2);
            --yellow: #f59e0b;
            --red: #ef4444;
            --blue: #3b82f6;
        }

        * {
            box-sizing: border-box;
            margin: 0;
            padding: 0;
            font-family: 'Segoe UI', system-ui, -apple-system, sans-serif;
        }

        body {
            background-color: var(--bg-base);
            color: var(--text-primary);
            min-height: 100vh;
            padding: 24px;
            line-height: 1.5;
        }

        .container {
            max-width: 1440px;
            margin: 0 auto;
        }

        /* HEADER */
        .header {
            display: flex;
            justify-content: space-between;
            align-items: center;
            flex-wrap: wrap;
            gap: 20px;
            background: linear-gradient(135deg, rgba(24, 27, 42, 0.9) 0%, rgba(18, 20, 31, 0.95) 100%);
            border: 1px solid var(--border);
            border-radius: 18px;
            padding: 24px 32px;
            backdrop-filter: blur(16px);
            box-shadow: 0 10px 30px rgba(0, 0, 0, 0.4);
            margin-bottom: 24px;
        }

        .header-title-box {
            display: flex;
            align-items: center;
            gap: 18px;
        }

        .logo-icon {
            width: 52px;
            height: 52px;
            border-radius: 14px;
            background: linear-gradient(135deg, var(--purple-neon), var(--cyan-neon));
            display: flex;
            align-items: center;
            justify-content: center;
            font-size: 26px;
            box-shadow: 0 0 20px var(--purple-glow);
        }

        .header-title {
            font-size: 26px;
            font-weight: 800;
            background: linear-gradient(135deg, #ffffff 40%, var(--purple-neon) 100%);
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
        }

        .header-subtitle {
            color: var(--text-secondary);
            font-size: 14px;
            margin-top: 2px;
        }

        .header-badges {
            display: flex;
            gap: 12px;
            flex-wrap: wrap;
            align-items: center;
        }

        .badge {
            display: inline-flex;
            align-items: center;
            padding: 6px 14px;
            border-radius: 999px;
            font-size: 13px;
            font-weight: 600;
            gap: 6px;
        }

        .badge-live {
            background: rgba(16, 185, 129, 0.15);
            color: var(--green);
            border: 1px solid rgba(16, 185, 129, 0.4);
        }

        .badge-dry {
            background: rgba(245, 158, 11, 0.15);
            color: var(--yellow);
            border: 1px solid rgba(245, 158, 11, 0.4);
        }

        .badge-meta {
            background: var(--bg-card);
            color: var(--cyan-neon);
            border: 1px solid var(--border);
        }

        /* METRIC CARDS */
        .stats-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(210px, 1fr));
            gap: 18px;
            margin-bottom: 24px;
        }

        .stat-card {
            background: var(--bg-card);
            border: 1px solid var(--border);
            border-radius: 16px;
            padding: 20px;
            transition: all 0.25s ease;
            position: relative;
            overflow: hidden;
        }

        .stat-card:hover {
            transform: translateY(-3px);
            border-color: var(--border-highlight);
            box-shadow: 0 8px 24px rgba(0, 0, 0, 0.3);
        }

        .stat-card::before {
            content: '';
            position: absolute;
            top: 0;
            left: 0;
            width: 100%;
            height: 3px;
            background: var(--accent-bar, var(--purple-neon));
        }

        .stat-label {
            font-size: 13px;
            color: var(--text-secondary);
            font-weight: 500;
        }

        .stat-value {
            font-size: 32px;
            font-weight: 800;
            margin-top: 6px;
            color: var(--text-primary);
        }

        .stat-sub {
            font-size: 12px;
            color: var(--text-muted);
            margin-top: 4px;
        }

        /* SNAPSHOT & HARDWARE ACCORDION */
        .system-info-card {
            background: var(--bg-card);
            border: 1px solid var(--border);
            border-radius: 16px;
            padding: 22px;
            margin-bottom: 24px;
        }

        .system-info-header {
            display: flex;
            justify-content: space-between;
            align-items: center;
            margin-bottom: 16px;
        }

        .system-info-title {
            font-size: 18px;
            font-weight: 700;
            color: var(--cyan-neon);
            display: flex;
            align-items: center;
            gap: 10px;
        }

        .info-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(280px, 1fr));
            gap: 16px;
        }

        .info-item {
            background: rgba(18, 20, 31, 0.6);
            border: 1px solid rgba(38, 42, 64, 0.6);
            border-radius: 12px;
            padding: 12px 16px;
        }

        .info-item-label {
            font-size: 12px;
            color: var(--text-muted);
            margin-bottom: 4px;
        }

        .info-item-val {
            font-size: 14px;
            font-weight: 600;
            color: var(--text-primary);
        }

        /* CONTROLS & FILTERING */
        .controls-bar {
            display: flex;
            justify-content: space-between;
            align-items: center;
            flex-wrap: wrap;
            gap: 16px;
            background: var(--bg-surface);
            border: 1px solid var(--border);
            border-radius: 14px;
            padding: 14px 20px;
            margin-bottom: 20px;
        }

        .filter-buttons {
            display: flex;
            gap: 8px;
            flex-wrap: wrap;
        }

        .filter-btn {
            background: var(--bg-card);
            color: var(--text-secondary);
            border: 1px solid var(--border);
            border-radius: 8px;
            padding: 8px 16px;
            font-size: 13px;
            font-weight: 600;
            cursor: pointer;
            transition: all 0.2s;
        }

        .filter-btn:hover {
            color: var(--text-primary);
            border-color: var(--purple-neon);
        }

        .filter-btn.active {
            background: var(--purple-neon);
            color: #ffffff;
            border-color: var(--purple-neon);
            box-shadow: 0 0 12px var(--purple-glow);
        }

        .search-box {
            position: relative;
            min-width: 280px;
        }

        .search-input {
            width: 100%;
            background: var(--bg-card);
            border: 1px solid var(--border);
            border-radius: 8px;
            padding: 8px 14px 8px 36px;
            color: var(--text-primary);
            font-size: 13px;
            outline: none;
            transition: all 0.2s;
        }

        .search-input:focus {
            border-color: var(--cyan-neon);
            box-shadow: 0 0 10px var(--cyan-glow);
        }

        .search-icon {
            position: absolute;
            left: 12px;
            top: 50%;
            transform: translateY(-50%);
            color: var(--text-muted);
            font-size: 14px;
        }

        /* ACTIONS TABLE */
        .table-card {
            background: var(--bg-card);
            border: 1px solid var(--border);
            border-radius: 16px;
            overflow: hidden;
            box-shadow: 0 10px 30px rgba(0, 0, 0, 0.3);
        }

        .table-responsive {
            overflow-x: auto;
            max-height: 75vh;
        }

        table {
            width: 100%;
            border-collapse: collapse;
            text-align: right;
            font-size: 13px;
        }

        thead {
            background: var(--bg-surface);
            position: sticky;
            top: 0;
            z-index: 10;
        }

        th {
            padding: 14px 18px;
            color: var(--text-secondary);
            font-weight: 600;
            border-bottom: 1px solid var(--border);
            text-transform: uppercase;
            font-size: 12px;
            letter-spacing: 0.5px;
        }

        td {
            padding: 14px 18px;
            border-bottom: 1px solid rgba(38, 42, 64, 0.4);
            color: var(--text-primary);
            vertical-align: middle;
        }

        tr:hover td {
            background: var(--bg-card-hover);
        }

        .status-pill {
            display: inline-flex;
            align-items: center;
            padding: 4px 10px;
            border-radius: 6px;
            font-size: 11px;
            font-weight: 700;
            gap: 4px;
        }

        .status-changed {
            background: rgba(16, 185, 129, 0.15);
            color: var(--green);
            border: 1px solid rgba(16, 185, 129, 0.3);
        }

        .status-already {
            background: rgba(0, 242, 254, 0.12);
            color: var(--cyan-neon);
            border: 1px solid rgba(0, 242, 254, 0.25);
        }

        .status-notfound {
            background: rgba(100, 116, 139, 0.12);
            color: var(--text-muted);
            border: 1px solid rgba(100, 116, 139, 0.25);
        }

        .status-failed {
            background: rgba(239, 68, 68, 0.15);
            color: var(--red);
            border: 1px solid rgba(239, 68, 68, 0.3);
        }

        .status-skipped {
            background: rgba(245, 158, 11, 0.15);
            color: var(--yellow);
            border: 1px solid rgba(245, 158, 11, 0.3);
        }

        .target-name {
            font-weight: 600;
            color: #ffffff;
            font-family: 'Consolas', monospace;
            word-break: break-all;
        }

        .action-desc {
            color: var(--text-secondary);
            margin-top: 2px;
        }

        .val-flow {
            display: flex;
            align-items: center;
            gap: 8px;
            font-family: 'Consolas', monospace;
            font-size: 12px;
            direction: ltr;
        }

        .val-before {
            color: var(--text-muted);
            background: rgba(0,0,0,0.3);
            padding: 2px 6px;
            border-radius: 4px;
            max-width: 180px;
            overflow: hidden;
            text-overflow: ellipsis;
            white-space: nowrap;
        }

        .val-arrow {
            color: var(--purple-neon);
        }

        .val-after {
            color: var(--green);
            background: rgba(16, 185, 129, 0.1);
            padding: 2px 6px;
            border-radius: 4px;
            font-weight: 600;
            max-width: 180px;
            overflow: hidden;
            text-overflow: ellipsis;
            white-space: nowrap;
        }

        .revert-code {
            font-family: 'Consolas', monospace;
            font-size: 11px;
            background: #0f111a;
            border: 1px solid #232738;
            border-radius: 4px;
            padding: 4px 8px;
            color: var(--cyan-neon);
            direction: ltr;
            text-align: left;
            word-break: break-all;
        }

        .notice {
            background: rgba(245, 158, 11, 0.12);
            border: 1px solid rgba(245, 158, 11, 0.4);
            color: var(--yellow);
            border-radius: 12px;
            padding: 12px 18px;
            margin-bottom: 20px;
            font-weight: 600;
        }

        /* FOOTER */
        .footer {
            margin-top: 30px;
            text-align: center;
            color: var(--text-muted);
            font-size: 13px;
        }
    </style>
</head>
<body>
    <div class="container">
        <!-- HEADER -->
        <header class="header">
            <div class="header-title-box">
                <div class="logo-icon">&#x26A1;</div>
                <div>
                    <h1 class="header-title">WinFlexOS - דוח פעולות ואופטימיזציה</h1>
                    <p class="header-subtitle">שקיפות מלאה: פירוט מוחלט של כל שינוי, שירות, משימה ורגיסטרי</p>
                </div>
            </div>
            <div class="header-badges">
                $modeTag
                <span class="badge badge-meta">פרופילים: $profList</span>
                <span class="badge badge-meta">משך ריצה: ${dur} שניות</span>
                <span class="badge badge-meta">מחשב: $pcName</span>
            </div>
        </header>
        $dryNote
        $rebootNote

        <!-- STATS -->
        <div class="stats-grid">
            <div class="stat-card" style="--accent-bar: var(--green);">
                <div class="stat-label">שינויים שבוצעו בפועל</div>
                <div class="stat-value" style="color: var(--green);">$cntChanged</div>
                <div class="stat-sub">ערכים, שירותים ומשימות שהשתנו</div>
            </div>
            <div class="stat-card" style="--accent-bar: var(--cyan-neon);">
                <div class="stat-label">כבר היו תקינים</div>
                <div class="stat-value" style="color: var(--cyan-neon);">$cntAlready</div>
                <div class="stat-sub">הוגדרו כבר בעבר במערכת</div>
            </div>
            <div class="stat-card" style="--accent-bar: var(--text-muted);">
                <div class="stat-label">לא קיימים במחשב</div>
                <div class="stat-value" style="color: var(--text-muted);">$cntNotFound</div>
                <div class="stat-sub">רכיבים / אפליקציות שלא מותקנים</div>
            </div>
            <div class="stat-card" style="--accent-bar: var(--purple-neon);">
                <div class="stat-label">שטח אחסון שנוקה</div>
                <div class="stat-value" style="color: var(--purple-neon);">$freedFormatted</div>
                <div class="stat-sub">קבצי זבל, שאריות וקאש</div>
            </div>
            <div class="stat-card" style="--accent-bar: var(--red);">
                <div class="stat-label">נכשלו / נחסמו</div>
                <div class="stat-value" style="color: $(if ($cntFailed -gt 0) { 'var(--red)' } else { 'var(--text-muted)' });">$cntFailed</div>
                <div class="stat-sub">שגיאות או הרשאות מערכת</div>
            </div>
        </div>

        <!-- HARDWARE & SNAPSHOT -->
        <div class="system-info-card">
            <div class="system-info-header">
                <div class="system-info-title">&#x1F4BB; נתוני חומרה ומצב מערכת בעת הריצה</div>
                <span style="font-size: 13px; color: var(--text-muted);">תאריך: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</span>
            </div>
            <div class="info-grid">
                <div class="info-item">
                    <div class="info-item-label">מערכת הפעלה</div>
                    <div class="info-item-val">$hwOS</div>
                </div>
                <div class="info-item">
                    <div class="info-item-label">מעבד (CPU)</div>
                    <div class="info-item-val">$hwCPU</div>
                </div>
                <div class="info-item">
                    <div class="info-item-label">זיכרון עבודה (RAM)</div>
                    <div class="info-item-val">$hwRAM</div>
                </div>
                <div class="info-item">
                    <div class="info-item-label">כרטיס גרפי (GPU)</div>
                    <div class="info-item-val">$hwGPU</div>
                </div>
                <div class="info-item">
                    <div class="info-item-label">תהליכים פעילים</div>
                    <div class="info-item-val">לפני: $($script:WF.SnapBefore.Processes) | אחרי: $($script:WF.SnapAfter.Processes)</div>
                </div>
                <div class="info-item">
                    <div class="info-item-label">שירותים פועלים ברקע</div>
                    <div class="info-item-val">לפני: $($script:WF.SnapBefore.RunningServices) | אחרי: $($script:WF.SnapAfter.RunningServices)</div>
                </div>
            </div>
        </div>

        <!-- CONTROLS & FILTERS -->
        <div class="controls-bar">
            <div class="filter-buttons">
                <button class="filter-btn active" data-filter="ALL" onclick="setFilter('ALL')">הכל ($cntTotal)</button>
                <button class="filter-btn" data-filter="Changed" onclick="setFilter('Changed')">בוצע שינוי ($cntChanged)</button>
                <button class="filter-btn" data-filter="Already" onclick="setFilter('Already')">כבר תקין ($cntAlready)</button>
                <button class="filter-btn" data-filter="NotFound" onclick="setFilter('NotFound')">לא קיים במחשב ($cntNotFound)</button>
                <button class="filter-btn" data-filter="Failed" onclick="setFilter('Failed')">נכשל ($cntFailed)</button>
                <button class="filter-btn" data-filter="Skipped" onclick="setFilter('Skipped')">דולג ($cntSkipped)</button>
                <button class="filter-btn" data-filter="Service" onclick="setFilter('Service')">שירותים בלבד</button>
                <button class="filter-btn" data-filter="Registry" onclick="setFilter('Registry')">רגיסטרי בלבד</button>
                <button class="filter-btn" data-filter="Task" onclick="setFilter('Task')">משימות מתוזמנות</button>
                <button class="filter-btn" data-filter="App" onclick="setFilter('App')">אפליקציות UWP</button>
            </div>
            <div class="search-box">
                <span class="search-icon">&#x1F50D;</span>
                <input type="text" id="searchInput" class="search-input" placeholder="חיפוש לפי שם שירות, מפתח רגיסטרי, פעולה..." oninput="renderRows()">
            </div>
        </div>

        <!-- TABLE -->
        <div class="table-card">
            <div class="table-responsive">
                <table id="actionsTable">
                    <thead>
                        <tr>
                            <th style="width: 70px;">שעה</th>
                            <th style="width: 100px;">סוג</th>
                            <th style="width: 130px;">סטטוס</th>
                            <th>יעד / רכיב במערכת</th>
                            <th>פעולה שבוצעה</th>
                            <th>ערך לפני / אחרי</th>
                            <th>פקודת שחזור (Undo)</th>
                        </tr>
                    </thead>
                    <tbody id="tableBody">
                        <!-- Populated by JS -->
                    </tbody>
                </table>
            </div>
        </div>

        <footer class="footer">
            <p>נוצר על ידי WinFlexOS Optimizer v$($script:WFVersion) &bull; קובץ שחזור מצב נשמר לצד דוח זה: <code>$([System.IO.Path]::GetFileName($jsonPath))</code></p>
        </footer>
    </div>

    <script>
        const actions = $safeActionsJson;
$jsCode
    </script>
</body>
</html>
"@

    [System.IO.File]::WriteAllText($OutPath, $html, [System.Text.Encoding]::UTF8)
    $script:WF.ReportPath = $OutPath
    Write-WFRaw "`n========================================================" 'Green'
    Write-WFRaw "   [OK] HTML Optimization Report Generated Successfully!" 'Green'
    Write-WFRaw "   Path: $OutPath" 'Cyan'
    Write-WFRaw "========================================================`n" 'Green'

    if ($OpenReport) {
        try { Start-Process $OutPath } catch {}
    }

    return $OutPath
}


# ==============================================================================
# 1. System & Hardware Audit + Deep Forensic / AI Scans
# ==============================================================================

function Get-SystemHardwareAudit {
    Write-WFBanner "Phase 1: Comprehensive System & Hardware Audit" 'Magenta'

    $systemEnclosure = Get-CimInstance -ClassName Win32_SystemEnclosure -ErrorAction SilentlyContinue
    $chassisTypes = $systemEnclosure.ChassisTypes
    $batteryCheck = Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue

    $laptopChassisCodes = @(8, 9, 10, 11, 12, 14, 18, 21, 30, 31, 32)
    $script:IsLaptop = if ($batteryCheck) { $true } else { $false }
    if (-not $script:IsLaptop) {
        foreach ($c in $chassisTypes) { if ($laptopChassisCodes -contains $c) { $script:IsLaptop = $true; break } }
    }

    $formFactorName = if ($script:IsLaptop) { "Laptop" } else { "Desktop" }
    $osInfo = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $script:WF.IsWin11 = ($osInfo.BuildNumber -ge 22000)
    $osName = if ($script:WF.IsWin11) { "Windows 11" } else { "Windows 10" }

    $script:cpu = Get-CimInstance -ClassName Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
    $baseboard = Get-CimInstance -ClassName Win32_BaseBoard -ErrorAction SilentlyContinue | Select-Object -First 1
    $computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
    $bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction SilentlyContinue | Select-Object -First 1

    $ramSticks = Get-CimInstance -ClassName Win32_PhysicalMemory -ErrorAction SilentlyContinue
    $script:totalRamGB = [math]::Round((($ramSticks | Measure-Object -Property Capacity -Sum).Sum) / 1GB, 2)
    $script:gpus = Get-CimInstance -ClassName Win32_VideoController -ErrorAction SilentlyContinue
    $disks = Get-PhysicalDisk -ErrorAction SilentlyContinue

    $script:hasSSD = $false
    foreach ($d in $disks) {
        if ($d.MediaType -eq "SSD" -or $d.BusType -eq "NVMe") { $script:hasSSD = $true }
    }

    # Store in session state for HTML report
    $gpuDesc = (@($script:gpus | ForEach-Object { $_.Name }) -join ', ')
    $script:WF.HW = @{
        FormFactor = $formFactorName
        OS = "$osName (Build $($osInfo.BuildNumber))"
        Computer = "$($computerSystem.Manufacturer) $($computerSystem.Model)"
        Motherboard = "$($baseboard.Manufacturer) $($baseboard.Product) (BIOS: $($bios.SMBIOSBIOSVersion))"
        CPU = "$($script:cpu.Name) ($($script:cpu.NumberOfCores)C / $($script:cpu.NumberOfLogicalProcessors)T @ $($script:cpu.MaxClockSpeed)MHz)"
        RAM = "$($script:totalRamGB) GB Installed"
        GPU = if ($gpuDesc) { $gpuDesc } else { "Default Display Adapter" }
        HasSSD = $script:hasSSD
    }

    Write-WFRaw "`n[+] Detected System Configuration: $formFactorName" 'Cyan'
    Write-WFRaw "   * Operating System: $osName (Build $($osInfo.BuildNumber))" 'Gray'
    Write-WFRaw "   * Manufacturer & Model: $($computerSystem.Manufacturer) - $($computerSystem.Model)" 'Gray'
    Write-WFRaw "   * Motherboard: $($baseboard.Manufacturer) $($baseboard.Product) (BIOS: $($bios.SMBIOSBIOSVersion))" 'Gray'

    Write-WFRaw "`n   * CPU: $($script:cpu.Name)" 'Green'
    Write-WFRaw "     - $($script:cpu.NumberOfCores) Cores / $($script:cpu.NumberOfLogicalProcessors) Threads | Base Clock: $($script:cpu.MaxClockSpeed) MHz" 'DarkGray'

    Write-WFRaw "`n   * RAM: $($script:totalRamGB) GB Installed" 'Green'
    $stickIdx = 1
    foreach ($stick in $ramSticks) {
        $stickGb = [math]::Round($stick.Capacity / 1GB, 1)
        Write-WFRaw "     - Stick $($stickIdx): $stickGb GB | Speed: $($stick.ConfiguredClockSpeed) MHz (Maker: $($stick.Manufacturer))" 'DarkGray'
        $stickIdx++
    }

    Write-WFRaw "`n   * GPU(s):" 'Green'
    foreach ($gpu in $script:gpus) {
        $vram = if ($gpu.AdapterRAM -gt 0) { "$([math]::Round($gpu.AdapterRAM / 1GB, 2)) GB VRAM" } else { "Shared RAM" }
        Write-WFRaw "     - $($gpu.Name) [$vram] (Driver: $($gpu.DriverVersion))" 'DarkCyan'
    }

    Write-WFRaw "`n   * Storage:" 'Green'
    foreach ($d in $disks) {
        Write-WFRaw "     - $($d.FriendlyName) : $([math]::Round($d.Size / 1GB, 1)) GB | Media: $($d.MediaType) $($d.BusType)" 'DarkGray'
    }

    Write-WFRaw "`n   * Disk Health (S.M.A.R.T):" 'Green'
    foreach ($pd in $disks) {
        $health = if ($pd.HealthStatus -eq "Healthy") { "[Healthy]" } else { "[WARNING]" }
        Write-WFRaw "     - $($pd.FriendlyName): $health (Status: $($pd.OperationalStatus))" 'Gray'
    }

    Write-WFRaw "`n   * Network Interfaces & Latency:" 'Green'
    $nics = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq "Up" }
    foreach ($nic in $nics) {
        Write-WFRaw "     - $($nic.Name) ($($nic.InterfaceDescription)) - Link: $($nic.LinkSpeed)" 'Gray'
    }
    $ping = Test-Connection -ComputerName 8.8.8.8 -Count 1 -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($ping) {
        # Windows PowerShell exposes ResponseTime, PowerShell 7 exposes Latency.
        $ms = if ($null -ne $ping.ResponseTime) { $ping.ResponseTime } else { $ping.Latency }
        Write-WFRaw "     - Internet Ping (8.8.8.8): $ms ms" 'Cyan'
    }

    Add-WFAction -Category 'Audit' -Type 'System' -Target 'Hardware Specification' -Action "Audited: $($script:cpu.Name), $($script:totalRamGB)GB RAM, $gpuDesc" -Status Info | Out-Null
}

function Invoke-ForensicDeepScan {
    Write-WFBanner "Phase 2: Forensic Deep Scan (Driver, Registry & Disk Analysis)" 'Red'
    
    $desktop = [Environment]::GetFolderPath('Desktop')
    if (-not (Test-Path -LiteralPath $desktop)) { $desktop = $env:USERPROFILE }
    $reportPath = Join-Path $desktop "Forensic_System_Report.txt"
    Write-WFRaw "[!] A detailed forensic log will be saved to: $reportPath" 'Yellow'
    
    "========================================================" | Out-File $reportPath -Encoding utf8
    " FORENSIC SYSTEM REPORT - $(Get-Date)" | Out-File $reportPath -Append -Encoding utf8
    "========================================================" | Out-File $reportPath -Append -Encoding utf8

    # 1. Driver Forensic Scan
    Write-WFPhase "Auditing all installed drivers"
    $drivers = Get-CimInstance Win32_PnPSignedDriver -ErrorAction SilentlyContinue
    $totalDrivers = $drivers.Count
    "--- DRIVER AUDIT ---" | Out-File $reportPath -Append -Encoding utf8
    foreach ($drv in $drivers) {
        $line = "Driver: $($drv.DeviceName) | Provider: $($drv.ProviderName) | Version: $($drv.DriverVersion) | Class: $($drv.DeviceClass) | Path: $($drv.Location)"
        $line | Out-File $reportPath -Append -Encoding utf8
    }
    Add-WFAction -Category 'Forensic' -Type 'Driver' -Target 'PnPSignedDriver' -Action "Scanned $totalDrivers active hardware drivers" -Status Info -Detail "Saved to $reportPath" | Out-Null

    # 2. Third Party / OEM Drivers (Driver Store)
    Write-WFPhase "Analyzing Driver Store (OEM & 3rd party registry)"
    "--- DRIVER STORE (OEM) ---" | Out-File $reportPath -Append -Encoding utf8
    $oemDrivers = & pnputil.exe /enum-drivers 2>&1 | Out-String
    $oemDrivers | Out-File $reportPath -Append -Encoding utf8
    Add-WFAction -Category 'Forensic' -Type 'Driver' -Target 'DriverStore' -Action "Enumerated OEM drivers via pnputil" -Status Info | Out-Null

    # 3. Deep Folder & Registry Scan in Background
    Write-WFPhase "Deep Registry & File Scan for Telemetry, AI Models & Junk"
    $jobScript = {
        $aiExts = @(".safetensors", ".pt", ".pth", ".onnx", ".gguf", ".ckpt")
        $jnkExts = @(".tmp", ".dmp", ".bak")
        $aiFiles = [System.Collections.Generic.List[string]]::new()
        $junkSize = [long]0

        $tDirs = @("$env:USERPROFILE", "$env:ProgramData", "$env:ProgramFiles", "${env:ProgramFiles(x86)}")
        foreach ($d in $tDirs) {
            if ($d -and (Test-Path -LiteralPath $d)) {
                # Streamed through the pipeline instead of collecting millions of FileInfo objects in memory.
                Get-ChildItem -LiteralPath $d -File -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object {
                    $ext = $_.Extension.ToLower()
                    # .bin is used by countless programs - only count it as a model when it is large (>= 100 MB).
                    if (($aiExts -contains $ext) -or ($ext -eq '.bin' -and $_.Length -ge 100MB)) { $aiFiles.Add("$($_.FullName) ($([math]::Round($_.Length/1MB, 2)) MB)") }
                    if ($jnkExts -contains $ext) { $junkSize += $_.Length }
                }
            }
        }
        
        $suspiciousKeys = [System.Collections.Generic.List[string]]::new()
        $terms = @(
            "Telemetry", "Tracking", "Advertising", "Cortana", "DiagTrack",
            "GameDVR", "OneDrive", "Skype", "MixedReality", "YourPhone",
            "NewsAndInterests", "Widgets", "MapsBroker", "PeopleExperienceHost",
            "EdgePrelaunch", "PrintSpooler", "Fax"
        )
        $hives = @("HKCU:\Software", "HKLM:\SOFTWARE")
        $termRx = '(?i)' + (($terms | ForEach-Object { [regex]::Escape($_) }) -join '|')
        foreach ($hive in $hives) {
            # Depth-limited: a full recursive walk of HKLM\SOFTWARE takes very long and finds little more.
            Get-ChildItem -Path $hive -Recurse -Depth 5 -ErrorAction SilentlyContinue | ForEach-Object {
                if ($_.PSChildName -match $termRx) { $suspiciousKeys.Add("Key name matches '$($matches[0])': $($_.Name)") }
            }
        }
        return @{ Ai = $aiFiles; Junk = $junkSize; Reg = $suspiciousKeys }
    }

    $job = Start-Job -ScriptBlock $jobScript
    $spinner = @('|', '/', '-', '\')
    $c = 0
    while ($job.State -eq 'Running') {
        Write-Host -NoNewline "`r    $($spinner[$c % 4]) Deep Scanning Registry & Files... (Running in Background)" -ForegroundColor Cyan
        $c++
        Start-Sleep -Milliseconds 120
    }
    Write-Host "`r    [OK] Background Registry & File Scan Completed!                     " -ForegroundColor Green

    $jobRes = Receive-Job -Job $job
    Remove-Job -Job $job

    $aiFiles = $jobRes.Ai
    $junkSize = $jobRes.Junk
    $suspiciousKeys = $jobRes.Reg

    # 4. Applications and Packages
    Write-WFPhase "Cataloging installed software & UWP AppX packages"
    "--- INSTALLED SOFTWARE ---" | Out-File $reportPath -Append -Encoding utf8
    Get-ItemProperty HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\* -ErrorAction SilentlyContinue | Select-Object DisplayName, DisplayVersion, InstallLocation | Out-File $reportPath -Append -Encoding utf8
    Get-ItemProperty HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\* -ErrorAction SilentlyContinue | Select-Object DisplayName, DisplayVersion, InstallLocation | Out-File $reportPath -Append -Encoding utf8
    
    "--- UWP APPX PACKAGES ---" | Out-File $reportPath -Append -Encoding utf8
    Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue | Select-Object Name, PackageFullName, InstallLocation | Out-File $reportPath -Append -Encoding utf8

    "--- SCAN SUMMARY ---" | Out-File $reportPath -Append -Encoding utf8
    "Total Drivers Audited: $totalDrivers" | Out-File $reportPath -Append -Encoding utf8
    "Found Suspicious Registry Keys ($($suspiciousKeys.Count)):" | Out-File $reportPath -Append -Encoding utf8
    foreach ($sk in $suspiciousKeys) { $sk | Out-File $reportPath -Append -Encoding utf8 }
    "Identified AI/ML Model Files ($($aiFiles.Count)):" | Out-File $reportPath -Append -Encoding utf8
    foreach ($ai in $aiFiles) { $ai | Out-File $reportPath -Append -Encoding utf8 }
    "Total Identifiable Junk/Temp/Dump Size: $([math]::Round($junkSize/1GB, 2)) GB" | Out-File $reportPath -Append -Encoding utf8

    Add-WFAction -Category 'Forensic' -Type 'Registry' -Target 'Telemetry-related key names' -Action "Found $($suspiciousKeys.Count) registry keys whose name matches a telemetry/bloat keyword" -Status Info -Detail 'A matching name is only a hint - it does not prove the key tracks anything.' | Out-Null
    Add-WFAction -Category 'Forensic' -Type 'Files' -Target 'AI Model Weights' -Action "Found $($aiFiles.Count) AI model files on disk" -Status Info | Out-Null
    Add-WFAction -Category 'Forensic' -Type 'Files' -Target 'Junk / Temp Files' -Action "Identified $(Format-WFBytes $junkSize) of junk/dump files" -Status Info | Out-Null
}

function Invoke-DeepAIScan {
    Write-WFBanner "Phase: Massive AI & ML System Diagnostic" 'Magenta'

    Write-WFPhase "Auditing CPU instruction sets & cache for AI acceleration"
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    Write-WFRaw "    - Model: $($cpu.Name)" 'Gray'
    Write-WFRaw "    - Cores: $($cpu.NumberOfCores) / Threads: $($cpu.NumberOfLogicalProcessors)" 'Gray'
    Write-WFRaw "    - L3 Cache: $($cpu.L3CacheSize) MB" 'Gray'
    Write-WFRaw "    - Virtualization Enabled: $($cpu.VirtualizationFirmwareEnabled)" 'Gray'
    Add-WFAction -Category 'AI/ML' -Type 'Hardware' -Target 'CPU' -Action "$($cpu.Name) [L3: $($cpu.L3CacheSize)MB, Virt: $($cpu.VirtualizationFirmwareEnabled)]" -Status Info | Out-Null

    Write-WFPhase "Auditing Physical Memory & Pagefile allocation"
    $mem = Get-CimInstance Win32_PhysicalMemory -ErrorAction SilentlyContinue
    $totalMem = [math]::Round((($mem | Measure-Object -Property Capacity -Sum).Sum) / 1GB, 2)
    Write-WFRaw "    - Total Physical RAM: $totalMem GB" 'Green'
    $page = Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue
    if ($page) { foreach ($p in $page) { Write-WFRaw "    - PageFile: $($p.Name) | Allocated: $($p.AllocatedBaseSize) MB" 'Gray' } }
    Add-WFAction -Category 'AI/ML' -Type 'Hardware' -Target 'RAM/PageFile' -Action "$totalMem GB Physical RAM" -Status Info | Out-Null

    Write-WFPhase "Auditing GPU Accelerators & NVIDIA CUDA / AMD ROCm"
    $gpus = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue
    foreach ($gpu in $gpus) {
        Write-WFRaw "    - GPU: $($gpu.Name) (Driver: $($gpu.DriverVersion))" 'Gray'
        if ($gpu.Name -match "AMD|Radeon") {
            Write-WFRaw "      [!] AMD GPU Detected! Use DirectML or ROCm for PyTorch/TensorFlow." 'Yellow'
        }
    }
    $nvSmi = (Get-Command "nvidia-smi" -ErrorAction SilentlyContinue).Source
    if ($nvSmi) {
        try {
            $smiOut = & $nvSmi --query-gpu=name,memory.total,memory.free,temperature.gpu,utilization.gpu --format=csv,noheader
            Write-WFRaw "    - NVIDIA Stats: $smiOut" 'Green'
            Add-WFAction -Category 'AI/ML' -Type 'Hardware' -Target 'NVIDIA CUDA' -Action "nvidia-smi: $smiOut" -Status Info | Out-Null
        } catch {}
    } else {
        Write-WFRaw "    - nvidia-smi not in PATH" 'DarkGray'
    }

    Write-WFPhase "Checking AI Developer Toolchains in PATH"
    $tools = @("python", "git", "docker", "wsl", "ollama", "node", "cmake", "conda", "nvcc")
    foreach ($tool in $tools) {
        $path = (Get-Command $tool -ErrorAction SilentlyContinue).Source
        if ($path) {
            Write-WFRaw "    - [OK] $tool : Found ($path)" 'Green'
            Add-WFAction -Category 'AI/ML' -Type 'Toolchain' -Target $tool -Action "Installed: $path" -Status Info | Out-Null
        } else {
            Write-WFRaw "    - [ ] $tool : Not installed" 'DarkGray'
        }
    }
}


# ==============================================================================
# 2. Optimization & Debloat Profiles (Including Ultra-Deep Nuclear Debloat)
# ==============================================================================

function Invoke-BaseDebloat {
    # Shared by several profiles - run it only once per session (e.g. "-ProfileId 1,2").
    if ($script:WF.BaseDone) { return }
    $script:WF.BaseDone = $true
    Write-WFPhase "Base Debloat: Core Telemetry & Diagnostics"

    # 1. Telemetry Services
    # (WaaSMedicSvc is intentionally NOT touched: it is protected and keeps Windows Update able to repair itself.)
    Disable-WFService -Name "DiagTrack" -Desc "Connected User Experiences and Telemetry" -Category "Telemetry"
    Disable-WFService -Name "dmwappushservice" -Desc "Device Management Wireless Application Protocol Routing" -Category "Telemetry"
    Disable-WFService -Name "WerSvc" -Desc "Windows Error Reporting Service" -Category "Telemetry"

    # 2. Cortana & Start Menu Search
    Set-WFReg -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" -Name "AllowCortana" -Value 0 -Type DWord -Desc "Disable Cortana assistant" -Category "Privacy"
    Set-WFReg -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" -Name "DisableWebSearch" -Value 1 -Type DWord -Desc "Disable Bing web search in Start menu" -Category "Privacy"
    Set-WFReg -Path "HKCU:\Software\Policies\Microsoft\Windows\Explorer" -Name "DisableSearchBoxSuggestions" -Value 1 -Type DWord -Desc "Disable search box web suggestions" -Category "Privacy"

    # 3. Privacy & Activity Tracking
    Set-WFReg -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -Name "EnableActivityFeed" -Value 0 -Type DWord -Desc "Disable Activity Timeline feed" -Category "Privacy"
    Set-WFReg -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -Name "PublishUserActivities" -Value 0 -Type DWord -Desc "Stop uploading user activities to cloud" -Category "Privacy"
    Set-WFReg -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo" -Name "Enabled" -Value 0 -Type DWord -Desc "Disable personalized Advertising ID" -Category "Privacy"
    Set-WFReg -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy" -Name "TailoredExperiencesWithDiagnosticDataEnabled" -Value 0 -Type DWord -Desc "Disable tailored experiences using diagnostics" -Category "Privacy"

    # 4. Delivery Optimization
    Set-WFReg -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization" -Name "DODownloadMode" -Value 0 -Type DWord -Desc "Disable P2P Windows Update Delivery Optimization" -Category "Network"

    # 5. Explorer: Show Extensions & Hidden Files
    Set-WFReg -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "HideFileExt" -Value 0 -Type DWord -Desc "Show file name extensions in Explorer" -Category "System UI"

    # 6. SysMain for SSDs
    if ($script:hasSSD) {
        Disable-WFService -Name "SysMain" -Desc "SuperFetch / SysMain on SSD drives" -Category "Storage"
    }

    # 7. UWP Bloatware Removal
    Write-WFPhase "Base Debloat: UWP Consumer Bloatware"
    $bloatware = @(
        "Microsoft.BingNews", "Microsoft.MicrosoftSolitaireCollection", "Microsoft.NetworkSpeedTest",
        "Microsoft.SkypeApp", "Microsoft.WindowsFeedbackHub", "Microsoft.ZuneVideo", "Microsoft.ZuneMusic",
        "SpotifyAB.SpotifyMusic", "Clipchamp.Clipchamp", "Microsoft.Todos", "Microsoft.YourPhone", "Microsoft.MixedReality.Portal", "Microsoft.GetHelp"
    )
    foreach ($app in $bloatware) {
        Remove-WFAppx -Pattern $app -Desc "Standard Windows pre-installed app" -Category "Apps (UWP)"
    }
}

function Invoke-ProfileGaming {
    [void]$script:WF.ProfileNames.Add("Gaming")
    Write-WFPhase "Profile: 100000% Gaming, Latency & ASUS Tamer (Max FPS, Zero Mouse Accel, Minimal Ping)"

    # Windows Game Mode & GameDVR
    Set-WFReg -Path "HKCU:\Software\Microsoft\GameBar" -Name "AutoGameModeEnabled" -Value 1 -Type DWord -Desc "Enable Windows Game Mode" -Category "Gaming"
    Set-WFReg -Path "HKCU:\System\GameConfigStore" -Name "GameDVR_Enabled" -Value 0 -Type DWord -Desc "Disable Background Game DVR Recording" -Category "Gaming"
    Set-WFReg -Path "HKCU:\System\GameConfigStore" -Name "GameDVR_FSEBehaviorMode" -Value 2 -Type DWord -Desc "Fullscreen optimization stability" -Category "Gaming"
    Set-WFReg -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR" -Name "AllowGameDVR" -Value 0 -Type DWord -Desc "Policy: Disable Game DVR" -Category "Gaming"

    # MMCSS Priority & Zero Background CPU Reserve
    Set-WFReg -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" -Name "NetworkThrottlingIndex" -Value 0xFFFFFFFF -Type DWord -Desc "Disable Network Throttling (Lowest Ping)" -Category "Network"
    Set-WFReg -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" -Name "SystemResponsiveness" -Value 0 -Type DWord -Desc "Prioritize Games Over Background Tasks (100% CPU to games)" -Category "Gaming"

    $gamesKey = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games"
    Set-WFReg -Path $gamesKey -Name "GPU Priority" -Value 8 -Type DWord -Desc "MMCSS GPU Priority 8" -Category "Gaming"
    Set-WFReg -Path $gamesKey -Name "Priority" -Value 6 -Type DWord -Desc "MMCSS Task Priority 6" -Category "Gaming"
    Set-WFReg -Path $gamesKey -Name "Scheduling Category" -Value "High" -Type String -Desc "MMCSS Scheduling High" -Category "Gaming"
    Set-WFReg -Path $gamesKey -Name "SFIO Priority" -Value "High" -Type String -Desc "MMCSS SFIO High" -Category "Gaming"

    # Quantum Boost for Foreground Applications (Win32PrioritySeparation 0x26)
    Set-WFReg -Path "HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl" -Name "Win32PrioritySeparation" -Value 38 -Type DWord -Desc "Foreground Quantum Boost (0x26 - Snappy Responsiveness)" -Category "Kernel"

    # Disable Power Throttling
    Set-WFReg -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling" -Name "PowerThrottlingOff" -Value 1 -Type DWord -Desc "Disable CPU Power Throttling on games" -Category "Power"

    # Keep Kernel and Drivers resident in RAM (Disable Paging Executive)
    Set-WFReg -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management" -Name "DisablePagingExecutive" -Value 1 -Type DWord -Desc "Keep Kernel & Drivers in RAM (Zero Paging Lag)" -Category "Memory"
    Set-WFReg -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management" -Name "LargeSystemCache" -Value 0 -Type DWord -Desc "Prevent System Cache RAM bloating" -Category "Memory"

    # Network Low Latency (TCPNoDelay, TcpAckFrequency=1)
    $ifaceBase = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces"
    if (Test-Path $ifaceBase) {
        Get-ChildItem -Path $ifaceBase -ErrorAction SilentlyContinue | ForEach-Object {
            Set-WFReg -Path $_.PSPath -Name "TcpAckFrequency" -Value 1 -Type DWord -Desc "Send TCP ACK immediately" -Category "Network"
            Set-WFReg -Path $_.PSPath -Name "TCPNoDelay" -Value 1 -Type DWord -Desc "Disable Nagle algorithm (Instant packet send)" -Category "Network"
            Set-WFReg -Path $_.PSPath -Name "TcpDelAckTicks" -Value 0 -Type DWord -Desc "Zero TCP ACK Delay Ticks" -Category "Network"
        }
    }
    Set-WFNetshTcp -Setting "heuristics" -Value "disabled" -Desc "Disable TCP heuristics" -Category "Network"
    Set-WFNetshTcp -Setting "autotuninglevel" -Value "normal" -Desc "Optimal TCP auto-tuning" -Category "Network"
    Set-WFNetshTcp -Setting "rss" -Value "enabled" -Desc "Enable Receive Side Scaling" -Category "Network"

    # DPC Latency (HPET & Dynamic Tick)
    Remove-WFBcd -Name "useplatformclock" -Desc "Disable synthetic HPET (use CPU invariant TSC)" -Category "Boot / Latency"
    Set-WFBcd -Name "disabledynamictick" -Value "yes" -Desc "Disable dynamic tick for low micro-stutter" -Category "Boot / Latency"

    # Hardware-Accelerated GPU Scheduling (HAGS)
    Set-WFReg -Path "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" -Name "HwSchMode" -Value 2 -Type DWord -Desc "Enable Hardware-Accelerated GPU Scheduling" -Category "GPU"

    # Raw 1:1 Mouse Input
    Set-WFReg -Path "HKCU:\Control Panel\Mouse" -Name "MouseSpeed" -Value "0" -Type String -Desc "Disable Mouse Acceleration" -Category "Input"
    Set-WFReg -Path "HKCU:\Control Panel\Mouse" -Name "MouseThreshold1" -Value "0" -Type String -Desc "Zero Mouse Acceleration Threshold 1" -Category "Input"
    Set-WFReg -Path "HKCU:\Control Panel\Mouse" -Name "MouseThreshold2" -Value "0" -Type String -Desc "Zero Mouse Acceleration Threshold 2" -Category "Input"

    # Zero Menu Delay
    Set-WFReg -Path "HKCU:\Control Panel\Desktop" -Name "MenuShowDelay" -Value "0" -Type String -Desc "Zero Menu Show Delay (Instant UI)" -Category "System UI"
    Set-WFReg -Path "HKCU:\Control Panel\Desktop" -Name "AutoEndTasks" -Value "1" -Type String -Desc "Auto End Hung Tasks" -Category "System UI"

    # Power Scheme & Core Unparking
    if (-not $script:IsLaptop) {
        $uGuid = Get-WFUltimateGuid
        if ($uGuid) {
            Set-WFPowerPlan -Guid $uGuid -Name "Ultimate Performance" -Desc "Unpark all CPU cores & disable sleep states" -Category "Power" | Out-Null
        }
    }

    # ASUS Hardware & Armoury Crate Deep Taming (Auto-applied if ASUS detected)
    $bb = Get-CimInstance -ClassName Win32_BaseBoard -ErrorAction SilentlyContinue | Select-Object -First 1
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue | Select-Object -First 1
    $isAsus = ($bb.Manufacturer -match 'ASUS|ASUSTeK') -or ($cs.Manufacturer -match 'ASUS|ASUSTeK')
    if ($isAsus) {
        Write-WFPhase "ASUS Gaming Rig Detected: Applying Deep Armoury Crate & Anti-Stutter Tamer"
        # 1. Stop GameFirst
        @("AsusGameFirstService", "ROG Game First", "cFosSpeed", "cFosSpeedSvc") | ForEach-Object {
            Disable-WFService -Name $_ -Desc "Disable ASUS GameFirst network latency killer" -Category "Network"
        }
        # 2. Stop Telemetry
        @("AsusROGLSLService", "ASUSSoftwareManager", "ASUSLinkNear", "ASUSLinkRemote", "AsusAppService", "AsusCertService") | ForEach-Object {
            Disable-WFService -Name $_ -Desc "Disable ASUS background telemetry & ad polling" -Category "Telemetry"
        }
        # 3. Tame LightingService
        Set-WFReg -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\LightingService.exe\PerfOptions" -Name "CpuPriorityClass" -Value 5 -Type DWord -Desc "LightingService CPU Priority BelowNormal" -Category "Aura RGB"
        foreach ($proc in @(Get-Process -Name "LightingService" -ErrorAction SilentlyContinue)) {
            if ($script:WF.DryRun) { Add-WFAction -Category 'Aura RGB' -Type 'System' -Target "LightingService (PID $($proc.Id))" -Action 'Lower running process priority to BelowNormal' -Status Changed | Out-Null; continue }
            try {
                $proc.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::BelowNormal
                Add-WFAction -Category 'Aura RGB' -Type 'System' -Target "LightingService (PID $($proc.Id))" -Action 'Lower running process priority to BelowNormal' -After 'BelowNormal' -Status Changed -Detail 'Applies until the process restarts.' | Out-Null
            } catch { Add-WFAction -Category 'Aura RGB' -Type 'System' -Target 'LightingService' -Action 'Lower running process priority' -Status Failed -Detail $_.Exception.Message | Out-Null }
        }
        # 4. Kill runaway helpers
        foreach ($proc in @(Get-Process -Name "ArmouryCrate.UserSessionHelper" -ErrorAction SilentlyContinue | Where-Object { $_.CPU -gt 15 })) {
            if ($script:WF.DryRun) { Add-WFAction -Category 'Aura RGB' -Type 'System' -Target "ArmouryCrate.UserSessionHelper (PID $($proc.Id))" -Action 'Stop runaway helper process' -Status Changed | Out-Null; continue }
            try {
                Stop-Process -Id $proc.Id -Force -ErrorAction Stop
                Add-WFAction -Category 'Aura RGB' -Type 'System' -Target "ArmouryCrate.UserSessionHelper (PID $($proc.Id))" -Action 'Stop runaway helper process' -Status Changed -Detail ("Used {0:N0}s CPU time." -f $proc.CPU) | Out-Null
            } catch { Add-WFAction -Category 'Aura RGB' -Type 'System' -Target 'ArmouryCrate.UserSessionHelper' -Action 'Stop runaway helper process' -Status Failed -Detail $_.Exception.Message | Out-Null }
        }
    }
}

function Invoke-ProfileOffice {
    [void]$script:WF.ProfileNames.Add("Office & Browsing")
    Write-WFPhase "Profile: Office & Browsing (Maximum Stability & Efficiency)"

    Set-WFReg -Path "HKCU:\Software\Microsoft\GameBar" -Name "AutoGameModeEnabled" -Value 0 -Type DWord -Desc "Disable Game Mode for desktop stability" -Category "System"
    Set-WFPowerPlan -Guid "381b4222-f694-41f0-9685-ff5bb260df2e" -Name "Balanced" -Desc "Enable Balanced Power Plan" -Category "Power" | Out-Null
}

function Invoke-ProfileCreator {
    [void]$script:WF.ProfileNames.Add("Content Creation")
    Write-WFPhase "Profile: Content Creation (Stable Rendering & Export Pipelines)"

    Set-WFReg -Path "HKCU:\Software\Microsoft\GameBar" -Name "AutoGameModeEnabled" -Value 0 -Type DWord -Desc "Disable Game Mode" -Category "System"
    Set-WFReg -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" -Name "SystemResponsiveness" -Value 20 -Type DWord -Desc "Stable System Responsiveness (20%) for background rendering" -Category "Media"

    if (-not $script:IsLaptop) {
        if ((Get-WFPowerSchemeGuids) -contains '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c') {
            Set-WFPowerPlan -Guid "8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c" -Name "High Performance" -Desc "High Performance Power Plan for faster exports" -Category "Power" | Out-Null
        } else {
            Add-WFAction -Category 'Power' -Type 'Power' -Target 'Power plan' -Action 'Activate High Performance power plan' -Status NotFound -Detail 'This PC does not offer the High Performance plan (Modern Standby) - kept the current plan.' | Out-Null
        }
    }
}

function Invoke-ProfileAI {
    [void]$script:WF.ProfileNames.Add("AI & Machine Learning")
    Write-WFPhase "Profile: AI & Machine Learning (Deep Long Paths, VRAM & Max Compute)"

    Set-WFReg -Path "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem" -Name "LongPathsEnabled" -Value 1 -Type DWord -Desc "Enable NTFS Long Paths (>260 chars for deep Python/HuggingFace repos)" -Category "Developer"
    Set-WFReg -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" -Name "SystemResponsiveness" -Value 10 -Type DWord -Desc "System Responsiveness 10% for inference tasks" -Category "Compute"

    if (-not $script:IsLaptop) {
        $uGuid = Get-WFUltimateGuid
        if ($uGuid) {
            Set-WFPowerPlan -Guid $uGuid -Name "Ultimate Performance" -Desc "Ultimate Performance power scheme for sustained tensor compute" -Category "Power" | Out-Null
        }
    }
    Invoke-DeepAIScan
}

function Invoke-ProfilePrivacyShield {
    [void]$script:WF.ProfileNames.Add("Privacy Shield")
    Write-WFPhase "Profile: Privacy Shield (Total Tracking & Data Exfiltration Block)"

    # Telemetry level: 0 (Security / Diagnostic data off)
    Set-WFReg -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" -Name "AllowTelemetry" -Value 0 -Type DWord -Desc "Set Windows Telemetry level to 0 (Security Only)" -Category "Privacy"
    Set-WFReg -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection" -Name "AllowTelemetry" -Value 0 -Type DWord -Desc "Disable User Data Collection" -Category "Privacy"

    # Location (moved here from Base Debloat: it also turns off Maps, Weather and Find My Device)
    Set-WFReg -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors" -Name "DisableLocation" -Value 1 -Type DWord -Desc "Disable location for all apps (Maps, Weather, Find My Device)" -Category "Privacy"

    # Feedback Frequency: Never
    Set-WFReg -Path "HKCU:\Software\Microsoft\Siuf\Rules" -Name "NumberOfSIUFInPeriod" -Value 0 -Type DWord -Desc "Disable Windows Feedback prompts" -Category "Privacy"
    Set-WFReg -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" -Name "DoNotShowFeedbackNotifications" -Value 1 -Type DWord -Desc "Suppress feedback notification popups" -Category "Privacy"

    # Inking & Typing Telemetry
    Set-WFReg -Path "HKCU:\Software\Microsoft\InputPersonalization" -Name "RestrictImplicitInkCollection" -Value 1 -Type DWord -Desc "Block keystroke & typing data collection" -Category "Privacy"
    Set-WFReg -Path "HKCU:\Software\Microsoft\InputPersonalization" -Name "RestrictImplicitTextCollection" -Value 1 -Type DWord -Desc "Block handwriting data collection" -Category "Privacy"
    Set-WFReg -Path "HKCU:\Software\Microsoft\Personalization\Settings" -Name "AcceptedPrivacyPolicy" -Value 0 -Type DWord -Desc "Revoke input personalization consent" -Category "Privacy"

    # Application Diagnostic & Inventory
    Set-WFReg -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppCompat" -Name "DisableInventory" -Value 1 -Type DWord -Desc "Disable Application Compatibility Inventory collector" -Category "Privacy"
    Set-WFReg -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppCompat" -Name "AITEnable" -Value 0 -Type DWord -Desc "Disable Application Impact Telemetry" -Category "Privacy"

    # Scheduled Tasks for Telemetry & CEIP
    Disable-WFTask -Path "\Microsoft\Windows\Application Experience\" -Name "Microsoft Compatibility Appraiser" -Desc "Compatibility telemetry scanner" -Category "Scheduled Tasks"
    Disable-WFTask -Path "\Microsoft\Windows\Application Experience\" -Name "ProgramDataUpdater" -Desc "Application telemetry updater" -Category "Scheduled Tasks"
    Disable-WFTask -Path "\Microsoft\Windows\Application Experience\" -Name "StartupAppTask" -Desc "Startup app scanner" -Category "Scheduled Tasks"
    Disable-WFTask -Path "\Microsoft\Windows\Customer Experience Improvement Program\" -Name "Consolidator" -Desc "CEIP telemetry consolidator" -Category "Scheduled Tasks"
    Disable-WFTask -Path "\Microsoft\Windows\Customer Experience Improvement Program\" -Name "UsbCeip" -Desc "USB CEIP telemetry" -Category "Scheduled Tasks"
    Disable-WFTask -Path "\Microsoft\Windows\Autochk\" -Name "Proxy" -Desc "SQM autochk proxy task" -Category "Scheduled Tasks"
    Disable-WFTask -Path "\Microsoft\Windows\DiskDiagnostic\" -Name "Microsoft-Windows-DiskDiagnosticDataCollector" -Desc "Disk diagnostic data exfiltration" -Category "Scheduled Tasks"
    Disable-WFTask -Path "\Microsoft\Windows\Feedback\Siuf\" -Name "DmClient" -Desc "Feedback SIUF DM client" -Category "Scheduled Tasks"
    Disable-WFTask -Path "\Microsoft\Windows\Feedback\Siuf\" -Name "DmClientOnScenarioDownload" -Desc "Feedback download scenario" -Category "Scheduled Tasks"

    # Known Microsoft Telemetry Domains
    Add-WFHostsBlock -Domains @(
        "vortex.data.microsoft.com", "vortex-win.data.microsoft.com", "telemetry.microsoft.com",
        "telecommand.telemetry.microsoft.com", "telecommand.telemetry.microsoft.com.nsatc.net",
        "oca.telemetry.microsoft.com", "sqm.telemetry.microsoft.com", "watson.telemetry.microsoft.com",
        "redir.metaservices.microsoft.com", "choice.microsoft.com", "df.telemetry.microsoft.com",
        "reports.wes.df.telemetry.microsoft.com", "cs1.wpc.v0cdn.net", "v10.events.data.microsoft.com",
        "v20.events.data.microsoft.com"
    ) -Desc "Block Microsoft telemetry data endpoint" -Category "Network / Hosts"
    # settings-win.data.microsoft.com is not blocked: Windows Update, Store and Defender read their settings from it.
    Add-WFAction -Category 'Network / Hosts' -Type 'Hosts' -Target 'Microsoft Defender' -Action 'Note about the hosts file' -Status Info -Detail 'Defender may flag hosts entries for Microsoft domains (SettingsModifier:Win32/HostsFileHijack) and remove them. If that happens, allow the detection in Windows Security or accept the removal.' | Out-Null
}

function Invoke-ProfileNetworkSupercharger {
    [void]$script:WF.ProfileNames.Add("Network Supercharger")
    Write-WFPhase "Profile: Network Supercharger (TCP/IP Optimization & DNS Refresh)"

    Set-WFNetshTcp -Setting "heuristics" -Value "disabled" -Desc "Disable TCP heuristics scaling" -Category "Network"
    Set-WFNetshTcp -Setting "autotuninglevel" -Value "normal" -Desc "Enable TCP window auto-tuning" -Category "Network"
    Set-WFNetshTcp -Setting "rss" -Value "enabled" -Desc "Receive Side Scaling (multithreaded packet processing)" -Category "Network"
    Set-WFNetshTcp -Setting "fastopen" -Value "enabled" -Desc "TCP Fast Open for web sockets" -Category "Network"

    # Disable LLMNR & NetBIOS over TCP/IP (Security & latency)
    Set-WFReg -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient" -Name "EnableMulticast" -Value 0 -Type DWord -Desc "Disable Link-Local Multicast Name Resolution (LLMNR)" -Category "Network"

    # Flush DNS cache
    Invoke-WFOneShot -Category "Network" -Type "System" -Target "DNS Cache" -Action "Flush DNS Resolver Cache" -Script {
        & ipconfig.exe /flushdns 2>&1 | Out-String
    } -OkDetail "DNS resolver cache flushed successfully." -Revert "ipconfig /registerdns"
}

function Invoke-ProfileBatterySaver {
    [void]$script:WF.ProfileNames.Add("Laptop Battery Saver")
    Write-WFPhase "Profile: Laptop Battery Saver (Aggressive Power Conservation)"

    # Power Saver plan (a1841308...). Modern Standby PCs only ship Balanced - fall back to it there.
    $saver = 'a1841308-3541-4fab-bc81-f71556f20b4a'
    if ((Get-WFPowerSchemeGuids) -contains $saver) {
        Set-WFPowerPlan -Guid $saver -Name "Power Saver" -Desc "Switch to Power Saver profile" -Category "Power" | Out-Null
    } else {
        Set-WFPowerPlan -Guid "381b4222-f694-41f0-9685-ff5bb260df2e" -Name "Balanced" -Desc "Power Saver plan is not available on this PC - using Balanced with the battery limits below" -Category "Power" | Out-Null
    }
    Set-WFPowerSetting -Sub "SUB_PROCESSOR" -Setting "PROCTHROTTLEMAX" -AC 100 -DC 80 -Label "Max CPU Throttle (80% on Battery)" -Category "Power"
    Set-WFPowerSetting -Sub "SUB_DISK" -Setting "DISKIDLE" -AC 1200 -DC 300 -Label "Disk Idle Spin-down (5 min on Battery)" -Category "Power"
    Set-WFPowerSetting -Sub "SUB_VIDEO" -Setting "VIDEOIDLE" -AC 900 -DC 180 -Label "Display Timeout (3 min on Battery)" -Category "Power"
}

function Invoke-ProfileDeepCleanup {
    [void]$script:WF.ProfileNames.Add("Deep System Cleanup")
    Write-WFPhase "Profile: Deep Disk & Cache Cleanup"

    # User & Windows Temp
    Clear-WFFolder -Path $env:TEMP -Desc "User Temporary files cache" -Category "Cleanup"
    Clear-WFFolder -Path (Join-Path $env:SystemRoot "Temp") -Desc "Windows System Temporary files" -Category "Cleanup"

    # Windows Update Download Cache
    $wuCache = Join-Path $env:SystemRoot "SoftwareDistribution\Download"
    Clear-WFFolder -Path $wuCache -Desc "Windows Update installer cache" -Category "Cleanup" -StopServices @("wuauserv", "bits")

    # Delivery Optimization Cache
    $doCache = Join-Path $env:SystemRoot "ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache"
    Clear-WFFolder -Path $doCache -Desc "P2P Delivery Optimization cache" -Category "Cleanup" -StopServices @("DoSvc")

    # Crash Dumps & MiniDumps
    Clear-WFFolder -Path (Join-Path $env:SystemRoot "Minidump") -Desc "Kernel memory minidumps" -Category "Cleanup"
    Clear-WFFolder -Path (Join-Path $env:LOCALAPPDATA "CrashDumps") -Desc "User application crash dumps" -Category "Cleanup"

    # ReTrim SSD drives
    if ($script:hasSSD) {
        Invoke-WFOneShot -Category "Storage" -Type "System" -Target "SSD Volume C:" -Action "Issue TRIM (Defrag ReTrim) command" -Script {
            Optimize-Volume -DriveLetter C -ReTrim -ErrorAction SilentlyContinue | Out-String
        } -OkDetail "SSD TRIM command sent to Volume C:."
    }
}

function Invoke-ProfileSecurityHardening {
    [void]$script:WF.ProfileNames.Add("Security Hardening")
    Write-WFPhase "Profile: Windows Security Hardening & Attack Surface Reduction"

    # Disable Remote Assistance
    Set-WFReg -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Remote Assistance" -Name "fAllowToGetHelp" -Value 0 -Type DWord -Desc "Disable unsolicited Remote Assistance requests" -Category "Security"

    # Disable AutoRun / AutoPlay on external media
    Set-WFReg -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" -Name "NoDriveTypeAutoRun" -Value 255 -Type DWord -Desc "Disable AutoPlay on removable flash drives" -Category "Security"

    # Disable WPAD (Web Proxy Auto-Discovery) Attack Vector
    Set-WFReg -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings\Wpad" -Name "WpadOverride" -Value 1 -Type DWord -Desc "Disable WPAD proxy auto-discovery hijack" -Category "Security"

    # Hide Account Info on Lock Screen
    Set-WFReg -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "dontdisplaylastusername" -Value 1 -Type DWord -Desc "Hide last logged in username on lock screen" -Category "Security"
}

function Invoke-ProfileNuclearDebloat {
    [void]$script:WF.ProfileNames.Add("Ultra-Deep Nuclear Debloat")
    Write-WFBanner "Profile 11: Ultra-Deep Nuclear Debloat (Extreme Stripping)" 'Red'

    # Run Base Debloat + Privacy Shield
    Invoke-BaseDebloat
    Invoke-ProfilePrivacyShield

    Write-WFPhase "Nuclear Debloat: Windows 11 Copilot, Widgets & AI Telemetry Nuker"

    # Disable Windows Copilot
    Set-WFReg -Path "HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot" -Name "TurnOffWindowsCopilot" -Value 1 -Type DWord -Desc "Disable Windows Copilot assistant" -Category "Debloat"
    Set-WFReg -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot" -Name "TurnOffWindowsCopilot" -Value 1 -Type DWord -Desc "Policy: Disable Windows Copilot system-wide" -Category "Debloat"

    # Disable Taskbar Widgets & Feeds
    Set-WFReg -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "TaskbarDa" -Value 0 -Type DWord -Desc "Hide Taskbar Widgets icon" -Category "System UI" -Only11
    Set-WFReg -Path "HKLM:\SOFTWARE\Policies\Microsoft\Dsh" -Name "AllowNewsAndInterests" -Value 0 -Type DWord -Desc "Disable News and Interests widget engine" -Category "Debloat"

    # Disable Edge Prelaunch & Background Extensions
    Set-WFReg -Path "HKLM:\SOFTWARE\Policies\Microsoft\MicrosoftEdge\Main" -Name "AllowPrelaunch" -Value 0 -Type DWord -Desc "Disable Edge startup prelaunch" -Category "Debloat"
    Set-WFReg -Path "HKLM:\SOFTWARE\Policies\Microsoft\MicrosoftEdge\TabPreload" -Name "AllowTabPreloading" -Value 0 -Type DWord -Desc "Disable Edge tab preloading" -Category "Debloat"
    Set-WFReg -Path "HKLM:\SOFTWARE\Policies\Microsoft\Edge" -Name "BackgroundModeEnabled" -Value 0 -Type DWord -Desc "Disable Edge running background apps when closed" -Category "Debloat"

    # Disable Windows Recall (AI Screen Snapshot telemetry if present)
    Set-WFReg -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI" -Name "DisableAIDataAnalysis" -Value 1 -Type DWord -Desc "Disable Windows Recall & AI screenshot telemetry" -Category "Privacy"

    # Disable Consumer Cloud Content & Promoted Apps
    Set-WFReg -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" -Name "ContentDeliveryAllowed" -Value 0 -Type DWord -Desc "Disable Content Delivery Manager ads" -Category "Debloat"
    Set-WFReg -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" -Name "OemPreInstalledAppsEnabled" -Value 0 -Type DWord -Desc "Stop silent installation of OEM bloatware" -Category "Debloat"
    Set-WFReg -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" -Name "PreInstalledAppsEnabled" -Value 0 -Type DWord -Desc "Stop silent pre-installed Microsoft store apps" -Category "Debloat"
    Set-WFReg -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" -Name "PreInstalledAppsEverEnabled" -Value 0 -Type DWord -Desc "Disable pre-installed apps toggle" -Category "Debloat"
    Set-WFReg -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" -Name "SilentInstalledAppsEnabled" -Value 0 -Type DWord -Desc "Block silent background app installs" -Category "Debloat"
    Set-WFReg -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" -Name "SubscribedContent-338388Enabled" -Value 0 -Type DWord -Desc "Disable Start menu tips & tricks" -Category "Debloat"
    Set-WFReg -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" -Name "SubscribedContent-338389Enabled" -Value 0 -Type DWord -Desc "Disable Start suggestions" -Category "Debloat"
    Set-WFReg -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" -Name "SystemPaneSuggestionsEnabled" -Value 0 -Type DWord -Desc "Disable Settings app suggested content" -Category "Debloat"

    # Extreme Services Disabling
    Write-WFPhase "Nuclear Debloat: Disabling Background Bloat Services"
    $deepServices = @(
        @{ Name = "RetailDemo"; Desc = "Retail Demo Service" },
        @{ Name = "MapsBroker"; Desc = "Downloaded Maps Manager" },
        @{ Name = "PhoneSvc"; Desc = "Phone Service (Your Phone sync)" },
        @{ Name = "lfsvc"; Desc = "Geolocation Service" },
        @{ Name = "RemoteRegistry"; Desc = "Remote Registry Service" }
    )
    # SharedAccess is kept: disabling it breaks the Mobile Hotspot feature.
    # Sensor services drive auto-rotation and adaptive brightness, so they are only disabled on desktops.
    if (-not $script:IsLaptop) {
        $deepServices += @{ Name = "SensorService"; Desc = "Sensor Service" }
        $deepServices += @{ Name = "SensrSvc"; Desc = "Sensor Monitoring Service" }
    }
    foreach ($s in $deepServices) {
        Disable-WFService -Name $s.Name -Desc $s.Desc -Category "Services (Debloat)"
    }

    # Nuclear AppX Purge
    Write-WFPhase "Nuclear Debloat: Complete AppX Bloatware Purge"
    $nuclearApps = @(
        "Microsoft.549981C3F5F10", # Cortana
        "Microsoft.BingWeather",
        "Microsoft.GetHelp",
        "Microsoft.Getstarted",
        "Microsoft.MicrosoftOfficeHub",
        "Microsoft.Microsoft3DViewer",
        "Microsoft.MSPaint",
        "Microsoft.People",
        "Microsoft.WindowsFeedbackHub",
        "Microsoft.WindowsMaps",
        "Microsoft.YourPhone",
        "Microsoft.ZuneMusic",
        "Microsoft.ZuneVideo",
        "Microsoft.PowerAutomateDesktop",
        "MicrosoftTeams",
        "Clipchamp.Clipchamp",
        "SpotifyAB.SpotifyMusic",
        "Disney.37853FC22B2CE",
        "ByteDance.TikTok",
        "Facebook.InstagramBeta"
    )
    foreach ($app in $nuclearApps) {
        Remove-WFAppx -Pattern $app -Desc "Deep bloatware app" -Category "Apps (Nuclear)"
    }

    # Deep Cleanup
    Invoke-ProfileDeepCleanup
}

function Get-WFUndoSource {
    # Finds the newest real run (not a DRY RUN, not an UNDO run) that recorded undo data.
    # A run that was interrupted only has a journal file - that is used as well.
    $dirs = @((Get-WFStateDir), [Environment]::GetFolderPath('Desktop'))
    if ($ReportDir) { $dirs += $ReportDir }
    $cands = @()
    foreach ($d in ($dirs | Where-Object { $_ } | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $d)) { continue }
        $cands += @(Get-ChildItem -LiteralPath $d -File -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -like 'run-*.json' -or $_.Name -like 'run-*.journal.jsonl' -or $_.Name -like 'WinFlexOS_Optimization_Report_*.json'
        })
    }
    foreach ($f in ($cands | Sort-Object LastWriteTime -Descending)) {
        try {
            if ($f.Name -like '*.journal.jsonl') {
                $acts = @(Get-Content -LiteralPath $f.FullName -Encoding UTF8 -ErrorAction Stop | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
                if ($acts.Count -eq 0) { continue }
                $stamp = $f.Name -replace '^run-', '' -replace '\.journal\.jsonl$', ''
                return @{ File = $f.FullName; Date = $f.LastWriteTime.ToString('yyyy-MM-dd HH:mm'); Actions = $acts; RunStamp = $stamp; Interrupted = $true }
            }
            $st = [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
            if ($st.DryRun -or $st.IsUndo) { continue }
            if (@($st.Profiles) -match 'UNDO') { continue }   # state files written by v6.0
            $acts = @($st.Actions | Where-Object { $_.Undo })
            if ($acts.Count -eq 0) { continue }
            return @{ File = $f.FullName; Date = $st.Date; Actions = $acts; RunStamp = $st.RunStamp; Interrupted = $false }
        } catch { continue }
    }
    return $null
}

function Complete-WFUndoSource {
    # Marks the restored run as done so the next UNDO does not apply it again.
    param($Src)
    $files = @($Src.File)
    if ($Src.RunStamp) {
        $dirs = @((Get-WFStateDir), [Environment]::GetFolderPath('Desktop'))
        if ($ReportDir) { $dirs += $ReportDir }
        foreach ($d in $dirs) {
            if (-not $d) { continue }
            foreach ($n in @("run-$($Src.RunStamp).json", "run-$($Src.RunStamp).journal.jsonl", "WinFlexOS_Optimization_Report_$($Src.RunStamp).json")) {
                $p = Join-Path $d $n
                if (Test-Path -LiteralPath $p) { $files += $p }
            }
        }
    }
    foreach ($p in ($files | Select-Object -Unique)) {
        if ($script:WF.DryRun) { continue }
        try { Rename-Item -LiteralPath $p -NewName ((Split-Path -Leaf $p) + '.undone') -Force -ErrorAction Stop } catch {}
    }
}

function ConvertFrom-WFJsonRegValue {
    # JSON turns byte[] / string[] into plain arrays - convert back to the real registry type.
    param($Value, [string]$Type)
    if ($null -eq $Value) { return $null }
    switch ($Type) {
        # The leading comma stops PowerShell from unrolling the array into Object[].
        'Binary'      { return , ([byte[]]@($Value)) }
        'MultiString' { return , ([string[]]@($Value)) }
        'DWord'       { $n = [int64]$Value; if ($n -gt [int32]::MaxValue) { $n -= 4294967296 }; return [int32]$n }
        'QWord'       { return [int64]$Value }
        default       { return [string]$Value }
    }
}

function Remove-WFHostsEntry {
    param([string]$Domain)
    $hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    $rx = '^\s*(0\.0\.0\.0|127\.0\.0\.1)\s+' + [regex]::Escape($Domain) + '\s*$'
    try {
        $all = [System.IO.File]::ReadAllLines($hostsPath)
        $keep = @($all | Where-Object { $_ -notmatch $rx })
        if ($keep.Count -eq $all.Count) {
            Add-WFAction -Category 'UNDO' -Type 'Hosts' -Target $Domain -Action 'Unblock domain in hosts file' -Status Already -Detail 'Domain is not blocked.' | Out-Null
            return
        }
        if ($script:WF.DryRun) { Add-WFAction -Category 'UNDO' -Type 'Hosts' -Target $Domain -Action 'Unblock domain in hosts file' -Before 'Blocked' -After 'Resolves normally' -Status Changed | Out-Null; return }
        [System.IO.File]::WriteAllLines($hostsPath, [string[]]$keep)
        Add-WFAction -Category 'UNDO' -Type 'Hosts' -Target $Domain -Action 'Unblock domain in hosts file' -Before 'Blocked' -After 'Resolves normally' -Status Changed | Out-Null
    } catch {
        Add-WFAction -Category 'UNDO' -Type 'Hosts' -Target $Domain -Action 'Unblock domain in hosts file' -Status Failed -Detail $_.Exception.Message | Out-Null
    }
}

function Restore-WFService {
    param([string]$Name, [string]$Mode, [bool]$WasRunning)
    $actionTxt = "Restore startup type to $Mode"
    if (-not (Get-Service -Name $Name -ErrorAction SilentlyContinue)) {
        Add-WFAction -Category 'UNDO' -Type 'Service' -Target $Name -Action $actionTxt -Status NotFound | Out-Null
        return
    }
    $cur = (Get-WFServiceStartMode $Name).Mode
    if ($cur -and $cur -ne 'Disabled') {
        Add-WFAction -Category 'UNDO' -Type 'Service' -Target $Name -Action $actionTxt -Before $cur -After $cur -Status Already -Detail 'Service is not disabled.' | Out-Null
        return
    }
    if ($script:WF.DryRun) { Add-WFAction -Category 'UNDO' -Type 'Service' -Target $Name -Action $actionTxt -Before 'Disabled' -After $Mode -Status Changed | Out-Null; return }
    $scMode = switch ($Mode) { 'Automatic (Delayed)' { 'delayed-auto' } 'Automatic' { 'auto' } 'Boot' { 'boot' } 'System' { 'system' } default { 'demand' } }
    $r = Invoke-WFNative 'sc.exe' @('config', $Name, 'start=', $scMode)
    $now = (Get-WFServiceStartMode $Name).Mode
    if ($now -eq 'Disabled' -or $null -eq $now) {
        Add-WFAction -Category 'UNDO' -Type 'Service' -Target $Name -Action $actionTxt -Before 'Disabled' -After (Format-WFVal $now) -Status Failed -Detail $r.Output | Out-Null
        return
    }
    $det = ''
    if ($WasRunning) {
        try { Start-Service -Name $Name -ErrorAction Stop } catch { $det = "Startup type restored, but the service could not be started now: $($_.Exception.Message)" }
    }
    Add-WFAction -Category 'UNDO' -Type 'Service' -Target $Name -Action $actionTxt -Before 'Disabled' -After $now -Status Changed -Detail $det | Out-Null
}

function Invoke-WFUndoRecord {
    param($u)
    switch ($u.Kind) {
        'Registry' {
            if ($u.Existed) {
                $val = ConvertFrom-WFJsonRegValue $u.Value $u.Type
                Set-WFReg -Path $u.Path -Name $u.Name -Value $val -Type $u.Type -Desc 'Restore previous registry value' -Category 'UNDO'
            } else {
                Remove-WFRegValue -Path $u.Path -Name $u.Name -Desc 'Remove value that did not exist before' -Category 'UNDO'
                if ($u.KeyCreated -and -not $script:WF.DryRun -and (Test-Path -LiteralPath $u.Path)) {
                    # Remove the key this script created, but only if nothing else lives in it.
                    $k = Get-Item -LiteralPath $u.Path -ErrorAction SilentlyContinue
                    if ($k -and $k.ValueCount -eq 0 -and $k.SubKeyCount -eq 0) { Remove-Item -LiteralPath $u.Path -Force -ErrorAction SilentlyContinue }
                }
            }
        }
        'Service' { Restore-WFService -Name $u.Name -Mode $u.Mode -WasRunning ([bool]$u.WasRunning) }
        'Task' {
            $target = $u.Path + $u.Name
            if ($script:WF.DryRun) { Add-WFAction -Category 'UNDO' -Type 'Task' -Target $target -Action 'Re-enable scheduled task' -Before 'Disabled' -After 'Ready' -Status Changed | Out-Null; return }
            try {
                Enable-ScheduledTask -TaskPath $u.Path -TaskName $u.Name -ErrorAction Stop | Out-Null
                Add-WFAction -Category 'UNDO' -Type 'Task' -Target $target -Action 'Re-enable scheduled task' -Before 'Disabled' -After 'Ready' -Status Changed | Out-Null
            } catch { Add-WFAction -Category 'UNDO' -Type 'Task' -Target $target -Action 'Re-enable scheduled task' -Status Failed -Detail $_.Exception.Message | Out-Null }
        }
        'Hosts' { Remove-WFHostsEntry -Domain $u.Domain }
        'Power' { if ($u.Guid) { Set-WFPowerPlan -Guid $u.Guid -Name 'Previous power plan' -Category 'UNDO' | Out-Null } }
        'PowerSetting' { Set-WFPowerSetting -Sub $u.Sub -Setting $u.Setting -AC $u.AC -DC $u.DC -Label "$($u.Sub) / $($u.Setting)" -Category 'UNDO' }
        'Bcd' {
            if ($u.Existed) { Set-WFBcd -Name $u.Name -Value $u.Value -Category 'UNDO' }
            else { Remove-WFBcd -Name $u.Name -Category 'UNDO' }
        }
        'Tcp' { if ($u.Value) { Set-WFNetshTcp -Setting $u.Setting -Value $u.Value -Category 'UNDO' } }
        'Env' {
            $target = "ENV (User)  $($u.Name)"
            if ($script:WF.DryRun) { Add-WFAction -Category 'UNDO' -Type 'Registry' -Target $target -Action 'Restore environment variable' -After (Format-WFVal $u.Value) -Status Changed | Out-Null; return }
            try {
                [Environment]::SetEnvironmentVariable($u.Name, $(if ($u.Existed) { [string]$u.Value } else { $null }), 'User')
                Add-WFAction -Category 'UNDO' -Type 'Registry' -Target $target -Action 'Restore environment variable' -After (Format-WFVal $u.Value) -Status Changed | Out-Null
            } catch { Add-WFAction -Category 'UNDO' -Type 'Registry' -Target $target -Action 'Restore environment variable' -Status Failed -Detail $_.Exception.Message | Out-Null }
        }
        'Feature' {
            if ($script:WF.DryRun) { Add-WFAction -Category 'UNDO' -Type 'Feature' -Target $u.Name -Action 'Turn Windows feature back on' -Before 'Disabled' -After 'Enabled' -Status Changed | Out-Null; return }
            try {
                $r = Enable-WindowsOptionalFeature -Online -FeatureName $u.Name -NoRestart -ErrorAction Stop
                if ($r.RestartNeeded) { $script:WF.RebootNeeded = $true }
                Add-WFAction -Category 'UNDO' -Type 'Feature' -Target $u.Name -Action 'Turn Windows feature back on' -Before 'Disabled' -After 'Enabled' -Status Changed | Out-Null
            } catch { Add-WFAction -Category 'UNDO' -Type 'Feature' -Target $u.Name -Action 'Turn Windows feature back on' -Status Failed -Detail $_.Exception.Message | Out-Null }
        }
        'Capability' {
            if ($script:WF.DryRun) { Add-WFAction -Category 'UNDO' -Type 'Feature' -Target $u.Name -Action 'Reinstall Windows capability' -Before 'Removed' -After 'Installed' -Status Changed | Out-Null; return }
            try {
                $r = Add-WindowsCapability -Online -Name $u.Name -ErrorAction Stop
                if ($r.RestartNeeded) { $script:WF.RebootNeeded = $true }
                Add-WFAction -Category 'UNDO' -Type 'Feature' -Target $u.Name -Action 'Reinstall Windows capability' -Before 'Removed' -After 'Installed' -Status Changed | Out-Null
            } catch { Add-WFAction -Category 'UNDO' -Type 'Feature' -Target $u.Name -Action 'Reinstall Windows capability' -Status Failed -Detail $_.Exception.Message | Out-Null }
        }
        default { Add-WFAction -Category 'UNDO' -Type 'System' -Target ([string]$u.Kind) -Action 'Unknown undo record' -Status Skipped | Out-Null }
    }
}

function Invoke-ProfileUndo {
    [void]$script:WF.ProfileNames.Add("UNDO (Restore System State)")
    $script:WF.IsUndo = $true
    Write-WFBanner "Phase: Reverting Changes from Saved State / Windows Defaults" 'Yellow'

    $src = Get-WFUndoSource
    if ($src) {
        Write-WFRaw "[+] Restoring from: $($src.File)" 'Green'
        if ($src.Interrupted) { Write-WFNote "That run was interrupted - restoring from its live journal." 'Yellow' }
        Write-WFPhase "Restoring $($src.Actions.Count) items from the run recorded on $($src.Date)"
        # Newest change first, so a value changed twice in one run returns to its original state.
        $acts = @($src.Actions)
        [array]::Reverse($acts)
        foreach ($act in $acts) {
            if ($act.Undo) { Invoke-WFUndoRecord $act.Undo }
        }
        Add-WFAction -Category 'UNDO' -Type 'App' -Target 'Removed apps' -Action 'Apps removed by the script are not reinstalled automatically' -Status Info -Detail 'Reinstall them from the Microsoft Store or with winget if you need them.' | Out-Null
        Complete-WFUndoSource $src
        return
    }

    Write-WFNote "No saved state file was found. Falling back to generic Windows defaults." 'Yellow'

    # Fallback generic undo
    Write-WFPhase "Generic UNDO: Restoring Windows defaults"
    foreach ($svc in @("DiagTrack", "dmwappushservice", "WerSvc", "SysMain")) {
        $mode = if ($svc -in @('DiagTrack', 'SysMain')) { 'Automatic' } else { 'Manual' }
        if ((Get-WFServiceStartMode $svc).Mode -eq 'Disabled') { Restore-WFService -Name $svc -Mode $mode -WasRunning ($mode -eq 'Automatic') }
    }

    Remove-WFRegValue -Path "HKCU:\Software\Policies\Microsoft\Windows\Explorer" -Name "DisableSearchBoxSuggestions" -Category "UNDO"
    Remove-WFRegValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization" -Name "DODownloadMode" -Category "UNDO"

    Set-WFReg -Path "HKCU:\Software\Microsoft\GameBar" -Name "AutoGameModeEnabled" -Value 1 -Type DWord -Category "UNDO"
    Set-WFReg -Path "HKCU:\System\GameConfigStore" -Name "GameDVR_Enabled" -Value 1 -Type DWord -Category "UNDO"
    Set-WFReg -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" -Name "NetworkThrottlingIndex" -Value 10 -Type DWord -Category "UNDO"
    Set-WFReg -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" -Name "SystemResponsiveness" -Value 20 -Type DWord -Category "UNDO"

    Set-WFNetshTcp -Setting "heuristics" -Value "disabled" -Category "UNDO"
    Set-WFNetshTcp -Setting "autotuninglevel" -Value "normal" -Category "UNDO"
    Remove-WFBcd -Name "disabledynamictick" -Category "UNDO"

    Set-WFReg -Path "HKCU:\Control Panel\Mouse" -Name "MouseSpeed" -Value "1" -Type String -Category "UNDO"
    Set-WFReg -Path "HKCU:\Control Panel\Mouse" -Name "MouseThreshold1" -Value "6" -Type String -Category "UNDO"
    Set-WFReg -Path "HKCU:\Control Panel\Mouse" -Name "MouseThreshold2" -Value "10" -Type String -Category "UNDO"

    Set-WFPowerPlan -Guid "381b4222-f694-41f0-9685-ff5bb260df2e" -Name "Balanced" -Category "UNDO" | Out-Null
}


# ==============================================================================
# 3. Interactive Menu & Pipeline Runner
# ==============================================================================

function Show-WFMenu {
    Write-WFBanner "Phase 2: Define Usage Profile (Customization & Debloat)" 'Magenta'
    Write-WFRaw "Select optimization profile (Enter a number 1-13 or comma-separated list like 1,8,12):`n" 'Cyan'

    Write-WFRaw " [1]  🎮 Gaming - Max performance, zero mouse accel, lower network latency."
    Write-WFRaw " [2]  🌐 Office & Browsing - Stability, power saving, bloatware removal."
    Write-WFRaw " [3]  🎬 Content Creation - Maximize stable resources for rendering/production."
    Write-WFRaw " [4]  🤖 AI & Machine Learning - Deep system scan, max RAM/VRAM utilization, Long Paths."
    Write-WFRaw " [5]  🕵️ Forensic Deep Scan - Full driver & folder analysis (~5-10 min)."
    Write-WFRaw " [6]  ⏪ UNDO - Restore system settings to recorded state or Windows defaults."
    Write-WFRaw " [7]  🧹 Ultimate Debloat - Standard telemetry and consumer bloat purge."
    Write-WFRaw " [8]  🛡️ Privacy Shield - Hosts block, telemetry levels, typing tracking block."
    Write-WFRaw " [9]  🔋 Laptop Battery Saver - Aggressive processor and display power savings."
    Write-WFRaw " [10] 🚀 Network Supercharger - TCP/IP stack tune, DNS cache flush, heuristics off."
    Write-WFRaw " [11] ☢️  Ultra-Deep Nuclear Debloat - Extreme stripping (Edge, Copilot, Widgets, background tasks)." 'Red'
    Write-WFRaw " [12] 🧼 Deep System Cleanup - Temp, Windows Update cache, crash dumps, SSD TRIM." 'Yellow'
    Write-WFRaw " [13] 🔒 Security Hardening - Disable WPAD, remote assistance, lock screen privacy." 'Green'

    Write-WFRaw ""
    $choice = ""
    while ($choice -notmatch '^([1-9]|1[0-3])(,\s*([1-9]|1[0-3]))*$') {
        $choice = Read-Host "Enter your choice (1-13)"
    }
    return $choice
}

function Start-WFOptimization {
    param(
        [string[]]$SelectedProfiles,
        [switch]$AsBackground
    )

    $SelectedProfiles = @($SelectedProfiles | ForEach-Object { "$_".Trim() } | Where-Object { $_ })

    if ($AsBackground -and -not $Worker) {
        if (-not $PSCommandPath) {
            # Started through 'irm | iex': there is no file a hidden worker could run.
            Write-WFRaw "`n[!] Background mode needs the script saved as a file - running in this window instead." 'Yellow'
        } else {
            Write-WFRaw "`n[*] Spawning Ultra-Deep Background Worker Process..." 'Cyan'
            Write-WFRaw "    The optimization will run in the background at low priority." 'Yellow'
            Write-WFRaw "    A rich HTML report will open as soon as it finishes." 'Green'

            $profArg = $SelectedProfiles -join ','
            $workerArgs = @(
                "-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden",
                "-File", "`"$PSCommandPath`"",
                "-ProfileId", "`"$profArg`"",
                "-Worker", "-Silent", "-NoPause", "-OpenReport"
            )
            if ($DryRun) { $workerArgs += "-DryRun" }
            if ($ReportDir) { $workerArgs += @("-ReportDir", "`"$ReportDir`"") }

            try {
                Start-Process -FilePath "powershell.exe" -ArgumentList $workerArgs -WindowStyle Hidden -ErrorAction Stop
                Write-WFRaw "[OK] Background process started! You may continue using your PC." 'Green'
                Write-WFRaw "     Live log: $(Join-Path $env:ProgramData 'WinFlexOS\Logs')" 'DarkGray'
                return
            } catch {
                Write-WFRaw "[!] Could not start the background worker ($($_.Exception.Message)) - running in this window instead." 'Yellow'
            }
        }
    }

    if ($Worker) {
        try { (Get-Process -Id $PID).PriorityClass = [System.Diagnostics.ProcessPriorityClass]::BelowNormal } catch {}
    }

    Open-WFLog
    $script:WF.SnapBefore = Get-WFSnapshot

    $isUndoOnly = ($SelectedProfiles | Where-Object { $_ -ne '6' }).Count -eq 0
    $modifies = @($SelectedProfiles | Where-Object { $_ -ne '5' }).Count -gt 0

    # Journal of undoable changes, written while the run is in progress (not for UNDO itself).
    if (-not $DryRun -and -not $isUndoOnly) {
        $script:WF.JournalPath = Join-Path (Get-WFStateDir) ("run-{0}.journal.jsonl" -f $script:WF.RunStamp)
    }

    $conflicts = @(@('1', '2', '3', '4') | Where-Object { $SelectedProfiles -contains $_ })
    if ($conflicts.Count -gt 1) {
        Write-WFRaw "[!] Profiles $($conflicts -join ', ') set conflicting values (Game Mode, power plan, SystemResponsiveness). The last one selected wins." 'Yellow'
    }

    try {
        # Safety restore point before anything that modifies the system (including UNDO).
        if ($modifies) {
            $ok = Invoke-WFRestorePoint -Label "WinFlexOS-Optimizer"
            if (-not $ok) {
                Write-WFRaw "[!] A System Restore Point could NOT be created." 'Red'
                if (-not $Silent -and -not $Worker) {
                    $ans = Read-Host "Continue WITHOUT a restore point? (Y/N) [Default: N]"
                    if ($ans -notmatch '^(y|Y)') {
                        Add-WFAction -Category 'Safety' -Type 'System' -Target 'Run' -Action 'Cancelled by the user (no restore point)' -Status Skipped | Out-Null
                        return
                    }
                } else {
                    Write-WFRaw "    Continuing (silent mode). Changes can still be undone with profile 6." 'Yellow'
                }
            }
        }

        foreach ($p in $SelectedProfiles) {
            switch ($p) {
                "1"  { Invoke-BaseDebloat; Invoke-ProfileGaming }
                "2"  { Invoke-BaseDebloat; Invoke-ProfileOffice }
                "3"  { Invoke-BaseDebloat; Invoke-ProfileCreator }
                "4"  { Invoke-BaseDebloat; Invoke-ProfileAI }
                "5"  { Invoke-ForensicDeepScan }
                "6"  { Invoke-ProfileUndo }
                "7"  { Invoke-BaseDebloat }
                "8"  { Invoke-ProfilePrivacyShield }
                "9"  { Invoke-ProfileBatterySaver }
                "10" { Invoke-ProfileNetworkSupercharger }
                "11" { Invoke-ProfileNuclearDebloat }
                "12" { Invoke-ProfileDeepCleanup }
                "13" { Invoke-ProfileSecurityHardening }
                default { Write-WFRaw "[!] Unknown profile '$p' - skipped." 'Yellow' }
            }
        }
    } catch {
        Write-WFRaw "[X] Run stopped by an error: $($_.Exception.Message)" 'Red'
        Add-WFAction -Category 'Run' -Type 'System' -Target 'Script' -Action 'Run stopped by an unexpected error' -Status Failed -Detail $_.Exception.Message | Out-Null
    } finally {
        # Runs even on Ctrl+C or an error, so the report and the UNDO state file are always written.
        Close-WFPhase
        $script:WF.SnapAfter = Get-WFSnapshot
        $reportFile = Export-WFHtmlReport -OutDir $ReportDir
        Close-WFLog
    }

    Write-WFBanner "Execution Completed!" 'Green'
    Write-WFRaw "A detailed interactive HTML report with exact details of every modified component," 'Green'
    Write-WFRaw "disabled service, and removed package was saved to:" 'Green'
    Write-WFRaw "  $reportFile`n" 'Cyan'

    if ($script:WF.RebootNeeded -and -not $DryRun) {
        Write-WFRaw "[!] A system restart is recommended to complete all requested changes." 'Yellow'
    }
}

# ==============================================================================
# Main Entry Point
# ==============================================================================
if (-not $LibraryOnly) {
    if (-not $Worker) { Clear-Host }
    Write-WFRaw "`n   ============================================================   " 'Cyan'
    Write-WFRaw "   [ WinFlexOS Smart Hardware Optimization & Privacy Suite v$($script:WFVersion) ]   " 'Green'
    Write-WFRaw "   ============================================================`n" 'Cyan'

    if ($DryRun -and -not $isAdmin) {
        Write-WFRaw "[!] DRY RUN without Administrator rights: apps, features and some services cannot be read," 'Yellow'
        Write-WFRaw "    so the report may list them as 'Not present'. Run as Administrator for an accurate preview." 'Yellow'
    }

    Get-SystemHardwareAudit

    $chosen = $ProfileId
    if (-not $chosen) {
        if ($Silent) {
            Write-WFRaw "[X] -Silent needs -ProfileId (for example: -ProfileId 7)." 'Red'
            exit 1
        }
        $chosen = Show-WFMenu
    }

    $profilesToRun = @($chosen -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    $bad = @($profilesToRun | Where-Object { $_ -notmatch '^([1-9]|1[0-3])$' })
    if ($bad.Count -gt 0) {
        Write-WFRaw "[X] Unknown profile number(s): $($bad -join ', '). Valid values are 1-13." 'Red'
        exit 1
    }

    # If option 11 (Nuclear Debloat) was picked or user passed -Background, offer or run background mode
    $runBg = $false
    if ($Background) {
        $runBg = $true
    } elseif ($profilesToRun -contains "11" -and -not $Silent -and $PSCommandPath) {
        $bgChoice = Read-Host "`nRun Ultra-Deep Nuclear Debloat in the background? (Y/N) [Default: Y]"
        if ($bgChoice -ne 'N' -and $bgChoice -ne 'n') {
            $runBg = $true
        }
    }

    Start-WFOptimization -SelectedProfiles $profilesToRun -AsBackground:$runBg

    if (-not $NoPause -and -not $Worker) {
        Pause
    }
}
