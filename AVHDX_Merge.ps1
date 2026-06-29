#Requires -RunAsAdministrator
#Requires -Modules Hyper-V

# =====================================================================
#  AVHDX_Merge.ps1
#  Author: https://github.com/Leproide
#  License: GPL-3.0
#
#  This program is free software: you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation, either version 3 of the License, or
#  (at your option) any later version.
#
#  This program is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#  You should have received a copy of the GNU General Public License
#  along with this program.  If not, see <https://www.gnu.org/licenses/>.
# =====================================================================

<#
.SYNOPSIS
    Analisi, consolidamento e riparazione interattiva di catene AVHDX in Hyper-V.

.DESCRIPTION
    - Elenca le VM con scelta numerica.
    - Modalità: solo analisi | analisi + merge orfani | consolidamento completo.
    - Ricostruisce la catena dischi (VM attiva + tutti gli snapshot) risalendo i parent.
    - Scansiona le cartelle pertinenti e individua gli AVHDX fuori catena (orfani).
    - Merge ricorsivo figli->padre, eliminazione residui, rimozione snapshot fantasma.

    Fix specifici per problemi reali frequenti:
      * Recovery checkpoint bloccati (lasciati da backup host-level interrotti).
      * Lock VMMS / file occupati durante un job di backup attivo (Veeam, WSB, Azure).
      * Mismatch identificatori parent/child nella catena (errore 0xC03A000E):
        riconnessione del parent con Set-VHD -IgnoreIdMismatch prima del merge.
      * Backup automatico opzionale dei file prima di operazioni distruttive.
      * De-duplicazione dei risultati per evitare doppioni nelle liste.

.PARAMETER AdditionalSearchPath
    Cartella aggiuntiva da scansionare (opzionale).

.PARAMETER BackupRoot
    Cartella in cui copiare i file della catena prima di operazioni distruttive.
    Se non specificata, lo script chiede interattivamente quando serve.

.PARAMETER NoBackup
    Disabilita la richiesta di backup pre-operazione (uso non presidiato/avanzato).

.EXAMPLE
    .\AVHDX_Merge.ps1
    .\AVHDX_Merge.ps1 -AdditionalSearchPath 'D:\HyperV\Backups'
    .\AVHDX_Merge.ps1 -BackupRoot 'F:\PreMergeBackup'

.NOTES
    Author: https://github.com/Leproide
    License: GPL-3.0
#>

[CmdletBinding()]
param(
    [string]$AdditionalSearchPath,
    [string]$BackupRoot,
    [switch]$NoBackup
)

$ErrorActionPreference = 'Stop'

# =====================================================================
# Utility output
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
        Write-Warn2 "Risposta non valida. Opzioni: $($Valid -join ', ')"
    }
}

# Normalizza path per confronti case-insensitive
function Normalize-Path($p) {
    if (-not $p) { return $null }
    try {
        $rp = (Resolve-Path -LiteralPath $p -ErrorAction Stop).Path
        return $rp.ToLower()
    } catch {
        return $p.ToLower()
    }
}

# =====================================================================
# Helper: rileva job di backup host-level attivi (Veeam, WSB, Azure, ecc.)
# Evita di operare sulla catena mentre VMMS tiene i file in lock.
# =====================================================================
function Test-BackupInProgress {
    param([Microsoft.HyperV.PowerShell.VirtualMachine]$VmObj)

    $reasons = @()

    # 1) Stato/operazioni VMMS che indicano backup o merge in corso
    $vmNow = Get-VM -Name $VmObj.Name -ErrorAction SilentlyContinue
    if ($vmNow) {
        if ($vmNow.Status -match 'Backing up|Backup|Merging') {
            $reasons += "Stato VM: '$($vmNow.Status)'"
        }
        $opsStr = if ($vmNow.Operations) {
            ($vmNow.Operations | ForEach-Object { $_.ToString() }) -join ','
        } else { '' }
        if ($opsStr -match 'Backup|Merg|Export|Snapshot') {
            $reasons += "Operazioni VMMS: '$opsStr'"
        }
    }

    # 2) Recovery checkpoint freschi (tipico marker di backup host-level in corso)
    $recovery = @(Get-VMSnapshot -VMName $VmObj.Name -ErrorAction SilentlyContinue |
                  Where-Object { $_.SnapshotType -eq 'Recovery' })
    foreach ($rc in $recovery) {
        $ageMin = [math]::Round(((Get-Date) - $rc.CreationTime).TotalMinutes, 1)
        $reasons += "Recovery checkpoint '$($rc.Name)' (eta' $ageMin min)"
    }

    # 3) Servizi di backup comuni in esecuzione
    $svc = @(Get-Service -ErrorAction SilentlyContinue |
             Where-Object {
                 $_.Status -eq 'Running' -and
                 ($_.Name -match 'Veeam' -or $_.DisplayName -match 'Veeam|Backup Exec|Commvault|Nakivo|Altaro|Hornetsecurity')
             })
    foreach ($s in $svc) { $reasons += "Servizio backup attivo: $($s.DisplayName)" }

    [pscustomobject]@{
        InProgress = ($reasons.Count -gt 0)
        Reasons    = $reasons
    }
}

# =====================================================================
# Helper: attende che la VM esca da merge/backup in background.
# Copre Status 'Merging disks' e 'Backing up' + Operations VMMS.
# =====================================================================
function Wait-VmIdle {
    param(
        [string]$VmName,
        [int]$TimeoutMinutes = 120
    )
    Write-Info "Attesa completamento operazioni VMMS in background..."
    $timeout = (Get-Date).AddMinutes($TimeoutMinutes)
    do {
        Start-Sleep -Seconds 5
        $vmNow = Get-VM -Name $VmName -ErrorAction SilentlyContinue
        if (-not $vmNow) { break }
        $opsStr = if ($vmNow.Operations) {
            ($vmNow.Operations | ForEach-Object { $_.ToString() }) -join ','
        } else { '' }
        $busy = ($vmNow.Status -match 'Merging|Backing up') -or ($opsStr -match 'Merg|Backup')
        if ($busy) {
            Write-Info ("  in corso... Status='{0}' Ops='{1}'" -f $vmNow.Status, $opsStr)
        }
        if ((Get-Date) -gt $timeout) {
            Write-Warn2 "Timeout attesa ($TimeoutMinutes min). Proseguo comunque."
            break
        }
    } while ($busy)
    Write-OK "Nessuna operazione VMMS in background residua."
}

# =====================================================================
# Helper: backup (copia) dei file della catena prima di operazioni distruttive.
# Ritorna $true se l'utente ha proceduto (con o senza backup), $false se annulla.
# =====================================================================
function Invoke-PreOpBackup {
    param(
        [string[]]$Files,
        [string]$Root
    )
    if ($NoBackup) {
        Write-Warn2 "Backup pre-operazione DISABILITATO (-NoBackup)."
        return $true
    }

    $Files = @($Files | Where-Object { $_ -and (Test-Path $_) } | Sort-Object -Unique)
    if ($Files.Count -eq 0) { return $true }

    $totalMB = [math]::Round((($Files | ForEach-Object { (Get-Item $_).Length }) |
                Measure-Object -Sum).Sum / 1MB, 1)
    Write-Warn2 "RACCOMANDATO: backup dei file della catena prima di procedere ($($Files.Count) file, ~$totalMB MB)."
    $b = Read-Choice "Eseguire una copia di sicurezza adesso? (s/n)" @('s','n')
    if ($b -ne 's') {
        $c = Read-Choice "Procedere SENZA backup? (s/n)" @('s','n')
        return ($c -eq 's')
    }

    if (-not $Root) {
        $def = Join-Path ([IO.Path]::GetDirectoryName($Files[0])) ("_PreMergeBackup_{0:yyyyMMdd_HHmmss}" -f (Get-Date))
        $in = Read-Host "Cartella destinazione backup [INVIO = $def]"
        $Root = if ([string]::IsNullOrWhiteSpace($in)) { $def } else { $in }
    }

    try {
        if (-not (Test-Path $Root)) { New-Item -ItemType Directory -Path $Root -Force | Out-Null }
        foreach ($f in $Files) {
            $dest = Join-Path $Root (Split-Path -Leaf $f)
            Write-Info "Copia: $f -> $dest"
            Copy-Item -LiteralPath $f -Destination $dest -Force
        }
        Write-OK "Backup completato in: $Root"
        return $true
    } catch {
        Write-Err2 "Backup fallito: $($_.Exception.Message)"
        $c = Read-Choice "Procedere comunque SENZA backup completo? (s/n)" @('s','n')
        return ($c -eq 's')
    }
}

# =====================================================================
# Helper: merge robusto di un differencing disk nel suo parent.
# Gestisce il mismatch ID (0xC03A000E) con Set-VHD -IgnoreIdMismatch,
# previa conferma esplicita dell'utente, e riprova il merge.
# Ritorna $true se il merge ha avuto successo.
# =====================================================================
function Invoke-RobustMerge {
    param(
        [string]$ChildPath,
        [string]$ParentPath
    )

    function _try-merge {
        Merge-VHD -Path $ChildPath -DestinationPath $ParentPath -ErrorAction Stop
    }

    try {
        _try-merge
        Write-OK "Merge completato."
        return $true
    } catch {
        $msg = $_.Exception.Message
        $hr  = $_.Exception.HResult

        # 0xC03A000E = mismatch identificatori parent/child
        $isIdMismatch = ($msg -match '0xC03A000E') -or ($msg -match 'mismatch') -or ($hr -eq 0xC03A000E)

        # 0x80070020 = file in uso (lock VMMS / backup): non si forza, si segnala.
        $isLock = ($msg -match '0x80070020') -or ($msg -match 'being used by another process')

        if ($isLock) {
            Write-Err2 "Merge fallito: file in uso (lock VMMS/backup). $msg"
            Write-Warn2 "Un backup host-level o un merge in background sta usando il file."
            Write-Warn2 "Attendere la fine del job, eventualmente 'Restart-Service vmms -Force', poi riprovare."
            return $false
        }

        if (-not $isIdMismatch) {
            Write-Err2 "Merge fallito: $msg"
            return $false
        }

        # --- Caso mismatch ID -------------------------------------------------
        Write-Warn2 "Merge bloccato da mismatch identificatori parent/child (0xC03A000E)."
        Write-Info  "Child : $ChildPath"
        Write-Info  "Parent: $ParentPath"

        if (-not (Test-Path $ParentPath)) {
            Write-Err2 "Parent inesistente: impossibile riallineare la catena."
            return $false
        }

        Write-Warn2 "Forzare la riconnessione al parent (Set-VHD -IgnoreIdMismatch) e ritentare il merge?"
        Write-Warn2 "ATTENZIONE: usare SOLO se il parent indicato e' davvero quello corretto e non e'"
        Write-Warn2 "stato modificato dopo la creazione del delta. In caso contrario il VHDX risultante"
        Write-Warn2 "sara' corrotto. Assicurarsi di avere un backup."
        $f = Read-Choice "Procedere con -IgnoreIdMismatch? (s/n)" @('s','n')
        if ($f -ne 's') {
            Write-Info "Riconnessione forzata annullata dall'utente."
            return $false
        }

        try {
            Set-VHD -Path $ChildPath -ParentPath $ParentPath -IgnoreIdMismatch -ErrorAction Stop
            Write-OK "Parent riconnesso (mismatch ignorato)."
        } catch {
            $sm = $_.Exception.Message
            if ($sm -match '0x80070020' -or $sm -match 'being used by another process') {
                Write-Err2 "Set-VHD fallito: file in uso (lock VMMS/backup). $sm"
                Write-Warn2 "Chiudere il job di backup / 'Restart-Service vmms -Force' e riprovare."
            } else {
                Write-Err2 "Set-VHD -IgnoreIdMismatch fallito: $sm"
            }
            return $false
        }

        try {
            _try-merge
            Write-OK "Merge completato dopo riallineamento parent."
            return $true
        } catch {
            Write-Err2 "Merge ancora fallito dopo Set-VHD: $($_.Exception.Message)"
            return $false
        }
    }
}

# =====================================================================
# Helper: rimozione snapshot con gestione recovery checkpoint bloccati.
# Se la rimozione fallisce per recovery checkpoint, tenta lo sblocco
# (restart VMMS) e ritenta. Ritorna $true se l'albero e' stato rimosso.
# =====================================================================
function Remove-SnapshotTreeSafe {
    param([Microsoft.HyperV.PowerShell.VMSnapshot]$RootSnapshot, [string]$VmName)

    try {
        Write-Info "Rimozione albero snapshot: $($RootSnapshot.Name)"
        Remove-VMSnapshot -VMSnapshot $RootSnapshot -IncludeAllChildSnapshots -Confirm:$false -ErrorAction Stop
        return $true
    } catch {
        $msg = $_.Exception.Message
        $isRecovery = $msg -match 'recovery checkpoint'

        if (-not $isRecovery) {
            Write-Err2 "Errore rimozione $($RootSnapshot.Name): $msg"
            return $false
        }

        # --- Recovery checkpoint bloccato -------------------------------------
        Write-Warn2 "Rimozione bloccata da un RECOVERY CHECKPOINT (residuo di un backup host-level)."
        Write-Warn2 "Tipicamente lasciato da un job Veeam/WSB/Azure interrotto o ancora in corso."

        $bk = Test-BackupInProgress -VmObj (Get-VM -Name $VmName)
        if ($bk.InProgress) {
            Write-Err2 "Risulta un backup/operazione ANCORA IN CORSO. Non forzo nulla."
            $bk.Reasons | ForEach-Object { Write-Warn2 "  - $_" }
            Write-Warn2 "Attendere la fine del job di backup e rilanciare lo script."
            return $false
        }

        Write-Warn2 "Nessun job di backup attivo rilevato: il checkpoint sembra ORFANO."
        $u = Read-Choice "Tentare lo sblocco (Restart-Service vmms) e ritentare la rimozione? (s/n)" @('s','n')
        if ($u -ne 's') { return $false }

        try {
            Write-Info "Restart del servizio Hyper-V Virtual Machine Management (vmms)..."
            Restart-Service vmms -Force -ErrorAction Stop
            Start-Sleep -Seconds 5
            # attende che il servizio risalga
            $svc = Get-Service vmms
            $deadline = (Get-Date).AddMinutes(2)
            while ($svc.Status -ne 'Running' -and (Get-Date) -lt $deadline) {
                Start-Sleep -Seconds 2; $svc.Refresh()
            }
            Write-OK "vmms: $($svc.Status)"
        } catch {
            Write-Err2 "Restart vmms fallito: $($_.Exception.Message)"
            return $false
        }

        # ritenta la rimozione, ri-risolvendo lo snapshot (l'oggetto puo' essere stantio)
        try {
            $fresh = Get-VMSnapshot -VMName $VmName -ErrorAction Stop |
                     Where-Object { $_.Id -eq $RootSnapshot.Id }
            if (-not $fresh) {
                Write-OK "Il recovery checkpoint risulta gia' rimosso dopo lo sblocco."
                return $true
            }
            Remove-VMSnapshot -VMSnapshot $fresh -IncludeAllChildSnapshots -Confirm:$false -ErrorAction Stop
            Write-OK "Recovery checkpoint rimosso dopo sblocco."
            return $true
        } catch {
            Write-Err2 "Rimozione ancora fallita dopo sblocco: $($_.Exception.Message)"
            Write-Warn2 "Verificare nella console di backup che non vi siano job appesi su questa VM."
            return $false
        }
    }
}

# =====================================================================
# 1) Selezione VM
# =====================================================================
Write-Section "Ricerca VM"
$vms = @(Get-VM | Sort-Object Name)
if ($vms.Count -eq 0) { Write-Err2 "Nessuna VM trovata su questo host."; return }

for ($i = 0; $i -lt $vms.Count; $i++) {
    "{0,3}) {1}  [{2}]" -f ($i + 1), $vms[$i].Name, $vms[$i].State | Write-Host
}

[int]$sel = 0
while ($sel -lt 1 -or $sel -gt $vms.Count) {
    $raw = Read-Host "`nSeleziona VM (1-$($vms.Count))"
    [void][int]::TryParse($raw, [ref]$sel)
}
$vm = $vms[$sel - 1]
Write-OK "VM selezionata: $($vm.Name)  (Stato: $($vm.State))"

# Guard globale: se c'e' un backup in corso, blocca subito le modalita' distruttive.
$bkInit = Test-BackupInProgress -VmObj $vm
if ($bkInit.InProgress) {
    Write-Warn2 "Rilevata attivita' di backup/merge in corso su questa VM:"
    $bkInit.Reasons | ForEach-Object { Write-Warn2 "  - $_" }
    Write-Warn2 "Operare ora sulla catena puo' generare recovery checkpoint orfani o corruzione."
    Write-Warn2 "Consigliato: attendere la fine del job. Sara' comunque possibile fare solo l'analisi."
}

# =====================================================================
# 2) Scelta modalità
# =====================================================================
Write-Section "Modalità"
Write-Host "  1) Solo analisi (read-only)"
Write-Host "  2) Analisi + merge / pulizia orfani"
Write-Host "  3) Consolidamento COMPLETO catena (rimuove snapshot + merge AVHDX nel parent VHDX)"
$modeRaw = Read-Host "Scelta (1/2/3)"
$doFix          = ($modeRaw -eq '2')
$doConsolidate  = ($modeRaw -eq '3')
$modeLabel = switch ($modeRaw) {
    '2' { 'ANALISI + FIX ORFANI' }
    '3' { 'CONSOLIDAMENTO CATENA' }
    default { 'SOLO ANALISI' }
}
Write-OK "Modalità: $modeLabel"

# Se backup in corso e l'utente sceglie una modalita' distruttiva, richiedi conferma forte.
if (($doFix -or $doConsolidate) -and $bkInit.InProgress) {
    Write-Err2 "Backup/merge in corso: le operazioni distruttive sono SCONSIGLIATE adesso."
    $force = Read-Choice "Forzare comunque (NON consigliato)? (s/n)" @('s','n')
    if ($force -ne 's') {
        Write-Info "Procedo in SOLA ANALISI per sicurezza."
        $doFix = $false; $doConsolidate = $false
    }
}

# =====================================================================
# 3) Ricostruzione catena dischi attivi
#    Include: dischi correntemente collegati + dischi di tutti gli snapshot
#    Per ognuno risale ricorsivamente al ParentPath
# =====================================================================
Write-Section "Analisi catena dischi"

$attached = @(Get-VMHardDiskDrive -VM $vm | Select-Object -ExpandProperty Path)
Write-Info "Dischi collegati alla VM: $($attached.Count)"

$snapshots = @(Get-VMSnapshot -VM $vm -ErrorAction SilentlyContinue)
Write-Info "Snapshot configurati: $($snapshots.Count)"

$snapDisks = @()
foreach ($s in $snapshots) {
    $snapDisks += @(Get-VMHardDiskDrive -VMSnapshot $s | Select-Object -ExpandProperty Path)
}

$activePaths = New-Object System.Collections.Generic.HashSet[string]

# Risale la catena padre per ogni disco e marca tutti i livelli come "attivi"
function Add-ChainToActive {
    param([string]$Path, [System.Collections.Generic.HashSet[string]]$Set)
    $current = $Path
    while ($current) {
        $norm = Normalize-Path $current
        if (-not $Set.Add($norm)) { break }  # già visitato
        try {
            $v = Get-VHD -Path $current -ErrorAction Stop
            $current = $v.ParentPath
        } catch {
            Write-Warn2 "VHD illeggibile nella catena: $current ($($_.Exception.Message))"
            break
        }
    }
}

foreach ($p in (@($attached) + @($snapDisks) | Sort-Object -Unique)) {
    if ($p) { Add-ChainToActive -Path $p -Set $activePaths }
}
Write-Info "File totali in catena attiva: $($activePaths.Count)"

# =====================================================================
# 4) Determina cartelle da scansionare
# =====================================================================
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
Write-Info "Cartelle da scansionare:"
$existingRoots | ForEach-Object { Write-Host "   - $_" }

# =====================================================================
# 5) Scansione AVHDX e individuazione orfani
# =====================================================================
$allAvhdx = @()
foreach ($r in $existingRoots) {
    $allAvhdx += @(Get-ChildItem -Path $r -Filter *.avhdx -Recurse -File -ErrorAction SilentlyContinue)
}
$allAvhdx = $allAvhdx | Sort-Object FullName -Unique

$orphans = @()
foreach ($f in $allAvhdx) {
    if (-not $activePaths.Contains((Normalize-Path $f.FullName))) {
        $orphans += $f
    }
}
$orphans = @($orphans | Sort-Object FullName -Unique)   # de-dup difensivo

$activeAvhdxCount = ($activePaths | Where-Object { $_ -like '*.avhdx' }).Count

Write-Section "Risultati analisi"
Write-Host "AVHDX totali trovati  : $($allAvhdx.Count)"
Write-Host "AVHDX in catena attiva: $activeAvhdxCount"
Write-Host "AVHDX orfani          : $($orphans.Count)" -ForegroundColor $(if ($orphans.Count) { 'Yellow' } else { 'Green' })

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

# Mostra dettaglio della catena attiva (utile per modalità 3)
$activeAvhdxFiles = @($activePaths | Where-Object { $_ -like '*.avhdx' })
if ($activeAvhdxFiles.Count -gt 0) {
    Write-Host "`nAVHDX nella catena attiva (candidati al consolidamento):"
    foreach ($p in $activeAvhdxFiles) {
        $size = if (Test-Path $p) { [math]::Round((Get-Item $p).Length / 1MB, 1) } else { 'n/a' }
        Write-Host ("   - {0}  ({1} MB)" -f $p, $size)
    }
}

# Stop se solo analisi
if (-not $doFix -and -not $doConsolidate) {
    Write-OK "Analisi completata. Nessuna modifica effettuata."
    return
}

# Modalità 2: nessun orfano = niente da fare
if ($doFix -and $orphans.Count -eq 0) {
    Write-OK "Nessun orfano da elaborare. Per consolidare la catena usare l'opzione 3."
    return
}

# Modalità 3: nessun AVHDX = nessuna catena da consolidare
if ($doConsolidate -and $activeAvhdxFiles.Count -eq 0 -and $orphans.Count -eq 0) {
    Write-OK "Nessun AVHDX presente. Catena già consolidata."
    return
}

# =====================================================================
# 6) Pre-fix: VM deve essere spenta per merge sicuro
# =====================================================================
Write-Section "Preparazione fix"

if ($vm.State -ne 'Off') {
    Write-Warn2 "VM in stato '$($vm.State)'. Il merge offline richiede VM SPENTA."
    $a = Read-Choice "Spegnere la VM ora? (s/n)" @('s', 'n')
    if ($a -eq 's') {
        try {
            Stop-VM -Name $vm.Name -Force -TurnOff -ErrorAction Stop
            Write-OK "VM spenta."
        } catch {
            Write-Err2 "Impossibile spegnere la VM: $($_.Exception.Message)"
            return
        }
    } else {
        Write-Err2 "Operazione annullata dall'utente."
        return
    }
}

# Ricontrolla backup in corso subito prima delle operazioni distruttive.
$bkNow = Test-BackupInProgress -VmObj (Get-VM -Name $vm.Name)
if ($bkNow.InProgress) {
    Write-Err2 "Rilevata attivita' di backup/merge in corso PROPRIO ORA:"
    $bkNow.Reasons | ForEach-Object { Write-Warn2 "  - $_" }
    $c = Read-Choice "Procedere comunque (NON consigliato)? (s/n)" @('s','n')
    if ($c -ne 's') { Write-Info "Annullato per sicurezza."; return }
}

# Backup pre-operazione dei file coinvolti (catena attiva + orfani noti).
$filesForBackup = @()
$filesForBackup += @($activePaths | Where-Object { $_ -and (Test-Path $_) })
$filesForBackup += @($orphans | ForEach-Object { $_.FullName })
if (-not (Invoke-PreOpBackup -Files $filesForBackup -Root $BackupRoot)) {
    Write-Info "Annullato."
    return
}

# =====================================================================
# 6.1) MODALITÀ 3: rimozione snapshot (innesca auto-merge di Hyper-V)
# =====================================================================
if ($doConsolidate) {
    Write-Section "Consolidamento: rimozione snapshot"

    $allSnaps = @(Get-VMSnapshot -VM $vm -ErrorAction SilentlyContinue)
    if ($allSnaps.Count -gt 0) {
        Write-Host "Snapshot presenti:"
        $allSnaps | ForEach-Object {
            $tag = if ($_.SnapshotType -eq 'Recovery') { '  [RECOVERY]' } else { '' }
            Write-Host "   - $($_.Name)  (tipo $($_.SnapshotType), creato $($_.CreationTime))$tag"
        }

        # Avviso esplicito se sono presenti recovery checkpoint.
        $recoveryPresent = @($allSnaps | Where-Object { $_.SnapshotType -eq 'Recovery' })
        if ($recoveryPresent.Count -gt 0) {
            Write-Warn2 "Presenti $($recoveryPresent.Count) RECOVERY checkpoint: residui di backup host-level."
            Write-Warn2 "Verranno gestiti con sblocco automatico se nessun backup risulta attivo."
        }

        $c = Read-Choice "Rimuovere TUTTI gli snapshot (Hyper-V eseguirà il merge automatico)? (s/n)" @('s','n')
        if ($c -eq 's') {
            # Rimuove gli alberi a partire dalle root (snapshot senza parent),
            # con gestione robusta dei recovery checkpoint bloccati.
            $rootSnaps = @($allSnaps | Where-Object { -not $_.ParentSnapshotId })
            foreach ($r in $rootSnaps) {
                [void](Remove-SnapshotTreeSafe -RootSnapshot $r -VmName $vm.Name)
            }

            # Attende il completamento del merge/backup in background di Hyper-V.
            Wait-VmIdle -VmName $vm.Name -TimeoutMinutes 120
            Write-OK "Auto-merge Hyper-V terminato."
        } else {
            Write-Info "Rimozione snapshot saltata."
        }
    } else {
        Write-Info "Nessuno snapshot configurato. Procedo direttamente al merge manuale."
    }

    # ---- Re-scan: ricalcola catena attiva e individua AVHDX rimasti come orfani ----
    Write-Section "Re-scan post auto-merge"
    $vm = Get-VM -Name $vm.Name   # refresh oggetto VM
    $activePaths.Clear()
    $attached2 = @(Get-VMHardDiskDrive -VM $vm | Select-Object -ExpandProperty Path)
    foreach ($p in $attached2) { Add-ChainToActive -Path $p -Set $activePaths }

    $allAvhdx2 = @()
    foreach ($r in $existingRoots) {
        $allAvhdx2 += @(Get-ChildItem -Path $r -Filter *.avhdx -Recurse -File -ErrorAction SilentlyContinue)
    }
    $orphans = @($allAvhdx2 | Where-Object { -not $activePaths.Contains((Normalize-Path $_.FullName)) } |
                Sort-Object FullName -Unique)

    Write-Host "AVHDX rimasti fuori catena: $($orphans.Count)"
    if ($orphans.Count -eq 0) {
        Write-OK "Consolidamento completato dall'auto-merge di Hyper-V. Salto al cleanup."
    } else {
        Write-Warn2 "Hyper-V non ha potuto completare tutto. Eseguo merge manuale di:"
        $orphans | ForEach-Object { Write-Host "   - $($_.FullName)" }
    }
}

# =====================================================================
# 7) Merge ricorsivo: figli prima dei padri (eseguito su $orphans)
# =====================================================================
if ($orphans.Count -gt 0) {
Write-Section "Esecuzione merge"

# Costruisce mappa: path -> ParentPath
$infoMap = @{}
foreach ($f in $orphans) {
    try {
        $v = Get-VHD -Path $f.FullName -ErrorAction Stop
        $infoMap[(Normalize-Path $f.FullName)] = [pscustomobject]@{
            Path   = $f.FullName
            Parent = $v.ParentPath
        }
    } catch {
        Write-Err2 "VHD corrotto / illeggibile: $($f.FullName) - $($_.Exception.Message)"
    }
}

# Mappa figli (limitata all'insieme degli orfani)
$childrenOf = @{}
foreach ($k in $infoMap.Keys) { $childrenOf[$k] = @() }
foreach ($k in $infoMap.Keys) {
    $p = $infoMap[$k].Parent
    if ($p) {
        $pk = Normalize-Path $p
        if ($childrenOf.ContainsKey($pk)) { $childrenOf[$pk] += $k }
    }
}

$processed = @{}

function Invoke-MergeRecursive {
    param([string]$Key)

    if ($processed[$Key]) { return }

    # 1) processa prima i figli (così quando faccio merge di questo, è una "foglia")
    foreach ($c in @($childrenOf[$Key])) {
        Invoke-MergeRecursive -Key $c
    }

    $item = $infoMap[$Key]
    if (-not $item) { $processed[$Key] = $true; return }

    if (-not $item.Parent) {
        Write-Warn2 "Nessun parent dichiarato per: $($item.Path) (orfano puro, skip merge)"
        $processed[$Key] = $true
        return
    }
    if (-not (Test-Path $item.Parent)) {
        Write-Warn2 "Parent mancante per $($item.Path) -> $($item.Parent) (skip)"
        $processed[$Key] = $true
        return
    }

    # Verifica che il file esista ancora (potrebbe essere stato consumato da un merge precedente)
    if (-not (Test-Path $item.Path)) {
        Write-Info "Già rimosso da merge precedente: $($item.Path)"
        $processed[$Key] = $true
        return
    }

    Write-Info "Merge: $($item.Path)"
    Write-Info "   --> $($item.Parent)"
    # Merge robusto: gestisce mismatch ID (0xC03A000E) e lock file (0x80070020).
    [void](Invoke-RobustMerge -ChildPath $item.Path -ParentPath $item.Parent)
    $processed[$Key] = $true
}

foreach ($k in @($infoMap.Keys)) { Invoke-MergeRecursive -Key $k }
} # fine if ($orphans.Count -gt 0)

# =====================================================================
# 8) Pulizia: AVHDX residui fuori catena + snapshot fantasma
# =====================================================================
Write-Section "Pulizia residui"

# Ricalcola la catena attiva reale dopo i merge, per non eliminare file ancora referenziati.
$activePaths.Clear()
$vm = Get-VM -Name $vm.Name
$attachedFinal = @(Get-VMHardDiskDrive -VM $vm | Select-Object -ExpandProperty Path)
$snapDisksFinal = @()
foreach ($s in (Get-VMSnapshot -VM $vm -ErrorAction SilentlyContinue)) {
    $snapDisksFinal += @(Get-VMHardDiskDrive -VMSnapshot $s | Select-Object -ExpandProperty Path)
}
foreach ($p in (@($attachedFinal) + @($snapDisksFinal) | Sort-Object -Unique)) {
    if ($p) { Add-ChainToActive -Path $p -Set $activePaths }
}

$remaining = @()
foreach ($r in $existingRoots) {
    $remaining += @(Get-ChildItem -Path $r -Filter *.avhdx -Recurse -File -ErrorAction SilentlyContinue)
}
# Dedup per FullName + esclusione di quanto ancora in catena attiva.
$remaining = @($remaining |
    Sort-Object FullName -Unique |
    Where-Object { -not $activePaths.Contains((Normalize-Path $_.FullName)) })

if ($remaining.Count -gt 0) {
    Write-Host "AVHDX residui non in catena attiva:"
    $remaining | ForEach-Object { Write-Host "   - $($_.FullName)  ($([math]::Round($_.Length/1MB,1)) MB)" }
    $rm = Read-Choice "Eliminare questi file? (s/n)" @('s', 'n')
    if ($rm -eq 's') {
        foreach ($f in $remaining) {
            try {
                Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
                Write-OK "Eliminato: $($f.FullName)"
            } catch {
                Write-Err2 "Impossibile eliminare $($f.FullName): $($_.Exception.Message)"
            }
        }
    }
} else {
    Write-OK "Nessun AVHDX residuo."
}

# Snapshot con file mancanti = snapshot fantasma
$brokenSnaps = @()
foreach ($s in (Get-VMSnapshot -VM $vm -ErrorAction SilentlyContinue)) {
    $missing = $false
    foreach ($d in (Get-VMHardDiskDrive -VMSnapshot $s)) {
        if (-not (Test-Path $d.Path)) { $missing = $true; break }
    }
    if ($missing) { $brokenSnaps += $s }
}

if ($brokenSnaps.Count -gt 0) {
    Write-Host "`nSnapshot con dischi mancanti:"
    $brokenSnaps | ForEach-Object { Write-Host "   - $($_.Name)  (creato $($_.CreationTime))" }
    $rs = Read-Choice "Rimuovere questi snapshot? (s/n)" @('s', 'n')
    if ($rs -eq 's') {
        foreach ($s in $brokenSnaps) {
            try {
                Remove-VMSnapshot -VMSnapshot $s -Confirm:$false -ErrorAction Stop
                Write-OK "Snapshot rimosso: $($s.Name)"
            } catch {
                Write-Err2 "Rimozione fallita ($($s.Name)): $($_.Exception.Message)"
            }
        }
    }
} else {
    Write-OK "Nessuno snapshot fantasma."
}

Write-Section "Completato"
Write-OK "Operazioni terminate sulla VM '$($vm.Name)'."
Write-Info "Suggerito: verificare lo stato della VM con Get-VM e Get-VHD prima di accenderla."
