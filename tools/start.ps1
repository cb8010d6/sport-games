# One-click start: the controller hub (in its own minimised window) plus the game.
# Closing the game also closes the hub this script started; a hub that was already
# running is left alone. Runs without a console of its own (problems come up as a
# message box). Run through start.bat (double-click) or:
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\start.ps1 [hub args...]
# Find Godot from REGINA_GODOT, PATH, tools/godot, or the optional legacy sibling install.

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$hubDir = Join-Path $root 'hub'
$gameDir = Join-Path $root 'game'
$hubPort = 47801     # protocol.HUB_PORT
$gamePort = 47800    # protocol.GAME_PORT

Add-Type -AssemblyName System.Windows.Forms

function Fail($msg) {
    [System.Windows.Forms.MessageBox]::Show($msg, 'Regina Sports', 'OK', 'Error') | Out-Null
    exit 1
}

function Port-Owner($port) {
    $ep = Get-NetUDPEndpoint -LocalPort $port -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($ep) { return $ep.OwningProcess }
    return $null
}

# Godot
$godot = $env:REGINA_GODOT
if (-not $godot) {
    $command = Get-Command godot -ErrorAction SilentlyContinue
    if ($command) { $godot = $command.Source }
}
if (-not $godot) {
    $locations = @((Join-Path $root 'tools\godot'),
        (Join-Path (Split-Path -Parent $root) 'tools\godot-4.7.2'))
    foreach ($location in $locations) {
        $candidate = Get-ChildItem -LiteralPath $location -Filter 'Godot*_win64.exe' -File -ErrorAction SilentlyContinue |
            Where-Object Name -NotMatch '_console' | Select-Object -First 1
        if ($candidate) { $godot = $candidate.FullName; break }
    }
}
if (-not $godot -or -not (Test-Path -LiteralPath $godot -PathType Leaf)) {
    Fail '找不到 Godot。请安装 Godot 4.7.2，将它加入 PATH，或设置 REGINA_GODOT 指向引擎可执行文件。'
}

if (Port-Owner $gamePort) {
    Fail '游戏已经在运行了（端口 47800 被占用）。'
}

# Hub: hub\.venv comes from the hashed runtime lock and is reinstalled when the lock
# changes (regina_hub.setup_env). An install runs in a visible window so it shows its
# progress; an up-to-date venv starts without one.
$py = Join-Path $hubDir '.venv\Scripts\python.exe'
$setupPy = $py
if (-not (Test-Path $py)) {
    $sys = Get-Command python -ErrorAction SilentlyContinue
    if (-not $sys) { Fail '没有找到 Python。请先安装 Python 3.11 或更新版本（安装时勾选 Add to PATH）。' }
    $setupPy = $sys.Source
}
# The check's message (Chinese) is read back through a pipe: make both ends UTF-8.
$env:PYTHONIOENCODING = 'utf-8'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
Push-Location $hubDir
try { $message = (& $setupPy -m regina_hub.setup_env --check | Out-String).Trim(); $status = $LASTEXITCODE }
finally { Pop-Location }
if ($status -eq 10) {
    $cmd = "title 安装 hub 依赖 && `"$setupPy`" -m regina_hub.setup_env"
    $setup = Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', $cmd) -WorkingDirectory $hubDir -Wait -PassThru
    if ($setup.ExitCode -ne 0 -or -not (Test-Path $py)) { Fail '创建 Python 环境或安装依赖失败，检查一下网络后再试。' }
} elseif ($status -ne 0) {
    Fail ($(if ($message) { $message } else { 'hub 的 Python 环境检查失败。单独运行 hub\run_hub.bat 可以看到错误信息。' }))
}

$hub = $null
if (-not (Port-Owner $hubPort)) {
    # Minimised: the phone QR code and the simulator address are in that window.
    $hubArgs = @('-m', 'regina_hub') + $args
    $hub = Start-Process -FilePath $py -ArgumentList $hubArgs -WorkingDirectory $hubDir `
        -WindowStyle Minimized -PassThru
    # Wait until it is listening (or has died).
    for ($i = 0; $i -lt 40 -and -not (Port-Owner $hubPort); $i++) {
        if ($hub.HasExited) { Fail 'hub 启动失败。单独运行 hub\run_hub.bat 可以看到错误信息。' }
        Start-Sleep -Milliseconds 250
    }
}

$game = Start-Process -FilePath $godot -ArgumentList @('--path', "`"$gameDir`"") -PassThru
$game.WaitForExit()

if ($hub -and -not $hub.HasExited) {
    # The venv's python.exe is a launcher with the real interpreter as its child: end the tree.
    & taskkill.exe /T /F /PID $hub.Id | Out-Null
}
