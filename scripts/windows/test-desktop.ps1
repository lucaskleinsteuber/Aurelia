# Runs on a Windows test machine, copied there by scripts/test-desktop-windows.sh, with synthetic
# data only: the server's Windows file probe with a real symbolic link and junction, the desktop
# tests against the real Windows server build (VLC playback tests left out), and with -Setup the
# installer check. Exits 1 when anything failed.
param([string]$Setup, [string]$Version, [string]$Build)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$failed = $false
Write-Host "== $([Environment]::OSVersion.VersionString) on $env:PROCESSOR_ARCHITECTURE"

# The probe expects Movies/Synthetic Movie (2020)/... and Movies/Linked pointing outside the library.
$probe = Join-Path $env:TEMP ('aurelia-probe-' + [guid]::NewGuid().ToString('N'))
$movie = Join-Path $probe 'Movies\Synthetic Movie (2020)'
$outside = Join-Path $probe 'Outside'
New-Item -ItemType Directory -Force -Path $movie, $outside | Out-Null
$bytes = [byte[]]::new(2000000)
for ($i = 0; $i -lt $bytes.Length; $i++) { $bytes[$i] = $i % 251 }
[IO.File]::WriteAllBytes((Join-Path $movie 'Synthetic Movie (2020).mkv'), $bytes)
[IO.File]::WriteAllText((Join-Path $outside 'Secret (2021).mkv'), 'outside')
$link = Join-Path $probe 'Movies\Linked'
foreach ($kind in 'SymbolicLink', 'Junction') {
    Write-Host "== Windows file probe with a $kind"
    New-Item -ItemType $kind -Path $link -Target $outside | Out-Null
    & (Join-Path $root 'probe\Aurelia.Server.WindowsProbe.exe') $probe
    if ($LASTEXITCODE -ne 0) { $failed = $true }
    # Removes the link itself, never the folder it points to.
    [IO.Directory]::Delete($link)
}
Remove-Item -Recurse -Force $probe

Write-Host '== Desktop tests against the Windows server build'
$env:AURELIA_TEST_SERVER = Join-Path $root 'server\Aurelia.Server.exe'
& (Join-Path $root 'tests\Aurelia.Desktop.Tests.exe') -class- 'Aurelia.Desktop.Tests.RealPlaybackTests' -class- 'Aurelia.Desktop.Tests.VlcEngineTests'
if ($LASTEXITCODE -ne 0) { $failed = $true }

if ($Setup) {
    Write-Host '== Installer'
    & (Join-Path $root 'test-installer.ps1') -Setup (Join-Path $root $Setup) -Version $Version -Build $Build
    if ($LASTEXITCODE -ne 0) { $failed = $true }
}
if ($failed) { exit 1 }
Write-Host '== All Windows checks passed.'
