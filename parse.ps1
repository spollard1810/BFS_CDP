$inputDir  = "C:\Temp\cdp_output"
$outputCsv = "C:\Temp\cdp_neighbors.csv"

$result = New-Object System.Collections.Generic.List[object]

Get-ChildItem -Path $inputDir -Filter *.txt | ForEach-Object {
    $sourceDevice = $_.BaseName
    $text = Get-Content -Path $_.FullName -Raw

    $text = $text -replace "`r`n", "`n"

$headerPattern = '(?sm)^\s*Device(?:-|\s+)ID\s+Local\s+Intrfce\s+Holdtme\s+Capability\s+Platform\s+Port\s+ID\s*\n(.*)$'
    if ($text -match $headerPattern) {
        $table = $matches[1]
    }
    else {
        return
    }

    $rowPattern = '^(?<Neighbor>\S+)\s+(?<LocalIntf>\S+)\s+(?<HoldTime>\S+)\s+(?<Capability>\S+)\s+(?<Platform>.+?)\s+(?<PortId>\S+)\s*$'

    $rows = [regex]::Matches(
        $table,
        $rowPattern,
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor
        [System.Text.RegularExpressions.RegexOptions]::Multiline
    )

    foreach ($r in $rows) {
        $result.Add(
            [pscustomobject]@{
                SourceDevice = $sourceDevice
                Neighbor     = $r.Groups['Neighbor'].Value
                LocalIntf    = $r.Groups['LocalIntf'].Value
                HoldTime     = $r.Groups['HoldTime'].Value
                Capability   = $r.Groups['Capability'].Value
                Platform     = $r.Groups['Platform'].Value.Trim()
                PortId       = $r.Groups['PortId'].Value
            }
        )
    }
}

$result | Export-Csv -Path $outputCsv -NoTypeInformation -Encoding UTF8
Write-Host "Wrote $($result.Count) rows to $outputCsv"
