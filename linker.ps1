param (
    [string]$DriveLetter,
    [string]$UNCPath,
    [string]$Type,
    [string]$Suffix,
    [switch]$ShowSkips
)

$RetroBatRoms = "C:\RetroBat\roms"
$Log = "C:\RetroBat\link_script.log"

function Log($msg) {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $Log -Value "[$timestamp] $msg"
    Write-Host $msg
}

function Escape-RegexLiteral {
    param ([string]$Text)
    return [Regex]::Escape($Text)
}

$SkipCount = 0
$PlatformSkipCount = 0

function LogSkip($path) {
    $global:SkipCount++
    $global:PlatformSkipCount++
}

function Load-Gamelists {
    param ([string[]]$Paths)
    $docs = @{}
    foreach ($path in $Paths) {
        if (Test-Path $path) {
            try {
                $content = Get-Content $path -Raw
                $doc = New-Object System.Xml.XmlDocument
                $doc.LoadXml($content)
                $docs[$path] = $doc
            } catch {
                Log "Failed to load XML file: $path ? $_"
            }
        }
    }
    return $docs
}

function Clone-GamelistEntry {
    param (
        [hashtable]$XmlDocs,
        [string]$OriginalRomName,
        [string]$NewRomName,
        [string]$Suffix
    )

    $originalPath = "./$OriginalRomName"
    $newPath = "./$NewRomName"
    $targetBase = $newPath -replace '^\.\/', '' -replace '\.[^\.]+$', ''
    $originalBase = $targetBase -replace "\[$Suffix\]$", ''

    foreach ($pair in $XmlDocs.GetEnumerator()) {
        $path = $pair.Key
        $xml = $pair.Value

        $matchingGame = $xml.gameList.game | Where-Object { $_.path -eq $originalPath }
        if ($matchingGame) {
            $clone = $matchingGame.Clone()
            $clone.path = $newPath
            if ($clone.name) { $clone.name = "$($clone.name)[$Suffix]" }
            if ($clone.sortname) { $clone.sortname = "$($clone.sortname)[$Suffix]" }

            foreach ($tag in @("image","video","marquee","cartridge","boxart","wheel","mix","screenshot")) {
                if ($clone.$tag) {
                    $clone.$tag = $clone.$tag -replace [regex]::Escape($originalBase), $targetBase
                }
            }

            $xml.gameList.AppendChild($xml.ImportNode($clone, $true)) | Out-Null
            Log "Cloned entry in $([System.IO.Path]::GetFileName($path)) for: $NewRomName"
        }
    }
}

function Create-Symlink {
    param (
        [string]$TargetPath,
        [string]$SourcePath
    )
    try {
        if (Test-Path -LiteralPath $TargetPath) {
            LogSkip $TargetPath
            return
        }

        New-Item -Path $TargetPath -ItemType SymbolicLink -Value $SourcePath -ErrorAction Stop | Out-Null
        Log "Linked: `"$TargetPath`""
    } catch {
        Log "Failed to link: $TargetPath ? $_"
    }
}

# PHASE 1: Non-elevated session
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
        $Suffix = if ($NetworkHost -match "^\d{1,3}(\.\d{1,3}){3}$") { "LAN" } else { "TS" }

        Log "Detected drive: $DriveLetter => $UNCPath (host: $NetworkHost)"
        Log "Type: $Type, Suffix: $Suffix"
        $confirm = Read-Host "Proceed with type [$Type] and suffix [$Suffix]? (y/n)"
        if ($confirm -ne "y") { Log "Aborted by user."; exit }

        $args = "-ExecutionPolicy Bypass -File `"$PSCommandPath`" -DriveLetter $DriveLetter -UNCPath `"$UNCPath`" -Type $Type -Suffix $Suffix"
        if ($ShowSkips) { $args += " -ShowSkips" }
        Start-Process powershell -Verb RunAs -ArgumentList $args
        exit
    } catch {
        Log "Error detecting drive info: $_"
        exit 1
    }
}

Log "Running with elevation. Mapping ${DriveLetter}: to $UNCPath"
cmd /c "net use ${DriveLetter}: /delete /yes" | Out-Null
cmd /c "net use ${DriveLetter}: `"$UNCPath`"" | Out-Null
$Drive = "${DriveLetter}:"

if ($Type -ne "ROMS") {
    Log "Only ROMS type is currently implemented. Exiting."
    exit
}

if (!(Test-Path -LiteralPath $RetroBatRoms)) {
    Log "Creating $RetroBatRoms"
    New-Item -Path $RetroBatRoms -ItemType Directory | Out-Null
} elseif ((Get-Item -LiteralPath $RetroBatRoms).Attributes -match "ReparsePoint") {
    Log "Recreating $RetroBatRoms"
    Remove-Item -LiteralPath $RetroBatRoms -Force
    New-Item -Path $RetroBatRoms -ItemType Directory | Out-Null
}

Get-ChildItem -LiteralPath $Drive -Directory | ForEach-Object {
    $global:PlatformSkipCount = 0
    $Platform = $_.Name
    Log "Scanning folder: $Platform"

    $SourcePlatformPath = Join-Path $Drive $Platform
    $TargetPlatformPath = Join-Path $RetroBatRoms $Platform
    $GamelistFiles = @("gamelist.xml", "gamelist_ARRM.xml", "gamelist_tempo_old.xml")
    $SourceGamelistFiles = $GamelistFiles | ForEach-Object { Join-Path $SourcePlatformPath $_ }
    $TargetGamelistFiles = $GamelistFiles | ForEach-Object { Join-Path $TargetPlatformPath $_ }

    if (Test-Path -LiteralPath $TargetPlatformPath) {
        if ((Get-Item -LiteralPath $TargetPlatformPath).Attributes -match "ReparsePoint") {
            Log "Removing old symlink: $TargetPlatformPath"
            Remove-Item -LiteralPath $TargetPlatformPath -Force
        }
    }

    if (-not (Test-Path -LiteralPath $TargetPlatformPath)) {
        Log "Creating folder: $TargetPlatformPath"
        New-Item -Path $TargetPlatformPath -ItemType Directory | Out-Null
    }

    for ($i = 0; $i -lt $SourceGamelistFiles.Count; $i++) {
        if ((Test-Path -LiteralPath $SourceGamelistFiles[$i]) -and (-not (Test-Path -LiteralPath $TargetGamelistFiles[$i]))) {
            Copy-Item -LiteralPath $SourceGamelistFiles[$i] -Destination $TargetGamelistFiles[$i]
            Log "Copied $($GamelistFiles[$i]) to: $TargetPlatformPath"
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
        $NewFileName = "{0}[{1}]{2}" -f $BaseName, $Suffix, $_.Extension
        $LinkPath = Join-Path $TargetPlatformPath $NewFileName

        Create-Symlink -TargetPath $LinkPath -SourcePath $OriginalFilePath
        $RenamedMap[$BaseName] = $NewFileName

        Clone-GamelistEntry -XmlDocs $LoadedGamelists -OriginalRomName $OriginalFile -NewRomName $NewFileName -Suffix $Suffix
    }

    foreach ($folderName in @("downloaded_images", "images", "manuals", "videos")) {
        $srcFolder = Join-Path $SourcePlatformPath $folderName
        $dstFolder = Join-Path $TargetPlatformPath $folderName

        if (Test-Path -LiteralPath $srcFolder) {
            if (-not (Test-Path -LiteralPath $dstFolder)) {
                Log "Creating asset folder: $dstFolder"
                New-Item -Path $dstFolder -ItemType Directory | Out-Null
            }

        foreach ($baseName in $RenamedMap.Keys) {
            $newBase = $RenamedMap[$baseName] -replace '\.[^.]+$', ''
            $expectedPrefix = "$baseName"  # original ROM name before suffix
            $expectedPrefixLength = $expectedPrefix.Length

            Get-ChildItem -LiteralPath $srcFolder -File | ForEach-Object {
                $Asset = $_
                if (
                    $Asset.BaseName.Length -gt $expectedPrefixLength -and
                    $Asset.BaseName.Substring(0, $expectedPrefixLength) -eq $expectedPrefix -and
                    ($Asset.BaseName[$expectedPrefixLength] -match '[^a-zA-Z0-9]')
                ) {
                    $AssetSuffix = $Asset.Name.Substring($expectedPrefixLength)
                    $TargetAssetName = "$newBase$AssetSuffix"
                    $dstLink = Join-Path $dstFolder $TargetAssetName
                    Create-Symlink -TargetPath $dstLink -SourcePath $Asset.FullName
                }
            }
        }
        }
    }

    foreach ($path in $LoadedGamelists.Keys) {
        try {
            $LoadedGamelists[$path].Save($path)
            Log "Saved updated gamelist: $([System.IO.Path]::GetFileName($path))"
        } catch {
            Log "Failed to save gamelist: $path ? $_"
        }
    }

    $LoadedGamelists.Clear()
    [System.GC]::Collect()

    Log "Items skipped for platform: $global:PlatformSkipCount"
}

Log "Script completed. Skipped $SkipCount total files."

