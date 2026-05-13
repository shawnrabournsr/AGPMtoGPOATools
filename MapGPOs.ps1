param(
    [Parameter(Mandatory)]
    [string]$CsvPath,

    [switch]$DryRun,

    [string]$LogPath = ".\GPO_MoveLog_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

    # Optional override if your GPOAdmin server name differs
   # [string]$GPOAdminServer = $env:COMPUTERNAME,

    #[int]$GPOAdminPort = 40200
)

# -----------------------------
# Logging helper
# -----------------------------
function Write-Log {
    param([string]$Message)
    $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $line = "$timestamp`t$Message"
    Add-Content -Path $LogPath -Value $line
    Write-Host $line
}

Write-Log "=== Starting GPOADmin Relocation Script ==="
Write-Log "CSV: $CsvPath"
Write-Log "DryRun: $DryRun"
Write-Log "Log: $LogPath"
Write-Log "Server: $GPOAdminServer"

# -----------------------------
# Ensure GPOADmin PSDrive exists
# -----------------------------
if (-not (Get-PSDrive -Name VCRoot -ErrorAction SilentlyContinue)) {
    Write-Log "Mounting VCRoot PSDrive..."

    try {
        New-PSDrive -Name VCRoot `
                    -PSProvider PSGPOADmin `
                    -Root "Version Control Root" | Out-Null

        Write-Log "VCRoot PSDrive mounted successfully."
    }
    catch {
        Write-Log "ERROR: Failed to mount VCRoot PSDrive — $_"
        throw "Cannot continue without VCRoot drive."
    }
}
else {
    Write-Log "VCRoot PSDrive already mounted."
}

# -----------------------------
# Import CSV
# -----------------------------
$rows = Import-Csv -Path $CsvPath

# -----------------------------
# Validate containers exist
# -----------------------------
$validContainers = @("Security","Infrastructure","PlatformEngineering")

foreach ($c in $validContainers) {
    $path = "VCRoot:\$c"
    if (-not (Test-Path $path)) {
        Write-Log "ERROR: Required container missing: $path"
        throw "Container missing: $path"
    }
}

# -----------------------------
# Cache all GPOs in VCRoot
# -----------------------------
Write-Log "Enumerating all GPOs in VCRoot..."
$allGpos = Get-ChildItem VCRoot:\ -Recurse -GPO
Write-Log "Found $($allGpos.Count) GPOs."

# -----------------------------
# Process each CSV row
# -----------------------------
foreach ($row in $rows) {

    $guid = $row.GPOID.Trim()
    $dest = $row.Destination.Trim()

    if (-not $guid) {
        Write-Log "SKIP: Empty GPOID row"
        continue
    }

    if ([string]::IsNullOrWhiteSpace($dest)) {
        Write-Log "SKIP: $guid has no destination"
        continue
    }

    if ($dest -notin $validContainers) {
        Write-Log "ERROR: $guid has invalid destination '$dest'"
        continue
    }

    # Find GPO in VCRoot
    $gpo = $allGpos | Where-Object { $_.Name -eq $guid }

    if (-not $gpo) {
        Write-Log "SKIP: $guid does not exist in GPOADmin"
        continue
    }

    $currentPath = $gpo.PSPath
    $currentContainer = Split-Path $currentPath
    $targetPath = "VCRoot:\$dest"

    if ($currentContainer -eq $targetPath) {
        Write-Log "SKIP: $guid already in correct container ($dest)"
        continue
    }

    Write-Log "MOVE: $guid from '$currentContainer' → '$targetPath'"

    if (-not $DryRun) {
        try {
            Move-Item -Path $currentPath -Destination $targetPath -Force
            Write-Log "SUCCESS: $guid moved to $dest"
        }
        catch {
            Write-Log "ERROR: Failed to move $guid — $_"
        }
    }
    else {
        Write-Log "DRYRUN: No change applied for $guid"
    }
}

Write-Log "=== Completed GPOADmin Relocation Script ==="
