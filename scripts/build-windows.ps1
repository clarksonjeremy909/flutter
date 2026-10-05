#Requires -Version 5.1
<#
.SYNOPSIS
  Build AktifDesk Windows x64 release ZIP on a Windows machine with Flutter + VS 2022.

.DESCRIPTION
  Prerequisites (install once):
    1. Flutter stable: https://docs.flutter.dev/get-started/install/windows
       - Add flutter\bin to PATH; run `flutter doctor` until Windows desktop is OK.
    2. Visual Studio 2022 Community (or Build Tools) with workload:
       "Desktop development with C++"
       AND individual component: "C++ ATL for latest v143 build tools (x86 & x64)"
    3. Git (for clone) if you don't already have the sources.

  Usage (from repo root, or anywhere — script cds to repo root):
    powershell -ExecutionPolicy Bypass -File .\scripts\build-windows.ps1

  Output:
    .\AktifDesk-windows-x64.zip  (contains AktifDesk.exe + DLLs + data)
    Upload that file to the GitHub Release as asset name AktifDesk-windows-x64.zip
#>

$ErrorActionPreference = 'Stop'

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
Set-Location $RepoRoot
Write-Host "==> Repo: $RepoRoot"

function Assert-Command($Name) {
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "Required command not found on PATH: $Name"
  }
}

Assert-Command flutter
Assert-Command git

Write-Host '==> flutter doctor (summary)'
flutter doctor -v | Select-String -Pattern 'Flutter|Windows|Visual Studio|Doctor' | ForEach-Object { $_.Line }

Write-Host '==> Enable Windows desktop'
flutter config --enable-windows-desktop | Out-Host

if (-not (Test-Path 'windows\CMakeLists.txt')) {
  Write-Host '==> windows/ platform files missing — running flutter create'
  flutter create --platforms=windows --org com.aktifdesk . | Out-Host
}

Write-Host '==> flutter pub get'
flutter pub get | Out-Host

Write-Host '==> flutter build windows --release'
flutter build windows --release
if ($LASTEXITCODE -ne 0) { throw "flutter build windows failed with exit $LASTEXITCODE" }

$Out = Join-Path $RepoRoot 'build\windows\x64\runner\Release'
if (-not (Test-Path (Join-Path $Out 'AktifDesk.exe'))) {
  throw "Expected AktifDesk.exe not found under $Out"
}

$Zip = Join-Path $RepoRoot 'AktifDesk-windows-x64.zip'
if (Test-Path $Zip) { Remove-Item -Force $Zip }

Write-Host "==> Zipping $Out -> $Zip"
Compress-Archive -Path (Join-Path $Out '*') -DestinationPath $Zip -Force

$Item = Get-Item $Zip
Write-Host ''
Write-Host 'SUCCESS'
Write-Host ("  ZIP : {0}" -f $Item.FullName)
Write-Host ("  Size: {0:N0} bytes ({1:N1} MB)" -f $Item.Length, ($Item.Length / 1MB))
Write-Host ("  Exe : {0}" -f (Join-Path $Out 'AktifDesk.exe'))
Write-Host ''
Write-Host 'Upload to GitHub Release (example):'
Write-Host '  gh release upload v1.1.0 AktifDesk-windows-x64.zip --repo clarksonjeremy909/flutter --clobber'
Write-Host 'Or drag-drop the zip onto https://github.com/clarksonjeremy909/flutter/releases/tag/v1.1.0'
