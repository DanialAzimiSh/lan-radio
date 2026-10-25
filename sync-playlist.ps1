# Appends the Windows shortcuts (or real files) in <music>\radio that are not in playlist.m3u yet.
# Nothing is removed or reordered: that is done in the panel (http://<this PC>:8001), which also edits playlist.m3u.
# Only files under the music folder can be played - that is all the radio container can see.
#   powershell -ExecutionPolicy Bypass -File sync-playlist.ps1 [-MusicDir D:\Music]
# Without -MusicDir it uses MUSIC_DIR from the .env next to this script.
param([string] $MusicDir)

if (-not $MusicDir) {
    $envFile = Join-Path $PSScriptRoot '.env'
    $line = if (Test-Path -LiteralPath $envFile) { Get-Content -LiteralPath $envFile | Where-Object { $_ -match '^\s*MUSIC_DIR\s*=' } | Select-Object -First 1 }
    if (-not $line) { throw 'Pass -MusicDir or set MUSIC_DIR in .env' }
    $MusicDir = ($line -split '=', 2)[1].Trim()
}
$root  = [IO.Path]::GetFullPath($MusicDir.Replace('/', '\')).TrimEnd('\')
$radio = Join-Path $root 'radio'
$m3u   = Join-Path $radio 'playlist.m3u'
$audio = '.mp3', '.m4a', '.ogg', '.flac', '.wav', '.aac', '.opus'

# Same form the panel writes: relative to the radio folder, e.g. ../Remix/x.mp3 or ../radio/x.mp3
function To-Entry([string] $path) {
    if ($path.StartsWith("$root\", 'OrdinalIgnoreCase')) { return '../' + $path.Substring($root.Length + 1).Replace('\', '/') }
    return $null
}

$shell = New-Object -ComObject WScript.Shell
$found = New-Object System.Collections.Generic.List[string]
foreach ($item in Get-ChildItem -LiteralPath $radio -File | Sort-Object Name) {
    $target = if ($item.Extension -eq '.lnk') { $shell.CreateShortcut($item.FullName).TargetPath } else { $item.FullName }
    if ($audio -notcontains [IO.Path]::GetExtension($target).ToLower()) { continue }
    if (-not (Test-Path -LiteralPath $target)) { Write-Warning "Broken shortcut, skipped: $($item.Name)"; continue }
    $entry = To-Entry $target
    if (-not $entry) { Write-Warning "Outside $root, the radio cannot reach it: $target"; continue }
    if (-not $found.Contains($entry)) { $found.Add($entry) }
}

$kept = @()
if (Test-Path -LiteralPath $m3u) {
    $kept = @(Get-Content -LiteralPath $m3u -Encoding UTF8 | ForEach-Object { $_.Trim([char]0xFEFF).Trim() } |
        Where-Object { $_ -and -not $_.StartsWith('#') })
}
$added = @($found | Where-Object { $kept -notcontains $_ })

[IO.File]::WriteAllLines($m3u, [string[]](@('#EXTM3U') + $kept + $added), (New-Object Text.UTF8Encoding $false))
"playlist.m3u: $($kept.Count + $added.Count) tracks ($($added.Count) new)"
