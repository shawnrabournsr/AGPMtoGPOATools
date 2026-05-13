param(
    [switch]$WhatIf
)

function Remove-OrphanedSidAcesFromPath {
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [string]$Context
    )

    if (-not (Test-Path $Path)) {
        Write-Host "[$Context] Path not found: $Path" -ForegroundColor DarkYellow
        return
    }

    $acl = Get-Acl -Path $Path

    # Orphaned/unresolved SIDs will appear as SecurityIdentifier with Value like S-1-5-21-...
    $orphanedAces = $acl.Access | Where-Object {
        $_.IdentityReference -is [System.Security.Principal.SecurityIdentifier] -and
        $_.IdentityReference.Value -like 'S-1-5-21-*'
    }

    if (-not $orphanedAces -or $orphanedAces.Count -eq 0) {
        Write-Host "[$Context] No orphaned SID ACEs found on $Path"
        return
    }

    Write-Host "[$Context] Found $($orphanedAces.Count) orphaned SID ACE(s) on $Path" -ForegroundColor Yellow

    if ($WhatIf) {
        foreach ($ace in $orphanedAces) {
           Write-Host "  WhatIf: Would remove ACE for $($ace.IdentityReference.Value) ($( if ($ace.ActiveDirectoryRights) { $ace.ActiveDirectoryRights } else { $ace.FileSystemRights } ))"

        }
        return
    }

    foreach ($ace in $orphanedAces) {
        # Use RemoveAccessRuleSpecific to avoid over-removal
        $null = $acl.RemoveAccessRuleSpecific($ace)
    }

    Set-Acl -Path $Path -AclObject $acl
    Write-Host "[$Context] Removed orphaned SID ACE(s) from $Path" -ForegroundColor Green
}

# --- Main GPO loop ---

Import-Module ActiveDirectory -ErrorAction Stop

$domain = Get-ADDomain
$domainDN = $domain.DistinguishedName
$policiesPath = "CN=Policies,CN=System,$domainDN"

Write-Host "Enumerating GPOs in $($domainDNSRoot) / $domainDN..." -ForegroundColor Cyan

$gpcs = Get-ADObject -LDAPFilter "(objectClass=groupPolicyContainer)" -SearchBase $policiesPath -Properties name


$i=0
foreach ($gpc in $gpcs) {

if ($i -lt 5) {
Read-Host "Paused for inspection. Press ENTER to continue"
}
i++

    $gpoName = $gpc.displayName
    if (-not $gpoName) { $gpoName = $gpc.Name }

    Write-Host "`nProcessing GPO: $gpoName ($($gpc.Name))" -ForegroundColor Cyan

    # AD GPC
    $adPath = "AD:$($gpc.DistinguishedName)"
    Remove-OrphanedSidAcesFromPath -Path $adPath -Context "GPC"

    # SYSVOL GPT
    $gpoId = $gpc.Name.Trim('{}')
    $sysvolRoot = "\\$($domain.DNSRoot)\SYSVOL\$($domain.DNSRoot)\Policies"
    $gptPath = Join-Path $sysvolRoot ("{$gpoId}")

    Remove-OrphanedSidAcesFromPath -Path $gptPath -Context "GPT"
}

Write-Host "`nCompleted orphaned SID cleanup. Use -WhatIf first to review changes." -ForegroundColor Magenta
