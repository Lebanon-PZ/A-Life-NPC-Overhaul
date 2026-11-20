# A-Life Chat Plus - one-time setup.
# 1. Installs Ollama if missing (winget), 2. downloads the AI model in model.txt, 3. low-memory Ollama settings,
# 4. adds a hidden helper to Windows startup that starts the AI + voice when Project Zomboid opens and stops them
#    when it closes. Undo: delete "A-Life Chat Plus helper" from shell:startup.
param([switch]$Cloud)
$ErrorActionPreference = "Continue"
$here = $PSScriptRoot
$model = (Get-Content (Join-Path $here "model.txt") -TotalCount 1).Trim()
function Step($t) { Write-Host ""; Write-Host "== $t" -ForegroundColor Cyan }

# 0.5.1: cloud AI instead of Ollama ("Set up cloud AI.cmd"): no Ollama, no model download
if ($Cloud) {
  Step "Cloud AI settings"
  $lua = Join-Path $env:USERPROFILE "Zomboid\Lua"
  if (-not (Test-Path $lua)) { New-Item -ItemType Directory -Path $lua -Force | Out-Null }
  $cf = Join-Path $lua "alifeai_cloud.txt"
  if (-not (Test-Path $cf)) { Copy-Item (Join-Path $here "cloud_template.txt") $cf; Write-Host "Created $cf" }
  Write-Host "Fill in url, key and model, set enabled=true, then SAVE and CLOSE Notepad to continue." -ForegroundColor Yellow
  Start-Process notepad.exe -ArgumentList ('"' + $cf + '"') -Wait
}
if (-not $Cloud) {
Step "Ollama"
$ollama = Get-Command ollama -ErrorAction SilentlyContinue
if (-not $ollama) {
  Write-Host "Ollama not found. Installing with winget..."
  winget install --id Ollama.Ollama -e --accept-source-agreements --accept-package-agreements
  $env:Path = [Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [Environment]::GetEnvironmentVariable("Path","User")
  $ollama = Get-Command ollama -ErrorAction SilentlyContinue
  if (-not $ollama) {
    Write-Host "Couldn't install Ollama automatically. Install it from https://ollama.com then run Setup again." -ForegroundColor Red
    Start-Process "https://ollama.com/download"; exit 1
  }
}
Write-Host "Ollama OK"
try { Invoke-RestMethod "http://127.0.0.1:11434/api/tags" -TimeoutSec 3 | Out-Null } catch { Start-Process ollama "serve" -WindowStyle Hidden; Start-Sleep 4 }

Step "Low-memory settings"
foreach ($kv in @(@("OLLAMA_MAX_LOADED_MODELS","1"),@("OLLAMA_NUM_PARALLEL","1"),@("OLLAMA_FLASH_ATTENTION","1"),@("OLLAMA_KV_CACHE_TYPE","q8_0"))) {
  [Environment]::SetEnvironmentVariable($kv[0], $kv[1], "User")
}
Write-Host "Done"
}

# 0.6.4: a real Python, not the Microsoft Store stub (python.exe that only says "Python was not found")
function HasPython {
  foreach ($c in @(@{ n = "py"; a = @("-3", "--version") }, @{ n = "python"; a = @("--version") })) {
    foreach ($cmd in @(Get-Command $c.n -CommandType Application -All -ErrorAction SilentlyContinue)) {
      try { $a = $c.a; $out = (& $cmd.Source @a 2>&1 | Out-String); if ($LASTEXITCODE -eq 0 -and $out -match 'Python 3') { return $true } } catch {}
    }
  }
  return $false
}
if (-not (HasPython)) {
  Write-Host "Python not found (needed for the A-Life Talk chat engine). Installing with winget..."
  winget install --id Python.Python.3.12 -e --accept-source-agreements --accept-package-agreements
}
if (-not $Cloud) {
Step "AI model: $model (change in model.txt)"
ollama pull $model
if ($LASTEXITCODE -ne 0) { Write-Host "Model download failed. Check your internet and run Setup again." -ForegroundColor Red; exit 1 }
}

Step "Auto-start helper"
$startup = [Environment]::GetFolderPath("Startup")
$lnk = Join-Path $startup "A-Life Chat Plus helper.lnk"
$ws = New-Object -ComObject WScript.Shell
$s = $ws.CreateShortcut($lnk)
$s.TargetPath = "wscript.exe"
$s.Arguments = '"' + (Join-Path $here "alifeai_hidden.vbs") + '"'
$s.WorkingDirectory = $here
$s.Save()
Start-Process wscript.exe ('"' + (Join-Path $here "alifeai_hidden.vbs") + '"')
Write-Host "Helper installed and running. It starts the AI and voice when Project Zomboid opens."

Write-Host ""
Write-Host "All set. Start Project Zomboid. The first launch downloads the speech model (~200 MB), give it a minute." -ForegroundColor Green
Write-Host "In game, problems show on screen. Hold Caps Lock to talk."
