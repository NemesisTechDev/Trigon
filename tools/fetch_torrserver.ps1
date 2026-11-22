# Downloads the TorrServer engine files and puts them where the app build
# expects them. Run from the project root (the folder with pubspec.yaml):
#   powershell -ExecutionPolicy Bypass -File tools\fetch_torrserver.ps1
# Use -Tag v136 (for example) to pin a release instead of "latest".
param([string]$Tag = "")

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if (-not (Test-Path "pubspec.yaml")) {
  throw "Run this from the project root (the folder that contains pubspec.yaml)."
}

if ($Tag) { $base = "https://github.com/YouROK/TorrServer/releases/download/$Tag" }
else      { $base = "https://github.com/YouROK/TorrServer/releases/latest/download" }

# release asset name  ->  where it goes
$files = @(
  @{ Asset = "TorrServer-android-arm64";      Dest = "android\app\src\main\jniLibs\arm64-v8a\libtorrserver.so" },
  @{ Asset = "TorrServer-android-arm7";       Dest = "android\app\src\main\jniLibs\armeabi-v7a\libtorrserver.so" },
  @{ Asset = "TorrServer-android-amd64";      Dest = "android\app\src\main\jniLibs\x86_64\libtorrserver.so" },
  @{ Asset = "TorrServer-windows-amd64.exe";  Dest = "windows\torrserver\torrserver.exe" }
)

foreach ($f in $files) {
  $dir = Split-Path $f.Dest -Parent
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $url = "$base/$($f.Asset)"
  Write-Host "Downloading $($f.Asset) ..."
  Invoke-WebRequest -Uri $url -OutFile $f.Dest -UseBasicParsing
  $size = (Get-Item $f.Dest).Length
  if ($size -lt 1MB) {
    Remove-Item $f.Dest -Force
    throw "$($f.Asset) downloaded only $size bytes - the asset name may have changed. Check https://github.com/YouROK/TorrServer/releases"
  }
  Write-Host ("  OK  {0}  ({1:N1} MB)" -f $f.Dest, ($size / 1MB))
}
Write-Host ""
Write-Host "Done. Now apply the steps in PHASE8.md (Gradle, manifest, CMake), then rebuild."
