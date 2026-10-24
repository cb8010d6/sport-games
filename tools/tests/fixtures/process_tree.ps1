# Native Windows ownership fixture: no AppX activation and no visible console.
param(
    [ValidateSet('wrapper', 'child', 'grandchild')][string]$Stage,
    [string]$Directory
)
$ErrorActionPreference = 'Stop'
$created = [Diagnostics.Process]::GetCurrentProcess().StartTime.ToFileTimeUtc()
[IO.File]::WriteAllText((Join-Path $Directory ($Stage + '.pid')), "$PID $created")
[Console]::WriteLine($Stage.ToUpperInvariant())
[Console]::Out.Flush()
if ($Stage -ne 'grandchild') {
    $next = if ($Stage -eq 'wrapper') { 'child' } else { 'grandchild' }
    $command = "& '" + $PSCommandPath.Replace("'", "''") + "' -Stage " + $next + " -Directory '" + $Directory.Replace("'", "''") + "'"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = Join-Path $PSHOME 'powershell.exe'
    $start.Arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ' + $encoded
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    # Inherit stdout/stderr, so descendants keep the exited wrapper's pipes open.
    $process = [Diagnostics.Process]::Start($start)
    $process.Dispose()
}
if ($Stage -ne 'wrapper') {
    [Threading.Thread]::Sleep(4000)
    [IO.File]::WriteAllText((Join-Path $Directory ($Stage + '.survived')), 'survived')
}
