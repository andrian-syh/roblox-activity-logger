<#
    Installs the Studio Activity Logger on a Windows machine.

    Asks for the collector address, proves it works before touching anything on
    disk, then writes the plugin where Studio loads it from. Run it again at any
    time to update. The address is always typed in full: a wrong one carried
    over from a previous install is the hardest kind of fault to notice.

    irm https://raw.githubusercontent.com/andrian-syh/roblox-activity-logger/main/install/install.ps1 | iex
#>

$ErrorActionPreference = 'Stop'

$Repository   = 'andrian-syh/roblox-activity-logger'
$PluginFile   = 'StudioActivityLogger.rbxmx'
$LegacyFiles  = @('StudioActivityLogger.rbxm', 'ActivityLogger.rbxmx')
$UrlPlaceholder   = 'PASTE_COLLECTOR_URL_HERE'
$TokenPlaceholder = 'PASTE_SHARED_TOKEN_HERE'

# Thrown rather than exited, because this script is normally piped into iex and
# an exit there would close the whole console.
function Fail($message) {
    Write-Host ''
    Write-Host "FAILED: $message" -ForegroundColor Red
    throw 'Installation cancelled.'
}

function Step($message) {
    Write-Host "  $message" -ForegroundColor DarkGray
}

# Only the three characters the builder escapes. Escaping quotes here would put
# an entity inside the Luau string and break it when Studio decodes the file.
function XmlEscape($text) {
    return $text.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;')
}

# A quote or a backslash would end or escape the Luau string the value is
# written into, whatever the XML around it says.
function RejectUnsafe($text, $what) {
    if ($text.Contains('"') -or $text.Contains('\')) {
        Fail "$what must not contain quotes or backslashes."
    }
}

Write-Host ''
Write-Host 'Studio Activity Logger' -ForegroundColor Cyan
Write-Host ''

# A plugin file replaced underneath a running Studio is either locked or simply
# ignored until the next start, and both look like a successful install.
if (Get-Process -Name 'RobloxStudio', 'RobloxStudioBeta' -ErrorAction SilentlyContinue) {
    Fail 'Roblox Studio is running. Close Studio completely, then run this command again.'
}

$pluginsDir = Join-Path $env:LOCALAPPDATA 'Roblox\Plugins'
if (-not (Test-Path $pluginsDir)) {
    New-Item -ItemType Directory -Path $pluginsDir -Force | Out-Null
    Step "Created plugins folder: $pluginsDir"
}

$target = Join-Path $pluginsDir $PluginFile

$collectorUrl = (Read-Host 'Collector URL (ends in /exec)').Trim()
if (-not $collectorUrl) { Fail 'Collector URL is required.' }
if ($collectorUrl -notmatch '^https://[^\s/]+\.[^\s/]+/.+') {
    Fail 'Collector URL is not a complete https address. Copy it exactly as your supervisor sent it.'
}
RejectUnsafe $collectorUrl 'Collector URL'

$tokenSecure = Read-Host 'Shared token' -AsSecureString
$sharedToken = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($tokenSecure)
).Trim()
if (-not $sharedToken) { Fail 'Shared token is required.' }
if ($sharedToken.Length -lt 8) { Fail 'Shared token is too short to be right. Copy it exactly as your supervisor sent it.' }
RejectUnsafe $sharedToken 'Shared token'

# Proving the address before writing anything turns a typo into a message here
# rather than a machine that silently never reports.
Write-Host ''
Step 'Checking the collector...'
# Apps Script turns away good requests for minutes at a time, so a failed
# check is tried again before it is believed.
$check = $null
for ($attempt = 1; $attempt -le 3; $attempt++) {
    try {
        $check = Invoke-RestMethod -Method Get -TimeoutSec 30 -Uri (
            '{0}?token={1}' -f $collectorUrl, [uri]::EscapeDataString($sharedToken)
        )
        break
    } catch {
        if ($attempt -eq 3) {
            Fail "Could not reach the collector after 3 attempts. $($_.Exception.Message)"
        }
        Step "No answer from the collector ($($_.Exception.Message)). Retrying in 10 seconds..."
        Start-Sleep -Seconds 10
    }
}
if (-not $check.ok) {
    Fail "The collector refused: $($check.error). Check the token, or ask your supervisor for the latest URL."
}
Step 'Collector reached, token accepted.'

Step 'Downloading the plugin...'
$downloadBase = "https://github.com/$Repository/releases/latest/download"
$temp = Join-Path ([IO.Path]::GetTempPath()) "$PluginFile.download"
try {
    Invoke-WebRequest -Uri "$downloadBase/$PluginFile" -OutFile $temp -UseBasicParsing -TimeoutSec 120
    $expected = (Invoke-RestMethod -Uri "$downloadBase/$PluginFile.sha256" -TimeoutSec 60).Trim().Split(' ')[0]
} catch {
    Fail "Download failed. $($_.Exception.Message)"
}

$actual = (Get-FileHash -Path $temp -Algorithm SHA256).Hash
if ($actual -ne $expected.ToUpper()) {
    Remove-Item $temp -Force -ErrorAction SilentlyContinue
    Fail 'Checksum mismatch. The download is damaged or the release files were replaced. Try again, and tell your supervisor if it keeps failing.'
}
Step 'Checksum verified.'

$content = Get-Content -Path $temp -Raw -Encoding UTF8
$version = if ($content -match 'Config\.VERSION = "([^"]*)"') { $Matches[1] } else { 'unknown' }

$content = $content.Replace($UrlPlaceholder, (XmlEscape $collectorUrl))
$content = $content.Replace($TokenPlaceholder, (XmlEscape $sharedToken))
[IO.File]::WriteAllText($target, $content, [Text.UTF8Encoding]::new($false))
Remove-Item $temp -Force -ErrorAction SilentlyContinue

# Two copies under different names both load, and every event is then reported
# twice.
foreach ($legacy in $LegacyFiles) {
    $stale = Join-Path $pluginsDir $legacy
    if (Test-Path $stale) {
        Remove-Item $stale -Force
        Step "Removed old copy: $legacy"
    }
}

Step "Plugin $version installed."

# Registering here means the supervisor sees the machine straight away, instead
# of waiting for whenever Studio is next opened.
$batchId = [guid]::NewGuid().ToString()
$epoch = [int][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$payload = @{
    token       = $sharedToken
    version     = $version
    batchId     = $batchId
    sessionId   = [guid]::NewGuid().ToString()
    userId      = "install:$env:COMPUTERNAME"
    placeId     = 0
    placeName   = 'installer'
    sentAtEpoch = $epoch
    events      = @(@{
        epoch      = $epoch
        kind       = 'installed'
        target     = $version
        mode       = 'edit'
        confidence = ''
        origin     = ''
        via        = ''
    })
} | ConvertTo-Json -Depth 5 -Compress

try {
    Invoke-RestMethod -Method Post -Uri $collectorUrl -ContentType 'application/json' -Body $payload -TimeoutSec 60 | Out-Null
} catch {
    # A spreadsheet collector answers the write over a redirect it refuses, so
    # the write is confirmed by asking rather than by this reply.
}

try {
    $stored = Invoke-RestMethod -Method Get -TimeoutSec 30 -Uri (
        '{0}?token={1}&batchId={2}' -f $collectorUrl, [uri]::EscapeDataString($sharedToken), $batchId
    )
    if ($stored.stored) { Step 'This machine is registered in the sheet.' }
    else { Step 'Installed. Registration will follow when Studio opens.' }
} catch {
    Step 'Installed. Registration will follow when Studio opens.'
}

Write-Host ''
Write-Host 'DONE.' -ForegroundColor Green
Write-Host '  1. Open Roblox Studio and find the Studio Activity Logger panel.'
Write-Host '  2. The Status tile should read Recording, in green.'
Write-Host '  3. If a Problem card appears, follow what it says. Ask your supervisor if it is unclear.'
Write-Host ''
