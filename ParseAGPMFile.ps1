# ============================
# CONFIGURATION
# ============================

$XmlPath   = "C:\Users\SRabourn\temp\gpostate.xml"
$OutputCsv = "C:\Users\SRabourn\temp\AGPM_GPO_SID_Matrix.csv"

$SIDMap = [ordered]@{
    SecurityOps_Editors        = 'S-1-5-21-2012301915-1854694151-564218192-427211'
    SecurityOps_Approvers      = 'S-1-5-21-2012301915-1854694151-564218192-427210'
    PlatformEng_Editors        = 'S-1-5-21-2012301915-1854694151-564218192-331467'
    PlatformEng_Approvers      = 'S-1-5-21-2012301915-1854694151-564218192-331468'
    Infra_Editors              = 'S-1-5-21-2012301915-1854694151-564218192-427209'
    Infra_Approvers            = 'S-1-5-21-2012301915-1854694151-564218192-427208'
}

# ===================================
# FUNCTION: Decode Hex → SIDs + ACEs
# ===================================

function Get-SDDLDetailsFromHex {
    param([string]$HexString)

    # Convert hex → byte[]
    $bytes = ($HexString -replace '\s+', '') -split '([A-Fa-f0-9]{2})' |
             Where-Object { $_ -match '^[A-Fa-f0-9]{2}$' } |
             ForEach-Object { [Convert]::ToByte($_, 16) }

    try {
        $raw = New-Object System.Security.AccessControl.RawSecurityDescriptor ($bytes, 0)
    }
    catch {
        Write-Host "  ERROR decoding SecurityDescriptor: $_"
        return @{
            SIDs = @()
            ACEs = @()
        }
    }

    $sidList = New-Object System.Collections.Generic.List[string]
    $aceList = New-Object System.Collections.Generic.List[object]

    # Owner
    if ($raw.Owner) { $sidList.Add($raw.Owner.Value) }

    # Group
    if ($raw.Group) { $sidList.Add($raw.Group.Value) }

    # DACL ACEs
    if ($raw.DiscretionaryAcl) {
        foreach ($ace in $raw.DiscretionaryAcl) {
            if ($ace.SecurityIdentifier) {
                $sidList.Add($ace.SecurityIdentifier.Value)
                $aceList.Add([PSCustomObject]@{
                    Type        = $ace.AceType
                    Rights      = $ace.FileSystemRights
                    Inheritance = $ace.AceFlags
                    SID         = $ace.SecurityIdentifier.Value
                })
            }
        }
    }

    # SACL ACEs
    if ($raw.SystemAcl) {
        foreach ($ace in $raw.SystemAcl) {
            if ($ace.SecurityIdentifier) {
                $sidList.Add($ace.SecurityIdentifier.Value)
                $aceList.Add([PSCustomObject]@{
                    Type        = $ace.AceType
                    Rights      = $ace.FileSystemRights
                    Inheritance = $ace.AceFlags
                    SID         = $ace.SecurityIdentifier.Value
                })
            }
        }
    }

    return @{
        SIDs = $sidList | Select-Object -Unique
        ACEs = $aceList
    }
}

# ============================
# LOAD XML + NAMESPACE
# ============================

Write-Host "Loading XML from: $XmlPath"
[xml]$xml = Get-Content -Path $XmlPath -Raw

$nsUri = "http://schemas.microsoft.com/MDOP/2007/02/AGPM"
$ns    = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
$ns.AddNamespace("agpm", $nsUri)

Write-Host "Namespace registered: $nsUri"

$GPOs = $xml.SelectNodes("//agpm:GPO", $ns)
Write-Host "Found $($GPOs.Count) GPO nodes using //agpm:GPO"

# ===============================
# PROCESS ROOT-LEVEL DESCRIPTORS
# ===============================

$RootRows = @()

function Process-RootDescriptor {
    param(
        [string]$Label,
        $Node
    )

    Write-Host "`n[ROOT] $Label"

    # Extract hex text safely
    $hex = $null

    if ($Node -is [System.Xml.XmlElement]) {
        $hex = $Node.InnerText
    }
    elseif ($Node -is [string]) {
        $hex = $Node
    }

    if ([string]::IsNullOrWhiteSpace($hex)) {
        Write-Host "  Descriptor is empty. Writing blank SID columns."

        $row = [ordered]@{ GPOID = $Label }
        foreach ($key in $SIDMap.Keys) { $row[$key] = $null }
        return [PSCustomObject]$row
    }

    Write-Host "  Length: $($hex.Length)"

    $decoded = Get-SDDLDetailsFromHex -HexString $hex
    $allSids = $decoded.SIDs
    $allAces = $decoded.ACEs

    if ($allSids.Count -gt 0) {
        Write-Host "  SIDs:"
        foreach ($sid in $allSids) { Write-Host "     $sid" }
    }
    else {
        Write-Host "  No SIDs found."
    }

    if ($allAces.Count -gt 0) {
        Write-Host "  ACE Details:"
        foreach ($ace in $allAces) {
            Write-Host ("     [{0}] SID={1} Rights={2} Inheritance={3}" -f `
                $ace.Type, $ace.SID, $ace.Rights, $ace.Inheritance)
        }
    }

    $row = [ordered]@{ GPOID = $Label }
    foreach ($key in $SIDMap.Keys) {
        $SID = $SIDMap[$key]
        $row[$key] = ($allSids -contains $SID)
    }

    return [PSCustomObject]$row
}

# Correct root descriptor paths
$RootRows += Process-RootDescriptor -Label "SecurityDescriptor" `
    -Node $xml.Archive.SecurityDescriptor

$RootRows += Process-RootDescriptor -Label "ProductionGPOSecurityDescriptor" `
    -Node $xml.Archive.GPODomain.ProductionGPOSecurityDescriptor

# ============================
# PROCESS GPO NODES
# ============================

$counter = 0
$Results = foreach ($gpo in $GPOs) {

    $counter++

    $GPOID = $gpo.GetAttribute("id", $nsUri)
    Write-Host "`n[$counter] GPO ID: $GPOID"

    if (-not $GPOID) {
        Write-Host "  WARNING: Missing agpm:id attribute. Writing blank row."
        $row = [ordered]@{ GPOID = "<missing>" }
        foreach ($key in $SIDMap.Keys) { $row[$key] = $null }
        [PSCustomObject]$row
        continue
    }

    # Try to get SecurityDescriptor
    $sdNode = $gpo.SelectSingleNode("agpm:SecurityDescriptor", $ns)

    if ($sdNode -eq $null) {
        Write-Host "  No SecurityDescriptor node found. Writing blank SID columns."

        $row = [ordered]@{ GPOID = $GPOID }
        foreach ($key in $SIDMap.Keys) { $row[$key] = $null }

        [PSCustomObject]$row
        continue
    }

    $SDDL = $sdNode.InnerText
    Write-Host "  SecurityDescriptor length: $($SDDL.Length)"

    # Decode SIDs + ACEs
    $decoded = Get-SDDLDetailsFromHex -HexString $SDDL
    $allSids = $decoded.SIDs
    $allAces = $decoded.ACEs

    # Output SIDs
    if ($allSids.Count -gt 0) {
        Write-Host "  All SIDs found:"
        foreach ($sid in $allSids) { Write-Host "     $sid" }
    }
    else {
        Write-Host "  No SIDs found."
    }

    # Output ACEs
    if ($allAces.Count -gt 0) {
        Write-Host "  ACE Details:"
        foreach ($ace in $allAces) {
            Write-Host ("     [{0}] SID={1} Rights={2} Inheritance={3}" -f `
                $ace.Type, $ace.SID, $ace.Rights, $ace.Inheritance)
        }
    }
    else {
        Write-Host "  No ACEs found."
    }

    # Build CSV row
    $row = [ordered]@{ GPOID = $GPOID }

    foreach ($key in $SIDMap.Keys) {
        $SID = $SIDMap[$key]
        $match = $allSids -contains $SID
        Write-Host "    [$key] $SID -> $match"
        $row[$key] = $match
    }

    [PSCustomObject]$row
}

# ============================
# OUTPUT CSV
# ============================

$AllRows = @()
$AllRows += $RootRows
$AllRows += $Results

Write-Host "`nWriting $($AllRows.Count) rows to CSV: $OutputCsv"
$AllRows | Export-Csv -Path $OutputCsv -NoTypeInformation -Encoding UTF8
Write-Host "Done."
