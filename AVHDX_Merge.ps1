#Requires -RunAsAdministrator
#Requires -Modules Hyper-V

<#
.SYNOPSIS
    Interactive analysis and merge of orphaned AVHD/AVHDX files in Hyper-V.

.DESCRIPTION
    - Lists VMs with numeric selection
    - Modes: analysis only | analysis + merge/cleanup/fix | full chain consolidation
    - Rebuilds the disk chain (active VM + all snapshots)
    - Automatically scans the relevant folders
    - Identifies AVHD/AVHDX not in the chain = orphans
    - Optional backup of disk files before the fix
    - Automatic VM state handling (Running/Paused/Saved)
    - Confirmation + free-space check before the merge
    - Recursive child->parent merge, residual cleanup, ghost snapshot removal
    - Full session log via transcript
    - At the end, asks whether to exit or restart from VM selection

.PARAMETER AdditionalSearchPath
    Additional folder to scan (optional).

.EXAMPLE
    .\AVHDX_Merge.ps1
    .\AVHDX_Merge.ps1 -AdditionalSearchPath 'D:\HyperV\Backups'
#>

[CmdletBinding()]
param(
    [string]$AdditionalSearchPath
)

# =====================================================================
# Output utilities
# =====================================================================
function Write-Section($t) { Write-Host "`n==== $t ====" -ForegroundColor Cyan }
function Write-OK($t)      { Write-Host "[OK]    $t" -ForegroundColor Green }
function Write-Warn2($t)   { Write-Host "[WARN]  $t" -ForegroundColor Yellow }
function Write-Err2($t)    { Write-Host "[ERROR] $t" -ForegroundColor Red }
function Write-Info($t)    { Write-Host "[INFO]  $t" -ForegroundColor Gray }

function Read-Choice {
    param([string]$Prompt, [string[]]$Valid)
    while ($true) {
        $a = (Read-Host $Prompt).ToLower()
        if ($Valid -contains $a) { return $a }
        Write-Warn2 "Invalid answer. Options: $($Valid -join ', ')"
    }
}

# Normalize path for case-insensitive comparisons
function Normalize-Path($p) {
    if (-not $p) { return $null }
    try {
        $rp = (Resolve-Path -LiteralPath $p -ErrorAction Stop).Path
        return $rp.ToLower()
    } catch {
        return $p.ToLower()
    }
}

# True if the path is a snapshot differencing disk (.avhd or .avhdx)
function Test-IsAvhd($p) {
    return ($p -match '\.avhdx?$')
}

# Scan a folder and return both .avhd and .avhdx (exact extension match,
# avoids the Windows filter bug where '*.avhd' also catches '.avhdx')
function Get-AvhdFiles {
    param([string]$Root)
    Get-ChildItem -Path $Root -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -ieq '.avhd' -or $_.Extension -ieq '.avhdx' }
}

# Walk the parent chain for each disk and mark every level as "active"
function Add-ChainToActive {
    param([string]$Path, [System.Collections.Generic.HashSet[string]]$Set)
    $current = $Path
    while ($current) {
        $norm = Normalize-Path $current
        if (-not $Set.Add($norm)) { break }  # already visited
        try {
            $v = Get-VHD -Path $current -ErrorAction Stop
            $current = $v.ParentPath
        } catch {
            Write-Warn2 "Unreadable VHD in chain: $current ($($_.Exception.Message))"
            break
        }
    }
}

# Replace characters not allowed in a Windows file/folder name with '_'
function New-SafeName {
    param([string]$Name)
    $invalid = [System.IO.Path]::GetInvalidFileNameChars()
    $chars = $Name.ToCharArray() | ForEach-Object {
        if ($invalid -contains $_) { '_' } else { $_ }
    }
    $safe = (-join $chars).Trim().TrimEnd('.', ' ')
    if ([string]::IsNullOrWhiteSpace($safe)) { $safe = 'VM' }
    return $safe
}

# Free space (bytes) on the volume hosting $Path. $null if not determinable.
function Get-FreeSpaceBytes {
    param([string]$Path)
    try {
        $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
        $root = [System.IO.Path]::GetPathRoot($resolved)
        $di = New-Object System.IO.DriveInfo($root)
        return [int64]$di.AvailableFreeSpace
    } catch {
        return $null
    }
}

# Backup: create <BaseFolder>\<VMName>_<timestamp> and copy the given files into it.
# Returns $true if all copies succeeded.
function Invoke-Backup {
    param(
        [string]$BaseFolder,
        [string]$VMName,
        [string[]]$Files
    )
    $ts     = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
    $safeVm = New-SafeName $VMName
    $dest   = Join-Path $BaseFolder ("{0}_{1}" -f $safeVm, $ts)

    try {
        New-Item -ItemType Directory -Path $dest -Force -ErrorAction Stop | Out-Null
    } catch {
        Write-Err2 "Cannot create backup folder '$dest': $($_.Exception.Message)"
        return $false
    }
    Write-Info "Backup folder: $dest"

    $used  = @{}    # file name collision handling
    $okAll = $true
    foreach ($src in $Files) {
        if (-not (Test-Path -LiteralPath $src)) { continue }
        $leaf   = Split-Path -Leaf $src
        $target = Join-Path $dest $leaf
        $n = 1
        while ($used.ContainsKey($target.ToLower())) {
            $base   = [System.IO.Path]::GetFileNameWithoutExtension($leaf)
            $ext    = [System.IO.Path]::GetExtension($leaf)
            $target = Join-Path $dest ("{0}_{1}{2}" -f $base, $n, $ext)
            $n++
        }
        $used[$target.ToLower()] = $true
        try {
            Copy-Item -LiteralPath $src -Destination $target -Force -ErrorAction Stop
            Write-OK "Backed up: $src"
        } catch {
            Write-Err2 "Backup failed ($src): $($_.Exception.Message)"
            $okAll = $false
        }
    }
    return $okAll
}

# Bring the VM to 'Off' state, handling Running/Paused/Saved/other.
# Returns the refreshed VM object, or $null if cancelled/failed.
function Ensure-VMOff {
    param($Vm)
    while ($true) {
        $state = "$($Vm.State)"
        if ($state -eq 'Off') { return $Vm }

        switch ($state) {
            'Saved' {
                Write-Warn2 "VM is in 'Saved' state: a saved state is present and blocks the merge."
                $a = Read-Choice "Delete the saved state (the in-RAM session will be lost)? (y/n)" @('y', 'n')
                if ($a -ne 'y') { Write-Err2 "Operation cancelled by user."; return $null }
                try {
                    Remove-VMSavedState -VMName $Vm.Name -ErrorAction Stop
                    Write-OK "Saved state deleted."
                } catch {
                    Write-Err2 "Cannot delete the saved state: $($_.Exception.Message)"
                    return $null
                }
            }
            'Paused' {
                Write-Warn2 "VM is paused."
                $a = Read-Choice "Power off the VM (forced TurnOff)? (y/n)" @('y', 'n')
                if ($a -ne 'y') { Write-Err2 "Operation cancelled by user."; return $null }
                try {
                    Stop-VM -Name $Vm.Name -Force -TurnOff -ErrorAction Stop
                    Write-OK "VM powered off."
                } catch {
                    Write-Err2 "Cannot power off the VM: $($_.Exception.Message)"
                    return $null
                }
            }
            'Running' {
                Write-Warn2 "VM is running. Offline merge requires the VM to be OFF."
                $a = Read-Choice "Power off: (g) graceful shutdown / (f) force TurnOff / (n) cancel" @('g', 'f', 'n')
                if ($a -eq 'n') { Write-Err2 "Operation cancelled by user."; return $null }
                try {
                    if ($a -eq 'g') {
                        Stop-VM -Name $Vm.Name -ErrorAction Stop
                    } else {
                        Stop-VM -Name $Vm.Name -Force -TurnOff -ErrorAction Stop
                    }
                    Write-OK "Shutdown command sent."
                } catch {
                    Write-Err2 "Cannot power off the VM: $($_.Exception.Message)"
                    return $null
                }
            }
            default {
                Write-Warn2 "State '$state' not handled automatically."
                $a = Read-Choice "Attempt forced TurnOff? (y/n)" @('y', 'n')
                if ($a -ne 'y') { Write-Err2 "Operation cancelled by user."; return $null }
                try {
                    Stop-VM -Name $Vm.Name -Force -TurnOff -ErrorAction Stop
                    Write-OK "VM powered off."
                } catch {
                    Write-Err2 "Cannot power off the VM: $($_.Exception.Message)"
                    return $null
                }
            }
        }

        Start-Sleep -Seconds 3
        $Vm = Get-VM -Name $Vm.Name
    }
}

# =====================================================================
# Full session (VM selection -> analysis -> fix -> cleanup)
# Internal 'return' statements only exit this function, not the script.
# =====================================================================
function Invoke-AvhdMergeSession {

    # -----------------------------------------------------------------
    # 1) VM selection
    # -----------------------------------------------------------------
    Write-Section "VM lookup"
    $vms = @(Get-VM | Sort-Object Name)
    if ($vms.Count -eq 0) { Write-Err2 "No VM found on this host."; return }

    for ($i = 0; $i -lt $vms.Count; $i++) {
        "{0,3}) {1}  [{2}]" -f ($i + 1), $vms[$i].Name, $vms[$i].State | Write-Host
    }

    [int]$sel = 0
    while ($sel -lt 1 -or $sel -gt $vms.Count) {
        $raw = Read-Host "`nSelect VM (1-$($vms.Count))"
        [void][int]::TryParse($raw, [ref]$sel)
    }
    $vm = $vms[$sel - 1]
    Write-OK "Selected VM: $($vm.Name)  (State: $($vm.State))"

    # -----------------------------------------------------------------
    # 2) Mode selection
    # -----------------------------------------------------------------
    Write-Section "Mode"
    Write-Host "  1) Analysis only (read-only)"
    Write-Host "  2) Analysis + merge / orphan cleanup"
    Write-Host "  3) FULL chain consolidation (removes snapshots + merges AVHD/AVHDX into the parent VHDX)"
    $modeRaw = Read-Host "Choice (1/2/3)"
    $doFix          = ($modeRaw -eq '2')
    $doConsolidate  = ($modeRaw -eq '3')
    $modeLabel = switch ($modeRaw) {
        '2' { 'ANALYSIS + ORPHAN FIX' }
        '3' { 'CHAIN CONSOLIDATION' }
        default { 'ANALYSIS ONLY' }
    }
    Write-OK "Mode: $modeLabel"

    # -----------------------------------------------------------------
    # 3) Rebuild active disk chain
    #    Includes: currently attached disks + disks of all snapshots
    #    For each, recursively walks up to the ParentPath
    # -----------------------------------------------------------------
    Write-Section "Disk chain analysis"

    $attached = @(Get-VMHardDiskDrive -VM $vm | Select-Object -ExpandProperty Path)
    Write-Info "Disks attached to the VM: $($attached.Count)"

    $snapshots = @(Get-VMSnapshot -VM $vm -ErrorAction SilentlyContinue)
    Write-Info "Configured snapshots: $($snapshots.Count)"

    $snapDisks = @()
    foreach ($s in $snapshots) {
        $snapDisks += @(Get-VMHardDiskDrive -VMSnapshot $s | Select-Object -ExpandProperty Path)
    }

    $activePaths = New-Object System.Collections.Generic.HashSet[string]

    foreach ($p in (@($attached) + @($snapDisks) | Sort-Object -Unique)) {
        if ($p) { Add-ChainToActive -Path $p -Set $activePaths }
    }
    Write-Info "Total files in active chain: $($activePaths.Count)"

    # -----------------------------------------------------------------
    # 4) Determine folders to scan
    # -----------------------------------------------------------------
    $searchRoots = New-Object System.Collections.Generic.HashSet[string]
    foreach ($p in $activePaths) {
        $d = Split-Path -Parent $p
        if ($d) { [void]$searchRoots.Add($d) }
    }
    if ($vm.Path) { [void]$searchRoots.Add($vm.Path) }
    if ($vm.SnapshotFileLocation) {
        [void]$searchRoots.Add((Join-Path $vm.SnapshotFileLocation 'Virtual Hard Disks'))
        [void]$searchRoots.Add($vm.SnapshotFileLocation)
    }
    if ($AdditionalSearchPath) { [void]$searchRoots.Add($AdditionalSearchPath) }

    $existingRoots = @($searchRoots | Where-Object { Test-Path $_ } | Sort-Object -Unique)
    Write-Info "Folders to scan:"
    $existingRoots | ForEach-Object { Write-Host "   - $_" }

    # -----------------------------------------------------------------
    # 5) Scan AVHD/AVHDX and detect orphans
    # -----------------------------------------------------------------
    $allAvhdx = @()
    foreach ($r in $existingRoots) {
        $allAvhdx += @(Get-AvhdFiles -Root $r)
    }
    $allAvhdx = $allAvhdx | Sort-Object FullName -Unique

    $orphans = @()
    foreach ($f in $allAvhdx) {
        if (-not $activePaths.Contains((Normalize-Path $f.FullName))) {
            $orphans += $f
        }
    }

    $activeAvhdxCount = ($activePaths | Where-Object { Test-IsAvhd $_ }).Count

    Write-Section "Analysis results"
    Write-Host "AVHD/AVHDX found total    : $($allAvhdx.Count)"
    Write-Host "AVHD/AVHDX in active chain: $activeAvhdxCount"
    Write-Host "AVHD/AVHDX orphans        : $($orphans.Count)" -ForegroundColor $(if ($orphans.Count) { 'Yellow' } else { 'Green' })

    if ($orphans.Count -gt 0) {
        Write-Host ""
        $orphanReport = foreach ($f in $orphans) {
            $parent = $null
            $err = $null
            try { $parent = (Get-VHD -Path $f.FullName -ErrorAction Stop).ParentPath }
            catch { $err = $_.Exception.Message }

            [pscustomobject]@{
                File       = $f.FullName
                SizeMB     = [math]::Round($f.Length / 1MB, 1)
                Modified   = $f.LastWriteTime
                ParentPath = $parent
                ParentOK   = if ($parent) { Test-Path $parent } else { $false }
                Error      = $err
            }
        }
        $orphanReport | Format-Table -AutoSize -Wrap
    }

    # Show active chain detail (useful for mode 3)
    $activeAvhdxFiles = @($activePaths | Where-Object { Test-IsAvhd $_ })
    if ($activeAvhdxFiles.Count -gt 0) {
        Write-Host "`nAVHD/AVHDX in the active chain (consolidation candidates):"
        foreach ($p in $activeAvhdxFiles) {
            $size = if (Test-Path $p) { [math]::Round((Get-Item $p).Length / 1MB, 1) } else { 'n/a' }
            Write-Host ("   - {0}  ({1} MB)" -f $p, $size)
        }
    }

    # Stop if analysis only
    if (-not $doFix -and -not $doConsolidate) {
        Write-OK "Analysis completed. No changes made."
        return
    }

    # Mode 2: no orphans = nothing to do
    if ($doFix -and $orphans.Count -eq 0) {
        Write-OK "No orphans to process. To consolidate the chain use option 3."
        return
    }

    # Mode 3: no AVHD/AVHDX = no chain to consolidate
    if ($doConsolidate -and $activeAvhdxFiles.Count -eq 0 -and $orphans.Count -eq 0) {
        Write-OK "No AVHD/AVHDX present. Chain already consolidated."
        return
    }

    # -----------------------------------------------------------------
    # 6) Pre-fix: VM off -> confirm -> optional backup
    # -----------------------------------------------------------------
    Write-Section "Fix preparation"

    $vm = Ensure-VMOff -Vm $vm
    if (-not $vm) { return }   # cancelled or shutdown failed

    $go = Read-Choice "Proceed with the fix operations? (y/n)" @('y', 'n')
    if ($go -ne 'y') { Write-Info "Cancelled."; return }

    # ---- Optional backup --------------------------------------------------
    $bk = Read-Choice "Run a BACKUP of the disk files before proceeding? (y/n)" @('y', 'n')
    if ($bk -eq 'y') {
        $base = (Read-Host "Backup destination folder (a <VM>_<date_time> subfolder will be created)").Trim('"').Trim()
        if (-not (Test-Path -LiteralPath $base)) {
            $cr = Read-Choice "Folder '$base' does not exist. Create it? (y/n)" @('y', 'n')
            if ($cr -eq 'y') {
                try { New-Item -ItemType Directory -Path $base -Force -ErrorAction Stop | Out-Null }
                catch { Write-Err2 "Cannot create '$base': $($_.Exception.Message)"; $base = $null }
            } else { $base = $null }
        }
        if ($base) {
            # File set to copy: existing active chain + orphans (case-insensitive dedup)
            $bkSet = New-Object System.Collections.Generic.HashSet[string]
            foreach ($p in $activePaths) { if (Test-Path -LiteralPath $p) { [void]$bkSet.Add($p) } }
            foreach ($o in $orphans)     { [void]$bkSet.Add($o.FullName) }

            $bkTotMB = 0
            foreach ($f in $bkSet) { if (Test-Path -LiteralPath $f) { $bkTotMB += (Get-Item -LiteralPath $f).Length / 1MB } }
            Write-Info ("Files to copy: {0}  (~{1} MB)" -f $bkSet.Count, [math]::Round($bkTotMB, 1))

            $okBk = Invoke-Backup -BaseFolder $base -VMName $vm.Name -Files @($bkSet)
            if (-not $okBk) {
                $cont = Read-Choice "The backup had errors. Proceed with the fix anyway? (y/n)" @('y', 'n')
                if ($cont -ne 'y') { Write-Info "Cancelled after failed backup."; return }
            }
        } else {
            Write-Warn2 "Backup skipped."
        }
    }

    # -----------------------------------------------------------------
    # 6.1) MODE 3: snapshot removal (triggers Hyper-V auto-merge)
    # -----------------------------------------------------------------
    if ($doConsolidate) {
        Write-Section "Consolidation: snapshot removal"

        $allSnaps = @(Get-VMSnapshot -VM $vm -ErrorAction SilentlyContinue)
        if ($allSnaps.Count -gt 0) {
            Write-Host "Snapshots present:"
            $allSnaps | ForEach-Object { Write-Host "   - $($_.Name)  (created $($_.CreationTime))" }
            $c = Read-Choice "Remove ALL snapshots (Hyper-V will perform the automatic merge)? (y/n)" @('y','n')
            if ($c -eq 'y') {
                # Remove trees starting from the roots (snapshots without a parent)
                $rootSnaps = @($allSnaps | Where-Object { -not $_.ParentSnapshotId })
                foreach ($r in $rootSnaps) {
                    try {
                        Write-Info "Removing snapshot tree: $($r.Name)"
                        Remove-VMSnapshot -VMSnapshot $r -IncludeAllChildSnapshots -Confirm:$false -ErrorAction Stop
                    } catch {
                        Write-Err2 "Error removing $($r.Name): $($_.Exception.Message)"
                    }
                }

                # Wait for Hyper-V background merge to complete
                Write-Info "Waiting for Hyper-V merge to complete..."
                $timeout = (Get-Date).AddMinutes(120)
                do {
                    Start-Sleep -Seconds 5
                    $vmNow = Get-VM -Name $vm.Name
                    $opsStr = if ($vmNow.Operations) { ($vmNow.Operations | ForEach-Object { $_.ToString() }) -join ',' } else { '' }
                    $isMerging = ($vmNow.Status -match 'Merging') -or ($opsStr -match 'Merg')
                    if ($isMerging) {
                        Write-Info ("  in progress... Status='{0}' Ops='{1}'" -f $vmNow.Status, $opsStr)
                    }
                    if ((Get-Date) -gt $timeout) {
                        Write-Warn2 "Merge wait timeout (120 min). Continuing anyway."
                        break
                    }
                } while ($isMerging)
                Write-OK "Hyper-V auto-merge finished."
            } else {
                Write-Info "Snapshot removal skipped."
            }
        } else {
            Write-Info "No snapshot configured. Proceeding directly to the manual merge."
        }

        # ---- Re-scan: recompute active chain and detect leftover AVHD/AVHDX as orphans ----
        Write-Section "Re-scan after auto-merge"
        $vm = Get-VM -Name $vm.Name   # refresh VM object
        $activePaths.Clear()
        $attached2 = @(Get-VMHardDiskDrive -VM $vm | Select-Object -ExpandProperty Path)
        foreach ($p in $attached2) { Add-ChainToActive -Path $p -Set $activePaths }

        $allAvhdx2 = @()
        foreach ($r in $existingRoots) {
            $allAvhdx2 += @(Get-AvhdFiles -Root $r)
        }
        $orphans = @($allAvhdx2 | Where-Object { -not $activePaths.Contains((Normalize-Path $_.FullName)) } | Sort-Object FullName -Unique)

        Write-Host "AVHD/AVHDX left out of the chain: $($orphans.Count)"
        if ($orphans.Count -eq 0) {
            Write-OK "Consolidation completed by the Hyper-V auto-merge. Skipping to cleanup."
        } else {
            Write-Warn2 "Hyper-V could not complete everything. Performing manual merge of:"
            $orphans | ForEach-Object { Write-Host "   - $($_.FullName)" }
        }
    }

    # -----------------------------------------------------------------
    # 7) Recursive merge: children before parents (run on $orphans)
    # -----------------------------------------------------------------
    if ($orphans.Count -gt 0) {
        Write-Section "Merge execution"

        # Build map: path -> ParentPath
        $infoMap = @{}
        foreach ($f in $orphans) {
            try {
                $v = Get-VHD -Path $f.FullName -ErrorAction Stop
                $infoMap[(Normalize-Path $f.FullName)] = [pscustomobject]@{
                    Path   = $f.FullName
                    Parent = $v.ParentPath
                    Size   = $f.Length
                }
            } catch {
                Write-Err2 "Corrupted / unreadable VHD: $($f.FullName) - $($_.Exception.Message)"
            }
        }

        # Children map (limited to the orphan set)
        $childrenOf = @{}
        foreach ($k in $infoMap.Keys) { $childrenOf[$k] = @() }
        foreach ($k in $infoMap.Keys) {
            $p = $infoMap[$k].Parent
            if ($p) {
                $pk = Normalize-Path $p
                if ($childrenOf.ContainsKey($pk)) { $childrenOf[$pk] += $k }
            }
        }

        # ---- Summary + space check + confirmation --------------------------
        $plan = foreach ($k in $infoMap.Keys) {
            $it = $infoMap[$k]
            if ($it.Parent -and (Test-Path $it.Parent) -and (Test-Path $it.Path)) {
                [pscustomobject]@{
                    Child   = $it.Path
                    Parent  = $it.Parent
                    SizeMB  = [math]::Round($it.Size / 1MB, 1)
                }
            }
        }
        $plan = @($plan)

        if ($plan.Count -eq 0) {
            Write-Warn2 "No merge can be executed (missing parents or absent files). Skipping to cleanup."
        } else {
            Write-Host "Planned merge operations (child -> parent):"
            $plan | Format-Table -AutoSize -Wrap

            # Space check: sum, per parent volume, the bytes of the children flowing into it
            $reqPerRoot = @{}
            foreach ($k in $infoMap.Keys) {
                $it = $infoMap[$k]
                if ($it.Parent -and (Test-Path $it.Parent) -and (Test-Path $it.Path)) {
                    try { $root = [System.IO.Path]::GetPathRoot((Resolve-Path -LiteralPath $it.Parent).Path) }
                    catch { $root = $null }
                    if ($root) {
                        if (-not $reqPerRoot.ContainsKey($root)) { $reqPerRoot[$root] = [int64]0 }
                        $reqPerRoot[$root] += [int64]$it.Size
                    }
                }
            }

            $spaceWarn = $false
            foreach ($root in $reqPerRoot.Keys) {
                $free = Get-FreeSpaceBytes -Path $root
                $reqMB  = [math]::Round($reqPerRoot[$root] / 1MB, 1)
                if ($null -eq $free) {
                    Write-Warn2 ("Volume {0}: free space not determinable (required ~{1} MB)." -f $root, $reqMB)
                } else {
                    $freeMB = [math]::Round($free / 1MB, 1)
                    if ($free -lt $reqPerRoot[$root]) {
                        Write-Warn2 ("Volume {0}: space POTENTIALLY INSUFFICIENT. Free {1} MB, estimated ~{2} MB." -f $root, $freeMB, $reqMB)
                        $spaceWarn = $true
                    } else {
                        Write-Info ("Volume {0}: free {1} MB, estimated ~{2} MB. OK." -f $root, $freeMB, $reqMB)
                    }
                }
            }
            if ($spaceWarn) {
                Write-Warn2 "The estimate is conservative (current child size); dynamic disks may grow less."
            }

            $confirm = Read-Choice ("Confirm execution of {0} merge(s)? (y/n)" -f $plan.Count) @('y', 'n')
            if ($confirm -ne 'y') {
                Write-Info "Merge cancelled by user."
                $infoMap = @{}   # empty: nothing will run
            }
        }

        # ---- Recursive merge execution ------------------------------------
        $processed = @{}

        function Invoke-MergeRecursive {
            param([string]$Key)

            if ($processed[$Key]) { return }

            # 1) process children first (so when merging this one, it is a "leaf")
            foreach ($c in @($childrenOf[$Key])) {
                Invoke-MergeRecursive -Key $c
            }

            $item = $infoMap[$Key]
            if (-not $item) { $processed[$Key] = $true; return }

            if (-not $item.Parent) {
                Write-Warn2 "No parent declared for: $($item.Path) (pure orphan, skip merge)"
                $processed[$Key] = $true
                return
            }
            if (-not (Test-Path $item.Parent)) {
                Write-Warn2 "Missing parent for $($item.Path) -> $($item.Parent) (skip)"
                $processed[$Key] = $true
                return
            }

            # Verify the file still exists (it may have been consumed by a previous merge)
            if (-not (Test-Path $item.Path)) {
                Write-Info "Already removed by a previous merge: $($item.Path)"
                $processed[$Key] = $true
                return
            }

            Write-Info "Merge: $($item.Path)"
            Write-Info "   --> $($item.Parent)"
            try {
                # Merge-VHD: merges the differencing disk into its parent and deletes the source
                Merge-VHD -Path $item.Path -DestinationPath $item.Parent -ErrorAction Stop
                Write-OK "Merge completed."
            } catch {
                Write-Err2 "Merge failed: $($_.Exception.Message)"
            }
            $processed[$Key] = $true
        }

        foreach ($k in @($infoMap.Keys)) { Invoke-MergeRecursive -Key $k }
    } # end if ($orphans.Count -gt 0)

    # -----------------------------------------------------------------
    # 8) Cleanup: residual AVHD/AVHDX out of chain + ghost snapshots
    # -----------------------------------------------------------------
    Write-Section "Residual cleanup"

    $remaining = @()
    foreach ($r in $existingRoots) {
        $remaining += @(Get-AvhdFiles -Root $r)
    }
    $remaining = @($remaining | Where-Object { -not $activePaths.Contains((Normalize-Path $_.FullName)) })

    if ($remaining.Count -gt 0) {
        Write-Host "Residual AVHD/AVHDX not in active chain:"
        $remaining | ForEach-Object { Write-Host "   - $($_.FullName)  ($([math]::Round($_.Length/1MB,1)) MB)" }
        $rm = Read-Choice "Delete these files? (y/n)" @('y', 'n')
        if ($rm -eq 'y') {
            foreach ($f in $remaining) {
                try {
                    Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
                    Write-OK "Deleted: $($f.FullName)"
                } catch {
                    Write-Err2 "Cannot delete $($f.FullName): $($_.Exception.Message)"
                }
            }
        }
    } else {
        Write-OK "No residual AVHD/AVHDX."
    }

    # Snapshots with missing files = ghost snapshots
    $brokenSnaps = @()
    foreach ($s in (Get-VMSnapshot -VM $vm -ErrorAction SilentlyContinue)) {
        $missing = $false
        foreach ($d in (Get-VMHardDiskDrive -VMSnapshot $s)) {
            if (-not (Test-Path $d.Path)) { $missing = $true; break }
        }
        if ($missing) { $brokenSnaps += $s }
    }

    if ($brokenSnaps.Count -gt 0) {
        Write-Host "`nSnapshots with missing disks:"
        $brokenSnaps | ForEach-Object { Write-Host "   - $($_.Name)  (created $($_.CreationTime))" }
        $rs = Read-Choice "Remove these snapshots? (y/n)" @('y', 'n')
        if ($rs -eq 'y') {
            foreach ($s in $brokenSnaps) {
                try {
                    Remove-VMSnapshot -VMSnapshot $s -Confirm:$false -ErrorAction Stop
                    Write-OK "Snapshot removed: $($s.Name)"
                } catch {
                    Write-Err2 "Removal failed ($($s.Name)): $($_.Exception.Message)"
                }
            }
        }
    } else {
        Write-OK "No ghost snapshot."
    }

    Write-Section "Done"
    Write-OK "Operations completed on VM '$($vm.Name)'."
    Write-Info "Suggested: verify the VM state with Get-VM and Get-VHD before powering it on."
}

# =====================================================================
# Start log (transcript) + main loop
# =====================================================================
$logTs  = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
$logDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$logPath = Join-Path $logDir ("AVHDX_Merge_{0}.log" -f $logTs)

$transcriptOn = $false
try {
    Start-Transcript -Path $logPath -ErrorAction Stop | Out-Null
    $transcriptOn = $true
    Write-Info "Session log: $logPath"
} catch {
    Write-Warn2 "Cannot start the file log: $($_.Exception.Message)"
}

try {
    do {
        Invoke-AvhdMergeSession
        $next = Read-Choice "`nDo you want to (r)estart from VM selection or (e)xit? (r/e)" @('r', 'e')
    } while ($next -eq 'r')
    Write-Info "Exiting."
} finally {
    if ($transcriptOn) { try { Stop-Transcript | Out-Null } catch {} }
}
