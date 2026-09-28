param([ValidateSet('win-x64','win-x86','win-arm64')][string]$Runtime='win-x64')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Set-Location $PSScriptRoot
& dotnet restore JustRecorder.Windows --locked-mode
if ($LASTEXITCODE -ne 0) { throw 'Locked dependency restore failed.' }
& dotnet restore JustRecorder.Tests --locked-mode
if ($LASTEXITCODE -ne 0) { throw 'Locked test dependency restore failed.' }
& dotnet run --project JustRecorder.Tests -c Release --no-restore
if ($LASTEXITCODE -ne 0) { throw 'Regression tests failed.' }
$root=Join-Path $PSScriptRoot '../build/windows'
New-Item -ItemType Directory -Force -Path $root | Out-Null
$stage=Join-Path $root ('.package-'+[guid]::NewGuid().ToString('N'))
$zip=Join-Path $root "$Runtime.zip"
$tempZip=Join-Path $root ('.package-'+[guid]::NewGuid().ToString('N')+'.zip')
try {
    & dotnet publish JustRecorder.Windows -c Release -r $Runtime --self-contained true -p:PublishSingleFile=false -p:RestoreLockedMode=true -o $stage
    if ($LASTEXITCODE -ne 0) { throw 'Windows build failed.' }
    if ($Runtime -in @('win-x64', 'win-x86') -and $env:PROCESSOR_ARCHITECTURE -eq 'AMD64') {
        $process=Start-Process -FilePath "$stage/JustRecorder.exe" -ArgumentList '--self-test' -PassThru
        try {
            if (-not $process.WaitForExit(120000)) {
                $process.Kill($true)
                $process.WaitForExit()
                throw 'Native Windows encoder checks exceeded two minutes.'
            }
            if (-not (Test-Path "$stage/native-checks.txt")) { throw 'Native encoder test produced no result.' }
            Get-Content "$stage/native-checks.txt"
            if ($process.ExitCode -ne 0) { throw 'Native Windows encoder checks failed.' }
        } finally {
            if (-not $process.HasExited) { $process.Kill($true); $process.WaitForExit() }
            $process.Dispose()
        }
        Remove-Item "$stage/native-checks.txt"
    }
    Copy-Item NAudio-LICENSE.txt $stage
    Copy-Item README.md $stage
    $required=@('JustRecorder.exe', 'JustRecorder.dll', 'JustRecorder.Core.dll', 'JustRecorder.runtimeconfig.json', 'JustRecorder.png', 'README.md', 'NAudio-LICENSE.txt')
    foreach ($name in $required) {
        if (-not (Test-Path -LiteralPath (Join-Path $stage $name) -PathType Leaf)) { throw "Missing package file: $name" }
    }
    Compress-Archive -Path "$stage/*" -DestinationPath $tempZip
    $archive=[System.IO.Compression.ZipFile]::OpenRead($tempZip)
    try {
        foreach ($name in $required) {
            $entry=$archive.GetEntry($name)
            if ($null -eq $entry -or $entry.Length -eq 0) { throw "Missing or empty ZIP entry: $name" }
        }
        foreach ($entry in $archive.Entries) {
            if ($entry.Name.Length -eq 0) { continue }
            $stream=$entry.Open()
            try { $stream.CopyTo([System.IO.Stream]::Null) } finally { $stream.Dispose() }
        }
    } finally { $archive.Dispose() }
    Move-Item -Path $tempZip -Destination $zip -Force
    Write-Host "Built $zip"
} finally {
    if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
    if (Test-Path $tempZip) { Remove-Item -Force $tempZip }
}
