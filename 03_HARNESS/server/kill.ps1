# GIGI harness kill — Windows.
# Killa solo i node.exe la cui CommandLine matcha panel.js / server.js / browser-pool, non
# touch altri node.exe (Adobe CC, dev server di altri progetti, etc.).

$patterns = @('panel\.js', 'server\.js', 'browser-pool')

Get-Process node -ErrorAction SilentlyContinue | ForEach-Object {
  try {
    $cmd = (Get-CimInstance Win32_Process -Filter "ProcessId=$($_.Id)").CommandLine
    if ($cmd) {
      foreach ($pat in $patterns) {
        if ($cmd -match $pat) {
          Stop-Process -Id $_.Id -Force
          Write-Host "killed pid $($_.Id) ($pat)"
          break
        }
      }
    }
  } catch {}
}
