<#
WinFlexSetupModern - Windows setup, apps & optimization (single file)
Compatibility: Windows 10 / Windows 11, Windows PowerShell 5.1

Run (as Administrator):
  irm https://raw.githubusercontent.com/dor2500/WinFlexSetupModern/master/WinFlexSetupModern.ps1 | iex

Modes:
  .\WinFlexSetupModern.ps1                          # GUI (apps, tweaks, profiles)
  .\WinFlexSetupModern.ps1 -Console                 # console engine with the profile menu
  .\WinFlexSetupModern.ps1 -ProfileId 1,8,12        # run profiles directly (Gaming + Privacy Shield + Deep Cleanup)
  .\WinFlexSetupModern.ps1 -ProfileId 7 -DryRun     # simulate: changes nothing, still writes the HTML report
  . .\WinFlexSetupModern.ps1 -LibraryOnly           # load the engine functions only

The file is plain ASCII on purpose: 'irm | iex' keeps a UTF-8 BOM as a stray character
(which breaks the first line), and Windows PowerShell 5.1 misreads UTF-8 without a BOM.
Hebrew text is therefore built from character codes / HTML entities.
#>
[CmdletBinding()]
param(
    # --- GUI ---
    [switch]$SkipWelcome,         # skip the welcome screen
    [string]$MenuPath,            # optional external menu file instead of the built-in menu
    # --- Console engine (any of these runs the engine instead of the GUI) ---
    [string]$ProfileId = '',      # "1".."13" or a comma separated list, e.g. "1,8,12"
    [switch]$Console,             # open the console profile menu
    [switch]$Silent,              # no prompts
    [switch]$NoPause,             # do not wait for a key at the end
    [switch]$DryRun,              # simulate everything, change nothing
    [switch]$Background,          # run the selected profile(s) in a hidden low-priority process
    [switch]$Worker,              # internal: this process IS the hidden background worker
    [switch]$OpenReport,          # open the HTML report when finished
    [switch]$LibraryOnly,         # only define the engine functions (dot-source)
    [string]$ReportDir = ''       # where to save the HTML report (default: Desktop)
)

$script:WFEngineMode = [bool]($ProfileId -or $Console -or $Silent -or $DryRun -or $Background -or $Worker -or $LibraryOnly)

if ($script:WFEngineMode) {
# ##############################################################################
#  CONSOLE ENGINE  (profiles, restore point, HTML report, UNDO)
# ##############################################################################
$script:WFVersion = '6.2'
$script:RawBase   = 'https://raw.githubusercontent.com/dor2500/WinFlexSetupModern/master'

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
            $remoteCmd = "& ([scriptblock]::Create((irm '$($script:RawBase)/WinFlexSetupModern.ps1'))) $($fwd -join ' ')"
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
    $rebootNote = if ($script:WF.RebootNeeded -and -not $script:WF.DryRun) { '<div class="notice">&#x26A0; &#x5DE;&#x5D5;&#x5DE;&#x5DC;&#x5E5; &#x5DC;&#x5D4;&#x5E4;&#x5E2;&#x5D9;&#x5DC; &#x5DE;&#x5D7;&#x5D3;&#x5E9; &#x5D0;&#x5EA; &#x5D4;&#x5DE;&#x5D7;&#x5E9;&#x5D1; &#x5DB;&#x5D3;&#x5D9; &#x5DC;&#x5D4;&#x5E9;&#x5DC;&#x5D9;&#x5DD; &#x5D7;&#x5DC;&#x5E7; &#x5DE;&#x5D4;&#x5E9;&#x5D9;&#x5E0;&#x5D5;&#x5D9;&#x5D9;&#x5DD;.</div>' } else { '' }
    $dryNote = if ($script:WF.DryRun) { '<div class="notice">&#x5D4;&#x5E8;&#x5E6;&#x5EA; &#x5E0;&#x5D9;&#x5E1;&#x5D9;&#x5D5;&#x5DF; - &#x5DC;&#x5D0; &#x5E9;&#x5D5;&#x5E0;&#x5D4; &#x5D3;&#x5D1;&#x5E8; &#x5D1;&#x5DE;&#x5D7;&#x5E9;&#x5D1;. &#x5D4;&#x5D3;&#x5D5;&#x5D7; &#x5DE;&#x5E6;&#x5D9;&#x5D2; &#x5DE;&#x5D4; &#x5D4;&#x5D9;&#x5D4; &#x5E7;&#x5D5;&#x5E8;&#x5D4;.' + $(if (-not $script:isAdmin) { ' (&#x5D4;&#x5D5;&#x5E8;&#x5E5; &#x5DC;&#x5DC;&#x5D0; &#x5D4;&#x5E8;&#x5E9;&#x5D0;&#x5D5;&#x5EA; &#x5DE;&#x5E0;&#x5D4;&#x5DC; - &#x5D7;&#x5DC;&#x5E7; &#x5DE;&#x5D4;&#x5E4;&#x5E8;&#x5D9;&#x5D8;&#x5D9;&#x5DD; &#x5E2;&#x5E9;&#x5D5;&#x5D9;&#x5D9;&#x5DD; &#x5DC;&#x5D4;&#x5D5;&#x5E4;&#x5D9;&#x5E2; &#x5DB;"&#x5DC;&#x5D0; &#x5E7;&#x5D9;&#x5D9;&#x5DD;" &#x5DC;&#x5DE;&#x5E8;&#x5D5;&#x5EA; &#x5E9;&#x5D4;&#x5DD; &#x5E7;&#x5D9;&#x5D9;&#x5DE;&#x5D9;&#x5DD;.)' } else { '' }) + '</div>' } else { '' }

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
                return sim ? '<span class="status-pill status-skipped">\u05D4\u05D9\u05D4 \u05DE\u05E9\u05EA\u05E0\u05D4</span>' : '<span class="status-pill status-changed">&#x2714; \u05E9\u05D5\u05E0\u05D4 \u05D1\u05D4\u05E6\u05DC\u05D7\u05D4</span>';
            }
            if (status === 'Already') return '<span class="status-pill status-already">&#x2713; \u05DB\u05D1\u05E8 \u05D4\u05D9\u05D4 \u05EA\u05E7\u05D9\u05DF</span>';
            if (status === 'NotFound') return '<span class="status-pill status-notfound">&#x2298; \u05DC\u05D0 \u05E7\u05D9\u05D9\u05DD</span>';
            if (status === 'Failed') return '<span class="status-pill status-failed">&#x2718; \u05E0\u05DB\u05E9\u05DC</span>';
            if (status === 'Skipped') return '<span class="status-pill status-skipped">&#x25B6; \u05D3\u05D5\u05DC\u05D2</span>';
            return '<span class="status-pill status-notfound">\u05DE\u05D9\u05D3\u05E2</span>';
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
                    const b = esc(a.before || '(\u05E8\u05D9\u05E7)'), af = esc(a.after || '(\u05E8\u05D9\u05E7)');
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
                `<tr><td colspan="7" style="text-align: center; padding: 40px; color: var(--text-muted);">\u05DC\u05D0 \u05E0\u05DE\u05E6\u05D0\u05D5 \u05E4\u05E8\u05D9\u05D8\u05D9\u05DD \u05D4\u05EA\u05D5\u05D0\u05DE\u05D9\u05DD \u05DC\u05E1\u05D9\u05E0\u05D5\u05DF \u05D0\u05D5 \u05D4\u05D7\u05D9\u05E4\u05D5\u05E9.</td></tr>`;
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
    <title>WinFlexOS - &#x5D3;&#x5D5;&#x5D7; &#x5D0;&#x5D5;&#x5E4;&#x5D8;&#x5D9;&#x5DE;&#x5D9;&#x5D6;&#x5E6;&#x5D9;&#x5D4; &#x5D5;&#x5E9;&#x5D9;&#x5E0;&#x5D5;&#x5D9;&#x5D9;&#x5DD; &#x5D1;&#x5DE;&#x5E2;&#x5E8;&#x5DB;&#x5EA;</title>
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
                    <h1 class="header-title">WinFlexOS - &#x5D3;&#x5D5;&#x5D7; &#x5E4;&#x5E2;&#x5D5;&#x5DC;&#x5D5;&#x5EA; &#x5D5;&#x5D0;&#x5D5;&#x5E4;&#x5D8;&#x5D9;&#x5DE;&#x5D9;&#x5D6;&#x5E6;&#x5D9;&#x5D4;</h1>
                    <p class="header-subtitle">&#x5E9;&#x5E7;&#x5D9;&#x5E4;&#x5D5;&#x5EA; &#x5DE;&#x5DC;&#x5D0;&#x5D4;: &#x5E4;&#x5D9;&#x5E8;&#x5D5;&#x5D8; &#x5DE;&#x5D5;&#x5D7;&#x5DC;&#x5D8; &#x5E9;&#x5DC; &#x5DB;&#x5DC; &#x5E9;&#x5D9;&#x5E0;&#x5D5;&#x5D9;, &#x5E9;&#x5D9;&#x5E8;&#x5D5;&#x5EA;, &#x5DE;&#x5E9;&#x5D9;&#x5DE;&#x5D4; &#x5D5;&#x5E8;&#x5D2;&#x5D9;&#x5E1;&#x5D8;&#x5E8;&#x5D9;</p>
                </div>
            </div>
            <div class="header-badges">
                $modeTag
                <span class="badge badge-meta">&#x5E4;&#x5E8;&#x5D5;&#x5E4;&#x5D9;&#x5DC;&#x5D9;&#x5DD;: $profList</span>
                <span class="badge badge-meta">&#x5DE;&#x5E9;&#x5DA; &#x5E8;&#x5D9;&#x5E6;&#x5D4;: ${dur} &#x5E9;&#x5E0;&#x5D9;&#x5D5;&#x5EA;</span>
                <span class="badge badge-meta">&#x5DE;&#x5D7;&#x5E9;&#x5D1;: $pcName</span>
            </div>
        </header>
        $dryNote
        $rebootNote

        <!-- STATS -->
        <div class="stats-grid">
            <div class="stat-card" style="--accent-bar: var(--green);">
                <div class="stat-label">&#x5E9;&#x5D9;&#x5E0;&#x5D5;&#x5D9;&#x5D9;&#x5DD; &#x5E9;&#x5D1;&#x5D5;&#x5E6;&#x5E2;&#x5D5; &#x5D1;&#x5E4;&#x5D5;&#x5E2;&#x5DC;</div>
                <div class="stat-value" style="color: var(--green);">$cntChanged</div>
                <div class="stat-sub">&#x5E2;&#x5E8;&#x5DB;&#x5D9;&#x5DD;, &#x5E9;&#x5D9;&#x5E8;&#x5D5;&#x5EA;&#x5D9;&#x5DD; &#x5D5;&#x5DE;&#x5E9;&#x5D9;&#x5DE;&#x5D5;&#x5EA; &#x5E9;&#x5D4;&#x5E9;&#x5EA;&#x5E0;&#x5D5;</div>
            </div>
            <div class="stat-card" style="--accent-bar: var(--cyan-neon);">
                <div class="stat-label">&#x5DB;&#x5D1;&#x5E8; &#x5D4;&#x5D9;&#x5D5; &#x5EA;&#x5E7;&#x5D9;&#x5E0;&#x5D9;&#x5DD;</div>
                <div class="stat-value" style="color: var(--cyan-neon);">$cntAlready</div>
                <div class="stat-sub">&#x5D4;&#x5D5;&#x5D2;&#x5D3;&#x5E8;&#x5D5; &#x5DB;&#x5D1;&#x5E8; &#x5D1;&#x5E2;&#x5D1;&#x5E8; &#x5D1;&#x5DE;&#x5E2;&#x5E8;&#x5DB;&#x5EA;</div>
            </div>
            <div class="stat-card" style="--accent-bar: var(--text-muted);">
                <div class="stat-label">&#x5DC;&#x5D0; &#x5E7;&#x5D9;&#x5D9;&#x5DE;&#x5D9;&#x5DD; &#x5D1;&#x5DE;&#x5D7;&#x5E9;&#x5D1;</div>
                <div class="stat-value" style="color: var(--text-muted);">$cntNotFound</div>
                <div class="stat-sub">&#x5E8;&#x5DB;&#x5D9;&#x5D1;&#x5D9;&#x5DD; / &#x5D0;&#x5E4;&#x5DC;&#x5D9;&#x5E7;&#x5E6;&#x5D9;&#x5D5;&#x5EA; &#x5E9;&#x5DC;&#x5D0; &#x5DE;&#x5D5;&#x5EA;&#x5E7;&#x5E0;&#x5D9;&#x5DD;</div>
            </div>
            <div class="stat-card" style="--accent-bar: var(--purple-neon);">
                <div class="stat-label">&#x5E9;&#x5D8;&#x5D7; &#x5D0;&#x5D7;&#x5E1;&#x5D5;&#x5DF; &#x5E9;&#x5E0;&#x5D5;&#x5E7;&#x5D4;</div>
                <div class="stat-value" style="color: var(--purple-neon);">$freedFormatted</div>
                <div class="stat-sub">&#x5E7;&#x5D1;&#x5E6;&#x5D9; &#x5D6;&#x5D1;&#x5DC;, &#x5E9;&#x5D0;&#x5E8;&#x5D9;&#x5D5;&#x5EA; &#x5D5;&#x5E7;&#x5D0;&#x5E9;</div>
            </div>
            <div class="stat-card" style="--accent-bar: var(--red);">
                <div class="stat-label">&#x5E0;&#x5DB;&#x5E9;&#x5DC;&#x5D5; / &#x5E0;&#x5D7;&#x5E1;&#x5DE;&#x5D5;</div>
                <div class="stat-value" style="color: $(if ($cntFailed -gt 0) { 'var(--red)' } else { 'var(--text-muted)' });">$cntFailed</div>
                <div class="stat-sub">&#x5E9;&#x5D2;&#x5D9;&#x5D0;&#x5D5;&#x5EA; &#x5D0;&#x5D5; &#x5D4;&#x5E8;&#x5E9;&#x5D0;&#x5D5;&#x5EA; &#x5DE;&#x5E2;&#x5E8;&#x5DB;&#x5EA;</div>
            </div>
        </div>

        <!-- HARDWARE & SNAPSHOT -->
        <div class="system-info-card">
            <div class="system-info-header">
                <div class="system-info-title">&#x1F4BB; &#x5E0;&#x5EA;&#x5D5;&#x5E0;&#x5D9; &#x5D7;&#x5D5;&#x5DE;&#x5E8;&#x5D4; &#x5D5;&#x5DE;&#x5E6;&#x5D1; &#x5DE;&#x5E2;&#x5E8;&#x5DB;&#x5EA; &#x5D1;&#x5E2;&#x5EA; &#x5D4;&#x5E8;&#x5D9;&#x5E6;&#x5D4;</div>
                <span style="font-size: 13px; color: var(--text-muted);">&#x5EA;&#x5D0;&#x5E8;&#x5D9;&#x5DA;: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</span>
            </div>
            <div class="info-grid">
                <div class="info-item">
                    <div class="info-item-label">&#x5DE;&#x5E2;&#x5E8;&#x5DB;&#x5EA; &#x5D4;&#x5E4;&#x5E2;&#x5DC;&#x5D4;</div>
                    <div class="info-item-val">$hwOS</div>
                </div>
                <div class="info-item">
                    <div class="info-item-label">&#x5DE;&#x5E2;&#x5D1;&#x5D3; (CPU)</div>
                    <div class="info-item-val">$hwCPU</div>
                </div>
                <div class="info-item">
                    <div class="info-item-label">&#x5D6;&#x5D9;&#x5DB;&#x5E8;&#x5D5;&#x5DF; &#x5E2;&#x5D1;&#x5D5;&#x5D3;&#x5D4; (RAM)</div>
                    <div class="info-item-val">$hwRAM</div>
                </div>
                <div class="info-item">
                    <div class="info-item-label">&#x5DB;&#x5E8;&#x5D8;&#x5D9;&#x5E1; &#x5D2;&#x5E8;&#x5E4;&#x5D9; (GPU)</div>
                    <div class="info-item-val">$hwGPU</div>
                </div>
                <div class="info-item">
                    <div class="info-item-label">&#x5EA;&#x5D4;&#x5DC;&#x5D9;&#x5DB;&#x5D9;&#x5DD; &#x5E4;&#x5E2;&#x5D9;&#x5DC;&#x5D9;&#x5DD;</div>
                    <div class="info-item-val">&#x5DC;&#x5E4;&#x5E0;&#x5D9;: $($script:WF.SnapBefore.Processes) | &#x5D0;&#x5D7;&#x5E8;&#x5D9;: $($script:WF.SnapAfter.Processes)</div>
                </div>
                <div class="info-item">
                    <div class="info-item-label">&#x5E9;&#x5D9;&#x5E8;&#x5D5;&#x5EA;&#x5D9;&#x5DD; &#x5E4;&#x5D5;&#x5E2;&#x5DC;&#x5D9;&#x5DD; &#x5D1;&#x5E8;&#x5E7;&#x5E2;</div>
                    <div class="info-item-val">&#x5DC;&#x5E4;&#x5E0;&#x5D9;: $($script:WF.SnapBefore.RunningServices) | &#x5D0;&#x5D7;&#x5E8;&#x5D9;: $($script:WF.SnapAfter.RunningServices)</div>
                </div>
            </div>
        </div>

        <!-- CONTROLS & FILTERS -->
        <div class="controls-bar">
            <div class="filter-buttons">
                <button class="filter-btn active" data-filter="ALL" onclick="setFilter('ALL')">&#x5D4;&#x5DB;&#x5DC; ($cntTotal)</button>
                <button class="filter-btn" data-filter="Changed" onclick="setFilter('Changed')">&#x5D1;&#x5D5;&#x5E6;&#x5E2; &#x5E9;&#x5D9;&#x5E0;&#x5D5;&#x5D9; ($cntChanged)</button>
                <button class="filter-btn" data-filter="Already" onclick="setFilter('Already')">&#x5DB;&#x5D1;&#x5E8; &#x5EA;&#x5E7;&#x5D9;&#x5DF; ($cntAlready)</button>
                <button class="filter-btn" data-filter="NotFound" onclick="setFilter('NotFound')">&#x5DC;&#x5D0; &#x5E7;&#x5D9;&#x5D9;&#x5DD; &#x5D1;&#x5DE;&#x5D7;&#x5E9;&#x5D1; ($cntNotFound)</button>
                <button class="filter-btn" data-filter="Failed" onclick="setFilter('Failed')">&#x5E0;&#x5DB;&#x5E9;&#x5DC; ($cntFailed)</button>
                <button class="filter-btn" data-filter="Skipped" onclick="setFilter('Skipped')">&#x5D3;&#x5D5;&#x5DC;&#x5D2; ($cntSkipped)</button>
                <button class="filter-btn" data-filter="Service" onclick="setFilter('Service')">&#x5E9;&#x5D9;&#x5E8;&#x5D5;&#x5EA;&#x5D9;&#x5DD; &#x5D1;&#x5DC;&#x5D1;&#x5D3;</button>
                <button class="filter-btn" data-filter="Registry" onclick="setFilter('Registry')">&#x5E8;&#x5D2;&#x5D9;&#x5E1;&#x5D8;&#x5E8;&#x5D9; &#x5D1;&#x5DC;&#x5D1;&#x5D3;</button>
                <button class="filter-btn" data-filter="Task" onclick="setFilter('Task')">&#x5DE;&#x5E9;&#x5D9;&#x5DE;&#x5D5;&#x5EA; &#x5DE;&#x5EA;&#x5D5;&#x5D6;&#x5DE;&#x5E0;&#x5D5;&#x5EA;</button>
                <button class="filter-btn" data-filter="App" onclick="setFilter('App')">&#x5D0;&#x5E4;&#x5DC;&#x5D9;&#x5E7;&#x5E6;&#x5D9;&#x5D5;&#x5EA; UWP</button>
            </div>
            <div class="search-box">
                <span class="search-icon">&#x1F50D;</span>
                <input type="text" id="searchInput" class="search-input" placeholder="&#x5D7;&#x5D9;&#x5E4;&#x5D5;&#x5E9; &#x5DC;&#x5E4;&#x5D9; &#x5E9;&#x5DD; &#x5E9;&#x5D9;&#x5E8;&#x5D5;&#x5EA;, &#x5DE;&#x5E4;&#x5EA;&#x5D7; &#x5E8;&#x5D2;&#x5D9;&#x5E1;&#x5D8;&#x5E8;&#x5D9;, &#x5E4;&#x5E2;&#x5D5;&#x5DC;&#x5D4;..." oninput="renderRows()">
            </div>
        </div>

        <!-- TABLE -->
        <div class="table-card">
            <div class="table-responsive">
                <table id="actionsTable">
                    <thead>
                        <tr>
                            <th style="width: 70px;">&#x5E9;&#x5E2;&#x5D4;</th>
                            <th style="width: 100px;">&#x5E1;&#x5D5;&#x5D2;</th>
                            <th style="width: 130px;">&#x5E1;&#x5D8;&#x5D8;&#x5D5;&#x5E1;</th>
                            <th>&#x5D9;&#x5E2;&#x5D3; / &#x5E8;&#x5DB;&#x5D9;&#x5D1; &#x5D1;&#x5DE;&#x5E2;&#x5E8;&#x5DB;&#x5EA;</th>
                            <th>&#x5E4;&#x5E2;&#x5D5;&#x5DC;&#x5D4; &#x5E9;&#x5D1;&#x5D5;&#x5E6;&#x5E2;&#x5D4;</th>
                            <th>&#x5E2;&#x5E8;&#x5DA; &#x5DC;&#x5E4;&#x5E0;&#x5D9; / &#x5D0;&#x5D7;&#x5E8;&#x5D9;</th>
                            <th>&#x5E4;&#x5E7;&#x5D5;&#x5D3;&#x5EA; &#x5E9;&#x5D7;&#x5D6;&#x5D5;&#x5E8; (Undo)</th>
                        </tr>
                    </thead>
                    <tbody id="tableBody">
                        <!-- Populated by JS -->
                    </tbody>
                </table>
            </div>
        </div>

        <footer class="footer">
            <p>&#x5E0;&#x5D5;&#x5E6;&#x5E8; &#x5E2;&#x5DC; &#x5D9;&#x5D3;&#x5D9; WinFlexOS Optimizer v$($script:WFVersion) &bull; &#x5E7;&#x5D5;&#x5D1;&#x5E5; &#x5E9;&#x5D7;&#x5D6;&#x5D5;&#x5E8; &#x5DE;&#x5E6;&#x5D1; &#x5E0;&#x5E9;&#x5DE;&#x5E8; &#x5DC;&#x5E6;&#x5D3; &#x5D3;&#x5D5;&#x5D7; &#x5D6;&#x5D4;: <code>$([System.IO.Path]::GetFileName($jsonPath))</code></p>
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
    Set-WFReg -Path "HKCU:\Control Panel\Desktop" -Name "WaitToKillAppTimeout" -Value "2000" -Type String -Desc "Close apps faster at shutdown (2s)" -Category "System UI"
    Set-WFReg -Path "HKCU:\Control Panel\Desktop" -Name "HungAppTimeout" -Value "1000" -Type String -Desc "Detect hung apps faster (1s)" -Category "System UI"
    Set-WFReg -Path "HKLM:\SYSTEM\CurrentControlSet\Control" -Name "WaitToKillServiceTimeout" -Value "2000" -Type String -Desc "Stop services faster at shutdown (2s)" -Category "System UI"

    # Receive Segment Coalescing off (lower latency at a small throughput cost)
    Set-WFNetshTcp -Setting "rsc" -Value "disabled" -Desc "Disable Receive Segment Coalescing" -Category "Network"

    # Budget PCs (<= 8 GB RAM or <= 4 cores): trim visual effects to free CPU/RAM for the game
    $cores = if ($script:cpu.NumberOfCores) { [int]$script:cpu.NumberOfCores } else { 4 }
    $ramGb = if ($script:totalRamGB) { [double]$script:totalRamGB } else { 8 }
    if ($ramGb -le 8 -or $cores -le 4) {
        Set-WFReg -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" -Name "VisualFXSetting" -Value 2 -Type DWord -Desc "Visual effects: best performance (budget PC detected)" -Category "System UI"
        Set-WFReg -Path "HKCU:\Control Panel\Desktop\WindowMetrics" -Name "MinAnimate" -Value "0" -Type String -Desc "Disable minimize/maximize animation (budget PC detected)" -Category "System UI"
    }

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
        @("AsusROGLSLService", "ASUSSoftwareManager", "ASUSLinkNear", "ASUSLinkRemote", "AsusAppService", "AsusCertService", "AsusPTPCenter") | ForEach-Object {
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

    Write-WFRaw " [1]   Gaming - Max performance, zero mouse accel, lower network latency."
    Write-WFRaw " [2]   Office & Browsing - Stability, power saving, bloatware removal."
    Write-WFRaw " [3]   Content Creation - Maximize stable resources for rendering/production."
    Write-WFRaw " [4]   AI & Machine Learning - Deep system scan, max RAM/VRAM utilization, Long Paths."
    Write-WFRaw " [5]   Forensic Deep Scan - Full driver & folder analysis (~5-10 min)."
    Write-WFRaw " [6]   UNDO - Restore system settings to recorded state or Windows defaults."
    Write-WFRaw " [7]   Ultimate Debloat - Standard telemetry and consumer bloat purge."
    Write-WFRaw " [8]   Privacy Shield - Hosts block, telemetry levels, typing tracking block."
    Write-WFRaw " [9]   Laptop Battery Saver - Aggressive processor and display power savings."
    Write-WFRaw " [10]  Network Supercharger - TCP/IP stack tune, DNS cache flush, heuristics off."
    Write-WFRaw " [11]   Ultra-Deep Nuclear Debloat - Extreme stripping (Edge, Copilot, Widgets, background tasks)." 'Red'
    Write-WFRaw " [12]  Deep System Cleanup - Temp, Windows Update cache, crash dumps, SSD TRIM." 'Yellow'
    Write-WFRaw " [13]  Security Hardening - Disable WPAD, remote assistance, lock screen privacy." 'Green'

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

} else {
# ##############################################################################
#  GUI
# ##############################################################################
function Initialize-WFMenuData {
    $script:Categories = @(
        [pscustomobject]@{
            TitleEn = "System Tweaks & AI"
            TitleHe = "$(-join [char[]]@(0x05D0,0x05D5,0x05E4,0x05D8,0x05D9,0x05DE,0x05D9,0x05D6,0x05E6,0x05D9,0x05D4)) $(-join [char[]]@(0x05D5,0x05E4,0x05D9,0x05EA,0x05D5,0x05D7))"
            Key = "tweaks"
            Icon = "$([char]0xE770)"
            Items = @(
                [pscustomobject]@{ Name = "Block Ads & App Suggestions"; TweakId = "NoConsumerContent"; IsTweak = $true }
                [pscustomobject]@{ Name = "Classic Right-Click Menu (Win11)"; TweakId = "ClassicContextMenu"; IsTweak = $true }
                [pscustomobject]@{ Name = "Clean Temp & Cache Files"; TweakId = "ClearTemp"; IsTweak = $true }
                [pscustomobject]@{ Name = "Clean Windows Update Cache"; TweakId = "CleanupWinUpdate"; IsTweak = $true }
                [pscustomobject]@{ Name = "Disable Windows Copilot"; TweakId = "DisableCopilot"; IsTweak = $true }
                [pscustomobject]@{ Name = "ASUS Armoury Crate & ROG Stutter Fix"; TweakId = "AsusGamingFix"; IsTweak = $true }
                [pscustomobject]@{ Name = "Reset Network (DNS & Winsock)"; TweakId = "NetworkReset"; IsTweak = $true }
                [pscustomobject]@{ Name = "Show Hidden Files & Extensions"; TweakId = "ShowHiddenFiles"; IsTweak = $true }
                [pscustomobject]@{ Name = "SSD Trim & Optimization"; TweakId = "SSDOptimize"; IsTweak = $true }
                [pscustomobject]@{ Name = "Windows Dark Mode"; TweakId = "DarkMode"; IsTweak = $true }
            )
        },
        [pscustomobject]@{
            TitleEn = "Browsers"
            TitleHe = "$(-join [char[]]@(0x05D3,0x05E4,0x05D3,0x05E4,0x05E0,0x05D9,0x05DD))"
            Key = "browsers"
            Icon = "$([char]0xE774)"
            Items = @(
                [pscustomobject]@{ Name = "Arc Browser"; WingetId = "TheBrowserCompany.Arc" }
                [pscustomobject]@{ Name = "Brave"; WingetId = "Brave.Brave" }
                [pscustomobject]@{ Name = "DuckDuckGo"; WingetId = "DuckDuckGo.Desktop" }
                [pscustomobject]@{ Name = "Floorp"; WingetId = "Ablaze.Floorp" }
                [pscustomobject]@{ Name = "Google Chrome"; WingetId = "Google.Chrome" }
                [pscustomobject]@{ Name = "LibreWolf"; WingetId = "LibreWolf.LibreWolf" }
                [pscustomobject]@{ Name = "Microsoft Edge"; WingetId = "Microsoft.Edge" }
                [pscustomobject]@{ Name = "Mozilla Firefox"; WingetId = "Mozilla.Firefox" }
                [pscustomobject]@{ Name = "Mullvad Browser"; WingetId = "MullvadVPN.MullvadBrowser" }
                [pscustomobject]@{ Name = "Opera GX"; WingetId = "Opera.OperaGX" }
                [pscustomobject]@{ Name = "Sidekick Browser"; WingetId = "Sidekick.Sidekick" }
                [pscustomobject]@{ Name = "Thorium Browser"; WingetId = "Alex313031.Thorium" }
                [pscustomobject]@{ Name = "Tor Browser"; WingetId = "TorProject.TorBrowser" }
                [pscustomobject]@{ Name = "Vivaldi"; WingetId = "VivaldiTechnologies.Vivaldi" }
                [pscustomobject]@{ Name = "Waterfox"; WingetId = "Waterfox.Waterfox" }
                [pscustomobject]@{ Name = "Yandex Browser"; WingetId = "Yandex.Yandex" }
                [pscustomobject]@{ Name = "Zen Browser"; WingetId = "Zen-Team.Zen-Browser" }
            )
        },
        [pscustomobject]@{
            TitleEn = "Media & Audio"
            TitleHe = "$(-join [char[]]@(0x05DE,0x05D3,0x05D9,0x05D4)) $(-join [char[]]@(0x05D5,0x05E1,0x05D0,0x05D5,0x05E0,0x05D3))"
            Key = "media"
            Icon = "$([char]0xE189)"
            Items = @(
                [pscustomobject]@{ Name = "AIMP"; WingetId = "AIMP.AIMP" }
                [pscustomobject]@{ Name = "Audacity"; WingetId = "Audacity.Audacity" }
                [pscustomobject]@{ Name = "CapCut"; WingetId = "Bytedance.CapCut" }
                [pscustomobject]@{ Name = "EarTrumpet"; WingetId = "FileTrekker.EarTrumpet" }
                [pscustomobject]@{ Name = "Foobar2000"; WingetId = "PeterPawlowski.foobar2000" }
                [pscustomobject]@{ Name = "GOM Player"; WingetId = "GOMLab.GOMPlayer" }
                [pscustomobject]@{ Name = "HandBrake"; WingetId = "HandBrake.HandBrake" }
                [pscustomobject]@{ Name = "iTunes"; WingetId = "Apple.iTunes" }
                [pscustomobject]@{ Name = "K-Lite Codec Pack (Mega)"; WingetId = "CodecGuide.K-LiteCodecPack.Mega" }
                [pscustomobject]@{ Name = "Kodi"; WingetId = "XBMCFoundation.Kodi" }
                [pscustomobject]@{ Name = "MediaMonkey"; WingetId = "Ventis.MediaMonkey" }
                [pscustomobject]@{ Name = "MPC-HC Player"; WingetId = "clsid2.mpc-hc" }
                [pscustomobject]@{ Name = "OBS Studio"; WingetId = "OBSProject.OBSStudio" }
                [pscustomobject]@{ Name = "Plex Media Server"; WingetId = "Plex.PlexMediaServer" }
                [pscustomobject]@{ Name = "Spotify"; WingetId = "Spotify.Spotify" }
                [pscustomobject]@{ Name = "Tenacity (Audacity Alt)"; WingetId = "tenacityteam.tenacity" }
                [pscustomobject]@{ Name = "VLC Media Player"; WingetId = "VideoLAN.VLC" }
                [pscustomobject]@{ Name = "Winamp"; WingetId = "Radionomy.Winamp" }
            )
        },
        [pscustomobject]@{
            TitleEn = "Design & Creativity"
            TitleHe = "$(-join [char[]]@(0x05E2,0x05D9,0x05E6,0x05D5,0x05D1)) $(-join [char[]]@(0x05D5,0x05D9,0x05E6,0x05D9,0x05E8,0x05D4))"
            Key = "design"
            Icon = "$([char]0xE115)"
            Items = @(
                [pscustomobject]@{ Name = "Blender"; WingetId = "BlenderFoundation.Blender" }
                [pscustomobject]@{ Name = "DaVinci Resolve"; WingetId = "BlackmagicDesign.DaVinciResolve" }
                [pscustomobject]@{ Name = "Figma"; WingetId = "Figma.Figma" }
                [pscustomobject]@{ Name = "GIMP"; WingetId = "GIMP.GIMP" }
                [pscustomobject]@{ Name = "Inkscape"; WingetId = "Inkscape.Inkscape" }
                [pscustomobject]@{ Name = "IrfanView"; WingetId = "IrfanSkiljan.IrfanView" }
                [pscustomobject]@{ Name = "Krita"; WingetId = "KDE.Krita" }
                [pscustomobject]@{ Name = "Paint.NET"; WingetId = "dotPDNLLC.paintdotnet" }
                [pscustomobject]@{ Name = "ShareX"; WingetId = "ShareX.ShareX" }
            )
        },
        [pscustomobject]@{
            TitleEn = "Gaming & Launchers"
            TitleHe = "$(-join [char[]]@(0x05D2,0x05D9,0x05D9,0x05DE,0x05D9,0x05E0,0x05D2)) $(-join [char[]]@(0x05D5,0x05DE,0x05E9,0x05D2,0x05E8,0x05D9,0x05DD))"
            Key = "gaming"
            Icon = "$([char]0xE7FC)"
            Items = @(
                [pscustomobject]@{ Name = "Amazon Games"; WingetId = "Amazon.Games" }
                [pscustomobject]@{ Name = "Battle.net"; WingetId = "Blizzard.BattleNet" }
                [pscustomobject]@{ Name = "CurseForge"; WingetId = "Overwolf.CurseForge" }
                [pscustomobject]@{ Name = "EA app"; WingetId = "ElectronicArts.EADesktop" }
                [pscustomobject]@{ Name = "Epic Games Launcher"; WingetId = "EpicGames.EpicGamesLauncher" }
                [pscustomobject]@{ Name = "GOG Galaxy"; WingetId = "GOG.Galaxy" }
                [pscustomobject]@{ Name = "Logitech G HUB"; WingetId = "Logitech.GHUB" }
                [pscustomobject]@{ Name = "Minecraft Launcher"; WingetId = "Mojang.MinecraftLauncher" }
                [pscustomobject]@{ Name = "Moonlight Game Streaming"; WingetId = "MoonlightGameStreamingProject.Moonlight" }
                [pscustomobject]@{ Name = "MSI Afterburner"; WingetId = "Guru3D.Afterburner" }
                [pscustomobject]@{ Name = "NVIDIA GeForce NOW"; WingetId = "Nvidia.GeForceNOW" }
                [pscustomobject]@{ Name = "Osu!"; WingetId = "ppy.osu" }
                [pscustomobject]@{ Name = "Overwolf"; WingetId = "Overwolf.Overwolf" }
                [pscustomobject]@{ Name = "Parsec"; WingetId = "Parsec.Parsec" }
                [pscustomobject]@{ Name = "Playnite (Game Manager)"; WingetId = "JosefNemec.Playnite" }
                [pscustomobject]@{ Name = "Razer Synapse 3"; WingetId = "Razer.Synapse" }
                [pscustomobject]@{ Name = "RetroArch"; WingetId = "Libretro.RetroArch" }
                [pscustomobject]@{ Name = "Riot Client"; WingetId = "RiotGames.RiotClient" }
                [pscustomobject]@{ Name = "Roblox"; WingetId = "Roblox.Roblox" }
                [pscustomobject]@{ Name = "Steam"; WingetId = "Valve.Steam" }
                [pscustomobject]@{ Name = "Twitch"; WingetId = "Twitch.Twitch" }
                [pscustomobject]@{ Name = "Ubisoft Connect"; WingetId = "Ubisoft.Connect" }
                [pscustomobject]@{ Name = "Xbox App"; WingetId = "Microsoft.XboxApp" }
            )
        },
        [pscustomobject]@{
            TitleEn = "Communication & Chat"
            TitleHe = "$(-join [char[]]@(0x05EA,0x05E7,0x05E9,0x05D5,0x05E8,0x05EA)) $(-join [char[]]@(0x05D5,0x05E6))'$(-join [char[]]@(0x05D0,0x05D8))"
            Key = "chat"
            Icon = "$([char]0xE717)"
            Items = @(
                [pscustomobject]@{ Name = "Discord"; WingetId = "Discord.Discord" }
                [pscustomobject]@{ Name = "Microsoft Teams"; WingetId = "Microsoft.Teams" }
                [pscustomobject]@{ Name = "Signal"; WingetId = "OpenWhisperSystems.Signal" }
                [pscustomobject]@{ Name = "Skype"; WingetId = "Microsoft.Skype" }
                [pscustomobject]@{ Name = "Slack"; WingetId = "SlackTechnologies.Slack" }
                [pscustomobject]@{ Name = "Telegram"; WingetId = "Telegram.TelegramDesktop" }
                [pscustomobject]@{ Name = "WhatsApp"; WingetId = "WhatsApp.WhatsApp" }
                [pscustomobject]@{ Name = "Zoom"; WingetId = "Zoom.Zoom" }
            )
        },
        [pscustomobject]@{
            TitleEn = "Development Tools"
            TitleHe = "$(-join [char[]]@(0x05DB,0x05DC,0x05D9)) $(-join [char[]]@(0x05E4,0x05D9,0x05EA,0x05D5,0x05D7))"
            Key = "dev"
            Icon = "$([char]0xE943)"
            Items = @(
                [pscustomobject]@{ Name = "Android Studio"; WingetId = "Google.AndroidStudio" }
                [pscustomobject]@{ Name = "Cursor (AI Code Editor)"; WingetId = "Cursor.Cursor" }
                [pscustomobject]@{ Name = "DBeaver Community"; WingetId = "dbeaver.dbeaver" }
                [pscustomobject]@{ Name = "Git"; WingetId = "Git.Git" }
                [pscustomobject]@{ Name = "GitHub Desktop"; WingetId = "GitHub.GitHubDesktop" }
                [pscustomobject]@{ Name = "HeidiSQL"; WingetId = "HeidiSQL.HeidiSQL" }
                [pscustomobject]@{ Name = "IntelliJ IDEA Community"; WingetId = "JetBrains.IntelliJIDEA.Community" }
                [pscustomobject]@{ Name = "LM Studio"; WingetId = "ElementLabs.LMStudio" }
                [pscustomobject]@{ Name = "MySQL Workbench"; WingetId = "Oracle.MySQLWorkbench" }
                [pscustomobject]@{ Name = "Neovim"; WingetId = "Neovim.Neovim" }
                [pscustomobject]@{ Name = "Ollama (Local AI)"; WingetId = "Ollama.Ollama" }
                [pscustomobject]@{ Name = "pgAdmin 4"; WingetId = "pgAdmin.pgAdmin4" }
                [pscustomobject]@{ Name = "Postman"; WingetId = "Postman.Postman" }
                [pscustomobject]@{ Name = "PuTTY"; WingetId = "PuTTY.PuTTY" }
                [pscustomobject]@{ Name = "PyCharm Community"; WingetId = "JetBrains.PyCharm.Community" }
                [pscustomobject]@{ Name = "Rider"; WingetId = "JetBrains.Rider" }
                [pscustomobject]@{ Name = "Sublime Text 4"; WingetId = "SublimeHQ.SublimeText.4" }
                [pscustomobject]@{ Name = "Termius"; WingetId = "Termius.Termius" }
                [pscustomobject]@{ Name = "Unity Hub"; WingetId = "Unity.UnityHub" }
                [pscustomobject]@{ Name = "Visual Studio Code"; WingetId = "Microsoft.VisualStudioCode" }
                [pscustomobject]@{ Name = "WebStorm"; WingetId = "JetBrains.WebStorm" }
                [pscustomobject]@{ Name = "WinSCP"; WingetId = "WinSCP.WinSCP" }
                [pscustomobject]@{ Name = "Zed"; WingetId = "Zed.Zed" }
            )
        },
        [pscustomobject]@{
            TitleEn = "Runtimes & Frameworks"
            TitleHe = "$(-join [char[]]@(0x05E1,0x05D1,0x05D9,0x05D1,0x05D5,0x05EA)) $(-join [char[]]@(0x05E8,0x05D9,0x05E6,0x05D4)) $(-join [char[]]@(0x05D5,0x05DE,0x05E1,0x05D3,0x05D9)) $(-join [char[]]@(0x05E0,0x05EA,0x05D5,0x05E0,0x05D9,0x05DD))"
            Key = "runtimes"
            Icon = "$([char]0xE756)"
            Items = @(
                [pscustomobject]@{ Name = ".NET Desktop Runtime 8"; WingetId = "Microsoft.DotNet.DesktopRuntime.8" }
                [pscustomobject]@{ Name = ".NET SDK 8"; WingetId = "Microsoft.DotNet.SDK.8" }
                [pscustomobject]@{ Name = "CMake"; WingetId = "Kitware.CMake" }
                [pscustomobject]@{ Name = "DirectX Runtime"; WingetId = "Microsoft.DirectX" }
                [pscustomobject]@{ Name = "Docker Desktop"; WingetId = "Docker.DockerDesktop" }
                [pscustomobject]@{ Name = "Go"; WingetId = "GoLang.Go" }
                [pscustomobject]@{ Name = "Java JDK 21 (Temurin)"; WingetId = "EclipseAdoptium.Temurin.21.JDK" }
                [pscustomobject]@{ Name = "Java JRE 21 (Temurin)"; WingetId = "EclipseAdoptium.Temurin.21.JRE" }
                [pscustomobject]@{ Name = "MongoDB"; WingetId = "MongoDB.Server" }
                [pscustomobject]@{ Name = "MySQL"; WingetId = "Oracle.MySQL" }
                [pscustomobject]@{ Name = "PHP"; WingetId = "PHP.PHP" }
                [pscustomobject]@{ Name = "PostgreSQL"; WingetId = "PostgreSQL.PostgreSQL" }
                [pscustomobject]@{ Name = "Python 3.12"; WingetId = "Python.Python.3.12" }
                [pscustomobject]@{ Name = "Ruby"; WingetId = "RubyInstallerTeam.Ruby" }
                [pscustomobject]@{ Name = "Rust"; WingetId = "Rustlang.Rustup" }
                [pscustomobject]@{ Name = "Visual C++ Redist x64"; WingetId = "Microsoft.VCRedist.2015+.x64" }
                [pscustomobject]@{ Name = "Visual C++ Redist x86"; WingetId = "Microsoft.VCRedist.2015+.x86" }
                [pscustomobject]@{ Name = "WebView2 Runtime"; WingetId = "Microsoft.EdgeWebView2Runtime" }
            )
        },
        [pscustomobject]@{
            TitleEn = "Utilities & System"
            TitleHe = "$(-join [char[]]@(0x05E2,0x05D6,0x05E8,0x05D9)) $(-join [char[]]@(0x05DE,0x05E2,0x05E8,0x05DB,0x05EA))"
            Key = "utils"
            Icon = "$([char]0xE713)"
            Items = @(
                [pscustomobject]@{ Name = "7-Zip"; WingetId = "7zip.7zip" }
                [pscustomobject]@{ Name = "AnyDesk"; WingetId = "AnyDeskSoftwareGmbH.AnyDesk" }
                [pscustomobject]@{ Name = "AOMEI Partition Assistant"; WingetId = "AOMEI.PartitionAssistant" }
                [pscustomobject]@{ Name = "AutoHotkey"; WingetId = "Lexikos.AutoHotkey" }
                [pscustomobject]@{ Name = "CrystalDiskInfo"; WingetId = "CrystalDewWorld.CrystalDiskInfo" }
                [pscustomobject]@{ Name = "CrystalDiskMark"; WingetId = "CrystalDewWorld.CrystalDiskMark" }
                [pscustomobject]@{ Name = "Dropbox"; WingetId = "Dropbox.Dropbox" }
                [pscustomobject]@{ Name = "Everything (Instant Search)"; WingetId = "voidtools.Everything" }
                [pscustomobject]@{ Name = "FanControl"; WingetId = "Rem0o.FanControl.Beta" }
                [pscustomobject]@{ Name = "Fluent Search"; WingetId = "BlastApps.FluentSearch" }
                [pscustomobject]@{ Name = "Foxit PDF Reader"; WingetId = "Foxit.FoxitReader" }
                [pscustomobject]@{ Name = "Google Drive"; WingetId = "Google.Drive" }
                [pscustomobject]@{ Name = "HWiNFO"; WingetId = "REALiX.HWiNFO" }
                [pscustomobject]@{ Name = "HWMonitor"; WingetId = "CPUID.HWMonitor" }
                [pscustomobject]@{ Name = "Macrorit Partition Expert"; WingetId = "Macrorit.PartitionExpert" }
                [pscustomobject]@{ Name = "Microsoft PowerToys"; WingetId = "Microsoft.PowerToys" }
                [pscustomobject]@{ Name = "Notepad++"; WingetId = "Notepad++.Notepad++" }
                [pscustomobject]@{ Name = "PowerShell 7"; WingetId = "Microsoft.PowerShell" }
                [pscustomobject]@{ Name = "Process Explorer"; WingetId = "Microsoft.Sysinternals.ProcessExplorer" }
                [pscustomobject]@{ Name = "qBittorrent"; WingetId = "qBittorrent.qBittorrent" }
                [pscustomobject]@{ Name = "Rufus (USB Creator)"; WingetId = "Rufus.Rufus" }
                [pscustomobject]@{ Name = "RustDesk"; WingetId = "RustDesk.RustDesk" }
                [pscustomobject]@{ Name = "StartAllBack"; WingetId = "Tihiy.StartAllBack" }
                [pscustomobject]@{ Name = "SumatraPDF"; WingetId = "SumatraPDF.SumatraPDF" }
                [pscustomobject]@{ Name = "Sysinternals Suite"; WingetId = "Microsoft.Sysinternals" }
                [pscustomobject]@{ Name = "TeamViewer"; WingetId = "TeamViewer.TeamViewer" }
                [pscustomobject]@{ Name = "TeraCopy"; WingetId = "CodeSector.TeraCopy" }
                [pscustomobject]@{ Name = "TranslucentTB"; WingetId = "TranslucentTB.TranslucentTB" }
                [pscustomobject]@{ Name = "TreeSize Free"; WingetId = "JAMSoftware.TreeSize.Free" }
                [pscustomobject]@{ Name = "VirtualBox"; WingetId = "Oracle.VirtualBox" }
                [pscustomobject]@{ Name = "VMware Workstation Player"; WingetId = "VMware.WorkstationPlayer" }
                [pscustomobject]@{ Name = "Winaero Tweaker"; WingetId = "Winaero.WinaeroTweaker" }
                [pscustomobject]@{ Name = "WindirStat"; WingetId = "WinDirStat.WinDirStat" }
                [pscustomobject]@{ Name = "Windows Terminal"; WingetId = "Microsoft.WindowsTerminal" }
                [pscustomobject]@{ Name = "WinRAR"; WingetId = "RARLab.WinRAR" }
            )
        },
        [pscustomobject]@{
            TitleEn = "Security & Cleanup"
            TitleHe = "$(-join [char[]]@(0x05D0,0x05D1,0x05D8,0x05D7,0x05D4)) $(-join [char[]]@(0x05D5,0x05E0,0x05D9,0x05E7,0x05D5,0x05D9))"
            Key = "security"
            Icon = "$([char]0xE773)"
            Items = @(
                [pscustomobject]@{ Name = "1Password"; WingetId = "AgileBits.1Password" }
                [pscustomobject]@{ Name = "Bitwarden"; WingetId = "Bitwarden.Bitwarden" }
                [pscustomobject]@{ Name = "BleachBit"; WingetId = "BleachBit.BleachBit" }
                [pscustomobject]@{ Name = "CCleaner"; WingetId = "Piriform.CCleaner" }
                [pscustomobject]@{ Name = "Geek Uninstaller"; WingetId = "ThomasKoen.GeekUninstaller" }
                [pscustomobject]@{ Name = "Malwarebytes"; WingetId = "Malwarebytes.Malwarebytes" }
                [pscustomobject]@{ Name = "Revo Uninstaller"; WingetId = "RevoUninstaller.RevoUninstaller" }
                [pscustomobject]@{ Name = "Wireshark"; WingetId = "WiresharkFoundation.Wireshark" }
            )
        },
        [pscustomobject]@{
            TitleEn = "Hardware Audit & Privacy"
            TitleHe = "$(-join [char[]]@(0x05D1,0x05D3,0x05D9,0x05E7,0x05EA)) $(-join [char[]]@(0x05D7,0x05D5,0x05DE,0x05E8,0x05D4)) $(-join [char[]]@(0x05D5,0x05E4,0x05E8,0x05D8,0x05D9,0x05D5,0x05EA))"
            Key = "audit"
            Icon = "$([char]0xE9D9)"
            Items = @(
                [pscustomobject]@{ Name = "Profile: Gaming"; Title = "Gaming"; Desc = "Max performance, zero mouse accel, lower network latency."; TweakId = "AuditProfile1"; IsTweak = $true }
                [pscustomobject]@{ Name = "Profile: Office & Browsing"; Title = "Office & Browsing"; Desc = "Stability, power saving, bloatware removal."; TweakId = "AuditProfile2"; IsTweak = $true }
                [pscustomobject]@{ Name = "Profile: Content Creation"; Title = "Content Creation"; Desc = "Maximize stable resources for rendering/production."; TweakId = "AuditProfile3"; IsTweak = $true }
                [pscustomobject]@{ Name = "Profile: AI & Machine Learning"; Title = "AI & Machine Learning"; Desc = "Deep system scan, max RAM/VRAM utilization, Long Paths."; TweakId = "AuditProfile4"; IsTweak = $true }
                [pscustomobject]@{ Name = "Profile: Forensic Deep Scan"; Title = "Forensic Deep Scan"; Desc = "Driver & Targeted Folder Analysis - ~5-10 Minutes."; TweakId = "AuditProfile5"; IsTweak = $true }
                [pscustomobject]@{ Name = "Profile: UNDO"; Title = "UNDO"; Desc = "Restore every change recorded by the last run (or Windows defaults)."; TweakId = "AuditProfile6"; IsTweak = $true }
                [pscustomobject]@{ Name = "Profile: Ultimate Debloat"; Title = "Ultimate Debloat"; Desc = "Telemetry services off, consumer bloatware removed, Bing search off."; TweakId = "AuditProfile7"; IsTweak = $true }
                [pscustomobject]@{ Name = "Profile: Privacy Shield"; Title = "Privacy Shield"; Desc = "Telemetry level 0, tracking tasks off, telemetry domains blocked."; TweakId = "AuditProfile8"; IsTweak = $true }
                [pscustomobject]@{ Name = "Profile: Laptop Battery Saver"; Title = "Laptop Battery Saver"; Desc = "Power Saver plan, CPU capped at 80% on battery, faster screen/disk sleep."; TweakId = "AuditProfile9"; IsTweak = $true }
                [pscustomobject]@{ Name = "Profile: Network Supercharger"; Title = "Network Supercharger"; Desc = "Optimize TCP/IP stack, flush DNS, prioritize gaming packets."; TweakId = "AuditProfile10"; IsTweak = $true }
                [pscustomobject]@{ Name = "Profile: Nuclear Ultra-Deep Debloat"; Title = "Nuclear Ultra-Deep Debloat"; Desc = "Extreme background stripping of Edge, Copilot, Widgets & telemetry."; TweakId = "AuditProfile11"; IsTweak = $true }
                [pscustomobject]@{ Name = "Profile: Deep System Cleanup"; Title = "Deep System Cleanup"; Desc = "Clean Windows Update cache, crash dumps, temp files, and SSD TRIM."; TweakId = "AuditProfile12"; IsTweak = $true }
                [pscustomobject]@{ Name = "Profile: Security Hardening"; Title = "Security Hardening"; Desc = "Disable WPAD, Remote Assistance, and lock screen exposure."; TweakId = "AuditProfile13"; IsTweak = $true }
                [pscustomobject]@{ Name = "Generate HTML Report (Desktop)"; Title = "Generate HTML Report"; Desc = "Create an interactive, transparent HTML report of all system changes."; TweakId = "GenerateHtmlReport"; IsTweak = $true }
            )
        }
    )
}

$script:isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$scriptPath = $MyInvocation.MyCommand.Path
# If running via irm/iex, $scriptPath will be empty. We handle this gracefully.
if (-not $scriptPath) {
    $script:scriptDir = $env:TEMP
} else {
    $script:scriptDir = Split-Path -Parent $scriptPath
}

# Raw GitHub location of this script (used when it has to be downloaded or relaunched).
$script:RawBase = 'https://raw.githubusercontent.com/dor2500/WinFlexSetupModern/master'
function Get-WFSupportFile([string]$Name) {
    $local = Join-Path $script:scriptDir $Name
    if (Test-Path -LiteralPath $local) { return $local }
    if ($PSScriptRoot) {
        $alt = Join-Path $PSScriptRoot $Name
        if (Test-Path -LiteralPath $alt) { return $alt }
    }
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $content = (Invoke-WebRequest -Uri "$($script:RawBase)/$Name" -UseBasicParsing -ErrorAction Stop).Content
        if ($content -is [byte[]]) { $content = [Text.Encoding]::UTF8.GetString($content) }
        # Saved with a BOM so Windows PowerShell 5.1 reads the Hebrew text correctly.
        [IO.File]::WriteAllText($local, $content.TrimStart([char]0xFEFF), (New-Object Text.UTF8Encoding($true)))
        return $local
    } catch {
        return $null
    }
}

# The console engine runs in its own process, which needs this script as a file.
# Started from a file: use it. Started with 'irm | iex': download a fresh copy once per session.
function Get-WFSelfPath {
    if ($PSCommandPath) { return $PSCommandPath }
    if ($script:WFSelfPath -and (Test-Path -LiteralPath $script:WFSelfPath)) { return $script:WFSelfPath }
    $target = Join-Path $script:scriptDir 'WinFlexSetupModern.ps1'
    Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
    $script:WFSelfPath = Get-WFSupportFile 'WinFlexSetupModern.ps1'
    return $script:WFSelfPath
}
if (-not $script:isAdmin) {
    if ($scriptPath) {
        Write-Host "Elevating to Administrator..." -ForegroundColor Yellow
        Start-Process powershell.exe -Verb RunAs -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-STA", "-File", "`"$scriptPath`"")
        exit
    } else {
        Write-Host "Elevating to Administrator..." -ForegroundColor Yellow
        try {
            Start-Process powershell.exe -Verb RunAs -ErrorAction Stop -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", "irm '$($script:RawBase)/WinFlexSetupModern.ps1' | iex")
        } catch {
            Write-Warning "Administrator rights are required. Right-click PowerShell -> Run as Administrator, then paste the command again."
        }
        # 'exit' would close the console the user typed the command in.
        return
    }
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms
[System.Windows.Forms.Application]::EnableVisualStyles() | Out-Null

$backgroundImagePath = "C:\MENU\Discovery+of+The+Lost+Vista+1+-+4K.jpg"
$audioPath = "C:\MENU\winflex.wav"
$script:LogPath = Join-Path $env:TEMP "winflex-setup.log"
function He([int[]]$codes){$s="";foreach($c in $codes){$s+=[char]$c};$s}

function Write-Log([string]$Message) {
    $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    try { Add-Content -Path $script:LogPath -Value "[$ts] $Message" -Encoding UTF8 } catch {}
}

$script:player = $null; $script:isMuted = $false
if (Test-Path -LiteralPath $audioPath) {
    try { $script:player = New-Object System.Media.SoundPlayer -ArgumentList $audioPath; $script:player.Load() } catch { $script:player = $null }
}
function Play-Sound { if ($script:player -and -not $script:isMuted) { try { $script:player.PlayLooping() } catch {} } }
function Toggle-Mute {
    if (-not $script:player) { return }
    if ($script:isMuted) { $script:isMuted = $false; try { $script:player.PlayLooping() } catch {} }
    else { $script:isMuted = $true; try { $script:player.Stop() } catch {} }
}

function Test-Winget { [bool](Get-Command winget -ErrorAction SilentlyContinue) }
function Install-Winget {
    if (Test-Winget) { return $true }
    $tmpDir = Join-Path $env:TEMP "winget-install"
    New-Item -ItemType Directory -Force -Path $tmpDir -ErrorAction SilentlyContinue | Out-Null
    $bundle = Join-Path $tmpDir "Microsoft.DesktopAppInstaller.msixbundle"
    try { (New-Object Net.WebClient).DownloadFile("https://aka.ms/getwinget", $bundle) } catch {}
    try { Add-AppxPackage -Path $bundle -ErrorAction SilentlyContinue | Out-Null } catch {}
    Start-Sleep -Seconds 2; return (Test-Winget)
}
function Invoke-WingetInstall([string]$Id, [bool]$IsExact=$true) {
    if ($IsExact) {
        $a = @("install","-e","--id",$Id,"--silent","--accept-package-agreements","--accept-source-agreements")
    } else {
        $a = @("install",$Id,"--silent","--accept-package-agreements","--accept-source-agreements")
    }
    $p = Start-Process -FilePath "winget" -ArgumentList $a -PassThru -Wait -NoNewWindow
    if ($p.ExitCode -ne 0) { throw "winget failed for $Id (ExitCode=$($p.ExitCode))" }
}

# ===== ADDED HARDWARE AUDIT & TWEAKS =====
function Get-SystemHardwareAudit {
    $systemEnclosure = Get-CimInstance -ClassName Win32_SystemEnclosure -ErrorAction SilentlyContinue
    $chassisTypes = $systemEnclosure.ChassisTypes
    $batteryCheck = Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue
    
    $laptopChassisCodes = @(8, 9, 10, 11, 12, 14, 18, 21, 30, 31, 32)
    $script:IsLaptop = if ($batteryCheck) { $true } else { $false }
    if (-not $script:IsLaptop) {
        foreach ($c in $chassisTypes) { if ($laptopChassisCodes -contains $c) { $script:IsLaptop = $true; break } }
    }
    
    $formFactorName = if ($script:IsLaptop) { "Laptop" } else { "Desktop" }
    $script:IsAsus = ($baseboard.Manufacturer -match 'ASUS|ASUSTeK') -or ($computerSystem.Manufacturer -match 'ASUS|ASUSTeK')
    $osInfo = Get-CimInstance Win32_OperatingSystem
    $isWin11 = $osInfo.BuildNumber -ge 22000
    $osName = if ($isWin11) { "Windows 11" } else { "Windows 10" }

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

    if ($null -ne $AuditTerminalText -and $AuditTerminalText.Inlines.Count -eq 0) {
        $AuditTerminalText.Inlines.Clear()
        function Add-ColorText([string]$text, [string]$color) {
            $run = New-Object System.Windows.Documents.Run
            $run.Text = $text
            $run.Foreground = (New-Object System.Windows.Media.BrushConverter).ConvertFromString($color)
            $AuditTerminalText.Inlines.Add($run) | Out-Null
        }
        
        Add-ColorText "[ Smart Hardware Optimization & Profile customization ]`n" "#00FF00"
        Add-ColorText "-------------------------------------------------------`n`n" "#888888"

        Add-ColorText "Phase 1: Comprehensive System & Hardware Audit`n" "#FF00FF"

        Add-ColorText "`n[+] Detected System Configuration: $formFactorName`n" "#00FFFF"
        Add-ColorText "  * Operating System: $osName (Build $($osInfo.BuildNumber))`n" "#AAAAAA"
        Add-ColorText "  * Manufacturer & Model: $($computerSystem.Manufacturer) $($computerSystem.Model)`n" "#AAAAAA"
        Add-ColorText "  * Motherboard: $($baseboard.Manufacturer) $($baseboard.Product) (BIOS: $($bios.SMBIOSBIOSVersion))`n" "#AAAAAA"
        if ($script:IsAsus) {
            Add-ColorText "  * [*] ASUS Hardware: Detected (Armoury Crate Deep Taming & Anti-Stutter Engine Ready)`n" "#FF00FF"
        }
        Add-ColorText "`n" "#AAAAAA"
        
        Add-ColorText "* CPU: $($script:cpu.Name)`n" "#00FF00"
        Add-ColorText "  - $($script:cpu.NumberOfCores) Cores / $($script:cpu.NumberOfLogicalProcessors) Threads | Base Clock: $($script:cpu.MaxClockSpeed) MHz`n`n" "#888888"
        
        Add-ColorText "* RAM: $($script:totalRamGB) GB Installed`n" "#00FF00"
        $stickIdx = 1
        foreach ($stick in $ramSticks) {
            $stickGb = [math]::Round($stick.Capacity / 1GB, 1)
            Add-ColorText "  - Stick $($stickIdx): $stickGb GB | Speed: $($stick.ConfiguredClockSpeed) MHz (Maker: $($stick.Manufacturer))`n" "#888888"
            $stickIdx++
        }
        
        Add-ColorText "`n* GPU(s):`n" "#00FF00"
        foreach ($gpu in $script:gpus) { 
            $vram = if ($gpu.AdapterRAM -gt 0) { "$([math]::Round($gpu.AdapterRAM / 1GB, 2)) GB VRAM" } else { "Shared RAM" }
            Add-ColorText "  - $($gpu.Name) [$vram] (Driver: $($gpu.DriverVersion))`n" "#00AAAA"
        }
        
        Add-ColorText "`n* Storage:`n" "#00FF00"
        foreach ($d in $disks) {
            Add-ColorText "  - $($d.FriendlyName) : $([math]::Round($d.Size / 1GB, 1)) GB | Media: $($d.MediaType) $($d.BusType)`n" "#888888"
        }
        
        Add-ColorText "`n* Disk Health (S.M.A.R.T):`n" "#00FF00"
        foreach ($pd in $disks) {
            $health = if ($pd.HealthStatus -eq "Healthy") { "[Healthy]" } else { "[WARNING]" }
            Add-ColorText "  - $($pd.FriendlyName): $health (Status: $($pd.OperationalStatus))`n" "#AAAAAA"
        }
        
        Add-ColorText "`n* Network Interfaces & Latency:`n" "#00FF00"
        $nics = Get-NetAdapter | Where-Object { $_.Status -eq "Up" } -ErrorAction SilentlyContinue
        foreach ($nic in $nics) {
            Add-ColorText "  - $($nic.Name) ($($nic.InterfaceDescription)) - Link: $($nic.LinkSpeed)`n" "#AAAAAA"
        }
        $ping = Test-Connection -ComputerName 8.8.8.8 -Count 1 -ErrorAction SilentlyContinue
        if ($ping) { Add-ColorText "  - Internet Ping (8.8.8.8): $($ping.ResponseTime) ms`n" "#00FFFF" }

        Add-ColorText "`n-------------------------------------------------------`n" "#888888"
        Add-ColorText "Phase 2: Define Usage Profile (Customization)`n" "#FF00FF"
        Add-ColorText "What is the primary use case for this PC? (Select a number):`n" "#AAAAAA"
        
        Add-ColorText "[1] Gaming" "#00FFFF"
        Add-ColorText " - Max performance, zero mouse accel, lower network latency.`n" "#AAAAAA"
        Add-ColorText "[2] Office & Browsing" "#00FFFF"
        Add-ColorText " - Stability, power saving, bloatware removal.`n" "#AAAAAA"
        Add-ColorText "[3] Content Creation" "#00FFFF"
        Add-ColorText " - Maximize stable resources for rendering/production.`n" "#AAAAAA"
        Add-ColorText "[4] AI & Machine Learning" "#00FFFF"
        Add-ColorText " - Deep system scan, max RAM/VRAM utilization, Long Paths.`n" "#AAAAAA"
        Add-ColorText "[5] Forensic Deep Scan" "#00FFFF"
        Add-ColorText " - (Driver & Targeted Folder Analysis) - ~5-10 Minutes`n" "#AAAAAA"
        Add-ColorText "[6] UNDO" "#00FFFF"
        Add-ColorText " - Revert all optimizations to Windows defaults.`n" "#AAAAAA"
        Add-ColorText "[7] Ultimate Debloat" "#00FFFF"
        Add-ColorText " - Extreme telemetry removal, disable Defender, remove Edge.`n" "#AAAAAA"
        Add-ColorText "[8] Privacy Shield" "#00FFFF"
        Add-ColorText " - Block all tracking, disable Cortana, spoof telemetry.`n" "#AAAAAA"
        Add-ColorText "[9] Laptop Battery Saver" "#00FFFF"
        Add-ColorText " - Underclock CPU, max power saving, disable background sync.`n" "#AAAAAA"
        Add-ColorText "[10] Network Supercharger" "#00FFFF"
        Add-ColorText " - Optimize TCP/IP stack, flush DNS, prioritize gaming packets.`n" "#AAAAAA"
        Add-ColorText "[11] Nuclear Ultra-Deep Debloat" "#FF0055"
        Add-ColorText " - Extreme background stripping of Edge, Copilot, Widgets & telemetry.`n" "#AAAAAA"
        Add-ColorText "[12] Deep System Cleanup" "#FFD700"
        Add-ColorText " - Clean Windows Update cache, crash dumps, temp files, and SSD TRIM.`n" "#AAAAAA"
        Add-ColorText "[13] Security & Privacy Hardening" "#00FF66"
        Add-ColorText " - Disable WPAD, remote assistance, and lock screen privacy exposure.`n" "#AAAAAA"
    }
}


# ==============================================================================
# [100000% SUPERCHARGED ENGINE] ASUS Hardware & Armoury Crate Deep Taming
# ==============================================================================
function Test-IsAsusDevice {
    if ($null -ne $script:IsAsus) { return $script:IsAsus }
    $bb = Get-CimInstance -ClassName Win32_BaseBoard -ErrorAction SilentlyContinue | Select-Object -First 1
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue | Select-Object -First 1
    $script:IsAsus = [bool](($bb.Manufacturer -match 'ASUS|ASUSTeK') -or ($cs.Manufacturer -match 'ASUS|ASUSTeK'))
    return $script:IsAsus
}

function Invoke-AsusGamingOptimization {
    if (-not (Test-IsAsusDevice)) { return $null }

    Write-Log "[ASUS Engine] ASUS Motherboard/System Detected! Beginning 100000% Deep Taming..."
    $actions = [System.Collections.Generic.List[string]]::new()

    # 1. Eliminate GameFirst / cFosSpeed Network Filter (Causes massive ping spikes & latency jitter)
    $netServices = @("AsusGameFirstService", "ROG Game First", "cFosSpeed", "cFosSpeedSvc")
    foreach ($svc in $netServices) {
        $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
        if ($s) {
            Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
            Set-Service -Name $svc -StartupType Disabled -ErrorAction SilentlyContinue
            $actions.Add("Disabled ASUS GameFirst / cFosSpeed service ($svc) -> Zero ping spikes.")
            Write-Log "ASUS Optimization: Disabled $svc"
        }
    }

    # 2. Disable heavy background telemetry, update loops and live ad services
    # (Keeps core fan, hotkey, and power controls like ASUS Optimization / System Control Interface fully working!)
    $telemetryServices = @(
        "AsusROGLSLService",       # ROG Live Service (ad banners, deals, continuous CPU polling)
        "ASUSSoftwareManager",     # Background update checker loop
        "ASUSLinkNear",            # Link to MyASUS near device polling
        "ASUSLinkRemote",          # Link to MyASUS remote
        "AsusAppService",          # Analytics and app telemetry service
        "AsusCertService",         # Certificate/installer validation loop
        "AsusPTPCenter"            # Telemetry service
    )
    foreach ($svc in $telemetryServices) {
        $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
        if ($s) {
            Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
            Set-Service -Name $svc -StartupType Disabled -ErrorAction SilentlyContinue
            $actions.Add("Disabled ASUS background telemetry service ($svc) -> Micro-stutters stopped.")
            Write-Log "ASUS Optimization: Disabled $svc"
        }
    }

    # 3. Tame LightingService.exe (Aura Sync RGB)
    # LightingService is notorious for DPC latency spikes, micro-stutters, and anti-cheat false positives.
    # Permanently set IFEO CpuPriorityClass = 5 (BelowNormal) so RGB stays on without frame drops.
    try {
        $ifeoPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\LightingService.exe\PerfOptions"
        New-Item -Path $ifeoPath -Force -ErrorAction SilentlyContinue | Out-Null
        Set-ItemProperty -Path $ifeoPath -Name "CpuPriorityClass" -Value 5 -Type DWord -Force -ErrorAction SilentlyContinue
        $actions.Add("Configured LightingService.exe (Aura RGB) Priority to BelowNormal -> Anti-Cheat safe & zero frame drops.")
    } catch {}
    $lightingProcs = Get-Process -Name "LightingService" -ErrorAction SilentlyContinue
    if ($lightingProcs) {
        foreach ($proc in $lightingProcs) {
            try { $proc.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::BelowNormal } catch {}
        }
    }

    # 4. Terminate hung/memory-leak instances of ArmouryCrate helper processes
    $hangHelpers = @("ArmouryCrate.UserSessionHelper", "ArmourySocketServer")
    foreach ($helper in $hangHelpers) {
        $procs = Get-Process -Name $helper -ErrorAction SilentlyContinue
        if ($procs) {
            $procs | Where-Object { $_.CPU -gt 15 -or $_.WorkingSet64 -gt 350MB } | Stop-Process -Force -ErrorAction SilentlyContinue
            $actions.Add("Terminated hung/leaking instance of $helper.")
            Write-Log "ASUS Optimization: Terminated hung helper $helper"
        }
    }

    # 5. Prevent UEFI ASUS Grid / Armoury Crate auto-injection installer popups during games
    $gridKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
    if (Test-Path $gridKey) {
        Remove-ItemProperty -Path $gridKey -Name "AsusUpdateCheck" -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $gridKey -Name "ArmouryCrateInstaller" -ErrorAction SilentlyContinue
    }
    $tasksToDisable = @(
        "\ASUS\Armoury Crate\AsusUpdateCheck",
        "\ASUS\Framework\AsusUnistallEvent"
    )
    foreach ($taskPath in $tasksToDisable) {
        try {
            $tFolder = $taskPath | Split-Path -Parent
            $tName = $taskPath | Split-Path -Leaf
            Disable-ScheduledTask -TaskPath $tFolder -TaskName $tName -ErrorAction SilentlyContinue | Out-Null
        } catch {}
    }

    # 6. Prevent ASUS Power Scheme conflicts with Windows Ultimate / Game Mode
    try {
        Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerSettings\54533251-82be-4824-96c1-47b60b740d00\be337238-0d82-4146-a960-4f3749d470c7" -Name "Attributes" -Value 2 -Type DWord -Force -ErrorAction SilentlyContinue
        $actions.Add("Prevented Armoury Crate power scheme overrides over Windows Ultimate Performance.")
    } catch {}

    if ($actions.Count -eq 0) {
        $actions.Add("ASUS Hardware verified: Essential controls (fans/hotkeys) active, zero bloat/conflicting services detected.")
    }

    return $actions
}

function Invoke-SystemTweak($tweakId) {
    if ($null -eq $script:hasSSD) { Get-SystemHardwareAudit | Out-Null }

    $auditScriptPath = Get-WFSelfPath

    # Route Audit Profiles to the enhanced transparent engine (restore point + HTML report + UNDO)
    if ($tweakId -match "^AuditProfile(\d+)$") {
        $pNum = $matches[1]
        Write-Log "Executing Profile $pNum with live transparency & HTML report generation..."
        if ($auditScriptPath) {
            $p = Start-Process -FilePath "powershell.exe" -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$auditScriptPath`"", "-ProfileId", "$pNum", "-Silent", "-NoPause", "-OpenReport") -PassThru -Wait -NoNewWindow
            Write-Log "Profile $pNum finished with exit code $($p.ExitCode)"
        } else {
            Write-Log "Profile $pNum skipped: WinFlexSetupModern.ps1 could not be saved to disk for the engine process."
        }
        return
    }

    switch ($tweakId) {
        # Both gaming entries use the engine's Gaming profile, so they get a restore point, a report and UNDO.
        "ProfileGaming" {
            Invoke-SystemTweak "AuditProfile1"
        }
        "ExtremeGamingBoost" {
            Invoke-SystemTweak "AuditProfile1"
        }
        "AsusGamingFix" {
            $asusRes = Invoke-AsusGamingOptimization
            if ($asusRes) { foreach ($act in $asusRes) { Write-Log "[ASUS] $act" } }
        }
        "NuclearDebloat" {
            Invoke-SystemTweak "AuditProfile11"
        }
        "SecurityHardening" {
            Invoke-SystemTweak "AuditProfile13"
        }
        "GenerateHtmlReport" {
            Write-Log "Generating HTML System Report on Desktop..."
            if ($auditScriptPath) {
                Start-Process -FilePath "powershell.exe" -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$auditScriptPath`"", "-DryRun", "-ProfileId", "11", "-Silent", "-NoPause", "-OpenReport") -Wait -NoNewWindow
            }
        }
        "ExtremeDebloat" {
            Invoke-SystemTweak "AuditProfile7"
        }
        "ForensicScan" {
            Invoke-SystemTweak "AuditProfile5"
        }
        "DeepDebloat" {
            $telemetryServices = @("DiagTrack", "dmwappushservice", "WerSvc")
            foreach ($svc in $telemetryServices) {
                Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
                Set-Service -Name $svc -StartupType Disabled -ErrorAction SilentlyContinue
            }
            New-Item -Path "HKCU:\Software\Policies\Microsoft\Windows\Explorer" -Force -ErrorAction SilentlyContinue | Out-Null
            Set-ItemProperty -Path "HKCU:\Software\Policies\Microsoft\Windows\Explorer" -Name "DisableSearchBoxSuggestions" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
            New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization" -Force -ErrorAction SilentlyContinue | Out-Null
            Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization" -Name "DODownloadMode" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
            $bloatware = @(
                "Microsoft.BingNews", "Microsoft.MicrosoftSolitaireCollection", "Microsoft.NetworkSpeedTest",
                "Microsoft.SkypeApp", "Microsoft.WindowsFeedbackHub", "Microsoft.ZuneVideo", "Microsoft.ZuneMusic",
                "SpotifyAB.SpotifyMusic", "Clipchamp.Clipchamp", "Microsoft.Todos", "Microsoft.YourPhone"
            )
            foreach ($app in $bloatware) {
                Get-AppxPackage -Name "*$app*" -AllUsers -ErrorAction SilentlyContinue | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
            }
        }
        "ClearTemp" {
            foreach ($p in @($env:TEMP, "$env:SystemRoot\Temp", "$env:LOCALAPPDATA\Microsoft\Windows\INetCache", "$env:LOCALAPPDATA\CrashDumps")) {
                if (Test-Path $p) { Get-ChildItem -Path $p -Force -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notlike "*winflex*" } | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue }
            }
            Remove-Item "$env:LOCALAPPDATA\Microsoft\Windows\Explorer\thumbcache_*.db" -Force -ErrorAction SilentlyContinue
            Write-Log "Temp files, caches and crash dumps cleaned (Recycle Bin left untouched)."
        }
        "CleanupWinUpdate" {
            Stop-Service -Name wuauserv -Force -ErrorAction SilentlyContinue
            Remove-Item "$env:SystemRoot\SoftwareDistribution\Download\*" -Recurse -Force -ErrorAction SilentlyContinue
            Start-Service -Name wuauserv -ErrorAction SilentlyContinue
            Dism.exe /Online /Cleanup-Image /StartComponentCleanup | Out-Null
            Write-Log "Windows Update download cache and component store cleaned."
        }
        "NetworkReset" {
            ipconfig /flushdns | Out-Null
            netsh winsock reset | Out-Null
            netsh int ip reset | Out-Null
            Write-Log "DNS cache flushed; Winsock and TCP/IP stack reset."
        }
        "DisableCopilot" {
            New-Item -Path "HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot" -Force -ErrorAction SilentlyContinue | Out-Null
            Set-ItemProperty -Path "HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot" -Name "TurnOffWindowsCopilot" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
            New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot" -Force -ErrorAction SilentlyContinue | Out-Null
            Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot" -Name "TurnOffWindowsCopilot" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
            Write-Log "Windows Copilot disabled by policy."
        }
        "NoConsumerContent" {
            New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" -Force -ErrorAction SilentlyContinue | Out-Null
            Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" -Name "DisableWindowsConsumerFeatures" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
            Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" -Name "DisableSoftLanding" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
            $cdm = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"
            foreach ($n in @("SubscribedContent-338388Enabled","SubscribedContent-338389Enabled","SubscribedContent-353694Enabled","SubscribedContent-353696Enabled","SilentInstalledAppsEnabled","SystemPaneSuggestionsEnabled","SoftLandingEnabled","RotatingLockScreenOverlayEnabled")) {
                Set-ItemProperty -Path $cdm -Name $n -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
            }
            Write-Log "Consumer content, app suggestions and silent app installs disabled."
        }
        "ShowHiddenFiles" {
            Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "Hidden" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
            Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "HideFileExt" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
            Write-Log "Explorer: Hidden files & extensions set to visible."
        }
        "DarkMode" {
            $k = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"
            Set-ItemProperty -Path $k -Name "AppsUseLightTheme" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
            Set-ItemProperty -Path $k -Name "SystemUsesLightTheme" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
            Write-Log "Windows dark mode enabled."
        }
        "ClassicContextMenu" {
            New-Item -Path "HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32" -Force -ErrorAction SilentlyContinue | Out-Null
            Set-ItemProperty -Path "HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32" -Name "(default)" -Value "" -Force -ErrorAction SilentlyContinue
            Write-Log "Classic (full) right-click menu enabled for Windows 11."
        }
        "ProfileOffice" {
            Set-ItemProperty -Path "HKCU:\Software\Microsoft\GameBar" -Name "AutoGameModeEnabled" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
            powercfg -setactive 381b4222-f694-41f0-9685-ff5bb260df2e
            Write-Log "Office profile applied."
        }
        "ProfileCreator" {
            Set-ItemProperty -Path "HKCU:\Software\Microsoft\GameBar" -Name "AutoGameModeEnabled" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
            Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" -Name "SystemResponsiveness" -Value 20 -Type DWord -Force -ErrorAction SilentlyContinue
            if (-not $script:IsLaptop) { powercfg -setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c }
            Write-Log "Content Creator profile applied."
        }
        "ProfileAI" {
            Set-ItemProperty -Path "HKCU:\Software\Microsoft\GameBar" -Name "AutoGameModeEnabled" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
            Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem" -Name "LongPathsEnabled" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
            Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" -Name "SystemResponsiveness" -Value 10 -Type DWord -Force -ErrorAction SilentlyContinue
            if (-not $script:IsLaptop) {
                powercfg -attributes SUB_PROCESSOR 0cc5b647-c1df-4637-891a-dec35c318583 -ATTRIB_HIDE 2>$null | Out-Null
                $uGuid = powercfg -duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61
                if ($uGuid -match "([A-Fa-f0-9\-]{36})") { powercfg -setactive $matches[1] } else { powercfg -setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c }
            }
            Write-Log "AI Profile applied: Long Paths, Ultimate Power, System Responsiveness adjusted."
        }
        "SSDOptimize" {
            if ($script:hasSSD) {
                fsutil behavior set DisableDeleteNotify 0 | Out-Null
                Optimize-Volume -DriveLetter C -ReTrim -ErrorAction SilentlyContinue | Out-Null
                Write-Log "SSD TRIM optimization command completed."
            }
        }
    }
}
# ==========================================

# # -------- Software Lists (Loaded Dynamically) --------
# The software lists ($browsers, etc.) and $script:Categories are loaded dynamically from GitHub during the Preflight check.

$script:Lang = "he"
function L([string]$he, [string]$en) { if ($script:Lang -eq "he") { $he } else { $en } }

$script:Themes = @(
    @{ Name="Cosmic (Video)"; Bg="#AA040209"; Sidebar="#88080414"; Card="#66100520"; Card2="#440A0214"; Fg="#FFFFFF"; Sub="#A296D4"; Accent="#B122E5"; Border="#55442266" },
    @{ Name="Neon Cyan";    Bg="#0F0F0F"; Sidebar="#141414"; Card="#1E1E1E"; Card2="#181818"; Fg="#FFFFFF"; Sub="#B0B0B0"; Accent="#00BFFF"; Border="#2A2A2A" },
    @{ Name="Tokyo Night";  Bg="#1A1B26"; Sidebar="#16161E"; Card="#24283B"; Card2="#1F2335"; Fg="#C0CAF5"; Sub="#787C99"; Accent="#7AA2F7"; Border="#2A3240" }
)
$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="WinFlexOS Setup" WindowStyle="None" ResizeMode="CanResize" WindowState="Maximized"
        AllowsTransparency="True" Background="Transparent" FontFamily="Bahnschrift, Segoe UI, sans-serif" FontSize="14">
  <Window.Resources>
    <SolidColorBrush x:Key="ThemeBg" Color="#0F0F0F"/><SolidColorBrush x:Key="ThemeSidebar" Color="#141414"/>
    <SolidColorBrush x:Key="ThemeCard" Color="#1E1E1E"/><SolidColorBrush x:Key="ThemeCard2" Color="#181818"/>
    <SolidColorBrush x:Key="ThemeFg" Color="#FFFFFF"/><SolidColorBrush x:Key="ThemeSub" Color="#B0B0B0"/>
    <SolidColorBrush x:Key="ThemeBorder" Color="#2A2A2A"/><SolidColorBrush x:Key="ThemeAccent" Color="#00BFFF"/>
    <CornerRadius x:Key="Rxl">22</CornerRadius><CornerRadius x:Key="Rl">18</CornerRadius>
    <CornerRadius x:Key="Rm">14</CornerRadius><CornerRadius x:Key="Rs">10</CornerRadius>
    <DropShadowEffect x:Key="CardShadow" BlurRadius="20" ShadowDepth="5" Direction="270" Color="Black" Opacity="0.2"/>
    <DropShadowEffect x:Key="SoftGlow" BlurRadius="25" ShadowDepth="0" Color="#B122E5" Opacity="0.7"/>
    <Style TargetType="ScrollBar"><Setter Property="Background" Value="Transparent"/><Setter Property="Width" Value="8"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ScrollBar">
        <Grid x:Name="G" Width="8" Background="Transparent"><Track x:Name="PART_Track" IsDirectionReversed="true"><Track.Thumb><Thumb><Thumb.Template><ControlTemplate TargetType="Thumb">
          <Border x:Name="T" Background="#55888888" CornerRadius="4"/>
          <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="T" Property="Background" Value="{DynamicResource ThemeAccent}"/></Trigger>
          <Trigger Property="IsDragging" Value="True"><Setter TargetName="T" Property="Background" Value="{DynamicResource ThemeFg}"/></Trigger></ControlTemplate.Triggers>
        </ControlTemplate></Thumb.Template></Thumb></Track.Thumb></Track></Grid>
        <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="G" Property="Width" Value="12"/></Trigger></ControlTemplate.Triggers>
      </ControlTemplate></Setter.Value></Setter></Style>
    <Style TargetType="ComboBox"><Setter Property="Foreground" Value="{DynamicResource ThemeFg}"/><Setter Property="Background" Value="{DynamicResource ThemeCard}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource ThemeBorder}"/><Setter Property="BorderThickness" Value="1"/><Setter Property="Height" Value="32"/><Setter Property="FontSize" Value="14"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ComboBox"><Grid>
        <ToggleButton Name="ToggleButton" Focusable="false" IsChecked="{Binding Path=IsDropDownOpen,Mode=TwoWay,RelativeSource={RelativeSource TemplatedParent}}" ClickMode="Press">
          <ToggleButton.Template><ControlTemplate TargetType="ToggleButton"><Border Background="{DynamicResource ThemeCard}" BorderBrush="{DynamicResource ThemeBorder}" BorderThickness="1" CornerRadius="6">
            <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="20"/></Grid.ColumnDefinitions>
            <Path Grid.Column="1" HorizontalAlignment="Center" VerticalAlignment="Center" Fill="{DynamicResource ThemeSub}" Data="M 0 0 L 4 4 L 8 0 Z"/></Grid>
          </Border></ControlTemplate></ToggleButton.Template></ToggleButton>
        <ContentPresenter Name="ContentSite" IsHitTestVisible="False" Content="{TemplateBinding SelectionBoxItem}" Margin="10,0,23,0" VerticalAlignment="Center" HorizontalAlignment="Left"/>
        <Popup Name="Popup" Placement="Bottom" IsOpen="{TemplateBinding IsDropDownOpen}" AllowsTransparency="True" Focusable="False" PopupAnimation="Slide">
          <Grid MinWidth="{TemplateBinding ActualWidth}" MaxHeight="{TemplateBinding MaxDropDownHeight}"><Border Background="{DynamicResource ThemeCard}" BorderBrush="{DynamicResource ThemeBorder}" BorderThickness="1" CornerRadius="6"/>
            <ScrollViewer Margin="4,6" SnapsToDevicePixels="True"><StackPanel IsItemsHost="True"/></ScrollViewer></Grid></Popup>
      </Grid></ControlTemplate></Setter.Value></Setter></Style>
    <Style TargetType="ComboBoxItem"><Setter Property="Foreground" Value="{DynamicResource ThemeFg}"/><Setter Property="Background" Value="{DynamicResource ThemeCard}"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ComboBoxItem">
        <Border x:Name="Bd" Background="{TemplateBinding Background}" Padding="5" CornerRadius="4"><ContentPresenter/></Border>
        <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Background" Value="{DynamicResource ThemeAccent}"/><Setter Property="Foreground" Value="White"/></Trigger>
          <Trigger Property="IsSelected" Value="True"><Setter TargetName="Bd" Property="Background" Value="{DynamicResource ThemeBorder}"/></Trigger>
        </ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter></Style>
    <Style x:Key="WinCtrlBtn" TargetType="Button"><Setter Property="Width" Value="45"/><Setter Property="Height" Value="35"/><Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="#AAAAAA"/><Setter Property="FontFamily" Value="Segoe MDL2 Assets"/><Setter Property="FontSize" Value="12"/><Setter Property="BorderThickness" Value="0"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button"><Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="6"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
        <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Background" Value="#22888888"/><Setter Property="Foreground" Value="{DynamicResource ThemeFg}"/></Trigger>
        <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.55"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter></Style>
    <Style x:Key="CloseBtn" TargetType="Button"><Setter Property="Width" Value="45"/><Setter Property="Height" Value="35"/><Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="#AAAAAA"/><Setter Property="FontFamily" Value="Segoe MDL2 Assets"/><Setter Property="FontSize" Value="12"/><Setter Property="BorderThickness" Value="0"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button"><Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="0,12,0,0"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
        <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Background" Value="#E81123"/><Setter Property="Foreground" Value="White"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter></Style>
    <Style x:Key="PrimaryBtn" TargetType="Button"><Setter Property="Background" Value="{DynamicResource ThemeCard}"/><Setter Property="Foreground" Value="{DynamicResource ThemeFg}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource ThemeAccent}"/><Setter Property="BorderThickness" Value="1"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
        <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="{StaticResource Rs}" RenderTransformOrigin="0.5,0.5">
          <Border.RenderTransform><ScaleTransform x:Name="PS" ScaleX="1" ScaleY="1"/></Border.RenderTransform>
          <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="{TemplateBinding Padding}"/></Border>
        <ControlTemplate.Triggers>
          <EventTrigger RoutedEvent="MouseEnter"><BeginStoryboard><Storyboard><DoubleAnimation Storyboard.TargetName="PS" Storyboard.TargetProperty="ScaleX" To="1.06" Duration="0:0:0.15"/><DoubleAnimation Storyboard.TargetName="PS" Storyboard.TargetProperty="ScaleY" To="1.06" Duration="0:0:0.15"/></Storyboard></BeginStoryboard></EventTrigger>
          <EventTrigger RoutedEvent="MouseLeave"><BeginStoryboard><Storyboard><DoubleAnimation Storyboard.TargetName="PS" Storyboard.TargetProperty="ScaleX" To="1" Duration="0:0:0.2"/><DoubleAnimation Storyboard.TargetName="PS" Storyboard.TargetProperty="ScaleY" To="1" Duration="0:0:0.2"/></Storyboard></BeginStoryboard></EventTrigger>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Background" Value="{DynamicResource ThemeAccent}"/><Setter TargetName="Bd" Property="BorderBrush" Value="Transparent"/><Setter Property="Foreground" Value="White"/></Trigger>
          <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.55"/></Trigger>
        </ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter></Style>
    <Style x:Key="SidebarBtn" TargetType="Button"><Setter Property="Background" Value="Transparent"/><Setter Property="Foreground" Value="{DynamicResource ThemeSub}"/>
      <Setter Property="Height" Value="44"/><Setter Property="FontSize" Value="15"/><Setter Property="Margin" Value="10,4"/><Setter Property="Padding" Value="16,0"/><Setter Property="Cursor" Value="Arrow"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
        <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="12" Padding="{TemplateBinding Padding}">
          <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
            <TextBlock x:Name="Ic" Grid.Column="0" FontFamily="Segoe MDL2 Assets" FontSize="16" Text="{TemplateBinding Tag}" Foreground="{TemplateBinding Foreground}" VerticalAlignment="Center" Margin="0,0,12,0"/>
            <ContentPresenter Grid.Column="1" VerticalAlignment="Center" HorizontalAlignment="Left"/></Grid></Border>
        <ControlTemplate.Triggers>
        </ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter></Style>
  </Window.Resources>
  <Grid>
    <Grid>
      <Rectangle>
        <Rectangle.Fill>
          <RadialGradientBrush Center="0.5,0.5" RadiusX="1.2" RadiusY="1.2">
            <GradientStop Color="#0B0515" Offset="0"/>
            <GradientStop Color="#020105" Offset="1"/>
          </RadialGradientBrush>
        </Rectangle.Fill>
      </Rectangle>
      <!-- Orbs -->
      <Ellipse Width="1000" Height="1000" Margin="-400,-400,0,0" HorizontalAlignment="Left" VerticalAlignment="Top" IsHitTestVisible="False">
        <Ellipse.Fill>
          <RadialGradientBrush>
            <GradientStop Color="#220066FF" Offset="0"/><GradientStop Color="#00000000" Offset="1"/>
          </RadialGradientBrush>
        </Ellipse.Fill>
      </Ellipse>
      <Ellipse Width="1200" Height="1200" Margin="0,0,-500,-500" HorizontalAlignment="Right" VerticalAlignment="Bottom" IsHitTestVisible="False">
        <Ellipse.Fill>
          <RadialGradientBrush>
            <GradientStop Color="#22B122E5" Offset="0"/><GradientStop Color="#00000000" Offset="1"/>
          </RadialGradientBrush>
        </Ellipse.Fill>
      </Ellipse>
      <Image x:Name="BgImage" Stretch="UniformToFill" Opacity="0.1"/>
    </Grid>
    <Border x:Name="MainBorder" Background="{DynamicResource ThemeBg}" CornerRadius="{StaticResource Rxl}" BorderBrush="{DynamicResource ThemeBorder}" BorderThickness="1" Margin="30,20" Effect="{StaticResource CardShadow}" Visibility="Collapsed" MaxWidth="1200" MaxHeight="850">
      <Border.LayoutTransform><ScaleTransform ScaleX="1.25" ScaleY="1.25"/></Border.LayoutTransform>
      <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="260"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
        <Border Grid.Column="0" Background="{DynamicResource ThemeSidebar}" CornerRadius="22,0,0,22" BorderBrush="{DynamicResource ThemeBorder}" BorderThickness="0,0,1,0">
          <Grid>
             <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
             <StackPanel Grid.Row="0" Orientation="Horizontal" VerticalAlignment="Center" Margin="30,40,30,30" HorizontalAlignment="Center">
               <Border Width="36" Height="36" CornerRadius="10" Background="{DynamicResource ThemeAccent}" HorizontalAlignment="Center" Margin="0,0,10,0" Effect="{StaticResource SoftGlow}">
                 <TextBlock Text="&#xE7F4;" FontFamily="Segoe MDL2 Assets" FontSize="18" Foreground="White" HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
               <TextBlock FontSize="20" FontWeight="SemiBold" VerticalAlignment="Center"><Run Text="Win" Foreground="White"/><Run Text="Flex" Foreground="{DynamicResource ThemeAccent}"/><Run Text="OS" Foreground="White"/></TextBlock></StackPanel>
             <ScrollViewer Grid.Row="1" HorizontalScrollBarVisibility="Disabled" VerticalScrollBarVisibility="Auto" Margin="0,0,0,20">
               <StackPanel x:Name="SideMenu" Orientation="Vertical"/></ScrollViewer>
             <StackPanel Grid.Row="2" Margin="20,0,20,30">
               <TextBlock x:Name="SideSub" Visibility="Collapsed"/><TextBlock x:Name="SideFooter" Visibility="Collapsed"/>
               <ComboBox x:Name="CmbTheme" Height="30" Margin="0,0,0,15" Padding="8,4"/>
               <StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
                 <Button x:Name="BtnLang" Content="EN" Margin="0,0,8,0" Width="40" Height="30" FontSize="12" Foreground="{DynamicResource ThemeSub}" Background="Transparent" BorderThickness="0" Cursor="Hand"/>
                 <Button x:Name="BtnMute" Content="Mute" Width="40" Height="30" FontSize="12" Foreground="{DynamicResource ThemeSub}" Background="Transparent" BorderThickness="0" Cursor="Hand"/>
               </StackPanel>
             </StackPanel>
          </Grid>
        </Border>
        <Grid Grid.Column="1">
          <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
          <StackPanel Grid.Row="0" Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,15,15,0" Panel.ZIndex="10">
              <Button x:Name="BtnMin" Content="&#xE921;" Style="{StaticResource WinCtrlBtn}" Width="30" Height="30" FontSize="10"/>
              <Button x:Name="BtnMax" Content="&#xE922;" Style="{StaticResource WinCtrlBtn}" Width="30" Height="30" FontSize="10"/>
              <Button x:Name="BtnClose" Content="&#xE8BB;" Style="{StaticResource CloseBtn}" Width="30" Height="30" FontSize="10"/></StackPanel>
          <Grid x:Name="MainArea" Grid.Row="1" Margin="30,20,30,20" IsEnabled="False" Opacity="0.6">
           <Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
             <Grid Grid.Row="0" Margin="0,0,0,20"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
               <StackPanel><TextBlock x:Name="TopTitle" Visibility="Collapsed"/><TextBlock x:Name="TopSub" Visibility="Collapsed"/>
                 <TextBlock x:Name="PageTitle" Text="Welcome" Foreground="{DynamicResource ThemeFg}" FontSize="28" FontWeight="SemiBold"/>
                 <TextBlock x:Name="PageDesc" Text="Select" Foreground="{DynamicResource ThemeSub}" FontSize="14" Margin="0,4,0,0" TextWrapping="Wrap"/></StackPanel>
               <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Bottom">
                 <Button x:Name="BtnSelectAll" Content="Select All" Padding="16,8" Margin="0,0,10,0" FontSize="13" Background="Transparent" Foreground="{DynamicResource ThemeAccent}" BorderBrush="{DynamicResource ThemeAccent}" BorderThickness="1" Cursor="Hand"/>
                 <Button x:Name="BtnDeselectAll" Content="Deselect" Padding="16,8" FontSize="13" Background="Transparent" Foreground="{DynamicResource ThemeSub}" BorderBrush="{DynamicResource ThemeBorder}" BorderThickness="1" Cursor="Hand"/></StackPanel></Grid>
             <Grid Grid.Row="1"><Grid x:Name="BrowsePanel"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                 <Border x:Name="SearchBoxBorder" Grid.Row="0" Background="{DynamicResource ThemeCard}" BorderBrush="{DynamicResource ThemeBorder}" BorderThickness="1" CornerRadius="10" Margin="0,0,0,16" Padding="12,8" Visibility="Collapsed">
                   <DockPanel><TextBlock Text="&#xE721;" FontFamily="Segoe MDL2 Assets" Foreground="{DynamicResource ThemeSub}" VerticalAlignment="Center" Margin="5,0,12,0" FontSize="16"/>
                     <TextBox x:Name="TxtSearch" Background="Transparent" BorderThickness="0" Foreground="{DynamicResource ThemeFg}" VerticalContentAlignment="Center" FontSize="15" CaretBrush="{DynamicResource ThemeAccent}"/></DockPanel></Border>
                 <Border x:Name="InternetBanner" Grid.Row="1" Background="#14202B" BorderBrush="{DynamicResource ThemeBorder}" BorderThickness="1" CornerRadius="{StaticResource Rm}" Padding="16" Margin="0,0,0,16" Visibility="Collapsed">
                   <DockPanel><ProgressBar IsIndeterminate="True" Width="140" Height="8" Margin="0,0,16,0" DockPanel.Dock="Left"/>
                     <TextBlock x:Name="InternetText" Text="Waiting..." Foreground="{DynamicResource ThemeFg}" VerticalAlignment="Center" FontSize="14"/></DockPanel></Border>
                 <ScrollViewer Grid.Row="2" VerticalScrollBarVisibility="Auto">
                   <StackPanel>
                     <ItemsControl x:Name="ItemsList">
                       <ItemsControl.ItemsPanel><ItemsPanelTemplate><WrapPanel Orientation="Horizontal" ItemWidth="280" ItemHeight="90"/></ItemsPanelTemplate></ItemsControl.ItemsPanel>
                     <ItemsControl.ItemTemplate><DataTemplate>
                         <CheckBox IsChecked="{Binding Selected}" Focusable="False" Margin="6" Cursor="Hand">
                           <CheckBox.Template><ControlTemplate TargetType="CheckBox">
                               <Border x:Name="CardBorder" Background="{DynamicResource ThemeCard2}" BorderBrush="{DynamicResource ThemeBorder}" BorderThickness="1" CornerRadius="12" Padding="16">
                                 <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                                   <StackPanel Grid.Column="0" VerticalAlignment="Center">
                                     <TextBlock Text="{Binding Name}" Foreground="{DynamicResource ThemeFg}" FontSize="15" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/>
                                     <TextBlock Text="{Binding Sub}" Foreground="{DynamicResource ThemeSub}" FontSize="12" Margin="0,4,0,0" TextTrimming="CharacterEllipsis"/></StackPanel>
                                   <Grid Grid.Column="1" Width="36" Height="20" VerticalAlignment="Center" Margin="10,0" FlowDirection="LeftToRight">
                                     <Border x:Name="ToggleBg" Background="{DynamicResource ThemeCard}" BorderBrush="{DynamicResource ThemeBorder}" BorderThickness="1" CornerRadius="10"/>
                                     <Ellipse x:Name="ToggleKnob" Width="12" Height="12" Fill="{DynamicResource ThemeSub}" HorizontalAlignment="Left" Margin="4,0,0,0"/></Grid></Grid></Border>
                               <ControlTemplate.Triggers>
                                 <Trigger Property="IsChecked" Value="True"><Setter TargetName="ToggleBg" Property="Background" Value="{DynamicResource ThemeAccent}"/><Setter TargetName="ToggleBg" Property="BorderBrush" Value="{DynamicResource ThemeAccent}"/><Setter TargetName="ToggleKnob" Property="Fill" Value="White"/><Setter TargetName="ToggleKnob" Property="HorizontalAlignment" Value="Right"/><Setter TargetName="ToggleKnob" Property="Margin" Value="0,0,4,0"/><Setter TargetName="CardBorder" Property="BorderBrush" Value="{DynamicResource ThemeAccent}"/><Setter TargetName="CardBorder" Property="Background" Value="#11B122E5"/></Trigger>
                                 <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="CardBorder" Property="Background" Value="{DynamicResource ThemeCard}"/></Trigger>
                               </ControlTemplate.Triggers></ControlTemplate></CheckBox.Template></CheckBox>
                       </DataTemplate></ItemsControl.ItemTemplate></ItemsControl>
                   </StackPanel></ScrollViewer>
                 <Border Grid.Row="3" Background="#111318" BorderBrush="{DynamicResource ThemeBorder}" BorderThickness="1" CornerRadius="{StaticResource Rm}" Padding="16,12" Margin="0,16,0,0">
                   <Grid>
                     <Grid.ColumnDefinitions>
                       <ColumnDefinition Width="Auto"/>
                       <ColumnDefinition Width="*"/>
                     </Grid.ColumnDefinitions>
                     <TextBlock x:Name="StatusText" Grid.Column="0" Text="Ready." Foreground="{DynamicResource ThemeSub}" VerticalAlignment="Center" FontSize="13" TextTrimming="CharacterEllipsis" Margin="0,0,16,0"/>
                     <ProgressBar x:Name="InstallProgress" Grid.Column="1" Height="8" Minimum="0" Maximum="100" Value="0" HorizontalAlignment="Stretch"/>
                   </Grid>
                 </Border></Grid>
               <Grid x:Name="AuditPanel" Visibility="Collapsed">
                 <Border Background="{DynamicResource ThemeCard}" BorderBrush="{DynamicResource ThemeBorder}" BorderThickness="1" CornerRadius="12" Padding="20" Margin="0,0,0,0">
                   <Grid>
                     <Grid.RowDefinitions>
                       <RowDefinition Height="*"/>
                       <RowDefinition Height="Auto"/>
                     </Grid.RowDefinitions>
                     <ScrollViewer Grid.Row="0" VerticalScrollBarVisibility="Auto">
                       <TextBlock x:Name="AuditTerminalText" FontFamily="Consolas" FontSize="14" Foreground="{DynamicResource ThemeFg}" TextWrapping="Wrap" LineHeight="22" FlowDirection="LeftToRight" TextAlignment="Left"/>
                     </ScrollViewer>
                     <StackPanel Grid.Row="1" Orientation="Horizontal" Margin="0,20,0,0" FlowDirection="LeftToRight" HorizontalAlignment="Left">
                       <TextBlock Text="Enter profile number (1-10):" Foreground="{DynamicResource ThemeFg}" FontSize="16" VerticalAlignment="Center" FontFamily="Consolas" Margin="0,0,10,0"/>
                       <TextBox x:Name="AuditInputBox" Width="80" Height="30" FontSize="16" FontFamily="Consolas" Background="{DynamicResource ThemeCard}" Foreground="{DynamicResource ThemeFg}" BorderBrush="{DynamicResource ThemeAccent}" BorderThickness="1" Padding="5,0" VerticalContentAlignment="Center"/>
                     </StackPanel>
                   </Grid>
                 </Border>
               </Grid>
               <Grid x:Name="InstallPanel" Visibility="Collapsed">
                 <StackPanel VerticalAlignment="Center" HorizontalAlignment="Center" Width="600">
                   <Border Width="80" Height="80" CornerRadius="25" Background="{DynamicResource ThemeAccent}" HorizontalAlignment="Center" Margin="0,0,0,30" Effect="{StaticResource SoftGlow}">
                     <TextBlock Text="&#xE896;" FontFamily="Segoe MDL2 Assets" FontSize="36" Foreground="White" HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
                   <TextBlock x:Name="InstTitle" Text="Installing..." Foreground="{DynamicResource ThemeFg}" FontSize="32" FontWeight="Bold" HorizontalAlignment="Center" Margin="0,0,0,10"/>
                   <TextBlock x:Name="InstAppName" Text="" Foreground="{DynamicResource ThemeAccent}" FontSize="24" FontWeight="SemiBold" HorizontalAlignment="Center" Margin="0,0,0,8"/>
                   <TextBlock x:Name="InstCount" Text="0 / 0" Foreground="{DynamicResource ThemeSub}" FontSize="16" HorizontalAlignment="Center" Margin="0,0,0,30"/>
                   <Border Background="{DynamicResource ThemeCard2}" CornerRadius="12" Padding="6" Margin="0,0,0,16">
                     <ProgressBar x:Name="InstProgressBig" Height="16" Minimum="0" Maximum="100" Value="0"/></Border>
                   <TextBlock x:Name="InstPct" Text="0%" Foreground="{DynamicResource ThemeFg}" FontSize="42" FontWeight="Bold" HorizontalAlignment="Center" Margin="0,0,0,16"/>
                   <TextBlock x:Name="InstStatus" Text="" Foreground="{DynamicResource ThemeSub}" FontSize="15" HorizontalAlignment="Center" TextWrapping="Wrap"/></StackPanel></Grid></Grid></Grid></Grid>
          <Border Grid.Row="2" Background="{DynamicResource ThemeCard}" CornerRadius="0,0,22,0" BorderBrush="{DynamicResource ThemeBorder}" BorderThickness="0,1,0,0" Padding="20,16">
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
              <Button x:Name="BtnBack" Content="Back" Padding="24,10" Margin="0,0,12,0" Style="{StaticResource PrimaryBtn}" FontSize="15"/>
              <Button x:Name="BtnNext" Content="Next" Padding="24,10" Style="{StaticResource PrimaryBtn}" FontSize="15"/></StackPanel></Border></Grid></Grid></Border>
    <Border x:Name="StartupOverlay" Visibility="Visible" Panel.ZIndex="100" Background="{DynamicResource ThemeBg}" CornerRadius="{StaticResource Rxl}" BorderBrush="{DynamicResource ThemeBorder}" BorderThickness="1" Margin="30,20" Effect="{StaticResource CardShadow}" MaxWidth="1200" MaxHeight="850">
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>
        
        <!-- Top Window Controls -->
        <Grid Grid.Row="0" Margin="20,15">
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Top">
            <Button x:Name="OvMute" Content="Mute" Margin="0,0,8,0" Height="30" FontSize="12" Foreground="{DynamicResource ThemeSub}" Background="Transparent" BorderThickness="0" Cursor="Hand"/>
            <Button x:Name="OvMin" Content="&#xE921;" Style="{StaticResource WinCtrlBtn}" Width="30" Height="30" FontSize="10"/>
            <Button x:Name="OvClose" Content="&#xE8BB;" Style="{StaticResource CloseBtn}" Width="30" Height="30" FontSize="10"/>
          </StackPanel>
        </Grid>
        
        <Grid Grid.Row="1" Margin="50,20,50,50">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="1.1*"/>
            <ColumnDefinition Width="0.9*"/>
          </Grid.ColumnDefinitions>
          
          <!-- Column 0 (Hero & Buttons) - Visual Right in RTL -->
          <StackPanel Grid.Column="0" VerticalAlignment="Center" Margin="0,0,40,0" HorizontalAlignment="Left">
            <TextBlock x:Name="WelcomeTitle" FontSize="76" FontWeight="Bold" Margin="0,0,0,10">
              <Run Text="Win" Foreground="White"/><Run Text="Flex" Foreground="{DynamicResource ThemeAccent}"/><Run Text="OS" Foreground="White"/>
            </TextBlock>
            <TextBlock x:Name="WelcomeDesc" Text="F L E X I B L E   &#x2022;   F A S T   &#x2022;   Y O U R S" Foreground="{DynamicResource ThemeAccent}" Opacity="0.9" FontSize="16" FontWeight="SemiBold" Margin="0,0,0,40"/>
            
            <Border Height="3" Width="60" Background="{DynamicResource ThemeAccent}" HorizontalAlignment="Left" CornerRadius="1.5" Margin="0,0,0,40"/>
            
            <TextBlock x:Name="WelcomeBodyTitle" Text="Welcome" Foreground="{DynamicResource ThemeFg}" FontSize="38" FontWeight="Bold" Margin="0,0,0,15"/>
            <TextBlock x:Name="WelcomeIntroText" Text="Loading..." Foreground="{DynamicResource ThemeSub}" TextWrapping="Wrap" FontSize="18" LineHeight="28" MaxWidth="500" HorizontalAlignment="Left"/>
            
            <!-- Footer Buttons -->
            <StackPanel Orientation="Horizontal" Margin="0,60,0,0">
              <Button x:Name="BtnContinue" Content="Get Started" Padding="50,18" Margin="0,0,20,0" Style="{StaticResource PrimaryBtn}" FontSize="18" FontWeight="Bold"/>
              <Button x:Name="BtnExitWelcome" Content="Exit" Padding="40,18" FontSize="18" FontWeight="SemiBold" Background="Transparent" Foreground="{DynamicResource ThemeSub}" BorderBrush="{DynamicResource ThemeBorder}" BorderThickness="1" Cursor="Hand"/>
            </StackPanel>
          </StackPanel>
          
          <!-- Column 1 (Cards) - Visual Left in RTL -->
          <StackPanel Grid.Column="1" VerticalAlignment="Center">
             <!-- About Card -->
             <Border x:Name="WelcomePanel" Background="{DynamicResource ThemeCard}" BorderBrush="{DynamicResource ThemeBorder}" BorderThickness="1" CornerRadius="16" Padding="30" Margin="0,0,0,25" Effect="{StaticResource CardShadow}">
                <StackPanel>
                   <StackPanel Orientation="Horizontal" Margin="0,0,0,15">
                      <Border Background="#20FF00FF" CornerRadius="10" Padding="8" Margin="0,0,15,0">
                         <TextBlock Text="&#xE9D5;" FontFamily="Segoe MDL2 Assets" FontSize="20" Foreground="{DynamicResource ThemeAccent}"/>
                      </Border>
                      <TextBlock x:Name="AboutTitleText" Text="About" Foreground="{DynamicResource ThemeFg}" FontSize="22" FontWeight="Bold" VerticalAlignment="Center"/>
                   </StackPanel>
                   <TextBlock x:Name="AboutBodyText" Text="Loading details..." Foreground="{DynamicResource ThemeSub}" TextWrapping="Wrap" FontSize="15" LineHeight="24"/>
                </StackPanel>
             </Border>
             
             <!-- Usage Card -->
             <Border Background="{DynamicResource ThemeCard2}" BorderBrush="{DynamicResource ThemeBorder}" BorderThickness="1" CornerRadius="16" Padding="30" Effect="{StaticResource CardShadow}">
                <StackPanel>
                   <StackPanel Orientation="Horizontal" Margin="0,0,0,15">
                      <Border Background="#2000FFFF" CornerRadius="10" Padding="8" Margin="0,0,15,0">
                         <TextBlock Text="&#xE9EE;" FontFamily="Segoe MDL2 Assets" FontSize="20" Foreground="#00FFFF"/>
                      </Border>
                      <TextBlock x:Name="UsageTitleText" Text="How to use" Foreground="{DynamicResource ThemeFg}" FontSize="22" FontWeight="Bold" VerticalAlignment="Center"/>
                   </StackPanel>
                   <TextBlock x:Name="UsageBodyText" Text="Loading steps..." Foreground="{DynamicResource ThemeSub}" TextWrapping="Wrap" FontSize="15" LineHeight="24"/>
                </StackPanel>
             </Border>
          </StackPanel>
          
          <TextBlock x:Name="HintText" Visibility="Collapsed"/>
          
          <!-- Hidden Preflight for compatibility -->
          <Border x:Name="PreflightPanel" Visibility="Collapsed">
             <StackPanel>
                <TextBlock x:Name="PreflightHeader"/>
                <TextBlock x:Name="PreflightStatus"/>
                <ProgressBar x:Name="PreflightBar"/>
                <TextBlock x:Name="PreflightPct"/>
             </StackPanel>
          </Border>
          <TextBlock x:Name="WelcomeFoot" Visibility="Collapsed"/>
        </Grid>
      </Grid>
    </Border>
    <Grid x:Name="IntroOverlay" Panel.ZIndex="200" Background="Black" Visibility="Collapsed">
      <MediaElement x:Name="IntroVideo" LoadedBehavior="Manual" UnloadedBehavior="Stop" Stretch="Uniform"/>
      <Button x:Name="BtnSkipIntro" Content="Skip Intro" HorizontalAlignment="Right" VerticalAlignment="Bottom" Margin="30" Padding="20,10" Background="#55000000" Foreground="White" BorderThickness="1" BorderBrush="White" Cursor="Hand" FontSize="16"/>
    </Grid>
  </Grid>
</Window>
"@

try {
    $reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
    $window = [Windows.Markup.XamlReader]::Load($reader)
} catch { throw "XAML load failed: $($_.Exception.Message)" }
function Find([string]$name) { $window.FindName($name) }

$BgImage=Find "BgImage"; $TopTitle=Find "TopTitle"; $TopSub=Find "TopSub"
$PageTitle=Find "PageTitle"; $PageDesc=Find "PageDesc"; $ItemsList=Find "ItemsList"
$InstallProgress=Find "InstallProgress"; $StatusText=Find "StatusText"
$InternetBanner=Find "InternetBanner"; $InternetText=Find "InternetText"
$BtnBack=Find "BtnBack"; $BtnNext=Find "BtnNext"
$BtnLang=Find "BtnLang"; $BtnMute=Find "BtnMute"; $BtnMin=Find "BtnMin"
$BtnMax=Find "BtnMax"; $BtnClose=Find "BtnClose"; $SideMenu=Find "SideMenu"
$AuditPanel=Find "AuditPanel"; $AuditTerminalText=Find "AuditTerminalText"; $AuditInputBox=Find "AuditInputBox"
$SideSub=Find "SideSub"; $SideFooter=Find "SideFooter"; $CmbTheme=Find "CmbTheme"
$MainBorder=Find "MainBorder"; $MainArea=Find "MainArea"; $StartupOverlay=Find "StartupOverlay"
$BrowsePanel=Find "BrowsePanel"; $InstallPanel=Find "InstallPanel"
$InstTitle=Find "InstTitle"; $InstAppName=Find "InstAppName"; $InstCount=Find "InstCount"
$InstProgressBig=Find "InstProgressBig"; $InstPct=Find "InstPct"; $InstStatus=Find "InstStatus"
$WelcomeTitle=Find "WelcomeTitle"; $WelcomeDesc=Find "WelcomeDesc"
$WelcomePanel=Find "WelcomePanel"; $WelcomeBodyTitle=Find "WelcomeBodyTitle"
$WelcomeIntroText=Find "WelcomeIntroText"; $AboutTitleText=Find "AboutTitleText"
$AboutBodyText=Find "AboutBodyText"; $UsageTitleText=Find "UsageTitleText"
$UsageBodyText=Find "UsageBodyText"; $HintText=Find "HintText"
$PreflightPanel=Find "PreflightPanel"
$PreflightHeader=Find "PreflightHeader"; $PreflightStatus=Find "PreflightStatus"
$PreflightBar=Find "PreflightBar"; $PreflightPct=Find "PreflightPct"
$BtnContinue=Find "BtnContinue"; $BtnExitWelcome=Find "BtnExitWelcome"; $WelcomeFoot=Find "WelcomeFoot"
$BtnSelectAll=Find "BtnSelectAll"; $BtnDeselectAll=Find "BtnDeselectAll"
$OvMin=Find "OvMin"; $OvClose=Find "OvClose"; $OvMute=Find "OvMute"
$TxtSearch=Find "TxtSearch"; $SearchBoxBorder=Find "SearchBoxBorder"
$IntroOverlay=Find "IntroOverlay"; $IntroVideo=Find "IntroVideo"; $BtnSkipIntro=Find "BtnSkipIntro"

if (Test-Path -LiteralPath $backgroundImagePath) {
    try { $bmp=New-Object System.Windows.Media.Imaging.BitmapImage; $bmp.BeginInit(); $bmp.CacheOption=[System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad; $bmp.UriSource=[Uri]::new("file:///$backgroundImagePath"); $bmp.EndInit(); $BgImage.Source=$bmp } catch {} }
# Log labels removed

$MainBorder.Add_MouseLeftButtonDown({ try { if ($_.ClickCount -eq 2) { if ($window.WindowState -eq 'Maximized') { $window.WindowState='Normal' } else { $window.WindowState='Maximized' } } else { $window.DragMove() } } catch {} })
$BtnClose.Add_Click({ $window.Close() }); $OvClose.Add_Click({ $window.Close() })
$BtnMin.Add_Click({ $window.WindowState='Minimized' }); $OvMin.Add_Click({ $window.WindowState='Minimized' })
$BtnMax.Add_Click({ if ($window.WindowState -eq 'Maximized') { $window.WindowState='Normal' } else { $window.WindowState='Maximized' } })
$MuteHandler = { 
    Toggle-Mute
    $text = $(if ($script:isMuted) { (L (-join([char]0x05D1,[char]0x05D8,[char]0x05DC,[char]0x0020,[char]0x05D4,[char]0x05E9,[char]0x05EA,[char]0x05E7,[char]0x05D4)) "Unmute") } 
            else { (L (-join([char]0x05D4,[char]0x05E9,[char]0x05EA,[char]0x05E7)) "Mute") })
    $BtnMute.Content = $text
    $OvMute.Content = $text
}
$BtnMute.Add_Click($MuteHandler)
$OvMute.Add_Click($MuteHandler)

foreach ($t in $script:Themes) { [void]$CmbTheme.Items.Add($t.Name) }; $CmbTheme.SelectedIndex=0
function Apply-ThemeByName([string]$Name) {
    $t=$script:Themes|Where-Object{$_.Name -eq $Name}|Select-Object -First 1; if(-not $t){return}
    function SetBrush([string]$key,[string]$hex){$bc=New-Object System.Windows.Media.BrushConverter;$brush=[System.Windows.Media.Brush]$bc.ConvertFromString($hex);$brush.Freeze();$window.Resources[$key]=$brush}
    SetBrush "ThemeBg" $t.Bg; SetBrush "ThemeSidebar" $t.Sidebar; SetBrush "ThemeCard" $t.Card; SetBrush "ThemeCard2" $t.Card2
    SetBrush "ThemeFg" $t.Fg; SetBrush "ThemeSub" $t.Sub; SetBrush "ThemeAccent" $t.Accent; SetBrush "ThemeBorder" $t.Border
}
$CmbTheme.Add_SelectionChanged({ Apply-ThemeByName ([string]$CmbTheme.SelectedItem) }); Apply-ThemeByName ([string]$CmbTheme.SelectedItem)

function New-ItemVm($item) {
    $sub=if($item.IsTweak){"System Tweak"}elseif($item.WingetId){"winget: $($item.WingetId)"}elseif($item.Path){"file: $($item.Path)"}else{""}
    $sel=$false
    [pscustomobject]@{Name=$item.Name;Sub=$sub;Raw=$item;Selected=$sel}
}
$script:CurrentCategoryIndex=0; $script:CategoryVms=@(); $script:IsInstallPhase=$false
function Initialize-CategoryVms {
    $script:CategoryVms=@()
    foreach($cat in $script:Categories){$script:CategoryVms+=,(@($cat.Items|ForEach-Object{New-ItemVm $_}))}
}

function Get-CategorySelectedCount([int]$idx) { $c=0; foreach($vm in $script:CategoryVms[$idx]){if($vm.Selected){$c++}}; return $c }
function Get-TotalSelectedCount { $c=0; for($i=0;$i -lt $script:CategoryVms.Count;$i++){$c+=(Get-CategorySelectedCount $i)}; return $c }

function Apply-Language {
    $script:isHe = ($script:Lang -eq "he")
    $BtnLang.Content = $(if ($script:isHe) { "EN" } else { "HE" })
    
    $BtnMute.Content = $(if ($script:isMuted) { (L (He @(0x05D1,0x05D8,0x05DC,0x0020,0x05D4,0x05E9,0x05EA,0x05E7,0x05D4)) "Unmute") } else { (L (He @(0x05D4,0x05E9,0x05EA,0x05E7)) "Mute") })
    $BtnBack.Content = $(L (He @(0x05D4,0x05E7,0x05D5,0x05D3,0x05DD)) "Back")
    $BtnNext.Content = $(L (He @(0x05D4,0x05D1,0x05D0)) "Next")
    $TopSub.Text = $(L (He @(0x05D1,0x05D7,0x05E8,0x20,0x05EA,0x05D5,0x05DB,0x05E0,0x05D5,0x05EA,0x20,0x05DC,0x05D4,0x05EA,0x05E7,0x05E0,0x05D4)) "Choose apps to install")
    $SideSub.Text = $(L (He @(0x05EA,0x05E4,0x05E8,0x05D9,0x05D8,0x20,0x05D4,0x05EA,0x05E7,0x05E0,0x05D4)) "Installation menu")
    $StatusText.Text = $(L (He @(0x05DE,0x05D5,0x05DB,0x05DF,0x2E)) "Ready.")
    $InternetText.Text = $(L (He @(0x5DE,0x5DE,0x5EA,0x5D9,0x5E0,0x5D9,0x5DD,0x20,0x5DC,0x5D0,0x5D9,0x5E0,0x5D8,0x5E8,0x5E0,0x5D8,0x2E,0x2E,0x2E)) "Waiting for internet...")
    $BtnSelectAll.Content = $(L (He @(0x05D1,0x05D7,0x05E8,0x20,0x05D4,0x05DB,0x05DC)) "Select All")
    $BtnDeselectAll.Content = $(L (He @(0x05D1,0x05D8,0x05DC,0x05D4,0x05DB,0x05DC)) "Deselect All")
    $BtnContinue.Content = $(L (He @(0x05D4,0x05D1,0x05D0)) "Next")
    $BtnExitWelcome.Content = $(L (He @(0x05DC,0x05D0,0x20,0x05DE,0x05E2,0x05D5,0x05E0,0x05D9,0x05D9,0x05DF)) "No thanks")
    
    $userName = $env:USERNAME
    $wGreHe = (He @(0x05E9, 0x05DC, 0x05D5, 0x05DD, 0x20)) + $userName
    $wTitleHe = He @(0x05D1,0x05E8,0x05D5,0x05DB,0x05D9,0x05DD,0x20,0x05D4,0x05D1,0x05D0,0x05D9,0x05DD,0x20,0x05DC,0x2D,0x57,0x69,0x6E,0x46,0x6C,0x65,0x78,0x4F,0x53)
    $wDescHe = He @(0x05D4,0x05D2,0x05E8,0x05E1,0x05D4,0x20,0x05E9,0x05DC,0x05DA,0x2C,0x20,0x05D4,0x05E9,0x05DC,0x05D9,0x05D8,0x05D4,0x20,0x05E9,0x05DC,0x05DA,0x2E)
    # $WelcomeTitle.Text = $(L $wTitleHe "Welcome to WinFlexOS")
    $WelcomeDesc.Text = $(L $wGreHe ("Hello " + $userName))
    
    $window.FlowDirection = $(if ($script:isHe) { "RightToLeft" } else { "LeftToRight" })
}
$BtnLang.Add_Click({ $script:Lang=$(if($script:Lang -eq "he"){"en"}else{"he"}); Apply-Language; Render-SideMenu; Show-Category })

$TxtSearch.Add_KeyDown({
    if ($_.Key -eq 'Return' -or $_.Key -eq 'Enter') {
        $val = $TxtSearch.Text.Trim()
        if ($val -ne "") {
            $newItem = [pscustomobject]@{Name=$val; Sub="winget: $val"; Raw=@{Name=$val; WingetId=$val; IsCustom=$true}; Selected=$true}
            $script:CategoryVms[$script:CurrentCategoryIndex] += $newItem
            $ItemsList.ItemsSource = $null
            $ItemsList.ItemsSource = $script:CategoryVms[$script:CurrentCategoryIndex]
            $TxtSearch.Text = ""
            Render-SideMenu
        }
    }
})

$script:SideButtons=@()
function Render-SideMenu {
    $SideMenu.Children.Clear(); $script:SideButtons=@()
    for($i=0;$i -lt $script:Categories.Count;$i++){
        $cat=$script:Categories[$i]; $cnt=Get-CategorySelectedCount $i
        $label=(L $cat.TitleHe $cat.TitleEn); if($cnt -gt 0){$label+=" ($cnt)"}
        $btn=New-Object System.Windows.Controls.Button
        $btn.Content=$label; $btn.Tag=$cat.Icon; $btn.Uid=$i.ToString(); $btn.Style=$window.FindResource("SidebarBtn")
        $btn.IsHitTestVisible = $false
        $SideMenu.Children.Add($btn)|Out-Null; $script:SideButtons+=$btn
    }
    for($j=0;$j -lt $script:SideButtons.Count;$j++){
        $b=$script:SideButtons[$j]
        if($j -eq $script:CurrentCategoryIndex){$b.Foreground=$window.Resources["ThemeFg"];$b.Background=New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#15222E"))}
        else{$b.Foreground=$window.Resources["ThemeSub"];$b.Background=[System.Windows.Media.Brushes]::Transparent}
    }
}
function Show-Category {
    $script:IsInstallPhase=$false; $cat=$script:Categories[$script:CurrentCategoryIndex]
    $PageTitle.Text=(L $cat.TitleHe $cat.TitleEn)
    $PageDesc.Text=(L (-join([char]0x05D1,[char]0x05D7,[char]0x05E8,[char]0x0020,[char]0x05DE,[char]0x05D4,[char]0x0020,[char]0x05DC,[char]0x05D4,[char]0x05EA,[char]0x05E7,[char]0x05D9,[char]0x05DF,[char]0x002E)) "Select what to install.")
    $ItemsList.ItemsSource=$script:CategoryVms[$script:CurrentCategoryIndex]
    if($cat.Key -eq "custom"){$SearchBoxBorder.Visibility='Visible'}else{$SearchBoxBorder.Visibility='Collapsed'}
    $InstallPanel.Visibility='Collapsed'
    if ($cat.Key -eq "audit") {
        $BrowsePanel.Visibility='Collapsed'
        $AuditPanel.Visibility='Visible'
        Get-SystemHardwareAudit
    } else {
        $BrowsePanel.Visibility='Visible'
        $AuditPanel.Visibility='Collapsed'
    }
    $InstallProgress.Value=0; $StatusText.Text=(L (-join([char]0x05DE,[char]0x05D5,[char]0x05DB,[char]0x05DF,[char]0x002E)) "Ready.")
    $BtnBack.IsEnabled=$true; $BtnNext.IsEnabled=$true; Render-SideMenu
}
function Get-SelectedSoftware { $sel=New-Object System.Collections.Generic.List[object]; for($i=0;$i -lt $script:CategoryVms.Count;$i++){foreach($vm in $script:CategoryVms[$i]){if($vm.Selected){$sel.Add($vm.Raw)}}}; return $sel }

$BtnSelectAll.Add_Click({ foreach($vm in $script:CategoryVms[$script:CurrentCategoryIndex]){$vm.Selected=$true}; $ItemsList.ItemsSource=$null; $ItemsList.ItemsSource=$script:CategoryVms[$script:CurrentCategoryIndex]; Render-SideMenu })
$BtnDeselectAll.Add_Click({ foreach($vm in $script:CategoryVms[$script:CurrentCategoryIndex]){$vm.Selected=$false}; $ItemsList.ItemsSource=$null; $ItemsList.ItemsSource=$script:CategoryVms[$script:CurrentCategoryIndex]; Render-SideMenu })

function Start-InstallPhase {
    $selected=@(Get-SelectedSoftware)
    if ($AuditInputBox -and $AuditInputBox.Text -match "^([1-9]|1[0-3])$") {
        $tId = "AuditProfile" + $AuditInputBox.Text
        $tName = "Profile $tId"
        $selected += [pscustomobject]@{ Name = $tName; TweakId = $tId; IsTweak = $true }
    }
    if($selected.Count -eq 0){$StatusText.Text=(L (He @(0x05DC,0x05D0,0x0020,0x05E0,0x05D1,0x05D7,0x05E8,0x0020,0x05DB,0x05DC,0x05D5,0x05DD,0x002E)) "Nothing selected.");return}
    $script:IsInstallPhase=$true; $BrowsePanel.Visibility='Collapsed'; $AuditPanel.Visibility='Collapsed'; $InstallPanel.Visibility='Visible'
    $PageTitle.Text=(L (He @(0x05DE,0x05EA,0x05E7,0x05D9,0x05DF,0x0020,0x05EA,0x05D5,0x05DB,0x05E0,0x05D5,0x05EA,0x002E,0x002E,0x002E)) "Installing..."); $PageDesc.Text=(L (He @(0x05D0,0x05E0,0x05D0,0x0020,0x05D4,0x05DE,0x05EA,0x05DF,0x002E,0x002E,0x002E)) "Please wait...")
    $BtnBack.IsEnabled=$false; $BtnNext.IsEnabled=$false; $window.Dispatcher.Invoke([action]{},"Background")

    $tweaks = @($selected | Where-Object { $_.IsTweak })
    $softwares = @($selected | Where-Object { -not $_.IsTweak })

    if ($tweaks.Count -gt 0) {
        $InstTitle.Text=(L (He @(0x05DE,0x05E0,0x05E7,0x05D4,0x0020,0x05D5,0x05DE,0x05D9,0x05D9,0x05E2,0x05DC,0x002E,0x002E,0x002E)) "Cleaning and optimizing...")
        $total=$tweaks.Count
        for($i=0;$i -lt $total;$i++){
            $sw=$tweaks[$i]; $name=$sw.Name
            $InstAppName.Text=$name; $InstCount.Text="$($i+1) / $total"
            $InstPct.Text="$([int](($i*100)/$total))%"; $InstProgressBig.Value=[int](($i*100)/$total)
            $InstStatus.Text=(L ((He @(0x05DE,0x05D1,0x05E6,0x05E2,0x003A,0x0020))+$name) "Applying: $name"); $window.Dispatcher.Invoke([action]{},"Background")
            try{ Write-Log "Tweak start: $name"
                Invoke-SystemTweak $sw.TweakId
                Write-Log "Tweak success: $name"
            }catch{Write-Log "Tweak failed: $name :: $($_.Exception.Message)"}
        }
    }

    if ($softwares.Count -gt 0) {
        $InstTitle.Text=(L (He @(0x05DE,0x05EA,0x05E7,0x05D9,0x05DF,0x0020,0x05EA,0x05D5,0x05DB,0x05E0,0x05D5,0x05EA,0x002E,0x002E,0x002E)) "Installing software...")
        $InstAppName.Text=""; $InstCount.Text=""; $InstStatus.Text=""; $InstProgressBig.Value=0; $InstPct.Text="0%"
        $hasWinget=[bool](Get-Command winget -ErrorAction SilentlyContinue)
        if(-not $hasWinget){
            Write-Log "winget missing"; $InstAppName.Text="Winget"
            $InstStatus.Text=(L (He @(0x05DE,0x05EA,0x05E7,0x05D9,0x05DF,0x0020,0x0057,0x0069,0x006E,0x0067,0x0065,0x0074,0x002E,0x002E,0x002E)) "Installing Winget..."); $window.Dispatcher.Invoke([action]{},"Background")
            $tmpDir=Join-Path $env:TEMP "winget-install"; New-Item -ItemType Directory -Force -Path $tmpDir -ErrorAction SilentlyContinue|Out-Null
            $bundle=Join-Path $tmpDir "Microsoft.DesktopAppInstaller.msixbundle"
            try{(New-Object Net.WebClient).DownloadFile("https://aka.ms/getwinget",$bundle)}catch{}
            try{Add-AppxPackage -Path $bundle -ErrorAction SilentlyContinue|Out-Null}catch{}; Start-Sleep -Seconds 2 }
        $total=$softwares.Count
        for($i=0;$i -lt $total;$i++){
            $sw=$softwares[$i]; $name=$sw.Name
            $InstAppName.Text=$name; $InstCount.Text="$($i+1) / $total"
            $InstPct.Text="$([int](($i*100)/$total))%"; $InstProgressBig.Value=[int](($i*100)/$total)
            $InstStatus.Text=(L ((He @(0x05DE,0x05EA,0x05E7,0x05D9,0x05DF,0x003A,0x0020))+$name) "Installing: $name"); $window.Dispatcher.Invoke([action]{},"Background")
            try{ Write-Log "Install start: $name"
                if($sw.IsCustom) { Invoke-WingetInstall $sw.WingetId $false }
                elseif($sw.WingetId){Invoke-WingetInstall $sw.WingetId}
                elseif($sw.Path){if(-not(Test-Path -LiteralPath $sw.Path)){throw "Not found: $($sw.Path)"};Start-Process -FilePath $sw.Path -Wait}
                else{throw "Unknown method"}; Write-Log "Install success: $name"
            }catch{Write-Log "Install failed: $name :: $($_.Exception.Message)"}
        }
    }
    
    $InstProgressBig.Value=100; $InstPct.Text="100%"
    $InstTitle.Text=(L (He @(0x05D4,0x05D5,0x05E9,0x05DC,0x05DD,0x05D5,0x0021)) "Completed!"); $InstAppName.Text=(L (He @(0x05DB,0x05DC,0x0020,0x05D4,0x05EA,0x05D5,0x05DB,0x05E0,0x05D5,0x05EA,0x0020,0x05D4,0x05D5,0x05EA,0x05E7,0x05E0,0x05D5,0x002E)) "All software installed.")
    $InstCount.Text=""; $InstStatus.Text=(L (He @(0x05D1,0x05D3,0x05D5,0x05E7,0x0020,0x05DC,0x05D5,0x05D2,0x002E)) "Check log.")
    $PageTitle.Text=(L (He @(0x05D4,0x05D5,0x05E9,0x05DC,0x05DD,0x05D5,0x0021)) "Completed."); $PageDesc.Text=(L (He @(0x05DB,0x05DC,0x0020,0x05D4,0x05EA,0x05D5,0x05DB,0x05E0,0x05D5,0x05EA,0x05D4,0x05D5,0x05EA,0x05E7,0x05E0,0x05D5,0x002E)) "All software installed.")
    $BtnBack.IsEnabled=$true; $BtnNext.IsEnabled=$false
}

function Set-PreflightUI([int]$pct,[string]$msg) { if($pct -lt 0){$pct=0}; if($pct -gt 100){$pct=100}; $PreflightBar.Value=$pct; $PreflightPct.Text="$pct%"; $PreflightStatus.Text=$msg }
function Run-PreflightAsync {
    if($script:preflightTimer){try{$script:preflightTimer.Stop()}catch{};$script:preflightTimer=$null}
    $BtnContinue.IsEnabled=$false; $BtnExitWelcome.IsEnabled=$false
    $script:preflightPhase="ping"; $script:preflightPingIdx=0; $script:preflightPingOk=0
    $script:preflightWingetPs=$null; $script:preflightWingetAsync=$null; $script:preflightWingetTick=0
    Write-Log "Preflight: starting ICMP ping sequence"
    Set-PreflightUI 2 (L (-join([char]0x05E9,[char]0x05D5,[char]0x05DC,[char]0x05D7,[char]0x0020,[char]0x0070,[char]0x0069,[char]0x006E,[char]0x0067)) "Starting ping...")
    $script:preflightTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:preflightTimer.Interval = [TimeSpan]::FromMilliseconds(450)
    $script:preflightTimer.Add_Tick({
        try {
            if ($script:preflightPhase -eq "ping") {
                if ($script:preflightPingIdx -lt 4) {
                    $n=$script:preflightPingIdx+1; $pct=[int](5+[Math]::Round($n*30/4)); $line=""
                    $p=New-Object System.Net.NetworkInformation.Ping
                    try { $r=$p.Send("1.1.1.1",4000)
                        if($r.Status -eq [System.Net.NetworkInformation.IPStatus]::Success){$script:preflightPingOk++;$ttl=$(if($null -ne $r.Options){$r.Options.Ttl}else{"?"});$line="Reply: time=$($r.RoundtripTime)ms TTL=$ttl"}
                        else{$line="Ping $n/4: $($r.Status)"} } catch { $line="Ping error" } finally { $p.Dispose() }
                    Set-PreflightUI $pct "Ping ($n/4) - $line"; $script:preflightPingIdx++; return }
                if ($script:preflightPingOk -lt 1) { Set-PreflightUI 36 (L (-join([char]0x05D0,[char]0x05D9,[char]0x05DF,[char]0x0020,[char]0x05EA,[char]0x05E9,[char]0x05D5,[char]0x05D3,[char]0x05D4,[char]0x002E)) "No reply.") }
                else { Set-PreflightUI 36 (L (-join([char]0x0050,[char]0x0069,[char]0x006E,[char]0x0067,[char]0x0020,[char]0x05D4,[char]0x05E6,[char]0x05DC,[char]0x05D7,[char]0x05D3,[char]0x002E)) "Ping OK.") }
                $script:preflightPhase="menu"
                return
            }
            if ($script:preflightPhase -eq "menu") {
                Set-PreflightUI 40 (L (-join([char]0x05DE,[char]0x05D5,[char]0x05E8,0x05D9,0x05D3,0x20,0x05EA,0x05E4,0x05E8,0x05D9,0x05D8,0x2E,0x2E,0x2E)) "Loading local menu...")
                try {
                    if ($MenuPath -and (Test-Path -LiteralPath $MenuPath)) { . $MenuPath } else { Initialize-WFMenuData }
                    if ($script:Categories) {
                        Initialize-CategoryVms
                        Render-SideMenu
                        Show-Category
                        Play-Sound
                        Write-Log "Preflight: menu loaded successfully"
                    } else {
                        throw "The built-in menu could not be loaded"
                    }
                    $script:preflightPhase="winget"
                    $ps=[PowerShell]::Create()
                    $ps.AddScript({param($LogPath);function Write-Log([string]$Message){$ts=(Get-Date).ToString("yyyy-MM-dd HH:mm:ss");try{Add-Content -Path $LogPath -Value "[$ts] $Message" -Encoding UTF8}catch{}};function Test-Winget{[bool](Get-Command winget -ErrorAction SilentlyContinue)};function Install-Winget{if(Test-Winget){return $true};$tmpDir=Join-Path $env:TEMP "winget-install";New-Item -ItemType Directory -Force -Path $tmpDir|Out-Null;$bundle=Join-Path $tmpDir "Microsoft.DesktopAppInstaller.msixbundle";(New-Object Net.WebClient).DownloadFile("https://aka.ms/getwinget",$bundle);Add-AppxPackage -Path $bundle -ErrorAction Stop|Out-Null;Start-Sleep -Seconds 2;return(Test-Winget)};Write-Log "Preflight: ensuring winget...";if(-not(Install-Winget)){throw "winget installation failed"};Write-Log "Preflight: OK";return $true}).AddArgument($script:LogPath)|Out-Null
                    $script:preflightWingetPs=$ps; $script:preflightWingetAsync=$ps.BeginInvoke(); return
                } catch {
                    Set-PreflightUI 0 (L ((-join([char]0x05E9,[char]0x05D2,[char]0x05D9,[char]0x05D0,[char]0x05D4,[char]0x003A,[char]0x0020))+$_.Exception.Message) ("Error: "+$_.Exception.Message))
                    $script:preflightTimer.Stop()
                    $BtnContinue.IsEnabled=$true
                    return
                }
            }
            if ($script:preflightPhase -eq "winget") {
                $wa=$script:preflightWingetAsync; if(-not $wa){return}; $script:preflightWingetTick++
                $cap=[Math]::Min(94,38+[Math]::Min(50,$script:preflightWingetTick))
                Set-PreflightUI $cap (L (-join([char]0x05DE,[char]0x05DB,[char]0x05D9,[char]0x05DF,[char]0x0020,[char]0x0077,[char]0x0069,[char]0x0065,[char]0x0067)) "Preparing winget...")
                if($wa.IsCompleted){$script:preflightTimer.Stop()
                    try{$null=$script:preflightWingetPs.EndInvoke($script:preflightWingetAsync)
                        Set-PreflightUI 100 (L (-join([char]0x05D1,[char]0x05D3,[char]0x05D9,[char]0x05E7,[char]0x05D5,[char]0x05EA,[char]0x0020,[char]0x05D4,[char]0x05D5,[char]0x05E9,[char]0x05DC,[char]0x05DE,[char]0x05D5,[char]0x002E)) "Checks complete.")
                        $StartupOverlay.Visibility='Collapsed'; $MainBorder.Visibility='Visible'; $MainArea.IsEnabled=$true;$MainArea.Opacity=1
                    }catch{Set-PreflightUI 0 (L ((-join([char]0x05E9,[char]0x05D2,[char]0x05D9,[char]0x05D0,[char]0x05D4,[char]0x003A,[char]0x0020))+$_.Exception.Message) ("Error: "+$_.Exception.Message));$BtnContinue.IsEnabled=$true}
                    finally{if($script:preflightWingetPs){$script:preflightWingetPs.Dispose()};$script:preflightWingetPs=$null;$script:preflightWingetAsync=$null} } }
        } catch {} })
    $script:preflightTimer.Start()
}

$BtnContinue.Add_Click({$WelcomePanel.Visibility='Collapsed';$PreflightPanel.Visibility='Visible';$BtnContinue.IsEnabled=$false;Run-PreflightAsync})
$BtnExitWelcome.Add_Click({$window.Close()})
$BtnBack.Add_Click({if($script:IsInstallPhase){$script:CurrentCategoryIndex=$script:Categories.Count-1;Show-Category}elseif($script:CurrentCategoryIndex -gt 0){$script:CurrentCategoryIndex--;Show-Category}})
$BtnNext.Add_Click({
    if($script:IsInstallPhase){return}
    if($script:CurrentCategoryIndex -lt ($script:Categories.Count-1)){$script:CurrentCategoryIndex++;Show-Category}
    else{Start-InstallPhase}
})

Apply-Language
$userName = $env:USERNAME

# Helper to decode Hebrew numeric arrays (and emojis)
function He { 
    param($arr) 
    $out = ""
    foreach($v in $arr) {
        if ($v -gt 0xFFFF) { $out += [char]::ConvertFromUtf32($v) }
        else { $out += [char]$v }
    }
    return $out
}

# Title and Description
#    -WinFlexOS
$wTitHe = He @(0x1F680, 0x20, 0x5D1, 0x5E8, 0x5D5, 0x5DB, 0x5D9, 0x5DD, 0x20, 0x5D4, 0x5D1, 0x5D0, 0x5D9, 0x5DD, 0x20, 0x5DC, 0x2D, 0x57, 0x69, 0x6E, 0x46, 0x6C, 0x65, 0x78, 0x4F, 0x53)
# $WelcomeTitle.Text = L $wTitHe " Welcome to WinFlexOS"

#  .  .
$wDesHe = He @(0x5D4, 0x5D2, 0x5E8, 0x5E1, 0x5D4, 0x20, 0x5E9, 0x5DC, 0x5DA, 0x2E, 0x20, 0x5D4, 0x5E9, 0x5DC, 0x5D9, 0x5D8, 0x5D4, 0x20, 0x5E9, 0x5DC, 0x5DA, 0x2E)
# $WelcomeDesc.Text = L $wDesHe "Your version. Your control."

#  []
$wGreHe = (He @(0x5E9, 0x5DC, 0x5D5, 0x5DD, 0x20)) + $userName
$WelcomeBodyTitle.Text = L $wGreHe "Hello $userName"

# Large Body Text - Broken into chunks for safety
$b1 = He @(0x05D1, 0x05E8, 0x05D5, 0x05DB, 0x05D9, 0x05DD, 0x0020, 0x05D4, 0x05D1, 0x05D0, 0x05D9, 0x05DD, 0x0020, 0x05DC, 0x002D, 0x0057, 0x0069, 0x006E, 0x0046, 0x006C, 0x0065, 0x0078, 0x004F, 0x0053, 0x0021, 0x000A)
$b2 = He @(0x05DC, 0x05E8, 0x05E9, 0x05D5, 0x05EA, 0x05DB, 0x05DD, 0x0020, 0x05EA, 0x05E4, 0x05E8, 0x05D9, 0x05D8, 0x0020, 0x05D4, 0x05EA, 0x05E7, 0x05E0, 0x05D5, 0x05EA, 0x0020, 0x05DE, 0x05D5, 0x05E8, 0x05D7, 0x05D1, 0x000A)
$b3 = He @(0x05E9, 0x05EA, 0x05E4, 0x05E7, 0x05D9, 0x05D3, 0x05D5, 0x0020, 0x05DC, 0x05D0, 0x05E4, 0x05E9, 0x05E8, 0x0020, 0x05DC, 0x05DB, 0x05DD, 0x0020, 0x05E9, 0x05DC, 0x05D9, 0x05D8, 0x05D4, 0x0020, 0x05DE, 0x05DC, 0x05D0, 0x05D4, 0x0020, 0x05E2, 0x05DC, 0x0020, 0x05DE, 0x05D4, 0x0020, 0x05E9, 0x05DE, 0x05D5, 0x05EA, 0x05E7, 0x05DF, 0x002E, 0x000A, 0x000A)
$b4 = He @(0xD83D, 0xDEE0, 0xFE0F, 0x0020, 0x05E2, 0x05DC, 0x0020, 0x05D4, 0x05DE, 0x05E2, 0x05E8, 0x05DB, 0x05EA, 0x000A, 0x000A)
$b5 = He @(0x0057, 0x0069, 0x006E, 0x0046, 0x006C, 0x0065, 0x0078, 0x004F, 0x0053, 0x0020, 0x05D4, 0x05D9, 0x05D0, 0x0020, 0x05DC, 0x05D0, 0x0020, 0x05E1, 0x05EA, 0x05DD, 0x0020, 0x05E2, 0x05D5, 0x05D3, 0x0020, 0x05D4, 0x05EA, 0x05E7, 0x05E0, 0x05D4, 0x002E, 0x0020, 0x05D4, 0x05D9, 0x05D0, 0x0020, 0x05E4, 0x05E8, 0x05D5, 0x05D9, 0x05E7, 0x05D8, 0x0020, 0x05E9, 0x05DC, 0x0020, 0x05D0, 0x05D5, 0x05E4, 0x05D8, 0x05D9, 0x05DE, 0x05D9, 0x05D6, 0x05E6, 0x05D9, 0x05D4, 0x0020, 0x05D5, 0x05D3, 0x05D9, 0x05D5, 0x05E7, 0x003A, 0x000A, 0x000A)
$b6 = He @(0x2022, 0x0020, 0x05D1, 0x05D9, 0x05E6, 0x05D5, 0x05E2, 0x05D9, 0x05DD, 0x0020, 0x05DE, 0x05E7, 0x05E1, 0x05D9, 0x05DE, 0x05DC, 0x05D9, 0x05D9, 0x05DD, 0x003A, 0x0020, 0x05D4, 0x05E1, 0x05E8, 0x05EA, 0x0020, 0x05E8, 0x05DB, 0x05D9, 0x05D1, 0x05D9, 0x05DD, 0x0020, 0x05DE, 0x05D9, 0x05D5, 0x05EA, 0x05E8, 0x05D9, 0x05DD, 0x0020, 0x0028, 0x0042, 0x006C, 0x006F, 0x0061, 0x0074, 0x0077, 0x0061, 0x0072, 0x0065, 0x0029, 0x0020, 0x05DB, 0x05D3, 0x05D9, 0x0020, 0x05DC, 0x05D4, 0x05D1, 0x05D8, 0x05D9, 0x05D7, 0x0020, 0x05DE, 0x05D4, 0x05D9, 0x05E8, 0x05D5, 0x05EA, 0x0020, 0x05EA, 0x05D2, 0x05D5, 0x05D1, 0x05D4, 0x0020, 0x05E9, 0x05D9, 0x05D0, 0x002E, 0x000A, 0x000A)
$b7 = He @(0x2022, 0x0020, 0x05DE, 0x05D9, 0x05E0, 0x05D9, 0x05DE, 0x05DC, 0x05D9, 0x05D6, 0x05DD, 0x0020, 0x05D7, 0x05DB, 0x05DD, 0x003A, 0x0020, 0x05DE, 0x05DE, 0x05E9, 0x05E7, 0x0020, 0x05E0, 0x05E7, 0x05D9, 0x0020, 0x05E9, 0x05DE, 0x05D0, 0x05E4, 0x05E9, 0x05E8, 0x0020, 0x05DC, 0x05DA, 0x0020, 0x05DC, 0x05D4, 0x05EA, 0x05E8, 0x05DB, 0x05D6, 0x0020, 0x05D1, 0x05DE, 0x05D4, 0x0020, 0x05E9, 0x05D7, 0x05E9, 0x05D5, 0x05D1, 0x002C, 0x0020, 0x05D1, 0x05DC, 0x05D9, 0x0020, 0x05D4, 0x05E4, 0x05E8, 0x05E2, 0x05D5, 0x05EA, 0x0020, 0x05E8, 0x05E7, 0x05E2, 0x002E, 0x000A, 0x000A)
$b7a = He @(0x2022, 0x0020, 0x05DB, 0x05DC, 0x05D9, 0x0020, 0x05D0, 0x05D1, 0x05D7, 0x05D5, 0x05DF, 0x0020, 0x05DE, 0x05D5, 0x05D1, 0x05E0, 0x05D9, 0x05DD, 0x003A, 0x0020, 0x05E9, 0x05D9, 0x05DC, 0x05D5, 0x05D1, 0x0020, 0x05E9, 0x05DC, 0x0020, 0x05E1, 0x05E7, 0x05E8, 0x05D9, 0x05E4, 0x05D8, 0x05D9, 0x05DD, 0x0020, 0x05DE, 0x05EA, 0x05E7, 0x05D3, 0x05DE, 0x05D9, 0x05DD, 0x0020, 0x0028, 0x05DB, 0x05DE, 0x05D5, 0x0020, 0x05D4, 0x002D, 0x0050, 0x006F, 0x0077, 0x0065, 0x0072, 0x0053, 0x0068, 0x0065, 0x006C, 0x006C, 0x0020, 0x0047, 0x0055, 0x0049, 0x0020, 0x05E9, 0x05E4, 0x05D9, 0x05EA, 0x05D7, 0x05E0, 0x05D5, 0x0029, 0x0020, 0x05DC, 0x05E0, 0x05D9, 0x05D4, 0x05D5, 0x05DC, 0x0020, 0x05D5, 0x05EA, 0x05E7, 0x05D9, 0x05E0, 0x05D5, 0x05EA, 0x0020, 0x05D4, 0x05DE, 0x05D7, 0x05E9, 0x05D1, 0x0020, 0x05D1, 0x05DC, 0x05D7, 0x05D9, 0x05E6, 0x05EA, 0x0020, 0x05DB, 0x05E4, 0x05EA, 0x05D5, 0x05E8, 0x002E, 0x000A, 0x000A)
$b7b = He @(0x2022, 0x0020, 0x05D2, 0x05DE, 0x05D9, 0x05E9, 0x05D5, 0x05EA, 0x0020, 0x0028, 0x0046, 0x006C, 0x0065, 0x0078, 0x0029, 0x003A, 0x0020, 0x05D4, 0x05DE, 0x05E2, 0x05E8, 0x05DB, 0x05EA, 0x0020, 0x05E0, 0x05D1, 0x05E0, 0x05EA, 0x05D4, 0x0020, 0x05DB, 0x05D3, 0x05D9, 0x0020, 0x05DC, 0x05D4, 0x05D9, 0x05D5, 0x05EA, 0x0020, 0x05D5, 0x05E8, 0x05E1, 0x05D8, 0x05D9, 0x05DC, 0x05D9, 0x05EA, 0x0020, 0x2013, 0x0020, 0x05D1, 0x05D9, 0x05DF, 0x0020, 0x05D0, 0x05DD, 0x0020, 0x05D6, 0x05D4, 0x0020, 0x05DC, 0x05E2, 0x05D1, 0x05D5, 0x05D3, 0x05D4, 0x0020, 0x05D1, 0x002D, 0x0056, 0x004D, 0x0020, 0x05D5, 0x05D1, 0x05D9, 0x05DF, 0x0020, 0x05D0, 0x05DD, 0x0020, 0x05DC, 0x05DE, 0x05DB, 0x05D5, 0x05E0, 0x05D4, 0x0020, 0x05E4, 0x05D9, 0x05D6, 0x05D9, 0x05EA, 0x002E, 0x000A)
$b8 = He @(0x000A)
$b9 = He @(0x05D0, 0x05D9, 0x05DA, 0x0020, 0x05DE, 0x05E9, 0x05EA, 0x05DE, 0x05E9, 0x05D9, 0x05DD, 0x0020, 0x05D1, 0x05EA, 0x05E4, 0x05E8, 0x05D9, 0x05D8, 0x0020, 0x05D4, 0x05D4, 0x05EA, 0x05E7, 0x05E0, 0x05D5, 0x05EA, 0x003F, 0x000A)
$b10 = He @(0x0031, 0x002E, 0x0020, 0x05D1, 0x05E8, 0x05D2, 0x05E2, 0x0020, 0x05E9, 0x05EA, 0x05DE, 0x05E9, 0x05D9, 0x05DB, 0x05D5, 0x002C, 0x0020, 0x05D4, 0x05DE, 0x05E2, 0x05E8, 0x05DB, 0x05EA, 0x0020, 0x05EA, 0x05D1, 0x05E6, 0x05E2, 0x0020, 0x05E1, 0x05E8, 0x05D9, 0x05E7, 0x05EA, 0x0020, 0x05E8, 0x05E9, 0x05EA, 0x002E, 0x000A)
$b11 = He @(0x0032, 0x002E, 0x0020, 0x05DC, 0x05D0, 0x05D7, 0x05E8, 0x0020, 0x05DE, 0x05DB, 0x05DF, 0x002C, 0x0020, 0x05D9, 0x05D5, 0x05E6, 0x05D2, 0x0020, 0x05DC, 0x05DB, 0x05DD, 0x0020, 0x05EA, 0x05E4, 0x05E8, 0x05D9, 0x05D8, 0x0020, 0x05E7, 0x05D8, 0x05D2, 0x05D5, 0x05E8, 0x05D9, 0x05D5, 0x05EA, 0x0020, 0x05E0, 0x05D5, 0x05D7, 0x0020, 0x05D1, 0x05D7, 0x05DC, 0x05E7, 0x05D5, 0x0020, 0x05D4, 0x05E6, 0x05D9, 0x05D3, 0x05D9, 0x0020, 0x05E9, 0x05DC, 0x0020, 0x05D4, 0x05DE, 0x05E1, 0x05DA, 0x002E, 0x000A)
$b12 = He @(0x0033, 0x002E, 0x0020, 0x05D1, 0x05D7, 0x05E8, 0x05D5, 0x0020, 0x05D0, 0x05EA, 0x0020, 0x05D4, 0x05E7, 0x05D8, 0x05D2, 0x05D5, 0x05E8, 0x05D9, 0x05D5, 0x05EA, 0x0020, 0x05D4, 0x05E9, 0x05D5, 0x05E0, 0x05D5, 0x05EA, 0x0020, 0x05D5, 0x05E1, 0x05DE, 0x05E0, 0x05D5, 0x0020, 0x05D0, 0x05D9, 0x05DC, 0x05D5, 0x0020, 0x05EA, 0x05D5, 0x05DB, 0x05E0, 0x05D5, 0x05EA, 0x0020, 0x05EA, 0x05E8, 0x05E6, 0x05D5, 0x0020, 0x05DC, 0x05D4, 0x05EA, 0x05E7, 0x05D9, 0x05DF, 0x002E, 0x000A)
$b13 = He @(0x0034, 0x002E, 0x0020, 0x05D1, 0x05E1, 0x05D9, 0x05D5, 0x05DD, 0x0020, 0x05D4, 0x05D1, 0x05D7, 0x05D9, 0x05E8, 0x05D4, 0x002C, 0x0020, 0x05DC, 0x05D7, 0x05E6, 0x05D5, 0x0020, 0x05E2, 0x05DC, 0x0020, 0x0027, 0x05D4, 0x05D1, 0x05D0, 0x0027, 0x002C, 0x0020, 0x05D5, 0x05D4, 0x05DE, 0x05E2, 0x05E8, 0x05DB, 0x05EA, 0x0020, 0x05EA, 0x05EA, 0x05D7, 0x05D9, 0x05DC, 0x0020, 0x05D1, 0x05D4, 0x05EA, 0x05E7, 0x05E0, 0x05D4, 0x0020, 0x05E9, 0x05E7, 0x05D8, 0x05D4, 0x0020, 0x05D1, 0x05E8, 0x05E7, 0x05E2, 0x0021, 0x000A)
$b14 = He @(0x000A)
$b15 = He @(0x05DC, 0x05D7, 0x05E6, 0x05D5, 0x0020, 0x05E2, 0x05DC, 0x0020, 0x0027, 0x05D4, 0x05D1, 0x05D0, 0x0027, 0x0020, 0x05DB, 0x05D3, 0x05D9, 0x0020, 0x05DC, 0x05D4, 0x05DE, 0x05E9, 0x05D9, 0x05DA, 0x002C, 0x0020, 0x05D0, 0x05D5, 0x0020, 0x05E2, 0x05DC, 0x0020, 0x0027, 0x05DC, 0x05D0, 0x0020, 0x05DE, 0x05E2, 0x05D5, 0x05E0, 0x05D9, 0x05D9, 0x05DF, 0x0027, 0x0020, 0x05DB, 0x05D3, 0x05D9, 0x0020, 0x05DC, 0x05E6, 0x05D0, 0x05EA, 0x0020, 0x05DE, 0x05DB, 0x05D0, 0x05DF, 0x002E)
$WelcomeIntroText.Text=(L ($b1+$b2+$b3) "").Trim();
$AboutTitleText.Text=(L (He @(0x05D9,0x05EA,0x05E8,0x05D5,0x05E0,0x05D5,0x05EA,0x0020,0x05D4,0x05DE,0x05E2,0x05E8,0x05DB,0x05EA)) "System Advantages")
$AboutBodyText.Text=(L ($b5+$b6+$b7+$b7b) "").Trim()
$UsageTitleText.Text=(L $b9 "").Trim()
$UsageBodyText.Text=(L ($b10+$b11+$b12+$b13) "").Trim(); $HintText.Text=(L $b15 "").Trim()
Apply-Language

# Preflight
$phHe = He @(0x05D1, 0x05D5, 0x05D3, 0x05E7, 0x20, 0x05D7, 0x05D9, 0x05D1, 0x05D5, 0x05E8, 0x20, 0x2D, 0x57, 0x69, 0x6E, 0x67, 0x65, 0x74)
$psHe = He @(0x05DE, 0x05DE, 0x05EA, 0x05D9, 0x05E0, 0x05D9, 0x05DD, 0x2E, 0x2E, 0x2E)
$PreflightHeader.Text = L $phHe "Checking connectivity & Winget..."
$PreflightStatus.Text = L $psHe "Please wait..."

if ($SkipWelcome) {
    Write-Log "Starting in SkipWelcome mode"
    $StartupOverlay.Visibility = 'Collapsed'
    $MainBorder.Visibility = 'Visible'
    $MainArea.IsEnabled = $true
    $MainArea.Opacity = 1
    
    if ($MenuPath -and (Test-Path -LiteralPath $MenuPath)) {
        Write-Log "Loading menu from parameter path: $MenuPath"
        . $MenuPath
    } else {
        try {
            Write-Log "Loading built-in menu"
            Initialize-WFMenuData
        } catch {
            Write-Log "Failed to load menu: $_"
            [System.Windows.MessageBox]::Show("Error loading menu: " + $_.Exception.Message)
            $window.Close()
            exit
        }
    }
    Initialize-CategoryVms
    Render-SideMenu
    Show-Category
    Play-Sound
}
$window.Add_Loaded({
    $introPath = Join-Path $script:scriptDir "intro.mp4"
    if (Test-Path -LiteralPath $introPath) {
        $IntroOverlay.Visibility = 'Visible'
        $IntroVideo.Source = [Uri]::new($introPath)
        $IntroVideo.Play()
    }
})
$BtnSkipIntro.Add_Click({
    $IntroVideo.Stop()
    $IntroOverlay.Visibility = 'Collapsed'
})
$IntroVideo.Add_MediaEnded({
    $IntroOverlay.Visibility = 'Collapsed'
})

$window.ShowDialog()|Out-Null
}
