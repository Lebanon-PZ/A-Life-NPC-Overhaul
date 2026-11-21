# A-Life NPC Overhaul pre-1.0: AUTOMATIC BUG REPORTS to the mod author's Discord (opt-in, OFF until the player says yes).
# Dot-sourced by alifeai_watcher.ps1 (the helper), so it works with the AI on OR off and needs no Python.
# The game asks once (ALifeBugReports.lua) and writes Zomboid\Lua\alifeai_report.txt (enabled=true/false).
# When a mod feature switches itself off after an error, the game writes it into Zomboid\Lua\ALifeChatPlus_health.txt.
# If enabled, this sends that file + the end of console.txt to a Discord webhook: a short message and two attachments.
# Windows user name and home folder become <user> / <home> first. At most max_per_day a day, and only when the list
# of features that turned off changed since the last report. Webhook: url= in alifeai_report.txt, else the first
# line of bridge\report_url.txt (the author's; a new mod update can swap it if it gets abused). Empty = nothing sent.

function Rep-Cfg([string]$path) {
  $cfg = @{}
  if (-not (Test-Path -LiteralPath $path)) { return $null }
  try {
    foreach ($l in (Get-Content -LiteralPath $path -Encoding UTF8)) {
      $t = $l.Trim()
      if (-not $t -or $t.StartsWith("#") -or -not $t.Contains("=")) { continue }
      $i = $t.IndexOf("=")
      $cfg[$t.Substring(0, $i).Trim().ToLower()] = $t.Substring($i + 1).Trim()
    }
  } catch { return $null }
  return $cfg
}
function Rep-On($cfg) { return ($cfg -ne $null) -and (@("true", "yes", "1", "on") -contains ([string]$cfg["enabled"]).ToLower()) }
# the "features that turned themselves off" block of the health report ("" if none)
function Rep-Offs([string]$text) {
  $m = [regex]::Match($text, "FEATURES THAT TURNED THEMSELVES OFF\r?\n(.*?)\r?\n\r?\n", "Singleline")
  if (-not $m.Success) { return "" }
  $b = $m.Groups[1].Value.Trim()
  if ($b -eq "none") { return "" }
  return $b
}
function Rep-Scrub([string]$text, [string]$homeDir, [string]$user) {
  if ($homeDir) {
    foreach ($h in @($homeDir, $homeDir.Replace("\", "/"), $homeDir.Replace("/", "\"))) { $text = $text.Replace($h, "<home>") }
  }
  if ($user -and $user.Length -ge 3) { $text = [regex]::Replace($text, [regex]::Escape($user), "<user>", "IgnoreCase") }
  return $text
}
function Rep-Url($cfg, [string]$bridgeDir) {
  $u = [string]$cfg["url"]
  if (-not $u) {
    try { $u = [string](Get-Content -LiteralPath (Join-Path $bridgeDir "report_url.txt") -TotalCount 1 -Encoding UTF8) } catch { $u = "" }
  }
  $u = $u.Trim()
  if ($u -notmatch '^https://') { return "" }
  return $u
}
function Rep-Sha1([string]$s) {
  $sha = [System.Security.Cryptography.SHA1]::Create()
  return (($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($s)) | ForEach-Object { $_.ToString("x2") }) -join "")
}
function Rep-Json([string]$s) {
  $sb = New-Object System.Text.StringBuilder
  foreach ($c in $s.ToCharArray()) {
    $n = [int]$c
    if ($c -eq '"') { [void]$sb.Append('\"') } elseif ($c -eq '\') { [void]$sb.Append('\\') }
    elseif ($n -eq 10) { [void]$sb.Append('\n') } elseif ($n -eq 13) { } elseif ($n -eq 9) { [void]$sb.Append('\t') }
    elseif ($n -lt 32) { [void]$sb.Append(('\u{0:x4}' -f $n)) } else { [void]$sb.Append($c) }
  }
  return '"' + $sb.ToString() + '"'
}
# Discord's message: one short line + the features that turned off (fits Discord's 2000 characters). No pings.
function Rep-Content([string]$health, [string]$offs, [string]$helperVer, [string]$aiState) {
  $first = ($health -split "\r?\n")[0]
  $ver = "?"; $m = [regex]::Match($first, "\(mod ([^)]*)\)"); if ($m.Success) { $ver = $m.Groups[1].Value }
  $n = @($offs -split "\r?\n" | Where-Object { $_.Trim() }).Count
  $body = $offs; if ($body.Length -gt 1600) { $body = $body.Substring(0, 1600) + "`n..." }
  $fence = '```'
  return "Bug report: mod " + $ver + " | helper " + $helperVer + " | AI " + $aiState + " | " + $n + " feature(s) turned off`n" + $fence + "`n" + $body.Replace($fence, "'''") + "`n" + $fence
}
# forum channel post title (Discord wants thread_name there; max 100): "Bug: <first feature> (mod <ver>)"
function Rep-Title([string]$health, [string]$offs) {
  $ver = "?"; $m = [regex]::Match((($health -split "\r?\n")[0]), "\(mod ([^)]*)\)"); if ($m.Success) { $ver = $m.Groups[1].Value }
  $line = (($offs -split "\r?\n")[0]).Trim()
  $f = [regex]::Match($line, "^game hour [^:]*:\s*(.+?)\s+-\s")
  $what = if ($f.Success) { $f.Groups[1].Value } else { $line }
  $n = @($offs -split "\r?\n" | Where-Object { $_.Trim() }).Count
  $t = "Bug: " + $what + $(if ($n -gt 1) { " +" + ($n - 1) + " more" } else { "" }) + " (mod " + $ver + ")"
  if ($t.Length -gt 100) { $t = $t.Substring(0, 97) + "..." }
  return $t
}
# multipart/form-data body (payload_json + files[0..n]) as bytes; Discord webhook format. $thread = forum post title.
function Rep-Body([string]$boundary, [string]$content, $files, [string]$thread = "") {
  $enc = New-Object System.Text.UTF8Encoding($false)
  $ms = New-Object System.IO.MemoryStream
  function W([string]$s) { $b = $enc.GetBytes($s); $ms.Write($b, 0, $b.Length) }
  W ("--" + $boundary + "`r`nContent-Disposition: form-data; name=`"payload_json`"`r`nContent-Type: application/json`r`n`r`n")
  $th = ""; if ($thread) { $th = ',"thread_name":' + (Rep-Json $thread) }
  W ('{"content":' + (Rep-Json $content) + $th + ',"allowed_mentions":{"parse":[]}}' + "`r`n")
  $i = 0
  foreach ($f in $files) {
    W ("--" + $boundary + "`r`nContent-Disposition: form-data; name=`"files[" + $i + "]`"; filename=`"" + $f.name + "`"`r`nContent-Type: text/plain; charset=utf-8`r`n`r`n")
    W ($f.text + "`r`n")
    $i++
  }
  W ("--" + $boundary + "--`r`n")
  return $ms.ToArray()
}
function Rep-Post([string]$url, [byte[]]$body, [string]$boundary) {
  try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
  $r = Invoke-WebRequest -Uri $url -Method Post -Body $body -ContentType ("multipart/form-data; boundary=" + $boundary) -UseBasicParsing -TimeoutSec 20 -UserAgent "ALifeNPCOverhaul-report"
  return ($r.StatusCode -ge 200 -and $r.StatusCode -lt 300)
}

function Rep-Int($cfg, [string]$key, [int]$default) {
  if ($cfg -eq $null -or -not $cfg.ContainsKey($key)) { return $default }
  try { return [math]::Max(0, [int]$cfg[$key]) } catch { return $default }
}
function Rep-Console([string]$luaDir, [int]$lines) {
  if ($lines -le 0) { return "" }
  try { return (Get-Content -LiteralPath (Join-Path (Split-Path $luaDir -Parent) "console.txt") -Tail $lines -Encoding UTF8) -join "`r`n" } catch { return "" }
}
# forum channel first (the author's is one: each report = its own post); a plain text channel answers 400 -> again without
function Rep-Send([string]$url, [string]$content, $files, [string]$title, $post) {
  $boundary = "----ALifeReport" + [Guid]::NewGuid().ToString("N")
  $ok = $false; $err = $null
  foreach ($thread in @($title, "")) {
    $body = Rep-Body $boundary $content $files $thread
    try {
      if ($post) { $ok = & $post $url $body $boundary } else { $ok = Rep-Post $url $body $boundary }
      $err = $null; break
    } catch {
      $err = $_.Exception.Message
      if ($err -notmatch "400") { break }
    }
  }
  if (-not $err -and -not $ok) { $err = "not accepted" }
  return @{ ok = [bool]$ok; err = $err }
}
function Rep-Result([string]$luaDir, [string]$id, [string]$state, [string]$msg) {
  $msg = ($msg -replace "[\r\n]+", " "); if ($msg.Length -gt 200) { $msg = $msg.Substring(0, 200) }
  $txt = "id=" + $id + "`nstate=" + $state + "`nmsg=" + $msg + "`nt=" + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() + "`n"
  try { [IO.File]::WriteAllText((Join-Path $luaDir "alifeai_report_result.txt"), $txt, (New-Object System.Text.UTF8Encoding($false))) } catch {}
}

# MANUAL report: the player pressed "Report a bug" in game. The game writes Zomboid\Lua\alifeai_report_send.txt
# (id=, ver=, hours=, note=); we delete it, send at once (no on/off switch needed: the click is the consent), and answer
# in alifeai_report_result.txt (id, state = sent | failed | limit | nourl, msg). manual_per_day (default 10),
# manual_console_lines (default 2000) in alifeai_report.txt. Returns $null (no request) or the state.
function Send-ManualReport([string]$luaDir, [string]$bridgeDir, [string]$helperVer, [string]$aiState, $post = $null) {
  $rp = Join-Path $luaDir "alifeai_report_send.txt"
  if (-not (Test-Path -LiteralPath $rp)) { return $null }
  $req = Rep-Cfg $rp
  try { Remove-Item -LiteralPath $rp -Force } catch {}
  if ($req -eq $null) { return $null }
  $id = [string]$req["id"]; if ($id -notmatch '^[A-Za-z0-9_\-]{1,40}$') { return $null }
  $cfg = Rep-Cfg (Join-Path $luaDir "alifeai_report.txt"); if ($cfg -eq $null) { $cfg = @{} }
  $url = Rep-Url $cfg $bridgeDir
  if (-not $url) { Rep-Result $luaDir $id "nourl" "no report address set"; return "nourl" }
  $sp = Join-Path $luaDir "alifeai_report_manual_state.json"
  $st = $null; try { $st = Get-Content -LiteralPath $sp -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
  $day = (Get-Date -Format "yyyy-MM-dd")
  $sent = 0; if ($st -ne $null -and $st.day -eq $day) { $sent = [int]$st.count }
  if ($sent -ge (Rep-Int $cfg "manual_per_day" 10)) { Rep-Result $luaDir $id "limit" "daily limit reached"; return "limit" }
  $homeDir = $env:USERPROFILE; $user = $env:USERNAME
  $note = ([string]$req["note"]).Trim(); if ($note.Length -gt 1000) { $note = $note.Substring(0, 1000) }
  $ver = [string]$req["ver"]; if (-not $ver) { $ver = "?" }
  $health = ""; try { $health = [IO.File]::ReadAllText((Join-Path $luaDir "ALifeChatPlus_health.txt")) } catch {}
  $console = Rep-Console $luaDir (Rep-Int $cfg "manual_console_lines" 2000)
  $files = @()
  if ($health) { $files += @{ name = "health.txt"; text = (Rep-Scrub $health $homeDir $user) } }
  if ($console) { $files += @{ name = "console.txt"; text = (Rep-Scrub $console $homeDir $user) } }
  $offs = Rep-Offs $health
  $n = 0; if ($offs) { $n = @($offs -split "\r?\n" | Where-Object { $_.Trim() }).Count }
  $shown = $note; if (-not $shown) { $shown = "(no note)" }
  $content = "Player report: mod " + $ver + " | helper " + $helperVer + " | AI " + $aiState + " | game hour " + [string]$req["hours"] + " | features off: " + $n + "`n> " + ($shown -replace "\r?\n", "`n> ")
  $content = Rep-Scrub $content $homeDir $user
  $short = ($note -replace "\s+", " "); if ($short.Length -gt 60) { $short = $short.Substring(0, 57) + "..." }
  if (-not $short) { $short = "(no note)" }
  $title = Rep-Scrub ("Report: " + $short + " (mod " + $ver + ")") $homeDir $user
  if ($title.Length -gt 100) { $title = $title.Substring(0, 97) + "..." }
  $res = Rep-Send $url $content $files $title $post
  if (-not $res.ok) {
    if (Get-Command HLog -ErrorAction SilentlyContinue) { HLog ("manual bug report not sent: " + $res.err) }
    Rep-Result $luaDir $id "failed" ([string]$res.err); return "failed"
  }
  $new = [ordered]@{ day = $day; count = $sent + 1 }
  try { [IO.File]::WriteAllText($sp, ($new | ConvertTo-Json -Compress), (New-Object System.Text.UTF8Encoding($false))) } catch {}
  if (Get-Command HLog -ErrorAction SilentlyContinue) { HLog "manual bug report sent" }
  Rep-Result $luaDir $id "sent" ""
  return "sent"
}

$script:repNext = 0
# returns $null (nothing to do), $true (sent) or $false (failed). $post can be swapped in tests.
function Send-BugReport([string]$luaDir, [string]$bridgeDir, [string]$helperVer, [string]$aiState, $post = $null, [switch]$now) {
  $t = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  if (-not $now -and $t -lt $script:repNext) { return $null }
  $script:repNext = $t + 60000
  $cfg = Rep-Cfg (Join-Path $luaDir "alifeai_report.txt")
  if (-not (Rep-On $cfg)) { return $null }
  $url = Rep-Url $cfg $bridgeDir
  if (-not $url) { return $null }
  $hp = Join-Path $luaDir "ALifeChatPlus_health.txt"
  if (-not (Test-Path -LiteralPath $hp)) { return $null }
  $health = ""; try { $health = [IO.File]::ReadAllText($hp) } catch { return $null }
  $offs = Rep-Offs $health
  if (-not $offs) { return $null }
  $digest = Rep-Sha1 $offs
  $sp = Join-Path $luaDir "alifeai_report_state.json"
  $st = $null; try { $st = Get-Content -LiteralPath $sp -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
  if ($st -ne $null -and $st.last -eq $digest) { return $null }
  $day = (Get-Date -Format "yyyy-MM-dd")
  $sent = 0; if ($st -ne $null -and $st.day -eq $day) { $sent = [int]$st.count }
  $cap = 3; try { if ($cfg.ContainsKey("max_per_day")) { $cap = [int]$cfg["max_per_day"] } } catch { $cap = 3 }
  if ($sent -ge $cap) { return $null }
  $console = Rep-Console $luaDir (Rep-Int $cfg "console_lines" 300)
  $homeDir = $env:USERPROFILE; $user = $env:USERNAME
  $files = @(@{ name = "health.txt"; text = (Rep-Scrub $health $homeDir $user) })
  if ($console) { $files += @{ name = "console.txt"; text = (Rep-Scrub $console $homeDir $user) } }
  $content = Rep-Scrub (Rep-Content $health $offs $helperVer $aiState) $homeDir $user
  $title = Rep-Scrub (Rep-Title $health $offs) $homeDir $user
  $res = Rep-Send $url $content $files $title $post
  $ok = $res.ok; $err = $res.err
  if ($err) {
    if (Get-Command HLog -ErrorAction SilentlyContinue) { HLog ("bug report not sent: " + $err) }
    return $false
  }
  if ($ok) {
    $new = [ordered]@{ last = $digest; day = $day; count = $sent + 1 }
    try { [IO.File]::WriteAllText($sp, ($new | ConvertTo-Json -Compress), (New-Object System.Text.UTF8Encoding($false))) } catch {}
    if (Get-Command HLog -ErrorAction SilentlyContinue) { HLog ("bug report sent (features turned off: " + @($offs -split "\r?\n").Count + ")") }
  }
  return $ok
}
