# A-Life NPC Overhaul 0.8.12: one long job for the game's AI tab, started by the helper (alifeai_watcher.ps1).
#   pull <model>   download a model through Ollama's web API, with progress
#   test <model>   load the model and ask for one line: time taken, load time, words a second, share on the graphics card
#   warm <model>   load the model only
#   get_ollama     install Ollama with winget (Windows asks once: Yes). No winget: open the download page.
# Writes Zomboid\Lua\alifeai_setup_status.txt (no BOM: the game reads it). Only these actions; the model name is
# checked again here and only ever goes into a JSON body for Ollama.
param([string]$Action, [string]$Arg = "", [string]$Id = "0", [string]$LuaDir = "")
$ErrorActionPreference = "Continue"
$lua = if ($LuaDir) { $LuaDir } else { Join-Path $env:USERPROFILE "Zomboid\Lua" }
$here = $PSScriptRoot
$Ollama = if ($env:ALIFEAI_OLLAMA_TEST) { $env:ALIFEAI_OLLAMA_TEST } else { "http://127.0.0.1:11434" }  # test harness only
$utf8 = New-Object System.Text.UTF8Encoding($false)
function NowMs { [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
function ValidModel([string]$m) { return ($m -match '^[A-Za-z0-9._:/\-]{1,120}$') -and ($m -notmatch '\.\.') -and ($m -notmatch '^[-/]') }
function Say([string]$state, [int]$pct, [string]$msg, $extra = $null) {
  $t = "id=$Id`naction=$Action`narg=$Arg`nstate=$state`nprogress=$pct`nmsg=" + ($msg -replace "[\r\n]", " ") + "`nt=" + (NowMs) + "`n"
  if ($extra) { foreach ($k in $extra.Keys) { $t += $k + "=" + (([string]$extra[$k]) -replace "[\r\n]", " ") + "`n" } }
  try { $tmp = Join-Path $lua "alifeai_setup_status.job.tmp"; [IO.File]::WriteAllText($tmp, $t, $utf8); Move-Item $tmp (Join-Path $lua "alifeai_setup_status.txt") -Force } catch {}
}
# the AI tab's choices first, then model.txt
function Setting([string]$key, $default) {
  foreach ($f in @((Join-Path $lua "alifeai_setup.txt"), (Join-Path $here "model.txt"))) {
    if (-not (Test-Path -LiteralPath $f)) { continue }
    try { foreach ($l in (Get-Content -LiteralPath $f -Encoding UTF8)) { if ($l -match ('^\s*' + [regex]::Escape($key) + '\s*=\s*(\S+)')) { return $Matches[1] } } } catch {}
  }
  return $default
}
function PostJson([string]$path, $obj, [int]$timeoutMs) {
  $req = [System.Net.HttpWebRequest]::Create($Ollama + $path)
  $req.Method = "POST"; $req.ContentType = "application/json"; $req.Timeout = $timeoutMs; $req.ReadWriteTimeout = $timeoutMs
  $b = $utf8.GetBytes(($obj | ConvertTo-Json -Compress -Depth 5))
  $s = $req.GetRequestStream(); $s.Write($b, 0, $b.Length); $s.Close()
  return $req.GetResponse()
}

if (@("pull", "test", "warm", "get_ollama") -notcontains $Action) { Say "failed" 0 "unknown action"; exit 1 }
if ($Action -ne "get_ollama" -and -not (ValidModel $Arg)) { Say "failed" 0 "bad model name"; exit 1 }

if ($Action -eq "pull") {
  Say "running" 0 "connecting"
  try {
    $resp = PostJson "/api/pull" @{ model = $Arg; name = $Arg; stream = $true } 3600000
    $rd = New-Object System.IO.StreamReader($resp.GetResponseStream())
    $last = 0; $pct = 0
    while ($null -ne ($line = $rd.ReadLine())) {
      $j = $null; try { $j = $line | ConvertFrom-Json } catch { continue }
      if ($j.error) { Say "failed" $pct ([string]$j.error); $rd.Close(); exit 1 }
      $extra = @{}
      if ($j.total -and $j.completed) {
        $pct = [int][math]::Floor(100.0 * $j.completed / $j.total)
        $extra["done_mb"] = [int]($j.completed / 1MB); $extra["total_mb"] = [int]($j.total / 1MB)
      }
      if ((NowMs) - $last -gt 700) { $last = NowMs; Say "running" $pct ([string]$j.status) $extra }
    }
    $rd.Close()
    Say "done" 100 ("downloaded " + $Arg)
  } catch { Say "failed" 0 ("download failed: " + $_.Exception.Message); exit 1 }
  exit 0
}

if ($Action -eq "test" -or $Action -eq "warm") {
  $ctx = 4096; try { $ctx = [int](Setting "num_ctx" 4096) } catch {}
  $wait = 180; try { $wait = [int](Setting "warmup" 180) } catch {}
  $prompt = if ($Action -eq "test") { "You are a tired survivor in a zombie apocalypse in Kentucky. A stranger walks up. Greet them in one short sentence, in character." } else { "" }
  Say "running" 10 ("loading " + $Arg)
  try {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $resp = PostJson "/api/generate" @{ model = $Arg; prompt = $prompt; stream = $false; keep_alive = "60m"; options = @{ num_ctx = $ctx; num_predict = 40 } } (1000 * ($wait + 60))
    $rd = New-Object System.IO.StreamReader($resp.GetResponseStream()); $body = $rd.ReadToEnd(); $rd.Close()
    $ms = $sw.ElapsedMilliseconds
    $r = $body | ConvertFrom-Json
    if ($r.error) { Say "failed" 0 ([string]$r.error); exit 1 }
    $extra = @{ model = $Arg; ms = $ms; load_ms = [int64]([double]$r.load_duration / 1e6) }
    if ([double]$r.eval_duration -gt 0) { $extra["tps"] = [math]::Round([double]$r.eval_count / ([double]$r.eval_duration / 1e9), 1) }
    $reply = ([string]$r.response).Trim()
    if ($reply.Length -gt 180) { $reply = $reply.Substring(0, 180) }
    $extra["reply"] = $reply
    try {
      $ps = Invoke-RestMethod ($Ollama + "/api/ps") -TimeoutSec 5
      $e = $ps.models | Where-Object { $_.name -eq $Arg -or $_.model -eq $Arg -or $_.name -eq ($Arg + ":latest") } | Select-Object -First 1
      if ($e -and [double]$e.size -gt 0) { $extra["gpu"] = [int][math]::Floor(100.0 * [double]$e.size_vram / [double]$e.size) }
    } catch {}
    Say "done" 100 ("answered in " + [math]::Round($ms / 1000, 1) + " s") $extra
  } catch { Say "failed" 0 ("no answer: " + $_.Exception.Message); exit 1 }
  exit 0
}

if ($Action -eq "get_ollama") {
  if (Get-Command ollama -ErrorAction SilentlyContinue) { Say "done" 100 "Ollama is already installed"; exit 0 }
  if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Start-Process "https://ollama.com/download"
    Say "failed" 0 "no winget on this PC: the download page opened in your browser. Install it, then come back."
    exit 1
  }
  Say "running" 20 "installing with winget (Windows may ask: click Yes)"
  try {
    $p = Start-Process winget -ArgumentList "install --id Ollama.Ollama -e --accept-source-agreements --accept-package-agreements" -WindowStyle Hidden -PassThru -Wait
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
    if (Get-Command ollama -ErrorAction SilentlyContinue) { Say "done" 100 "Ollama installed"; exit 0 }
    $local = Join-Path $env:LOCALAPPDATA "Programs\Ollama\ollama.exe"
    if (Test-Path -LiteralPath $local) { Say "done" 100 "Ollama installed"; exit 0 }
    Say "failed" 0 ("winget finished (code " + $p.ExitCode + ") but Ollama isn't there. Get it from ollama.com/download.")
  } catch { Say "failed" 0 ("could not run winget: " + $_.Exception.Message) }
  exit 1
}
