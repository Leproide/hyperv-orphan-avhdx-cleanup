# Hyper-V AVHDX Merge

Interactive PowerShell tool to analyze, merge, and clean up **orphaned AVHD/AVHDX differencing disks** in Microsoft Hyper-V.

It rebuilds the full disk chain of a VM (active disks + all snapshots), detects AVHD/AVHDX files that are no longer part of the chain ("orphans"), and can merge them back into their parents, consolidate the whole snapshot chain, remove leftover files, and clean up ghost snapshots — all behind interactive confirmations.

> Works with both legacy `.avhd` (VHD-based) and modern `.avhdx` differencing disks.

## Features

- **VM picker** — numeric selection from the list of VMs on the host.
- **Three modes:**
  1. **Analysis only** (read-only) — reports the chain and orphans, makes no changes.
  2. **Analysis + orphan fix** — merges orphaned AVHD/AVHDX into their parents and cleans up residuals.
  3. **Full chain consolidation** — removes all snapshots (triggering Hyper-V's auto-merge), then manually merges anything left over.
- **Chain reconstruction** — follows `ParentPath` recursively for attached disks and every snapshot disk.
- **Optional backup** before any change — you choose the destination folder; a `<VMName>_<yyyy-MM-dd_HH-mm-ss>` subfolder is created inside it. VM name is sanitized for invalid Windows characters, and duplicate file names are de-collided automatically.
- **Automatic VM state handling** — `Running` (graceful shutdown or forced TurnOff), `Paused` (TurnOff), `Saved` (discard saved state), and a fallback for other states.
- **Pre-merge summary + free-space check** — shows each planned `child -> parent` merge with sizes, estimates required space per volume, and warns if a volume may be too small. Requires explicit confirmation before merging.
- **Residual & ghost cleanup** — deletes leftover AVHD/AVHDX outside the active chain (on confirmation) and removes snapshots whose disk files are missing.
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

If script execution is blocked, you can run it for the current session with:

```powershell
powershell -ExecutionPolicy Bypass -File .\AVHDX_Merge.ps1
```

### Parameters

| Parameter | Description |
|---|---|
| `-AdditionalSearchPath` | Optional extra folder to include in the AVHD/AVHDX scan. |

## How it works

1. **Select** a VM and a mode.
2. The script builds the **active chain**: every attached disk and every snapshot disk, walked up to their root parents.
3. It scans the relevant folders for `.avhd` / `.avhdx` files and flags any not in the active chain as **orphans**.
4. In fix/consolidation modes it ensures the **VM is off**, offers a **backup**, optionally removes snapshots, then performs a **recursive merge** (children before parents) using `Merge-VHD`.
5. Finally it offers to **clean up** residual files and ghost snapshots.

Merges are **offline**: the VM must be powered off, which the script handles for you.

## Safety notes

- Always keep a **backup** of your `.vhd*` / `.avhd*` files before running a fix/consolidation. The built-in backup option is recommended.
- `Merge-VHD` modifies the parent disk and deletes the merged source — operations are **not reversible** without a backup.
- The free-space estimate is **conservative** (based on the current child file size); dynamic disks may grow less in practice.
- Verify the VM with `Get-VM` and `Get-VHD` before powering it back on.

## Disclaimer

Provided as-is, without warranty. Test on a non-production VM first. You are responsible for backing up your data before use.

## License

MIT (recommended — add a `LICENSE` file).
