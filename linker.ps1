param ([string]$DriveLetter, [string]$UNCPath, [string]$Type, [string]$Suffix, [string]$Platform, [switch]$ShowSkips, [switch]$AddSuffix)

$AssetFolders = @("downloaded_images", "images", "manuals", "videos")
$LogDir = "C:\RetroBat\logs"
if (-not (Test-Path -LiteralPath $LogDir)) {
    New-Item -Path $LogDir -ItemType Directory | Out-Null
}
$Log = if ($Platform) {
    "$LogDir\link_script_$Platform.log"
} else {
    "$LogDir\link_script_main.log"
}

$RetroBatRoms = "C:\RetroBat\roms"
$SkipCount = 0
$PlatformSkipCount = 0

function Log($msg) {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $Log -Value "[$timestamp] $msg"
    Write-Host $msg
}

function LogSkip($path) {
    $global:SkipCount++
    $global:PlatformSkipCount++
}

function Load-Gamelists {
    param ([string[]]$Paths)
    $docs = @{ }
    foreach ($path in $Paths) {
        if (Test-Path $path) {
            try {
                $content = Get-Content $path -Raw
                $doc = New-Object System.Xml.XmlDocument
                $doc.LoadXml($content)
                $docs[$path] = $doc
            } catch {
                Log "Failed to load XML file: ${path}: $_"
            }
        }
    }
    return $docs
}

function Clone-GamelistEntry {
    param ([hashtable]$XmlDocs, [string]$OriginalRomName, [string]$NewRomName, [string]$Suffix)
    $originalPath = "./$OriginalRomName"
    $newPath = "./$NewRomName"

    foreach ($pair in $XmlDocs.GetEnumerator()) {
        $path = $pair.Key
        $xml = $pair.Value

        $matchingGame = $xml.gameList.game | Where-Object { $_.path -eq $originalPath }
        if ($matchingGame) {
            $clone = $matchingGame.Clone()
            $clone.path = $newPath

            $xml.gameList.AppendChild($xml.ImportNode($clone, $true)) | Out-Null
            Log "Cloned entry in $([System.IO.Path]::GetFileName($path)) with new path: $NewRomName"
        }
    }
}

function Create-Symlink {
    param ([string]$TargetPath, [string]$SourcePath)
    try {
        if (-not (Test-Path -LiteralPath $SourcePath)) {
            Log "Source does not exist: $SourcePath"
            return
        }

        if (Test-Path -LiteralPath $TargetPath) {
            $linkInfo = Get-Item -LiteralPath $TargetPath -Force

            # Valid symlink check
            if ($linkInfo.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                $actualTarget = (Get-Item -LiteralPath $TargetPath -Force).Target
                if ($actualTarget -eq $SourcePath) {
                    LogSkip "$TargetPath (already correctly linked)"
                    return
                } else {
                    Log "Replacing incorrect symlink: $TargetPath → $actualTarget"
                    Remove-Item -LiteralPath $TargetPath -Force
                }
            } else {
                Log "Skipping non-symlink item at $TargetPath"
                return
            }
        }

        $targetDir = Split-Path -Parent $TargetPath
        if (-not (Test-Path -LiteralPath $targetDir)) {
            New-Item -Path $targetDir -ItemType Directory -Force | Out-Null
        }

        $escapedTarget = '"' + $TargetPath + '"'
        $escapedSource = '"' + $SourcePath + '"'

        cmd /c "mklink $escapedTarget $escapedSource" | Out-Null
        Log "Linked via mklink: $TargetPath → $SourcePath"
    } catch {
        Log "Failed to link: ${TargetPath}: $_"
    }
}

# PHASE 1: elevation & relaunch
if (-not $UNCPath) {
    try {
        $drive = Get-PSDrive -Name $DriveLetter
        $UNCPath = $drive.DisplayRoot
        if (-not $UNCPath -or -not ($UNCPath -match "\\\\([^\\]+)\\([^\\]+)")) {
            throw "Could not resolve UNC path for $DriveLetter"
        }
        $NetworkHost = $Matches[1]
        $Share = $Matches[2]
        $Type = $Share.Split()[0].ToUpper()
        $Suffix = if ($NetworkHost -match "^\d{1,3}(\.\d{1,3}){3}$") {
            "LAN"
        } else {
            "TS"
        }

        Log "Detected drive: $DriveLetter => $UNCPath (host: $NetworkHost)"
        Log "Type: $Type, Suffix: $Suffix"
        $confirm = Read-Host "Proceed with type [$Type] and suffix [$Suffix]? (y/n)"
        if ($confirm -ne "y") {
            Log "Aborted by user."; exit
        }

        $args = "-ExecutionPolicy Bypass -File `"$PSCommandPath`" -DriveLetter $DriveLetter -UNCPath `"$UNCPath`" -Type $Type -Suffix $Suffix"
        if ($AddSuffix) {
            $args += " -AddSuffix"
        }
        if ($ShowSkips) {
            $args += " -ShowSkips"
        }
        Start-Process powershell -Verb RunAs -ArgumentList $args
        exit
    } catch {
        Log "Error detecting drive info: $_"
        exit 1
    }
}

$Drive = "${DriveLetter}:"
if (-not $Platform) {
    if ((net use | Select-String "${DriveLetter}:")) {
        cmd /c "net use ${DriveLetter}: /delete" > $null 2>&1
        Start-Sleep -Milliseconds 500
    }
    cmd /c "net use ${DriveLetter}: `"$UNCPath`"" > $null 2>&1
    Log "Launching per-platform processes..."
    Get-ChildItem -LiteralPath $Drive -Directory | ForEach-Object {
        $PlatformName = $_.Name
        $argStr = "-ExecutionPolicy Bypass -File `"$PSCommandPath`" -DriveLetter $DriveLetter -UNCPath `"$UNCPath`" -Type $Type -Suffix $Suffix -Platform `"$PlatformName`""
        if ($AddSuffix) {
            $argStr += " -AddSuffix"
        }
        if ($ShowSkips) {
            $argStr += " -ShowSkips"
        }
        Start-Process powershell -ArgumentList $argStr
        Log "Started process for platform: $PlatformName"
    }
    Log "All platform jobs launched. Exiting main."
    exit
}

# PLATFORM-SPECIFIC BLOCK
Log "Processing platform: $Platform"
$SourcePlatformPath = Join-Path $Drive $Platform
$TargetPlatformPath = Join-Path $RetroBatRoms $Platform

if (!(Test-Path -LiteralPath $RetroBatRoms)) {
    Log "Creating $RetroBatRoms"
    New-Item -Path $RetroBatRoms -ItemType Directory | Out-Null
}
if (-not (Test-Path -LiteralPath $TargetPlatformPath)) {
    Log "Creating folder: $TargetPlatformPath"
    New-Item -Path $TargetPlatformPath -ItemType Directory | Out-Null
}

$GamelistFiles = @("gamelist.xml", "gamelist_ARRM.xml", "gamelist_tempo_old.xml")
$SourceGamelistFiles = $GamelistFiles | ForEach-Object { Join-Path $SourcePlatformPath $_ }
$TargetGamelistFiles = $GamelistFiles | ForEach-Object { Join-Path $TargetPlatformPath $_ }

for ($i = 0; $i -lt $SourceGamelistFiles.Count; $i++) {
    $src = $SourceGamelistFiles[$i]
    $dst = $TargetGamelistFiles[$i]

    if (Test-Path -LiteralPath $src) {
        $copyNeeded = $true

        if (Test-Path -LiteralPath $dst) {
            $srcSize = (Get-Item -LiteralPath $src).Length
            $dstSize = (Get-Item -LiteralPath $dst).Length

            if ($srcSize -eq $dstSize) {
                $copyNeeded = $false
                Log "Skipped copy of $($GamelistFiles[$i]): same size"
            }
        }

        if ($copyNeeded) {
            try {
                Copy-Item -LiteralPath $src -Destination $dst -Force
                Log "Copied $($GamelistFiles[$i]) to: $TargetPlatformPath"
            } catch {
                Log "Failed to copy $($GamelistFiles[$i]): $_"
            }
        }
    }
}

function Is-InAssetFolder {
    param (
        [string]$filePath,
        [string[]]$assetPaths
    )
    foreach ($assetPath in $assetPaths) {
        if ($filePath -like "$assetPath\*") {
            return $true
        }
    }
    return $false
}

$LoadedGamelists = Load-Gamelists -Paths $TargetGamelistFiles
$ExcludedFiles = @("gamelist.xml", "gamelist_ARRM.xml", "gamelist_tempo_old.xml", ".DS_Store", "._.DS_STORE", "_info.txt")
$RenamedMap = @{}

$RenamedMap = @{}
$AssetPaths = $AssetFolders | ForEach-Object { Join-Path $SourcePlatformPath $_ }
Get-ChildItem -LiteralPath $SourcePlatformPath -Recurse -File | Where-Object {
    $_.Name -notin $ExcludedFiles -and
            $_.Extension -ne ".sh" -and
            ($_.FullName.Substring($SourcePlatformPath.Length).TrimStart('\') -notmatch '^(backup\\|backup\/)') -and
            -not (Is-InAssetFolder -filePath $_.FullName -assetPaths $AssetPaths)
} | ForEach-Object {
    $OriginalFilePath = $_.FullName
    $RelativePath = $OriginalFilePath.Substring($SourcePlatformPath.Length).TrimStart('\')
    $SourceIsInRoot = ($RelativePath -notmatch '\\')

    $BaseName = $_.BaseName
    $Extension = $_.Extension

    $NewFileName = if ($AddSuffix -and $SourceIsInRoot) {
        "{0}[{1}]{2}" -f $BaseName, $Suffix, $Extension
    } else {
        $_.Name
    }

    $RelativeTargetPath = if ($SourceIsInRoot) {
        $NewFileName
    } else {
        Join-Path (Split-Path $RelativePath -Parent) $NewFileName
    }

    $TargetFullPath = Join-Path $TargetPlatformPath $RelativeTargetPath
    $TargetDir = Split-Path $TargetFullPath

    if (-not (Test-Path -LiteralPath $TargetDir)) {
        New-Item -Path $TargetDir -ItemType Directory -Force | Out-Null
        Log "Created subfolder: $TargetDir"
    }

    Create-Symlink -TargetPath $TargetFullPath -SourcePath $OriginalFilePath

    if ($SourceIsInRoot) {
        $RenamedMap[$BaseName] = $NewFileName
        if ($AddSuffix) {
            Clone-GamelistEntry -XmlDocs $LoadedGamelists -OriginalRomName $_.Name -NewRomName $NewFileName -Suffix $Suffix
        }
    }
}

# ASSET LINKING BLOCK
foreach ($folderName in $AssetFolders) {
    $srcFolder = Join-Path $SourcePlatformPath $folderName
    $dstFolder = Join-Path $TargetPlatformPath $folderName

    if (Test-Path -LiteralPath $srcFolder) {
        if (Test-Path -LiteralPath $dstFolder) {
            try {
                Remove-Item -LiteralPath $dstFolder -Recurse -Force
                Log "Removed existing folder: $dstFolder"
            } catch {
                Log "Failed to remove existing folder: ${dstFolder}: $_"
                continue
            }
        }

        try {
            New-Item -Path $dstFolder -ItemType SymbolicLink -Value $srcFolder -ErrorAction Stop | Out-Null
            Log "Linked asset folder: $dstFolder → $srcFolder"
        } catch {
            Log "Failed to link asset folder: ${dstFolder}: $_"
        }
    }
}

if ($AddSuffix) {
    foreach ($path in $LoadedGamelists.Keys) {
        try {
            $LoadedGamelists[$path].Save($path)
            Log "Saved updated gamelist: $([System.IO.Path]::GetFileName($path) )"
        } catch {
            Log "Failed to save gamelist: ${path}: $_"
        }
    }
}

$LoadedGamelists.Clear()
[System.GC]::Collect()

Log "Platform [$Platform] done. Skipped: $PlatformSkipCount files."
