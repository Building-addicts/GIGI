Get-Process node -ErrorAction SilentlyContinue | ForEach-Object {
  try {
    $cmd = (Get-CimInstance Win32_Process -Filter "ProcessId=$($_.Id)").CommandLine
    if ($cmd -and ($cmd -match 'bridge\.js' -or $cmd -match 'panel\.js')) {
      Stop-Process -Id $_.Id -Force
      Write-Host "killed pid $($_.Id)"
    }
  } catch {}
}
