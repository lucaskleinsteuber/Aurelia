# Installs Aurelia silently, checks the files, version, Start menu entry and firewall rule, checks
# that --quit returns when Aurelia is not running, then uninstalls silently and checks that the
# rule and the program are gone while the person's data stays. For test machines only.
param([Parameter(Mandatory)] [string]$Setup)
$ErrorActionPreference = 'Stop'
$failures = 0
function Check([bool]$passed, [string]$what) {
    if ($passed) { Write-Host "pass: $what" } else { Write-Host "FAIL: $what"; $script:failures++ }
}
$data = Join-Path $env:LOCALAPPDATA 'Aurelia Server'
if (Test-Path (Join-Path $data 'aurelia.db')) { throw 'An Aurelia server keeps its data on this PC. This check is for test machines only.' }
$app = Join-Path $env:ProgramFiles 'Aurelia'
$log = Join-Path $env:TEMP 'aurelia-setup.log'

$setup = Start-Process -FilePath $Setup -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "/LOG=`"$log`"" -Wait -PassThru
Check ($setup.ExitCode -eq 0) "setup finishes (exit $($setup.ExitCode))"
foreach ($file in 'Aurelia.exe', 'LibVLCSharp.dll', 'server\Aurelia.Server.exe', 'server\e_sqlite3.dll', 'libvlc', 'Third-Party Notices\README.md',
    'Third-Party Notices\LibVLC-LGPL-2.1.txt', 'unins000.exe') {
    Check (Test-Path (Join-Path $app $file)) "installed $file"
}
$version = (Get-Item (Join-Path $app 'Aurelia.exe')).VersionInfo
Check ($version.FileVersion -eq '0.1.0.5') "Aurelia.exe is version $($version.FileVersion)"
$shortcut = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Aurelia.lnk'
Check (Test-Path $shortcut) 'the Start menu has Aurelia'
$uninstall = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{5C492DDE-092C-42C6-9EE4-A7280B31BB37}_is1'
Check ($uninstall.DisplayName -eq 'Aurelia' -and $uninstall.DisplayVersion -eq '0.1.0') "Settings > Apps lists $($uninstall.DisplayName) $($uninstall.DisplayVersion)"

$rules = @(Get-NetFirewallRule -DisplayName 'Aurelia Server' -ErrorAction SilentlyContinue)
Check ($rules.Count -eq 2) "two firewall rules ($($rules.Count))"
foreach ($rule in $rules) {
    $program = ($rule | Get-NetFirewallApplicationFilter).Program
    $address = ($rule | Get-NetFirewallAddressFilter).RemoteAddress
    $port = $rule | Get-NetFirewallPortFilter
    Check ($rule.Enabled -eq 'True' -and $rule.Direction -eq 'Inbound' -and $rule.Action -eq 'Allow' -and $rule.Profile -eq 'Private') `
        "rule $($port.Protocol) $($port.LocalPort): inbound, allowed, Private networks only ($($rule.Profile))"
    Check ($program -eq (Join-Path $app 'server\Aurelia.Server.exe')) "rule $($port.Protocol) is for the server only"
    Check ("$address" -eq 'LocalSubnet') "rule $($port.Protocol) accepts the local subnet only ($address)"
}

$quit = Start-Process -FilePath (Join-Path $app 'Aurelia.exe') -ArgumentList '--quit' -PassThru
Check ($quit.WaitForExit(15000) -and $quit.ExitCode -eq 0) 'Aurelia.exe --quit returns at once when Aurelia is not running'

# The person's data must survive an uninstall that is not told otherwise.
$created = -not (Test-Path $data)
if ($created) { New-Item -ItemType Directory -Path $data | Out-Null }
$marker = Join-Path $data 'aurelia-installer-check.txt'
Set-Content -Path $marker -Value 'synthetic'
$uninstaller = Start-Process -FilePath (Join-Path $app 'unins000.exe') -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART' -Wait -PassThru
Check ($uninstaller.ExitCode -eq 0) "uninstall finishes (exit $($uninstaller.ExitCode))"
for ($wait = 0; $wait -lt 60 -and (Test-Path (Join-Path $app 'Aurelia.exe')); $wait++) { Start-Sleep -Seconds 1 }
Check (-not (Test-Path (Join-Path $app 'Aurelia.exe'))) 'the program is removed'
Check (@(Get-NetFirewallRule -DisplayName 'Aurelia Server' -ErrorAction SilentlyContinue).Count -eq 0) 'the firewall rules are removed'
Check (Test-Path $marker) 'the server data stays'
Remove-Item -Path $marker
if ($created) { Remove-Item -Path $data -Recurse }
if ($failures -gt 0) { Write-Host "$failures installer checks failed."; exit 1 }
Write-Host 'All installer checks passed.'
