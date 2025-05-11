param ([string]$DriveLetter, [string]$UNCPath, [string]$Type, [string]$Suffix, [string]$Platform, [switch]$ShowSkips, [switch]$AddSuffix)

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
                Log "Failed to load XML file: $path — $_"
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
        if (Test-Path -LiteralPath $TargetPath) {
            LogSkip $TargetPath
            return
        }
        New-Item -Path $TargetPath -ItemType SymbolicLink -Value $SourcePath -ErrorAction Stop | Out-Null
        Log "Linked: `"$TargetPath`""
    } catch {
        Log "Failed to link: $TargetPath — $_"
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
    if (Test-Path -LiteralPath $SourceGamelistFiles[$i]) {
        try {
            Copy-Item -LiteralPath $SourceGamelistFiles[$i] -Destination $TargetGamelistFiles[$i] -Force
            Log "Copied $($GamelistFiles[$i]) to: $TargetPlatformPath"
        } catch {
            Log "Failed to copy $($GamelistFiles[$i]) — $_"
        }
    }
}

$LoadedGamelists = Load-Gamelists -Paths $TargetGamelistFiles
$ExcludedFiles = @("gamelist.xml", "gamelist_ARRM.xml", "gamelist_tempo_old.xml", ".DS_Store", "._.DS_STORE", "_info.txt")
$RenamedMap = @{}

Get-ChildItem -LiteralPath $SourcePlatformPath -File | Where-Object {
    $_.Name -notin $ExcludedFiles -and $_.Extension -ne ".sh"
} | ForEach-Object {
    $OriginalFile = $_.Name
    $OriginalFilePath = $_.FullName
    $BaseName = $_.BaseName
    $NewFileName = if ($AddSuffix) {
        "{0}[{1}]{2}" -f $BaseName, $Suffix, $_.Extension
    } else {
        $_.Name
    }
    $LinkPath = Join-Path $TargetPlatformPath $NewFileName

    Create-Symlink -TargetPath $LinkPath -SourcePath $OriginalFilePath
    $RenamedMap[$BaseName] = $NewFileName
    if ($AddSuffix) {
        Clone-GamelistEntry -XmlDocs $LoadedGamelists -OriginalRomName $OriginalFile -NewRomName $NewFileName -Suffix $Suffix
    }
}

# ASSET LINKING BLOCK
$AssetFolders = @("downloaded_images", "images", "manuals", "videos")
foreach ($folderName in $AssetFolders) {
    $srcFolder = Join-Path $SourcePlatformPath $folderName
    $dstFolder = Join-Path $TargetPlatformPath $folderName

    if (Test-Path -LiteralPath $srcFolder) {
        if (Test-Path -LiteralPath $dstFolder) {
            try {
                Remove-Item -LiteralPath $dstFolder -Recurse -Force
                Log "Removed existing folder: $dstFolder"
            } catch {
                Log "Failed to remove existing folder: $dstFolder — $_"
                continue
            }
        }

        try {
            New-Item -Path $dstFolder -ItemType SymbolicLink -Value $srcFolder -ErrorAction Stop | Out-Null
            Log "Linked asset folder: $dstFolder → $srcFolder"
        } catch {
            Log "Failed to link asset folder: $dstFolder — $_"
        }
    }
}

if ($AddSuffix) {
    foreach ($path in $LoadedGamelists.Keys) {
        try {
            $LoadedGamelists[$path].Save($path)
            Log "Saved updated gamelist: $([System.IO.Path]::GetFileName($path) )"
        } catch {
            Log "Failed to save gamelist: $path — $_"
        }
    }
}

$LoadedGamelists.Clear()
[System.GC]::Collect()

Log "Platform [$Platform] done. Skipped: $PlatformSkipCount files."
