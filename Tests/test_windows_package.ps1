$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=Join-Path ([System.IO.Path]::GetTempPath()) ('recorder package tests '+[guid]::NewGuid().ToString('N'))
$originalLocation=Get-Location
$originalArchitecture=$env:PROCESSOR_ARCHITECTURE
New-Item -ItemType Directory -Path (Join-Path $root 'Windows') -Force | Out-Null
Copy-Item (Join-Path $PSScriptRoot '../Windows/build.ps1') (Join-Path $root 'Windows/build.ps1')
Set-Content (Join-Path $root 'Windows/NAudio-LICENSE.txt') 'test notice'
Set-Content (Join-Path $root 'Windows/README.md') 'test readme'
$global:recorderTestMode='success'
$global:recorderTestRestores=0
function global:dotnet {
    $global:LASTEXITCODE=0
    if ($args[0] -eq 'restore') {
        $global:recorderTestRestores++
        if ($args -notcontains '--locked-mode') { throw 'Restore was not locked.' }
        if ($global:recorderTestMode -eq 'restore-failure') { $global:LASTEXITCODE=1 }
    }
    if ($args[0] -eq 'publish') {
        if ($global:recorderTestMode -eq 'publish-failure') { $global:LASTEXITCODE=1; return }
        $index=[Array]::IndexOf($args,'-o')
        $output=$args[$index+1]
        New-Item -ItemType Directory -Path $output -Force | Out-Null
        foreach ($name in @('JustRecorder.exe','JustRecorder.dll','JustRecorder.Core.dll','JustRecorder.runtimeconfig.json','JustRecorder.png')) {
            if ($global:recorderTestMode -eq 'missing-output' -and $name -eq 'JustRecorder.exe') { continue }
            Set-Content (Join-Path $output $name) 'fixture'
        }
    }
}
try {
    $env:PROCESSOR_ARCHITECTURE='ARM64' # Skip Windows executable invocation in portable fixture tests.
    $build=Join-Path $root 'Windows/build.ps1'
    & $build -Runtime win-arm64
    $zip=Join-Path $root 'build/windows/win-arm64.zip'
    if (-not (Test-Path $zip) -or $global:recorderTestRestores -ne 2) { throw 'Successful package was not produced.' }
    $hash=(Get-FileHash $zip).Hash
    foreach ($scenario in @('restore-failure','publish-failure','missing-output')) {
        $global:recorderTestMode=$scenario
        $failed=$false
        try { & $build -Runtime win-arm64 } catch { $failed=$true }
        if (-not $failed) { throw "$scenario incorrectly succeeded." }
        if ((Get-FileHash $zip).Hash -ne $hash) { throw "$scenario replaced the existing ZIP." }
        $leftovers=@(Get-ChildItem (Split-Path $zip) -Force | Where-Object Name -Like '.package-*')
        if ($leftovers.Count -ne 0) { throw "$scenario left staging files." }
        Write-Host "PASS $scenario preserves the existing ZIP"
    }
    Write-Host 'PASS successful package with spaced paths, locked restore, validation and cleanup'
} finally {
    Set-Location $originalLocation
    $env:PROCESSOR_ARCHITECTURE=$originalArchitecture
    Remove-Item Function:\dotnet
    Remove-Variable recorderTestMode,recorderTestRestores -Scope Global
    Remove-Item -Recurse -Force $root
}
