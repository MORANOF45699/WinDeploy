# WinDeploy

Point it at a Windows ISO. It applies the image to a partition you pick and adds the
boot menu entry itself — no Media Creation Tool, no booting from a USB stick first.
It also writes bootable USBs, and backs up / restores drivers the way Double Driver did.

Plain PowerShell + WPF. Nothing to build, nothing to install: copy the folder, run it.

```
WinDeploy/
  WinDeploy.cmd                 <- right-click, Run as administrator
  WinDeploy.ps1
  ui/MainWindow.xaml
  modules/*.psm1
  assets/unattend.template.xml
```

## Requirements

- Windows 10 or 11, 64-bit
- Windows PowerShell 5.1 (ships with Windows — **not** PowerShell 7, WPF needs STA)
- Administrator. The script re-launches itself elevated if you forget.

## Tabs

### Install to partition
1. Pick an `.iso` (or a folder you already extracted one into) and press **Read editions**.
2. Pick the edition, then the target disk.
3. Either create a new partition (it shrinks an existing one if there is no free space),
   or point it at an existing partition to erase.
4. Optionally inject a driver backup and skip most of OOBE.
5. **Install Windows** — confirm by typing the disk number.

Under the hood: `DISM /Apply-Image` then `bcdboot`, which is exactly what Windows Setup
does. The result is a real installation, not a clone.

Reboot afterwards and the new entry is in the boot menu. The old Windows is untouched.

### Create bootable USB
GPT + FAT32, because that is what UEFI firmware with Secure Boot will actually boot.
An `install.wim` over 4 GB is split into `.swm` files automatically. On a stick larger
than 32 GB the remainder becomes a plain NTFS data partition.

Only removable USB disks are listed. The system disk is never offered.

### Drivers
**Scan drivers** lists every third-party driver, with the device each one is bound to.
Classes Windows rarely has a working driver for (Display, Net, Bluetooth, audio, …)
are ticked for you.

- **Back up selected** writes one folder per driver plus a `manifest.json`, optionally zipped.
- **Restore** puts them back, either into the running Windows (`pnputil /add-driver /install`)
  or offline into another Windows on a drive you pick (`DISM /Add-Driver`).

Offline is the good one: tick *Inject a driver backup* on the Install tab and the new
Windows comes up with network and display working on the very first boot.

### Boot menu
The EasyBCD part. Rename entries, set the default, delete stale ones, change the menu
timeout. Reads through the BCD WMI provider, so it works the same on a non-English Windows.

## Safety

- The boot menu is written **last**. If anything fails before that, the PC still boots
  exactly as it did — worst case some files are left on the target partition.
- The disk holding the running Windows can be shrunk, never wiped.
- Every destructive step asks you to type the disk number. A misread grid row should not
  cost somebody their photos.
- Everything is logged to `%LOCALAPPDATA%\WinDeploy\logs\`.

## Known limits

- **BitLocker**: suspend it before shrinking an encrypted volume, or the recovery key
  prompt shows up on the next boot. The log warns you when it spots one.
- **UEFI/GPT is the tested path.** BIOS/MBR uses `bcdboot /f BIOS` and should work, but
  has had less testing.
- A driver backed up from one machine will not necessarily install on different hardware.
- Windows licensing and where the ISO came from are your problem — this tool does not
  touch activation.
- Shrinking can fail on a fragmented volume with unmovable files near the end. Run Disk
  Cleanup and defrag, then try again.

## Testing it safely

Try it in a Hyper-V VM (Generation 2) before running it on a real machine:
install Windows in the VM, run WinDeploy from inside it, add a second Windows to a new
partition, reboot, and check both entries boot.
