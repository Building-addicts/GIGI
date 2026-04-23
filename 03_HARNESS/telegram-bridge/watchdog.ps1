$dir = "C:\Users\arman\Desktop\Harness\telegram-bridge"
$log = "$dir\logs\watchdog.log"
function Write-Log($msg) {
    $line = "[$(Get-Date -Format yyyy-MM-ddTHH:mm:ss)] $msg"
    Add-Content -Path $log -Value $line -ErrorAction SilentlyContinue
}
$running = Get-WmiObject Win32_Process | Where-Object { $_.Name -eq "node.exe" -and $_.CommandLine -like "*panel.js*" }
if ($running) { Write-Log "panel.js attivo (PID $($running.ProcessId))"; exit 0 }
Write-Log "panel.js non trovato, avvio..."
Start-Process -FilePath "node.exe" -ArgumentList "$dir\panel.js" -WorkingDirectory $dir -WindowStyle Hidden
Write-Log "panel.js avviato"
