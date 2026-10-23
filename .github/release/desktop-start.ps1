param(
  [Parameter(Mandatory = $true)] [string] $Installer,
  [Parameter(Mandatory = $true)] [string] $Logs,
  [Parameter(Mandatory = $true)] [string] $Version
)
# Installs the desktop app silently for this user, starts it, checks it is still running with a window after 45 s,
# keeps its logs and a screenshot in $Logs, then closes and uninstalls it.
$ErrorActionPreference = "Stop"

Write-Host "installing $Installer"
$p = Start-Process -FilePath $Installer -ArgumentList "/S" -Wait -PassThru
Write-Host "installer exit code $($p.ExitCode)"
if ($p.ExitCode -ne 0) { throw "installer failed" }

$exe = Get-ChildItem -Path "$env:LOCALAPPDATA\Programs" -Recurse -Filter "Assumer.exe" -ErrorAction SilentlyContinue |
  Where-Object { $_.Name -eq "Assumer.exe" } | Select-Object -First 1
if (-not $exe) { throw "Assumer.exe not found under $env:LOCALAPPDATA\Programs" }
Write-Host "installed at $($exe.FullName)"
$info = $exe.VersionInfo
Write-Host "ProductVersion $($info.ProductVersion) FileVersion $($info.FileVersion) ProductName $($info.ProductName)"
if (-not $info.ProductVersion.StartsWith($Version)) { throw "installed version is $($info.ProductVersion), not $Version" }

$app = Start-Process -FilePath $exe.FullName -PassThru
Start-Sleep -Seconds 45
$alive = Get-Process -Id $app.Id -ErrorAction SilentlyContinue
$all = Get-Process -Name "Assumer" -ErrorAction SilentlyContinue
Write-Host "main process alive: $([bool]$alive); Assumer processes: $(@($all).Count)"
$titles = @($all | Where-Object { $_.MainWindowTitle } | ForEach-Object { $_.MainWindowTitle })
Write-Host "window titles: $($titles -join ' | ')"

try {
  Add-Type -AssemblyName System.Windows.Forms, System.Drawing
  $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
  $bmp = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
  $bmp.Save((Join-Path $Logs "desktop-started.png"), [System.Drawing.Imaging.ImageFormat]::Png)
  Write-Host "screenshot saved"
} catch { Write-Host "screenshot failed: $_" }

foreach ($root in @($env:APPDATA, $env:LOCALAPPDATA)) {
  Get-ChildItem -Path $root -Recurse -Filter "*.log" -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match "assumer" -and $_.LastWriteTime -gt (Get-Date).AddMinutes(-10) } |
    ForEach-Object {
      Write-Host "log $($_.FullName)"
      Copy-Item $_.FullName (Join-Path $Logs ("app-" + $_.Directory.Name + "-" + $_.Name)) -ErrorAction SilentlyContinue
    }
}

$ok = [bool]$alive -and $titles.Count -gt 0
$all | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 3
$uninstaller = Get-ChildItem -Path $exe.DirectoryName -Filter "Uninstall*.exe" | Select-Object -First 1
if ($uninstaller) {
  $u = Start-Process -FilePath $uninstaller.FullName -ArgumentList "/S" -Wait -PassThru
  Write-Host "uninstaller exit code $($u.ExitCode)"
}
if (-not $ok) { throw "the app did not keep running with a window" }
Write-Host "desktop app started and showed a window"
