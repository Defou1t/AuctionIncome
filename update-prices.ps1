# Downloads ArcheAge Classic auction prices from sermeatball.com (public API
# of the fan site) into Addon\auction_income_market.lua, which Auction Income
# reads for the labor calculator (7-day averages) and the regrade panel
# (latest prices) - "Market" button in the Labor window, or at addon load.
# Addons cannot go online themselves, so run this outside the game.
#   powershell -ExecutionPolicy Bypass -File update-prices.ps1
param(
    [string]$AddonDir = (Join-Path ([Environment]::GetFolderPath("MyDocuments")) "AAClassic\Addon"),
    [int]$PageSize = 200   # the API returns at most 200 rows per request
)
$ErrorActionPreference = "Stop"
$api = "https://api.sermeatball.com/auction/market-items"
$prices = [ordered]@{}
$latest = [ordered]@{}
$offset = 0
$total = $null
while ($true) {
    $url = "${api}?sort=volume_30d&direction=desc&limit=$PageSize&offset=$offset"
    $page = Invoke-RestMethod -Uri $url -TimeoutSec 60 -Headers @{ "User-Agent" = "AuctionIncome-addon-price-sync" }
    $total = $page.total
    $rows = @($page.rows)
    if ($rows.Count -eq 0) { break }
    $traded = 0
    foreach ($row in $rows) {
        if (-not $row.volume_30d) { continue }
        $traded++
        # 7-day average, else the latest trade, else the 30-day average (copper per piece).
        $copper = $row.avg_7d_copper
        if (-not $copper) { $copper = $row.latest_copper }
        if (-not $copper) { $copper = $row.avg_30d_copper }
        if ($copper) { $prices["$($row.item_id)"] = [string][math]::Round([double]$copper) }
        # The latest auction price on its own, for the regrade panel.
        if ($row.latest_copper) { $latest["$($row.item_id)"] = [string][math]::Round([double]$row.latest_copper) }
    }
    # Sorted by 30-day volume: once a page has no traded items the rest has none either.
    if ($traded -eq 0) { break }
    $offset += $PageSize
    if ($offset -ge $total) { break }
    Start-Sleep -Milliseconds 300   # be gentle with a fan-run server
}
$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("{")
$lines.Add("    updated = `"$(Get-Date -Format 'yyyy-MM-dd HH:mm')`",")
$lines.Add("    source = `"sermeatball.com, copper per piece: items = 7-day average, latest = latest price`",")
$lines.Add("    items = {")
foreach ($id in $prices.Keys) { $lines.Add("        [`"$id`"] = `"$($prices[$id])`",") }
$lines.Add("    },")
$lines.Add("    latest = {")
foreach ($id in $latest.Keys) { $lines.Add("        [`"$id`"] = `"$($latest[$id])`",") }
$lines.Add("    },")
$lines.Add("}")
$target = Join-Path $AddonDir "auction_income_market.lua"
[IO.File]::WriteAllLines($target, $lines)
Write-Host "Saved $($prices.Count) prices to $target (of $total items on the site)."
