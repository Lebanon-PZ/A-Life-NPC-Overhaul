# A-Life Chat Plus helper (runs hidden from Windows startup).
# Waits for Project Zomboid; starts Ollama if needed, then the AI bridge and push-to-talk voice; stops them when the
# game closes. Writes Zomboid\Lua\alifeai_status.txt so the game can say what's wrong.
$here = $PSScriptRoot
$lua = Join-Path $env:USERPROFILE "Zomboid\Lua"
$HelperVer = "0.9.0"
# 0.8.12: an Ollama model name (letters, digits . _ : / - only): nothing in it a shell could read
function ValidModel([string]$m) { return ($m -match '^[A-Za-z0-9._:/\-]{1,120}$') -and ($m -notmatch '\.\.') -and ($m -notmatch '^[-/]') }
# 0.8.12: the AI tab's choices (Zomboid\Lua\alifeai_setup.txt) win over model.txt and survive mod updates
function SetupSetting([string]$key) {
  $f = Join-Path $script:lua "alifeai_setup.txt"
  if (-not (Test-Path -LiteralPath $f)) { return $null }
  try {
    foreach ($l in (Get-Content -LiteralPath $f -Encoding UTF8)) {
      if ($l -match ('^\s*' + [regex]::Escape($key) + '\s*=\s*(\S+)')) { return $Matches[1] }
    }
  } catch {}
  return $null
}
function ReadModel {
  $m = SetupSetting "model"
  if ($m -and (ValidModel $m)) { return $m }
  (Get-Content (Join-Path $script:here "model.txt") -TotalCount 1).Trim()
}
# 0.8.11.2: model.txt key=value settings (warmup=, fallback=, num_ctx=); 0.8.12: alifeai_setup.txt first
function ModelSetting([string]$key, $default) {
  $s = SetupSetting $key
  if ($s) { return $s }
  try {
    foreach ($l in (Get-Content (Join-Path $script:here "model.txt") -Encoding UTF8)) {
      if ($l -match ('^\s*' + [regex]::Escape($key) + '\s*=\s*(\S+)')) { return $Matches[1] }
    }
  } catch {}
  return $default
}
# 0.8.11.2: the AI bridge fell back to another model because yours didn't load in time -> the chat bridge uses it too
function FallbackModel([string]$m) {
  $f = Join-Path $script:lua "alifeai_model_fallback.txt"
  if (-not (Test-Path $f)) { return $null }
  $kv = @{}
  try { foreach ($l in (Get-Content $f -Encoding UTF8)) { if ($l -match '^(\w+)=(.*)$') { $kv[$Matches[1]] = $Matches[2] } } } catch {}
  if ($kv["from"] -eq $m -and $kv["to"]) { return $kv }
  return $null
}
$model = ReadModel
$pull = $null; $pulled = @{}
# GPU log (NVIDIA): how much video memory the game + AI use while you play -> Zomboid\Lua\alifeai_gpu.txt
$gpuLog = Join-Path $lua "alifeai_gpu.txt"; $gpuNext = 0; $gpuPeak = 0; $gpuSum = 0; $gpuN = 0
function Log-Gpu {
  if ((NowMs) -lt $script:gpuNext) { return }
  $script:gpuNext = (NowMs) + 30000
  $smi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
  if (-not $smi) { return }
  try {
    $q = (& nvidia-smi --query-gpu=name,memory.total,memory.used,utilization.gpu --format=csv,noheader,nounits | Select-Object -First 1).Split(",") | ForEach-Object { $_.Trim() }
    $used = [int]$q[2]; $total = [int]$q[1]
    $script:gpuN++; $script:gpuSum += $used; if ($used -gt $script:gpuPeak) { $script:gpuPeak = $used }
    $avg = [int]($script:gpuSum / $script:gpuN)
    $line = "{0} | gpu={1} | total_mb={2} used_mb={3} free_mb={4} | peak_used_mb={5} avg_used_mb={6} samples={7} | load%={8} | model={9}" -f (Get-Date -Format s), $q[0], $total, $used, ($total - $used), $script:gpuPeak, $avg, $script:gpuN, $q[3], $script:model
    $ps = ""; try { $ps = (& ollama ps 2>$null | Select-Object -Skip 1) -join " ; " } catch {}
    Set-Content -Path $script:gpuLog -Value @($line, ("ollama: " + $ps)) -Encoding UTF8
  } catch {}
}
# 0.3.1: helper log (why it started, what it replaced, any loop error) -> Zomboid\Lua\alifeai_helper_log.txt
$helperLog = Join-Path $lua "alifeai_helper_log.txt"
function HLog($m) {
  try {
    if ((Test-Path $script:helperLog) -and (Get-Item $script:helperLog).Length -gt 200000) { Remove-Item $script:helperLog -Force }
    Add-Content -Path $script:helperLog -Value ((Get-Date -Format s) + " " + $m) -Encoding UTF8
  } catch {}
}
# 0.3.1: the newest helper wins. An older copy (old mod version, old folder, stuck) used to keep the lock forever,
# so Setup's new helper quit at once and the status file went stale. Stop the old one and its AI processes first.
function Stop-OldHelpers {
  $n = 0
  try {
    $procs = Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
      $_.ProcessId -ne $PID -and $_.CommandLine -and (
        $_.CommandLine -match "alifeai_watcher\.ps1" -or $_.CommandLine -match "alifeai_bridge\.ps1" -or
        $_.CommandLine -match "alifeai_whisper\.ps1" -or $_.CommandLine -match "alifeai_voice\.ps1" -or
        $_.CommandLine -match "alifetalk_bridge\.py") }
    foreach ($p in $procs) {
      try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop; $n++; HLog ("stopped old " + $p.Name + " pid " + $p.ProcessId + ": " + $p.CommandLine) } catch {}
    }
  } catch { HLog ("could not list processes: " + $_.Exception.Message) }
  Get-Process whisper-server -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  return $n
}
trap { HLog ("error: " + $_.Exception.Message + " at line " + $_.InvocationInfo.ScriptLineNumber); continue }
HLog ("helper starting from " + $PSScriptRoot + " (pid " + $PID + ")")
$old = Stop-OldHelpers
if ($old -gt 0) { Start-Sleep 2 }
$mutex = New-Object System.Threading.Mutex($false, "ALifeChatPlusHelper")
$got = $false
try { $got = $mutex.WaitOne(10000) } catch [System.Threading.AbandonedMutexException] { $got = $true }
if (-not $got) { HLog "another helper still holds the lock after stopping old ones - exiting"; exit }
HLog ("helper running (replaced " + $old + " old process(es))")
$bridgeLog = Join-Path $lua "alifeai_bridge_log.txt"
$voiceLog = Join-Path $lua "alifeai_voice_log.txt"
$bridge = $null; $voice = $null; $talk = $null; $bridgeFails = 0; $voiceFails = 0; $talkFails = 0; $started = 0
$talkLog = Join-Path $lua "alifetalk_bridge_log.txt"
$pyTried = $false; $pyInstall = $null
# when the mod updates, restart on the new helper (no Setup re-run needed)
$selfPath = $MyInvocation.MyCommand.Path
$selfStamp = (Get-Item $selfPath).LastWriteTimeUtc
# pre-1.0: automatic bug reports to the author's Discord (opt-in; the game asks once). AI on or off.
$script:repOk = $false
try { . (Join-Path $here "alifeai_report.ps1"); $script:repOk = $true } catch { HLog ("bug reports unavailable: " + $_.Exception.Message) }
function Tick-Report([string]$ai) {
  if (-not $script:repOk) { return }
  try { [void](Send-ManualReport $script:lua $script:here $script:HelperVer $ai) } catch { HLog ("manual bug report failed: " + $_.Exception.Message) }
  try { [void](Send-BugReport $script:lua $script:here $script:HelperVer $ai) } catch { HLog ("bug report check failed: " + $_.Exception.Message) }
}
function Restart-IfUpdated {
  try { $now = (Get-Item $script:selfPath).LastWriteTimeUtc } catch { return }
  if ($now -ne $script:selfStamp) {
    Stop-All
    $script:mutex.ReleaseMutex() | Out-Null
    Start-Process wscript.exe ("`"" + (Join-Path $script:here "alifeai_hidden.vbs") + "`"")
    exit
  }
}
# 0.6.4: find a Python that really runs. Returns an array (full path, then args) - the leading comma stops PowerShell
# unrolling a one-item array into a string (that made $py[0] the letter "p": "cannot find the file specified").
# Skips the Microsoft Store stub (python.exe in WindowsApps that only says "Python was not found"). Cached; checked
# again only when the cache is cleared (after a Python install or a failed start).
$script:pyCache = $null
function PyTry($exe, $pre) {
  try {
    $a = @($pre) + @("--version")
    $out = (& $exe @a 2>&1 | Out-String)
    if ($LASTEXITCODE -eq 0 -and $out -match 'Python 3') { return $true }
  } catch {}
  return $false
}
function PyCmd {
  if ($script:pyCache) { return ,$script:pyCache }
  $found = $null
  foreach ($c in @(@{ n = "py"; a = @("-3") }, @{ n = "python"; a = @() }, @{ n = "python3"; a = @() })) {
    foreach ($cmd in @(Get-Command $c.n -CommandType Application -All -ErrorAction SilentlyContinue)) {
      $exe = $cmd.Source
      if (-not $exe) { continue }
      if (PyTry $exe $c.a) { $found = @($exe) + $c.a; break }
    }
    if ($found) { break }
  }
  if ($found) { $script:pyCache = $found; HLog ("python: " + ($found -join " ")) }
  if ($found) { return ,$found }
  return $null
}

function NowMs { [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
# 0.9.5+: AI power switch. Zomboid\Lualifeai_off.flag exists = AI is OFF: nothing is started, whatever the game or
# Windows does. Made by "Stop AI (free memory).cmd" or the AI tab; "Turn AI back on.cmd" / the tab removes it.
function AiOff { Test-Path -LiteralPath (Join-Path $script:lua "alifeai_off.flag") }
function Set-Power([bool]$on) {
  $f = Join-Path $script:lua "alifeai_off.flag"
  if ($on) { if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction Stop } }
  else { [IO.File]::WriteAllText($f, "AI is off. Delete this file (or run Turn AI back on.cmd) to turn it on.", (New-Object System.Text.UTF8Encoding($false))) }
}
# 0.5.1 cloud AI: Zomboid\Lua\alifeai_cloud.txt with enabled=true, url, key and model -> no Ollama needed at all
function CloudOn {
  $f = Join-Path $script:lua "alifeai_cloud.txt"
  if (-not (Test-Path $f)) { return $false }
  $c = @{}
  foreach ($line in (Get-Content $f -Encoding UTF8)) { if ($line -match '^\s*([A-Za-z_]+)\s*=\s*(.*?)\s*$') { $c[$matches[1].ToLower()] = $matches[2] } }
  return ((@("true","yes","1","on") -contains ([string]$c["enabled"]).ToLower()) -and $c["url"] -and $c["key"] -and $c["model"])
}
function CloudState($st) {
  $f = Join-Path $script:lua "alifeai_cloud_status.txt"
  if (-not (Test-Path $f)) { return }
  foreach ($line in (Get-Content $f -Encoding UTF8)) {
    if ($line -match '^state=(.*)$') { $st.cloud = $matches[1] }
    if ($line -match '^msg=(.*)$') { $st.cloud_error = $matches[1] }
  }
}
function LastLine($p) { if (Test-Path $p) { ((Get-Content $p -Tail 3 -ErrorAction SilentlyContinue) -join " ").Replace("`n"," ") } else { "" } }
function Status($h) {
  $t = "t=" + (NowMs) + "`n"
  foreach ($k in $h.Keys) { $t += $k + "=" + ($h[$k] -replace "[\r\n]"," ") + "`n" }
  try { $tmp = Join-Path $lua "alifeai_status.tmp"; Set-Content -LiteralPath $tmp -Value $t -NoNewline; Move-Item $tmp (Join-Path $lua "alifeai_status.txt") -Force } catch {}
}
function Launch($script, $log, $extra) {
  $a = "-NoProfile -ExecutionPolicy Bypass -File `"" + (Join-Path $here $script) + "`" " + $extra
  Start-Process powershell -ArgumentList $a -WindowStyle Hidden -PassThru -RedirectStandardOutput $log -RedirectStandardError ($log + ".err")
}
function Stop-All {
  foreach ($p in @($script:bridge, $script:voice, $script:talk)) { if ($p -and -not $p.HasExited) { try { Stop-Process -Id $p.Id -Force } catch {} } }
  Get-Process whisper-server -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  if (-not (CloudOn)) { try { ollama stop $model 2>$null | Out-Null } catch {} }
  $script:bridge = $null; $script:voice = $null; $script:talk = $null; $script:bridgeFails = 0; $script:voiceFails = 0; $script:talkFails = 0
}

# ===== 0.8.12: THE COMMAND CHANNEL (the game's AI tab) =====================================================
# The game writes Zomboid\Lua\alifeai_cmd.txt (id=, action=, arg=). We read it, delete it, and do ONLY one of the
# fixed actions below. Never a shell line: model names are checked (ValidModel) and go to Ollama's own web API or as
# one checked argument. Long jobs (pull, test, warm, get_ollama) run in alifeai_job.ps1, one at a time.
# Answer: Zomboid\Lua\alifeai_setup_status.txt (id, action, arg, state = running | done | failed, progress, msg, t).
$script:job = $null
$script:utf8NoBom = New-Object System.Text.UTF8Encoding($false)  # the game reads these: no BOM
$script:Actions = @("pull", "delete", "pick", "warm", "test", "restart", "doctor", "get_ollama", "autostart", "power")
# the same shortcut Setup.cmd makes (Windows Startup folder)
function AutostartLink { Join-Path ([Environment]::GetFolderPath("Startup")) "A-Life Chat Plus helper.lnk" }
function Set-Autostart([bool]$on) {
  $lnk = AutostartLink
  if (-not $on) { if (Test-Path -LiteralPath $lnk) { Remove-Item -LiteralPath $lnk -Force -ErrorAction Stop }; return }
  $ws = New-Object -ComObject WScript.Shell
  $sc = $ws.CreateShortcut($lnk)
  $vbs = Join-Path $script:here "alifeai_hidden.vbs"
  # self-cleaning if the mod is unsubscribed (same as Setup)
  $sc.TargetPath = "cmd.exe"
  $sc.Arguments = '/c if exist "' + $vbs + '" (start "" wscript.exe "' + $vbs + '") else (del /f /q "' + $lnk + '")'
  $sc.WindowStyle = 7
  $sc.WorkingDirectory = $script:here
  $sc.Save()
}
function JobStatus([string]$id, [string]$act, [string]$state, [int]$pct, [string]$msg, [string]$arg = "") {
  $t = "id=$id`naction=$act`narg=$arg`nstate=$state`nprogress=$pct`nmsg=" + ($msg -replace "[\r\n]", " ") + "`nt=" + (NowMs) + "`n"
  try { $tmp = Join-Path $script:lua "alifeai_setup_status.tmp"; [IO.File]::WriteAllText($tmp, $t, $script:utf8NoBom); Move-Item $tmp (Join-Path $script:lua "alifeai_setup_status.txt") -Force } catch {}
}
# Ollama's delete takes a JSON body; Windows PowerShell 5.1's Invoke-RestMethod is unreliable with a DELETE body
function OllamaDelete([string]$m) {
  $req = [System.Net.HttpWebRequest]::Create("http://127.0.0.1:11434/api/delete")
  $req.Method = "DELETE"; $req.ContentType = "application/json"; $req.Timeout = 30000
  $b = $script:utf8NoBom.GetBytes((@{ model = $m; name = $m } | ConvertTo-Json -Compress))
  $s = $req.GetRequestStream(); $s.Write($b, 0, $b.Length); $s.Close()
  $r = $req.GetResponse(); $r.Close()
}
function Tail([string]$p, [int]$n) {
  if (-not (Test-Path -LiteralPath $p)) { return @("(no file)") }
  try { return @(Get-Content -LiteralPath $p -Tail $n -Encoding UTF8 -ErrorAction Stop) } catch { return @("(could not read: " + $_.Exception.Message + ")") }
}
# Doctor check: one file with everything a bug report needs. The cloud key is masked.
function Write-Doctor {
  $out = New-Object System.Collections.Generic.List[string]
  function Sec($t) { $out.Add(""); $out.Add("===== " + $t + " =====") }
  $out.Add("A-Life NPC Overhaul doctor check " + (Get-Date -Format s) + " | helper " + $script:HelperVer + " | " + $script:here)
  $out.Add("Windows " + [Environment]::OSVersion.VersionString + " | PowerShell " + $PSVersionTable.PSVersion)
  Sec "game side"; foreach ($l in (Tail (Join-Path $script:lua "alifeai_doctor_game.txt") 400)) { $out.Add($l) }
  Sec "status"; foreach ($l in (Tail (Join-Path $script:lua "alifeai_status.txt") 40)) { $out.Add($l) }
  Sec "AI tab choices (alifeai_setup.txt)"; foreach ($l in (Tail (Join-Path $script:lua "alifeai_setup.txt") 40)) { $out.Add($l) }
  Sec "model.txt settings"
  try { foreach ($l in (Get-Content (Join-Path $script:here "model.txt") -Encoding UTF8)) { if ($l -and -not $l.StartsWith("#")) { $out.Add($l) } } } catch {}
  Sec "cloud (key hidden)"
  foreach ($l in (Tail (Join-Path $script:lua "alifeai_cloud.txt") 40)) { if ($l -match '^\s*key\s*=') { $out.Add("key=(hidden)") } else { $out.Add($l) } }
  Sec "ollama"
  try { $out.Add("version: " + (Invoke-RestMethod "http://127.0.0.1:11434/api/version" -TimeoutSec 2).version) } catch { $out.Add("version: not reachable") }
  try { foreach ($m in (Invoke-RestMethod "http://127.0.0.1:11434/api/tags" -TimeoutSec 2).models) { $out.Add("installed: " + $m.name + " " + [math]::Round($m.size / 1GB, 1) + " GB") } } catch {}
  try { foreach ($m in (Invoke-RestMethod "http://127.0.0.1:11434/api/ps" -TimeoutSec 2).models) { $out.Add("loaded: " + $m.name + " size " + [math]::Round($m.size / 1GB, 1) + " GB, on GPU " + [math]::Round($m.size_vram / 1GB, 1) + " GB") } } catch {}
  foreach ($n in @("OLLAMA_MAX_LOADED_MODELS", "OLLAMA_NUM_PARALLEL", "OLLAMA_FLASH_ATTENTION", "OLLAMA_KV_CACHE_TYPE")) { $out.Add($n + "=" + [Environment]::GetEnvironmentVariable($n, "User")) }
  Sec "health report (ALifeChatPlus_health.txt)"; foreach ($l in (Tail (Join-Path $script:lua "ALifeChatPlus_health.txt") 120)) { $out.Add($l) }
  Sec "bug reports (alifeai_report.txt)"; foreach ($l in (Tail (Join-Path $script:lua "alifeai_report.txt") 40)) { if ($l -match '^\s*url\s*=\s*\S') { $out.Add("url=(hidden)") } elseif ($l -and -not $l.StartsWith("#")) { $out.Add($l) } }
  Sec "gpu"; foreach ($l in (Tail (Join-Path $script:lua "alifeai_gpu.txt") 5)) { $out.Add($l) }
  Sec "last job"; foreach ($l in (Tail (Join-Path $script:lua "alifeai_setup_status.txt") 20)) { $out.Add($l) }
  Sec "helper log"; foreach ($l in (Tail $script:helperLog 60)) { $out.Add($l) }
  Sec "AI bridge log"; foreach ($l in (Tail $script:bridgeLog 60)) { $out.Add($l) }
  Sec "AI bridge errors"; foreach ($l in (Tail ($script:bridgeLog + ".err") 30)) { $out.Add($l) }
  Sec "chat bridge log"; foreach ($l in (Tail $script:talkLog 60)) { $out.Add($l) }
  Sec "chat bridge errors"; foreach ($l in (Tail ($script:talkLog + ".err") 30)) { $out.Add($l) }
  Sec "voice log"; foreach ($l in (Tail $script:voiceLog 20)) { $out.Add($l) }
  Sec "console.txt (A-Life lines and errors, last 3000 lines)"
  $con = Join-Path $env:USERPROFILE "Zomboid\console.txt"
  foreach ($l in (Tail $con 3000)) { if ($l -match 'ALife|A-Life|ProjectALife|Jimmy|ERROR|Exception|STACK TRACE') { $out.Add($l) } }
  $f = Join-Path $script:lua "alifeai_doctor.txt"
  try { Set-Content -LiteralPath $f -Value $out -Encoding UTF8; return $f } catch { return $null }
}
function Check-Job {
  if ($script:job -eq $null -or -not $script:job.HasExited) { return }
  # a job that died without saying so (killed, crashed) must not show "running" forever
  $sf = Join-Path $script:lua "alifeai_setup_status.txt"
  try { if (@(Get-Content -LiteralPath $sf -Encoding UTF8) -contains "state=running") { JobStatus $script:jobInfo[0] $script:jobInfo[1] "failed" 0 "the job stopped without an answer" $script:jobInfo[2] } } catch {}
  if ($script:jobInfo[1] -eq "get_ollama") { $script:pathAt = 0 }
  if ($script:jobInfo[1] -eq "pull") { Write-Models }
  $script:job = $null
}
function Check-Cmd {
  Check-Job
  $f = Join-Path $script:lua "alifeai_cmd.txt"
  if (-not (Test-Path -LiteralPath $f)) { return }
  $kv = @{}
  try { foreach ($l in (Get-Content -LiteralPath $f -Encoding UTF8)) { if ($l -match '^(\w+)=(.*)$') { $kv[$Matches[1]] = $Matches[2].Trim() } } } catch { return }
  try { Remove-Item -LiteralPath $f -Force -ErrorAction Stop } catch { return }
  $id = [string]$kv["id"]; $act = [string]$kv["action"]; $arg = [string]$kv["arg"]
  if ($id -notmatch '^\d{1,20}$') { $id = "0" }
  if ($script:Actions -notcontains $act) { HLog ("ignored unknown command '" + ($act -replace '[^\w]', '?') + "'"); JobStatus $id "unknown" "failed" 0 "unknown action"; return }
  if (@("pull", "delete") -contains $act) {
    if (-not (ValidModel $arg)) { JobStatus $id $act "failed" 0 "bad model name"; return }
  } elseif ($act -eq "autostart" -or $act -eq "power") {
    if (@("on", "off") -notcontains $arg) { JobStatus $id $act "failed" 0 "on or off only"; return }
  } else { $arg = "" }
  if ((AiOff) -and @("pull", "warm", "test", "get_ollama", "restart", "pick") -contains $act) { JobStatus $id $act "failed" 0 "the AI is turned off: turn it back on first" $arg; return }
  $jobBusy = $script:job -ne $null -and -not $script:job.HasExited
  if ($jobBusy -and @("pull", "delete", "warm", "test", "get_ollama") -contains $act) { JobStatus $id $act "failed" 0 "busy: another job is still running" $arg; return }
  HLog ("command " + $act + " " + $arg + " (id " + $id + ")")
  $fb = Join-Path $script:lua "alifeai_model_fallback.txt"
  switch ($act) {
    "restart" {
      Stop-All
      try { Remove-Item -LiteralPath $fb -Force -ErrorAction SilentlyContinue } catch {}
      $script:model = ReadModel
      JobStatus $id $act "done" 100 ("restarting with " + $script:model)
    }
    "pick" {
      $new = ReadModel
      Stop-All
      try { Remove-Item -LiteralPath $fb -Force -ErrorAction SilentlyContinue } catch {}
      $script:model = $new; $script:pulled = @{}
      JobStatus $id $act "done" 100 ("now using " + $new)
    }
    "delete" {
      if ($arg -eq $script:model -or $arg -eq ($script:model + ":latest") -or ($arg -replace ':latest$', '') -eq $script:model) { JobStatus $id $act "failed" 0 "it's in use: pick another model first" $arg; return }
      try {
        OllamaDelete $arg
        Write-Models
        JobStatus $id $act "done" 100 ("deleted " + $arg) $arg
      } catch { JobStatus $id $act "failed" 0 ("could not delete: " + $_.Exception.Message) $arg }
    }
    "autostart" {
      try { Set-Autostart ($arg -eq "on"); JobStatus $id $act "done" 100 ("start with Windows: " + $arg) $arg }
      catch { JobStatus $id $act "failed" 0 ("could not change the Startup shortcut: " + $_.Exception.Message) $arg }
    }
    "power" {
      try {
        Set-Power ($arg -eq "on")
        if ($arg -eq "off") { Stop-All }
        JobStatus $id $act "done" 100 ("AI " + $arg) $arg
      } catch { JobStatus $id $act "failed" 0 ("could not change the AI switch: " + $_.Exception.Message) $arg }
    }
    "doctor" {
      $p = Write-Doctor
      if ($p) { JobStatus $id $act "done" 100 ("saved " + $p) } else { JobStatus $id $act "failed" 0 "could not write the file" }
    }
    default {
      # pull / warm / test / get_ollama: alifeai_job.ps1 (test and warm use the model the chat runs on)
      if (@("warm", "test") -contains $act) {
        $fbk = FallbackModel $script:model
        $arg = if ($fbk) { $fbk["to"] } else { $script:model }
      }
      $a = "-NoProfile -ExecutionPolicy Bypass -File `"" + (Join-Path $script:here "alifeai_job.ps1") + "`" -Action " + $act + " -Id " + $id
      if ($arg) { $a += " -Arg `"" + $arg + "`"" }
      JobStatus $id $act "running" 0 "starting" $arg
      $script:jobInfo = @($id, $act, $arg)
      try { $script:job = Start-Process powershell -ArgumentList $a -WindowStyle Hidden -PassThru }
      catch { JobStatus $id $act "failed" 0 ("could not start: " + $_.Exception.Message) $arg }
    }
  }
}
# installed models for the AI tab: name|bytes per line
function Write-Models {
  try {
    $tags = Invoke-RestMethod "http://127.0.0.1:11434/api/tags" -TimeoutSec 2
    $lines = @($tags.models | ForEach-Object { $_.name + "|" + [int64]$_.size })
    $tmp = Join-Path $script:lua "alifeai_models.tmp"
    [IO.File]::WriteAllText($tmp, (($lines -join "`n") + "`n"), $script:utf8NoBom); Move-Item $tmp (Join-Path $script:lua "alifeai_models.txt") -Force
  } catch {}
}
$script:pathAt = 0
$script:offLogged = $false
function Log-Off { if (-not $script:offLogged) { $script:offLogged = $true; HLog "AI is turned off (alifeai_off.flag): starting nothing" } }

while ($true) {
  Restart-IfUpdated
  $game = Get-Process -Name "ProjectZomboid64","ProjectZomboid32","java" -ErrorAction SilentlyContinue |
    Where-Object { $_.ProcessName -ne "java" -or ($_.Path -and $_.Path -match "ProjectZomboid") }
  if (-not $game) {
    if ($bridge -or $voice -or $talk) { Stop-All }
    $model = ReadModel
    # a new session tries your own model again
    try { Remove-Item -LiteralPath (Join-Path $lua "alifeai_model_fallback.txt") -Force -ErrorAction SilentlyContinue } catch {}
    $gpuPeak = 0; $gpuSum = 0; $gpuN = 0
    Tick-Report "closed"
    Start-Sleep 5; continue
  }
  # AI turned off: stop everything once, start nothing, keep answering the game's commands
  if (AiOff) {
    if ($bridge -or $voice -or $talk) { Stop-All }
    Log-Off
    Tick-Report "off"
    $st = [ordered]@{ power = "off"; helper = $HelperVer; model_name = $model }
    $st.autostart = if (Test-Path -LiteralPath (AutostartLink)) { "on" } else { "off" }
    Status $st
    for ($i = 0; $i -lt 5; $i++) { Check-Cmd; Start-Sleep 1 }
    continue
  }
  Log-Gpu
  $st = [ordered]@{ power = "on" }
  # Ollama (skipped entirely when the cloud AI is set up)
  $cloud = CloudOn
  if ($cloud) { $st.ollama = "cloud"; $st.model = "ok"; CloudState $st }
  $tags = $null
  if (-not $cloud) {
  try { $tags = Invoke-RestMethod "http://127.0.0.1:11434/api/tags" -TimeoutSec 2 } catch {}
  if (-not $tags) {
    if (Get-Command ollama -ErrorAction SilentlyContinue) {
      if ((NowMs) - $started -gt 30000) { Start-Process ollama "serve" -WindowStyle Hidden; $started = NowMs }
      $st.ollama = "starting"
    } else {
      $st.ollama = "missing"
      # 0.8.12: Ollama installed from the AI tab (winget) is on PATH only for new processes: pick it up without a restart
      if ((NowMs) - $script:pathAt -gt 30000) { $script:pathAt = NowMs; $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User") }
    }
  } else {
    $st.ollama = "ok"
    Write-Models
    $names = @($tags.models | ForEach-Object { $_.name })
    $st.model = if ($names -contains $model -or $names -contains ($model + ":latest")) { "ok" } else { "missing" }
    # a model picked in model.txt that isn't downloaded yet: download it once, quietly
    if ($st.model -eq "missing") {
      if ($pull -ne $null -and -not $pull.HasExited) { $st.model = "downloading" }
      elseif (-not $pulled[$model]) {
        $pulled[$model] = $true
        $pull = Start-Process ollama -ArgumentList ("pull " + $model) -WindowStyle Hidden -PassThru
        $st.model = "downloading"
      }
    }
  }
  }
  # AI bridge
  if (($st.ollama -eq "ok" -or $st.ollama -eq "cloud") -and $st.model -eq "ok") {
    if ($bridge -eq $null -or $bridge.HasExited) {
      if ($bridge -ne $null) { $bridgeFails++ }
      if ($bridgeFails -lt 3) { $bridge = Launch "alifeai_bridge.ps1" $bridgeLog ("-Model " + $model); $st.bridge = "starting" }
      else { $st.bridge = "failed"; $st.bridge_error = LastLine $bridgeLog }
    } else {
      $beat = 0; try { $beat = [int64](Get-Content (Join-Path $lua "alifeai_alive.txt") -TotalCount 1) } catch {}
      if ((NowMs) - $beat -lt 15000) { $st.bridge = "ok" }
      elseif ((NowMs) - $bridge.StartTime.ToUniversalTime().Subtract([datetime]'1970-01-01').TotalMilliseconds -gt (1000 * ([int](ModelSetting "warmup" 180) * 2 + 60))) {
        $st.bridge = "stuck"; $st.bridge_error = LastLine $bridgeLog
        try { Stop-Process -Id $bridge.Id -Force } catch {}
      } else { $st.bridge = "starting" }
    }
  }
  # 0.8.11.2: model fallback (the AI bridge's warm-up failed on your model): the chat bridge follows
  $fbk = FallbackModel $model
  $talkModel = if ($fbk) { $fbk["to"] } else { $model }
  if ($fbk) { $st.fallback = $fbk["to"]; $st.fallback_from = $model; $st.fallback_at = $fbk["at"] }
  if ($talk -ne $null -and -not $talk.HasExited -and $script:talkRunModel -and $script:talkRunModel -ne $talkModel) {
    HLog ("chat bridge restarts on " + $talkModel + " (was " + $script:talkRunModel + ")")
    try { Stop-Process -Id $talk.Id -Force } catch {}
    $talk = $null
  }
  # A-Life Talk bridge (Python): free chat, relationships, news
  if (($st.ollama -eq "ok" -or $st.ollama -eq "cloud") -and $st.model -eq "ok") {
    $py = PyCmd
    if ($py -eq $null) {
      # install Python quietly once (per-user, no admin prompt) so existing players don't have to re-run Setup
      if (-not $pyTried -and (Get-Command winget -ErrorAction SilentlyContinue)) {
        $pyTried = $true
        $pyInstall = Start-Process winget -ArgumentList "install --id Python.Python.3.12 -e --scope user --silent --accept-source-agreements --accept-package-agreements" -WindowStyle Hidden -PassThru
      }
      if ($pyInstall -ne $null -and -not $pyInstall.HasExited) { $st.talk = "installing" }
      else {
        # winget puts py/python on PATH for new processes; pick it up without a restart
        $env:Path = [Environment]::GetEnvironmentVariable("Path", "User") + ";" + [Environment]::GetEnvironmentVariable("Path", "Machine")
        $script:pyCache = $null
        if ((PyCmd) -eq $null) { $st.talk = "nopython" }
      }
    }
    elseif ($talk -eq $null -or $talk.HasExited) {
      if ($talk -ne $null) { $talkFails++ }
      if ($talkFails -lt 3) {
        $args2 = @()
        if ($py.Count -gt 1) { $args2 += $py[1..($py.Count - 1)] }
        $args2 += @("`"" + (Join-Path $here "alifetalk_bridge.py") + "`"", "--exit-with-game", "--model", $talkModel)
        # 0.8.12: the AI tab's reply length and wait limit (numbers only)
        $np = SetupSetting "num_predict"; if ($np -match '^\d{1,4}$') { $args2 += @("--num-predict", $np) }
        $to = SetupSetting "timeout"; if ($to -match '^\d{1,3}$') { $args2 += @("--timeout", $to) }
        $script:talkRunModel = $talkModel
        $env:ALIFETALK_VOICE = "none"
        try {
          $talk = Start-Process -FilePath $py[0] -ArgumentList $args2 -WindowStyle Hidden -PassThru -RedirectStandardOutput $talkLog -RedirectStandardError ($talkLog + ".err") -ErrorAction Stop
          $st.talk = "starting"
        } catch {
          # counts as a failed start (3 strikes, then "failed" with the reason) instead of retrying forever
          $talkFails++; $script:pyCache = $null; $talk = $null
          HLog ("could not start the chat bridge with " + [string]$py[0] + ": " + $_.Exception.Message)
          $st.talk = "failed"; $st.talk_error = $_.Exception.Message
        }
      } else { $st.talk = "failed"; $st.talk_error = LastLine ($talkLog + ".err") }
    } else { $st.talk = "ok" }
  }
  # voice
  if ($voice -eq $null -or $voice.HasExited) {
    if ($voice -ne $null) { $voiceFails++ }
    if ($voiceFails -lt 3) { $voice = Launch "alifeai_whisper.ps1" $voiceLog ""; $st.voice = "starting" }
    else { $st.voice = "failed"; $st.voice_error = LastLine $voiceLog }
  } else { $st.voice = "ok" }
  $st.helper = $HelperVer; $st.model_name = $model
  $st.autostart = if (Test-Path -LiteralPath (AutostartLink)) { "on" } else { "off" }
  Status $st
  Tick-Report "on"
  # 0.8.12: the AI tab's commands get picked up within a second
  for ($i = 0; $i -lt 5; $i++) { Check-Cmd; Start-Sleep 1 }
}
