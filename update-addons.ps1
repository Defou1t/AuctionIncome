# Updates Auction Income and Raid & Fish Tools from their GitHub releases
# without touching your records:
#  - records live outside the addon folders (Addon\auction_income_*.lua,
#    Addon\raidfish_data.lua) and are never overwritten;
#  - RaidFishTools\whitelist.txt is kept;
#  - before anything changes, the addon folders and data files are copied to
#    Addon\_backups\<date time>\.
# Only addons you already have are updated (-Install adds missing ones).
# Auction Income is also added where Raid & Fish Tools is installed: the Fish
# Tracker moved into it (Raid Tools 1.4.0 / Auction Income 1.10.0).
#   powershell -ExecutionPolicy Bypass -File update-addons.ps1
param(
    [string]$AddonDir = (Join-Path ([Environment]::GetFolderPath("MyDocuments")) "AAClassic\Addon"),
    [switch]$Install
)
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$addons = @(
    @{ Name = "AuctionIncome"; Repo = "Defou1t/AuctionIncome"; Data = @("auction_income_*.lua"); Keep = @(); AlsoFor = "RaidFishTools" },
    @{ Name = "RaidFishTools"; Repo = "Defou1t/RaidFishTools"; Data = @("raidfish_data.lua"); Keep = @("whitelist.txt") }
)

if (-not (Test-Path $AddonDir)) { throw "Addon folder not found: $AddonDir (pass -AddonDir)" }
if (Get-Process -Name "archeage" -ErrorAction SilentlyContinue) {
    Write-Host "ArcheAge is running. It is safe, but the new version starts only after a restart" -ForegroundColor Yellow
    Write-Host "(or reloading the addon in the Addons window)." -ForegroundColor Yellow
}

$stamp = Get-Date -Format "yyyy-MM-dd_HHmmss"
$backup = Join-Path $AddonDir "_backups\$stamp"
$work = Join-Path ([IO.Path]::GetTempPath()) "aac-addon-update-$stamp"
New-Item -ItemType Directory -Force $work | Out-Null

function Get-Version($mainLua) {
    if (-not (Test-Path $mainLua)) { return $null }
    $m = Select-String -Path $mainLua -Pattern 'version\s*=\s*"([^"]+)"' | Select-Object -First 1
    if ($m) { return $m.Matches[0].Groups[1].Value }
    return $null
}

try {
    foreach ($a in $addons) {
        $dir = Join-Path $AddonDir $a.Name
        $have = Get-Version (Join-Path $dir "main.lua")
        $alsoFor = $a.AlsoFor -and (Test-Path (Join-Path $AddonDir "$($a.AlsoFor)\main.lua"))
        if (-not $have -and -not $Install -and -not $alsoFor) { Write-Host "$($a.Name): not installed, skipped (-Install to add it)"; continue }
        if (-not $have -and $alsoFor) { Write-Host "$($a.Name): added, it now holds the Fish Tracker" }

        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$($a.Repo)/releases/latest" -Headers @{ "User-Agent" = "aac-addon-update" }
        $latest = $release.tag_name
        if ($have -eq $latest) { Write-Host "$($a.Name): $have is the latest"; continue }
        $asset = $release.assets | Where-Object { $_.name -like "*.zip" } | Select-Object -First 1
        if (-not $asset) { Write-Host "$($a.Name): release $latest has no zip, skipped" -ForegroundColor Yellow; continue }

        # Backup: the addon folder and its data files.
        New-Item -ItemType Directory -Force $backup | Out-Null
        if (Test-Path $dir) { Copy-Item $dir (Join-Path $backup $a.Name) -Recurse -Force }
        foreach ($pattern in $a.Data) { Get-ChildItem $AddonDir -Filter $pattern -File | Copy-Item -Destination $backup -Force }

        $zip = Join-Path $work "$($a.Name).zip"
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip -UseBasicParsing -Headers @{ "User-Agent" = "aac-addon-update" }
        $unpacked = Join-Path $work $a.Name
        Expand-Archive $zip -DestinationPath $unpacked -Force
        $source = Join-Path $unpacked $a.Name
        if (-not (Test-Path (Join-Path $source "main.lua"))) { $source = $unpacked }
        if (-not (Test-Path (Join-Path $source "main.lua"))) { throw "$($a.Name): main.lua not found in $($asset.name)" }

        New-Item -ItemType Directory -Force $dir | Out-Null
        foreach ($file in Get-ChildItem $source -Recurse -File) {
            $relative = $file.FullName.Substring($source.Length).TrimStart('\')
            if ($a.Keep -contains $relative -and (Test-Path (Join-Path $dir $relative))) { continue }
            $target = Join-Path $dir $relative
            New-Item -ItemType Directory -Force (Split-Path $target) | Out-Null
            Copy-Item $file.FullName $target -Force
        }

        $list = Join-Path $AddonDir "addons.txt"
        if ((Test-Path $list) -and -not (Select-String -Path $list -Pattern "^\s*$($a.Name)\s*$" -Quiet)) {
            Add-Content $list $a.Name
        }
        Write-Host "$($a.Name): $(if ($have) { $have } else { 'new' }) -> $latest" -ForegroundColor Green
    }
} finally {
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}
if (Test-Path $backup) { Write-Host "Backup: $backup" }
Write-Host "Done. Records are kept: they are stored outside the addon folders."
