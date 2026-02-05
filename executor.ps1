[CmdletBinding()]
param(
    [string]$HostsFile,
    [string]$SecureCrt,
    [string]$ScriptPath,
    [string]$OutputDir,
    [string]$FoundHostsFile,
    [string]$NextHostsFile,
    [string]$EdgesFile,
    [string]$InventoryFile,
    [int]$TimeoutSec,
    [int]$MaxDepth,
    [pscredential]$Credential
)

$ErrorActionPreference = "Stop"

# USER-EDITABLE DEFAULTS (portable; relative to where you run the script)
$DefaultHostsFile    = "Hosts.txt"
$DefaultOutputDir    = "cdp_output"
$DefaultFoundHosts   = "found_hosts.txt"
$DefaultNextHosts    = "hosts_next.txt"
$DefaultEdgesFile    = "cdp_edges.csv"
$DefaultInventory    = "inventory.csv"
$DefaultSecureCrt    = "C:\Program Files\VanDyke Software\SecureCRT\SecureCRT.exe"
$DefaultScriptPath   = (Join-Path $PSScriptRoot "run_show_cdp.vbs")
$DefaultTimeoutSec   = 60
$DefaultMaxDepth     = -1

function Resolve-RelativePath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }
    if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
    return (Join-Path (Get-Location).Path $Path)
}

if ([string]::IsNullOrWhiteSpace($HostsFile)) { $HostsFile = $DefaultHostsFile }
if ([string]::IsNullOrWhiteSpace($OutputDir)) { $OutputDir = $DefaultOutputDir }
if ([string]::IsNullOrWhiteSpace($FoundHostsFile)) { $FoundHostsFile = $DefaultFoundHosts }
if ([string]::IsNullOrWhiteSpace($NextHostsFile)) { $NextHostsFile = $DefaultNextHosts }
if ([string]::IsNullOrWhiteSpace($EdgesFile)) { $EdgesFile = $DefaultEdgesFile }
if ([string]::IsNullOrWhiteSpace($InventoryFile)) { $InventoryFile = $DefaultInventory }
if ([string]::IsNullOrWhiteSpace($SecureCrt)) { $SecureCrt = $DefaultSecureCrt }
if ([string]::IsNullOrWhiteSpace($ScriptPath)) { $ScriptPath = $DefaultScriptPath }
if (-not $PSBoundParameters.ContainsKey('TimeoutSec')) { $TimeoutSec = $DefaultTimeoutSec }
if (-not $PSBoundParameters.ContainsKey('MaxDepth')) { $MaxDepth = $DefaultMaxDepth }

$HostsFile     = Resolve-RelativePath $HostsFile
$OutputDir     = Resolve-RelativePath $OutputDir
$FoundHostsFile = Resolve-RelativePath $FoundHostsFile
$NextHostsFile = Resolve-RelativePath $NextHostsFile
$EdgesFile     = Resolve-RelativePath $EdgesFile
$InventoryFile = Resolve-RelativePath $InventoryFile

function ConvertTo-QuotedArg {
    param([string]$Value)
    if ($null -eq $Value) { return '""' }
    return '"' + ($Value -replace '"', '""') + '"'
}

function Get-SafeFileName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return "_" }
    $invalid = [System.IO.Path]::GetInvalidFileNameChars()
    $chars = $Name.ToCharArray() | ForEach-Object {
        if ($invalid -contains $_) { "_" } else { $_ }
    }
    return -join $chars
}

function Read-Hosts {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return @() }
    return Get-Content -Path $Path |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and -not $_.StartsWith("#") } |
        Sort-Object -Unique
}

function Get-CdpNeighbors {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return @() }
    $text = Get-Content -Path $Path -Raw
    $text = $text -replace "`r`n", "`n"

    $headerPattern = '(?sm)^\s*Device(?:-|\s+)ID\s+Local\s+Intrfce\s+Holdtme\s+Capability\s+Platform\s+Port\s+ID\s*\n(.*)$'
    if ($text -notmatch $headerPattern) { return @() }
    $table = $matches[1]

    $rowPattern = '^(?<Neighbor>\S+)\s+(?<LocalIntf>\S+)\s+(?<HoldTime>\S+)\s+(?<Capability>\S+)\s+(?<Platform>.+?)\s+(?<PortId>\S+)\s*$'

    $rows = [regex]::Matches(
        $table,
        $rowPattern,
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor
        [System.Text.RegularExpressions.RegexOptions]::Multiline
    )

    $neighbors = foreach ($r in $rows) {
        $r.Groups["Neighbor"].Value
    }

    return $neighbors | Sort-Object -Unique
}

function Get-PlatformFromInventory {
    param([string]$Text)
    if ($Text -match '(?i)nexus|nx-os') { return "Nexus" }
    if ($Text -match '(?i)catalyst|ios[-\s]?xe|ws-c') { return "Catalyst" }
    return "Unknown"
}

function ConvertFrom-InventoryGeneric {
    param([string]$Text)
    $pattern = '(?ms)NAME:\s*"(?<Name>[^"]+)"\s*,\s*DESCR:\s*"(?<Descr>[^"]*)"\s*.*?\n\s*PID:\s*(?<Pid>[^,\r\n]+)\s*,\s*VID:\s*(?<Vid>[^,\r\n]+)\s*,\s*SN:\s*(?<Sn>\S+)'
    $invMatches = [regex]::Matches($Text, $pattern)

    if ($invMatches.Count -eq 0) {
        if ($Text -match 'SN:\s*(?<Sn>\S+)') {
            return [pscustomobject]@{
                Chassis = ""
                Serial  = $matches["Sn"]
                Pid     = ""
                Descr   = ""
            }
        }
        return $null
    }

    $blocks = foreach ($m in $invMatches) {
        [pscustomobject]@{
            Name  = $m.Groups["Name"].Value.Trim()
            Descr = $m.Groups["Descr"].Value.Trim()
            Pid   = $m.Groups["Pid"].Value.Trim()
            Sn    = $m.Groups["Sn"].Value.Trim()
        }
    }

    $selected = $blocks | Where-Object {
        $_.Name -match '(?i)chassis' -or $_.Descr -match '(?i)chassis'
    } | Select-Object -First 1

    if (-not $selected) {
        $selected = $blocks | Select-Object -First 1
    }

    return [pscustomobject]@{
        Chassis = $selected.Name
        Serial  = $selected.Sn
        Pid     = $selected.Pid
        Descr   = $selected.Descr
    }
}

function ConvertFrom-InventoryNexus {
    param([string]$Text)
    return ConvertFrom-InventoryGeneric -Text $Text
}

function ConvertFrom-InventoryCatalyst {
    param([string]$Text)
    return ConvertFrom-InventoryGeneric -Text $Text
}

function ConvertTo-PlainText {
    param([securestring]$SecureString)
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringAuto($ptr)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
    }
}

function Get-InventoryInfo {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }

    $text = Get-Content -Path $Path -Raw
    $text = $text -replace "`r`n", "`n"

    $platform = Get-PlatformFromInventory -Text $text
    switch ($platform) {
        "Nexus"    { $info = ConvertFrom-InventoryNexus -Text $text }
        "Catalyst" { $info = ConvertFrom-InventoryCatalyst -Text $text }
        default    { $info = ConvertFrom-InventoryGeneric -Text $text }
    }

    if (-not $info) { return $null }

    if ($platform -eq "Unknown") {
        if ($info.Pid -match '^(N\d|N\d{2}|N\d{3})') { $platform = "Nexus" }
        elseif ($info.Pid -match '^(WS-C|C\d)') { $platform = "Catalyst" }
    }

    return [pscustomobject]@{
        Chassis  = $info.Chassis
        Serial   = $info.Serial
        Pid      = $info.Pid
        Descr    = $info.Descr
        Platform = $platform
    }
}

function Write-ErrorLog {
    param(
        [string]$Message,
        [string]$Path = "cdp_errors.log"
    )
    $logPath = Resolve-RelativePath $Path
    $line = "{0} {1}" -f (Get-Date).ToString("s"), $Message
    $line | Add-Content -Path $logPath -Encoding UTF8
}

if (-not (Test-Path $HostsFile)) {
    throw "Hosts file not found: $HostsFile"
}

if (-not (Test-Path $SecureCrt)) {
    throw "SecureCRT not found: $SecureCrt"
}

if (-not (Test-Path $ScriptPath)) {
    throw "VBS script not found: $ScriptPath"
}

if (-not $Credential) {
    $Credential = Get-Credential -Message "Enter device credentials"
}

$Username = $Credential.UserName
$authSecret = ConvertTo-PlainText -SecureString $Credential.Password

New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
$cdpDir = Join-Path $OutputDir "cdp"
$invDir = Join-Path $OutputDir "inventory"
New-Item -ItemType Directory -Path $cdpDir -Force | Out-Null
New-Item -ItemType Directory -Path $invDir -Force | Out-Null

$edgesDir = Split-Path -Parent $EdgesFile
if ($edgesDir -and -not (Test-Path $edgesDir)) {
    New-Item -ItemType Directory -Path $edgesDir -Force | Out-Null
}

$invDirParent = Split-Path -Parent $InventoryFile
if ($invDirParent -and -not (Test-Path $invDirParent)) {
    New-Item -ItemType Directory -Path $invDirParent -Force | Out-Null
}

if (-not (Test-Path $EdgesFile)) {
    "Source,Neighbor" | Out-File -Path $EdgesFile -Encoding UTF8
}

if (-not (Test-Path $InventoryFile)) {
    "Device,Platform,Chassis,Serial,Pid,Descr" | Out-File -Path $InventoryFile -Encoding UTF8
}

$visited = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$found   = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

$currentHosts = Read-Hosts -Path $HostsFile
foreach ($h in $currentHosts) { $found.Add($h) | Out-Null }

$level = 0

while ($currentHosts.Count -gt 0) {
    Write-Host "Level $level: $($currentHosts.Count) devices"

    $nextHosts = New-Object System.Collections.Generic.List[string]

    foreach ($device in $currentHosts) {
        if ($visited.Contains($device)) { continue }

        $visited.Add($device) | Out-Null
        $safeName = Get-SafeFileName -Name $device

        $cdpPath = Join-Path $cdpDir ($safeName + "-cdp.txt")
        $invPath = Join-Path $invDir ($safeName + "-inventory.txt")

        if (Test-Path $cdpPath) { Remove-Item -Path $cdpPath -Force }
        if (Test-Path $invPath) { Remove-Item -Path $invPath -Force }

        Write-Host "Connecting to $device..."
        $argumentList = "/SCRIPT " +
            (ConvertTo-QuotedArg $ScriptPath) + " " +
            (ConvertTo-QuotedArg $device) + " " +
            (ConvertTo-QuotedArg $Username) + " " +
            (ConvertTo-QuotedArg $authSecret) + " " +
            (ConvertTo-QuotedArg $cdpPath) + " " +
            (ConvertTo-QuotedArg $invPath)

        $proc = Start-Process -FilePath $SecureCrt -ArgumentList $argumentList -PassThru -WindowStyle Hidden
        $proc | Wait-Process -Timeout $TimeoutSec | Out-Null

        if (-not $proc.HasExited) {
            try { $proc | Stop-Process -Force } catch {}
            Write-ErrorLog "Process timeout for $device."
            continue
        }

        if (-not (Test-Path $cdpPath)) {
            Write-ErrorLog "No CDP output for $device (connection failed)."
            continue
        }

        $neighbors = Get-CdpNeighbors -Path $cdpPath
        foreach ($n in $neighbors) {
            if ([string]::IsNullOrWhiteSpace($n)) { continue }
            "$device,$n" | Add-Content -Path $EdgesFile -Encoding UTF8
            if (-not $visited.Contains($n) -and -not $found.Contains($n)) {
                $nextHosts.Add($n)
            }
            $found.Add($n) | Out-Null
        }

        if (Test-Path $invPath) {
            $inv = Get-InventoryInfo -Path $invPath
            if ($inv) {
                [pscustomobject]@{
                    Device   = $device
                    Platform = $inv.Platform
                    Chassis  = $inv.Chassis
                    Serial   = $inv.Serial
                    Pid      = $inv.Pid
                    Descr    = $inv.Descr
                } | Export-Csv -Path $InventoryFile -Append -NoTypeInformation -Encoding UTF8
            } else {
                Write-ErrorLog "Inventory parse failed for $device."
            }
        } else {
            Write-ErrorLog "No inventory output for $device."
        }
    }

    $found | Sort-Object | Set-Content -Path $FoundHostsFile -Encoding UTF8
    $nextHosts | Sort-Object -Unique | Set-Content -Path $NextHostsFile -Encoding UTF8

    if ($MaxDepth -ge 0 -and $level -ge $MaxDepth) {
        break
    }

    $currentHosts = Read-Hosts -Path $NextHostsFile
    $level++
}

Write-Host "Done. Visited $($visited.Count) devices. Found $($found.Count) total."
