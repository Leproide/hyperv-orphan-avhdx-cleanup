# Hyper-V AVHDX Merge

Interactive PowerShell tool to analyze, merge, and clean up **orphaned AVHD/AVHDX differencing disks** in Microsoft Hyper-V.

It rebuilds the full disk chain of a VM (active disks + all snapshots), detects AVHD/AVHDX files that are no longer part of the chain ("orphans"), and can merge them back into their parents, consolidate the whole snapshot chain, remove leftover files, and clean up ghost snapshots — all behind interactive confirmations.

Beyond plain merging, it handles the real-world failure cases that normally stall a Hyper-V consolidation: **stuck recovery checkpoints** left by interrupted host-level backups, **file locks** held by an active backup job, and **parent/child identifier mismatches** in the chain (error `0xC03A000E`).

> Works with both legacy `.avhd` (VHD-based) and modern `.avhdx` differencing disks.

## Features

- **VM picker** — numeric selection from the list of VMs on the host.
- **Three modes:**
  1. **Analysis only** (read-only) — reports the chain and orphans, makes no changes.
  2. **Analysis + orphan fix** — merges orphaned AVHD/AVHDX into their parents and cleans up residuals.
  3. **Full chain consolidation** — removes all snapshots (triggering Hyper-V's auto-merge), then manually merges anything left over.
- **Chain reconstruction** — follows `ParentPath` recursively for attached disks and every snapshot disk.
- **Backup-in-progress detection** — before any destructive action the script checks for activity actually running **on the selected VM** and refuses to operate when it is unsafe. It separates:
  - **Strong (blocking)** signals — VM `Status` (`Backing up`, `Merging`), VMMS `Operations`, and **recovery checkpoints** present on the VM. Only these gate destructive operations.
  - **Weak (advisory)** signals — backup software merely installed/running on the host (Veeam, Backup Exec, Commvault, Nakivo, Altaro, Hornetsecurity). Reported for context but **never** blocking, so running the script on the Veeam B&R server itself is not a false positive.

  The actual VM status is printed every time. If a destructive mode is chosen while a strong signal is present, it is downgraded to analysis unless explicitly forced.
- **Stuck recovery-checkpoint handling** — when snapshot removal fails because the subtree contains a recovery checkpoint, the script confirms no backup is running, then offers to release the lock via `Restart-Service vmms` and retries the removal (re-resolving the stale snapshot object).
- **Robust merge** — wraps `Merge-VHD` and handles:
  - **ID mismatch (`0xC03A000E`)** — offers to reconnect the parent with `Set-VHD -IgnoreIdMismatch` (with explicit warnings and confirmation) and retries the merge.
  - **File lock (`0x80070020`)** — does not force; reports the lock and tells you to wait for the backup job / restart `vmms`.
- **Optional backup** before any change — you choose the destination folder; a `<VMName>_<yyyy-MM-dd_HH-mm-ss>` subfolder is created inside it. VM name is sanitized for invalid Windows characters, and duplicate file names are de-collided automatically.
- **Automatic VM state handling** — `Running` (graceful shutdown or forced TurnOff), `Paused` (TurnOff), `Saved` (discard saved state), and a fallback for other states.
- **Pre-merge summary + free-space check** — shows each planned `child -> parent` merge with sizes, estimates required space per volume, and warns if a volume may be too small. Requires explicit confirmation before merging.
- **Post-merge re-scan** — recomputes the active chain (including remaining snapshots) before cleanup, so files still referenced are never proposed for deletion.
- **Residual & ghost cleanup** — deletes leftover AVHD/AVHDX outside the active chain (on confirmation, de-duplicated) and removes snapshots whose disk files are missing.
- **Session log** — a full transcript is written to `AVHDX_Merge_<timestamp>.log` next to the script.
- **Restart loop** — at the end you can restart from VM selection or exit.

## Requirements

- Windows with the **Hyper-V** role and the **Hyper-V PowerShell module**.
- **Run as Administrator** (enforced via `#Requires -RunAsAdministrator`).
- Windows PowerShell 5.1 or PowerShell 7+.

## Usage

```powershell
# Default run (auto-detects folders to scan)
.\AVHDX_Merge.ps1

# Include an extra folder in the scan (e.g. a backup location)
.\AVHDX_Merge.ps1 -AdditionalSearchPath 'D:\HyperV\Backups'
```

If script execution is blocked, run it for the current session with:

```powershell
powershell -ExecutionPolicy Bypass -File .\AVHDX_Merge.ps1
```

### Parameters

| Parameter               | Description                                              |
| ----------------------- | -------------------------------------------------------- |
| `-AdditionalSearchPath` | Optional extra folder to include in the AVHD/AVHDX scan. |

## How it works

1. **Select** a VM and a mode. The script immediately checks for backup/merge activity and warns (or downgrades destructive modes to analysis) if any is found.
2. It builds the **active chain**: every attached disk and every snapshot disk, walked up to their root parents.
3. It scans the relevant folders for `.avhd` / `.avhdx` files and flags any not in the active chain as **orphans** (results are de-duplicated).
4. In fix/consolidation modes it ensures the **VM is off**, re-checks for active backups, then offers a **backup**.
5. **Consolidation mode** removes all snapshots — handling stuck recovery checkpoints — and waits for Hyper-V's background merge to finish, then re-scans for anything left over.
6. A **recursive merge** (children before parents) consolidates remaining orphans through the robust merge wrapper, repairing ID mismatches when confirmed and reporting locks without forcing.
7. Finally it **re-scans the chain** and offers to clean up residual files and ghost snapshots.

Merges are **offline**: the VM must be powered off, which the script handles for you.

## Safety notes

- Operating on a disk chain while a host-level backup is running is what creates stuck recovery checkpoints and corruption in the first place. The script tries to detect this and stop you — but if you force past the warnings, you own the outcome.
- `Set-VHD -IgnoreIdMismatch` forces reconnection to a parent despite a GUID mismatch. Use it **only** if the indicated parent is genuinely the correct one and was not modified after the differencing disk was created; otherwise the resulting VHDX will be corrupt. Always keep a backup first.
- Always keep a **backup** of your `.vhd*` / `.avhd*` files before running a fix/consolidation. The built-in backup option is recommended.
- `Merge-VHD` modifies the parent disk and deletes the merged source — operations are **not reversible** without a backup.
- The free-space estimate is **conservative** (based on the current child file size); dynamic disks may grow less in practice.
- Verify the VM with `Get-VM` and `Get-VHD` before powering it back on.

## Disclaimer

Provided as-is, without warranty. Test on a non-production VM first. You are responsible for backing up your data before use.

## License

This project is licensed under the **GNU General Public License v3.0 (GPL-3.0)**.
See <https://www.gnu.org/licenses/gpl-3.0.html> for the full text.

## Author

[https://github.com/Leproide](https://github.com/Leproide)
