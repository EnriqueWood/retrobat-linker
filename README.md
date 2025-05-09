# RetroBat Symlink Integrator

This PowerShell script simplifies and automates the integration of ROMs and their assets into the `C:\RetroBat\roms` folder by creating symbolic links from a network-mounted drive.

## Features

- Detects `ROMS` and network context `TS` for Tailscale or `LAN` of the mounted drive. (`BIOS` and `SAVES` mounted drives will be in a next release)
- Recursively creates symlinks from the drive's ROM folders into `C:\RetroBat\roms`.
- Skips existing files and logs all activity.
- Applies `[TS]` or `[LAN]` suffixes to linked ROMs and assets.
- Updates `gamelist.xml`, `gamelist_ARRM.xml`, and `gamelist_tempo_old.xml` with cloned entries for suffixed ROMs and their metadata.
- Ensures asset folders (`downloaded_images`, `images`, `manuals`, `videos`) are created as real folders and linked properly.

## Usage

1. Map your network drive in Windows (e.g., `X:`).
2. Rename the mounted drive to `ROMS [TYPE] servername`, for now, the only supported (and tested types are `TS` for Tailscale and `LAN`)
3. Open PowerShell where the script is located and run:

```powershell
powershell -ExecutionPolicy Bypass -File .\linker.ps1 -DriveLetter <DriveLetter>
```

* Replace <DriveLetter> with the letter of your network mounted drive

4. The script will auto-detect the type and suffix, then ask for confirmation.


You can have both symlinks and "physical" files, so maybe for larger roms it's better to have the physical rom so loading times are better.

Note: The script need to elevate to Administrator to create the symlinks.

### Optional Flags

- `-ShowSkips`: show every skipped file instead of summary only.

## Requirements

- Windows PowerShell
- Admin rights (required for creating symlinks)
- Network drive must be mounted before running the script

## Notes

- The script does not modify or delete original files.
- Only symbolic links are created in the RetroBat directory.
- For cloned gamelist entries, the script automatically adapts asset references to the suffixed ROM.

