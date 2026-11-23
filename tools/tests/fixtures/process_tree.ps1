# Native Windows ownership fixture: no AppX activation and no visible console.
param(
    [ValidateSet('wrapper', 'child', 'grandchild')][string]$Stage,
    [string]$Directory,
    [double]$StartupDelaySeconds = 0,
    [int]$WatchdogSeconds = 30
)
$ErrorActionPreference = 'Stop'
$watchdog = [Diagnostics.Stopwatch]::StartNew()
$created = [Diagnostics.Process]::GetCurrentProcess().StartTime.ToFileTimeUtc()
$record = Join-Path $Directory ($Stage + '.pid')
[IO.File]::WriteAllText(($record + '.tmp'), "$PID $created")
[IO.File]::Move(($record + '.tmp'), $record)
if ($Stage -eq 'child') {
    [Threading.Thread]::Sleep([int]($StartupDelaySeconds * 1000))
}
[Console]::WriteLine($Stage.ToUpperInvariant())
[Console]::Out.Flush()
if ($Stage -ne 'grandchild') {
    $next = if ($Stage -eq 'wrapper') { 'child' } else { 'grandchild' }
    $command = "& '" + $PSCommandPath.Replace("'", "''") + "' -Stage " + $next + " -Directory '" + $Directory.Replace("'", "''") + "' -StartupDelaySeconds " + $StartupDelaySeconds.ToString([Globalization.CultureInfo]::InvariantCulture) + " -WatchdogSeconds " + $WatchdogSeconds
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = Join-Path $PSHOME 'powershell.exe'
    $start.Arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ' + $encoded
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    # Inherit stdout/stderr, so descendants keep the exited wrapper's pipes open.
    $process = [Diagnostics.Process]::Start($start)
    $process.Dispose()
    while (-not [IO.File]::Exists((Join-Path $Directory ($next + '.ready')))) {
        if ($watchdog.Elapsed.TotalSeconds -ge $WatchdogSeconds) {
            throw ('Fixture watchdog expired waiting for ' + $next)
        }
        [Threading.Thread]::Sleep(20)
    }
}
[IO.File]::WriteAllText((Join-Path $Directory ($Stage + '.ready')), 'ready')
if ($Stage -ne 'wrapper') {
    while (-not [IO.File]::Exists((Join-Path $Directory 'release')) -and $watchdog.Elapsed.TotalSeconds -lt $WatchdogSeconds) {
        [Threading.Thread]::Sleep(20)
    }
}
