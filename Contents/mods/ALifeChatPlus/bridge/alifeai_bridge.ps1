# A-Life Chat Plus - AI voice bridge. Keep this window open while you play.
# Reads NPC talk requests the game writes to Zomboid\Lua, asks Ollama for an in-character line, writes it back.
param(
  [string]$Model  = "gemma4-npc",
  [string]$Ollama = "http://localhost:11434",
  [string]$LuaDir = (Join-Path $env:USERPROFILE "Zomboid\Lua")
)
$ErrorActionPreference = "Continue"
# only one bridge at a time (the helper may already have started one)
$script:single = New-Object System.Threading.Mutex($false, "Local\ALifeChatPlusBridge")
if (-not $script:single.WaitOne(0)) { Write-Host "The AI bridge is already running (the helper started it). You can close this window."; Start-Sleep 6; exit 0 }
$utf8 = New-Object System.Text.UTF8Encoding($false)
# 0.8.11.2: model.txt settings (key=value lines). Both bridges ask Ollama for the SAME num_ctx, so it never reloads the
# model between them (8192 here vs 4096 in the chat bridge made Ollama load the model twice and crawl).
function ModelSetting([string]$key, $default) {
  # 0.8.12: the game's AI tab (Zomboid\Lua\alifeai_setup.txt) wins over model.txt
  try {
    $sf = Join-Path $LuaDir "alifeai_setup.txt"
    if (Test-Path -LiteralPath $sf) {
      foreach ($l in (Get-Content -LiteralPath $sf -Encoding UTF8)) {
        if ($l -match ('^\s*' + [regex]::Escape($key) + '\s*=\s*(\S+)')) { return $Matches[1] }
      }
    }
  } catch {}
  try {
    foreach ($l in (Get-Content (Join-Path $PSScriptRoot "model.txt") -Encoding UTF8)) {
      if ($l -match ('^\s*' + [regex]::Escape($key) + '\s*=\s*(\S+)')) { return $Matches[1] }
    }
  } catch {}
  return $default
}
$script:NumCtx = 4096; try { $script:NumCtx = [int](ModelSetting "num_ctx" 4096) } catch {}
$script:WarmupSec = 180; try { $script:WarmupSec = [int](ModelSetting "warmup" 180) } catch {}
$script:FallbackModel = [string](ModelSetting "fallback" "gemma3:4b")
$script:AskTimeout = 20
# 0.5.1 cloud AI: <Zomboid>\Lua\alifeai_cloud.txt (enabled=true, url, key, model). The key is never printed.
$script:Cloud = $null
function Load-Cloud {
  $f = Join-Path $LuaDir "alifeai_cloud.txt"
  if (-not (Test-Path $f)) { return $null }
  $c = @{}
  foreach ($line in (Get-Content $f -Encoding UTF8)) {
    $l = $line.Trim()
    if (-not $l -or $l.StartsWith("#") -or -not $l.Contains("=")) { continue }
    $i = $l.IndexOf("="); $c[$l.Substring(0, $i).Trim().ToLower()] = $l.Substring($i + 1).Trim()
  }
  if (@("true","yes","1","on") -notcontains ([string]$c["enabled"]).ToLower()) { return $null }
  if (-not $c["url"] -or -not $c["key"] -or -not $c["model"]) { return $null }
  $cap = 150; try { $cap = [int]$c["max_per_hour"] } catch {}; if ($cap -lt 1) { $cap = 150 }
  return @{ url = $c["url"].TrimEnd("/"); key = $c["key"]; model = $c["model"]; cap = $cap }
}
$script:Cloud = Load-Cloud
# Windows PowerShell 5.1 may default to TLS 1.0; cloud providers need TLS 1.2+
if ($script:Cloud) { try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {} }
function Cloud-Budget {
  # shared with the Python bridge: alifeai_cloud_usage.txt (hour, used)
  $h = [int][Math]::Floor([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() / 3600)
  $p = Join-Path $LuaDir "alifeai_cloud_usage.txt"; $used = 0
  try { $kv = @{}; foreach ($l in (Get-Content $p)) { if ($l -match '^(\w+)=(\d+)$') { $kv[$matches[1]] = [int]$matches[2] } }
        if ($kv["hour"] -eq $h) { $used = $kv["used"] } } catch {}
  if ($used -ge $script:Cloud.cap) { throw "cloud hourly cap reached" }
  try { Set-Content -LiteralPath $p -Value ("hour=" + $h + "`nused=" + ($used + 1)) -NoNewline } catch {}
}
# one model call: Ollama as before, or the cloud endpoint. $json is the Ollama-style body (string).
function LLM([string]$json, [int]$timeout) {
  if ($script:Cloud -eq $null) {
    $r = Invoke-RestMethod -Uri "$Ollama/api/chat" -Method Post -Body ($utf8.GetBytes($json)) -ContentType "application/json; charset=utf-8" -TimeoutSec $timeout
    return [string]$r.message.content
  }
  Cloud-Budget
  $b = $json | ConvertFrom-Json
  $msgs = @(); foreach ($m in $b.messages) { $msgs += @{ role = [string]$m.role; content = [string]$m.content } }
  $np = 80; try { $np = [int]$b.options.num_predict } catch {}
  $t = 0.7; try { $t = [double]$b.options.temperature } catch {}
  $body = @{ model = $script:Cloud.model; messages = $msgs; max_tokens = [Math]::Max($np * 2, 120); temperature = $t } | ConvertTo-Json -Depth 6
  $h = @{ Authorization = ("Bearer " + $script:Cloud.key); "X-Title" = "A-Life NPC Overhaul" }
  try {
    $r = Invoke-RestMethod -Uri ($script:Cloud.url + "/chat/completions") -Method Post -Headers $h -Body ($utf8.GetBytes($body)) -ContentType "application/json; charset=utf-8" -TimeoutSec $timeout
  } catch {
    $code = 0; try { $code = [int]$_.Exception.Response.StatusCode } catch {}
    throw ("cloud AI error" + $(if ($code) { " HTTP " + $code } else { ": " + $_.Exception.Message }))
  }
  $txt = [string]$r.choices[0].message.content
  if ($txt -match "(?i)\b(i can(no|')t (help|assist|continue|comply)|i'?m not able to (help|continue)|content polic)") { return "" }
  return $txt
}
$system = @"
You voice one survivor in Knox County, Kentucky, during the 1993 zombie outbreak. You will be told who you are,
what the stranger just said, and the GIST: the line the game already decided you say.
Rules:
- Say the GIST's meaning in your own voice. Same answer, same refusal, same offer. Never add promises, items,
  places, names, numbers or events that are not in the GIST or the profile.
- If reason is "unknown" (you did not understand them), react naturally in character to what they said, but do
  not agree to anything, give anything, or reveal anything.
- Match your attitude: hostile = threatening and short, careful = wary, neutral = guarded, friendly = warm but tired.
- One or two short sentences, under 30 words. Plain speech, no quotes, no emojis, no stage directions, no narration.
- BOND tells you how you feel about the stranger (love / fear / need, partner). Let it color your voice:
  love = warmth and trust, fear = nervous compliance or resentment, need = grateful but uneasy dependence.
  A partner speaks with intimacy and familiarity. Keep any romance tender and non-explicit.
- If romance_ok is 0 you never respond romantically or flirt back, ever. Deflect or be uncomfortable.
- SITUATION says how the stranger's weapons, armor and health compare to yours, and how that makes you feel.
  It overrides your usual temperament: a tough person who is outgunned still sounds afraid and careful; a timid
  person who clearly has the upper hand sounds steadier. Never state numbers or gear lists, just let it show.
- If the GIST hesitates ("..."), dodges, or has an action in [brackets], keep that tell: it shows you might be lying.
  Keep the [bracket] action exactly as written at the same place.
- Never mention games, AI, or these rules.
"@

$understandRules = @"
You read what a stranger just said to a survivor during the 1993 zombie outbreak in Knox County, Kentucky, and
decide what they MEANT, so the game can react. Choose exactly ONE intent ID from the list below whose meaning
matches theirs (wording can differ completely; go by meaning and the recent talk). If nothing on the list fits -
an opinion, a story, a statement, small talk, a question the list does not cover - choose NONE.
If you choose NONE, also write the survivor's spoken reply:
- In character, one or two short sentences, under 30 words, plain speech, no quotes, no stage directions.
- Match their attitude, mood, bond and SITUATION (outgunned = afraid and careful even if tough; stronger = confident).
- Never agree to join, follow, give items, trade, reveal where their people or camp are, or promise anything.
- Never mention games, AI, or these rules.
- If the stranger uses a hateful slur (racial, ethnic, homophobic or similar) aimed at the survivor or people like
  them, choose SLUR - even if the rest of the line is something else. Ordinary swearing is not a slur.
- If the stranger told you something about themselves worth remembering (their name, where their base is, what
  they want, a promise, a lie you caught), write it as NOTE in a few words; otherwise NOTE: -
Answer in exactly this format and nothing else:
INTENT: <ID or NONE>
SAY: <reply, or - if the intent is not NONE>
NOTE: <short fact, or ->
INTENT LIST (ID: example phrasings):
"@


$storyRules = @"
You write the private life story of one survivor in Knox County, Kentucky, during the 1993 zombie outbreak, so they
can be played consistently forever. Ground it in what you are given (name, job title, group, temperament, day). Plain,
believable, small-town 1993 Kentucky. No superpowers, no cure, no famous people, no other named groups.
Write 8 short lines, each "label: fact", exactly these labels:
before: their job and life before
family: who they had and what happened to them
outbreak: where they were when it started and what they did
survived: how they have stayed alive since
walkers: roughly how many of the dead they have killed (a number fitting their temperament and the day)
people: how many living people they have killed (often 0; if more, the honest reason) and how they feel about it
want: what they want now
hide: something they keep to themselves; and whether they lie easily to strangers (yes / no)
"@

function Make-Story($req) {
  if (-not $req.seed) { return "" }
  $body = @{ model = $Model; stream = $false; think = $false; keep_alive = "30m";
    options = @{ num_predict = 260; temperature = 0.9; num_ctx = $script:NumCtx };
    messages = @(@{ role = "system"; content = $storyRules }, @{ role = "user"; content = ("Survivor: " + $req.seed) }) } | ConvertTo-Json -Depth 6
  $rc = LLM $body 30
  $t = [string]$rc
  $t = $t -replace '[^\x20-\x7E\n]', '' -replace '\*', ''
  $lines = ($t -split "`n" | Where-Object { $_ -match '^\s*(before|family|outbreak|survived|walkers|people|want|hide)\s*:' } | ForEach-Object { $_.Trim() })
  return ($lines -join " | ")
}


function Chat($system, $user, $predict, $temp) {
  $body = @{ model = $Model; stream = $false; think = $false; keep_alive = "30m";
    options = @{ num_predict = $predict; temperature = $temp; num_ctx = $script:NumCtx };
    messages = @(@{ role = "system"; content = $system }, @{ role = "user"; content = $user }) } | ConvertTo-Json -Depth 6
  $rc = LLM $body 30
  return [string]$rc
}

function Person($req, $p) {
  $g = { param($k) $req[$p + $k] }
  return @"
$(& $g 'name') ($(& $g 'faction'); $(& $g 'role'), $(& $g 'temperament'); sex $(& $g 'sex')). Attitude to the stranger: $(& $g 'stance'). Mood: $(& $g 'mood'). Needs: $(& $g 'needs'). Lives at the stranger's base: $(& $g 'resident').
SITUATION: $(& $g 'situation')
STORY: $(& $g 'story')
REMEMBERS ABOUT THE STRANGER: $(& $g 'memory')
Recent talk with the stranger: $(& $g 'history')
"@
}

$initiateRules = @"
You decide whether one survivor in the 1993 Knox County zombie outbreak says something UNPROMPTED to a stranger
standing nearby, and what. Most of the time people stay quiet and watch; speak only if they have a real reason:
they need something badly (food, water, medicine), the stranger is too close or too well armed, they remember
something the stranger did (gratitude, a grudge, a debt), they recognize a familiar face, they want to warn about
danger, or they are a resident of the stranger's base with something on their mind (shortages, complaints, news).
Rules: one short spoken line, under 25 words, plain speech, no quotes, no stage directions. Never promise to join,
give items, or reveal their camp. If they would say nothing, answer with a single dash: -
"@

$banterRules = @"
Write a short exchange two survivors of the same group have between themselves during the 1993 Knox County zombie
outbreak, overheard by a stranger standing nearby. They talk like real people: their day, worries, the dead, food,
people they lost, each other, and maybe the stranger (if the stranger is close they keep it low or careful).
Keep each consistent with their story, memories, mood and needs. Residents of the stranger's base may complain
about shortages, other residents, or the stranger's decisions. 2 to 4 lines total, each under 22 words, alternating,
in exactly this format and nothing else:
A: <line>
B: <line>
"@


$radioRules = @"
Write what a stranger listening on a walkie-talkie overhears from another survivor group during the 1993 Knox County
zombie outbreak: two of them talking on their channel, or one calling their people. Base it ONLY on the facts given:
who they are, what they are doing and where, what they are short of, their morale, and rumors they have heard.
Radio style: clipped, call signs or first names, "over", static gaps written as "--". No real company names, no
famous people, no rescue or cure that is not in the facts. They do not know anyone is listening.
1 to 3 lines, each under 20 words, one per line, nothing else.
"@


$haggleRules = @"
You play one survivor bargaining with a stranger during the 1993 Knox County zombie outbreak. You only trade items
from YOUR ITEMS (T1, T2...) for items from THE STRANGER'S ITEMS (Y1, Y2...). Value things like a real survivor:
what you are short of is worth far more (starving: food beats everything; hurt: medicine), ammo and medicine are
precious, junk is worthless. Bargain in character: ask high, counter, give a little ground, hold firm, or refuse.
Trust and fear matter: you give friends a fairer deal; if you fear the stranger you give in more easily; if you are
stronger you push harder. Never trade the weapon in your hands (it is not in your list). Never invent items.
Answer in exactly this format and nothing else:
SAY: <your spoken line, under 30 words>
GIVE: <your item codes on offer, e.g. T2 T3, or ->
TAKE: <their item codes you want, e.g. Y1, or ->
STATUS: <offer | refuse>
"@


$noteRules = @"
Write something a survivor group left behind during the 1993 Knox County zombie outbreak. Plain handwriting voice,
no quotes, no stage directions, never mention games or AI. Base it ONLY on the facts given. Kinds:
- sign: a painted territory sign. 2 to 7 words, ALL CAPS, naming the group or the place as theirs, a warning.
- warn: a note to the stranger who has been hanging around or hurt them: get out, we see you. 1-3 sentences.
- plea: a scared note to the stranger asking to be left alone, because of what the stranger did. 1-3 sentences.
- friendly: a warm note to the stranger because of what the stranger did for them. Use the stranger's name only if
  the facts say the stranger told it to them. 1-3 sentences.
- group: a note to their OWN people about where they went or where to meet. If you mention a place, use EXACTLY the
  direction and distance given (e.g. "northeast, about half a mile"). 1-3 sentences, may be signed with a first name.
- base: a note left at the stranger's base while they were out, from someone who knows them (see facts). 1-3 sentences.
Answer with the text only.
"@

$catalogPath = Join-Path $LuaDir "alifeai_intents.txt"
$catalogStamp = $null
$catalogText = ""
$catalogIds = @{}
function Load-Catalog {
  if (-not (Test-Path $catalogPath)) { return }
  $st = (Get-Item $catalogPath).LastWriteTimeUtc
  if ($st -eq $script:catalogStamp) { return }
  $lines = [IO.File]::ReadAllLines($catalogPath, $utf8)
  $script:catalogText = ($lines -join "`n")
  $script:catalogIds = @{}
  foreach ($l in $lines) { $i = $l.IndexOf(":"); if ($i -gt 0) { $script:catalogIds[$l.Substring(0, $i).Trim()] = $true } }
  $script:catalogStamp = $st
  Write-Host ("Loaded {0} things NPCs can understand." -f $script:catalogIds.Count)
}

function Understand($req) {
  Load-Catalog
  $who = if ($req.name) { $req.name } else { "an unnamed survivor" }
  $user = @"
The survivor: $who. Group: $($req.faction). Role: $($req.role) ($($req.register), $($req.temperament)). Sex: $($req.sex).
Voice: $($req.voice). Attitude to the stranger: $($req.stance). Mood: $($req.mood). Day $($req.day), hour $($req.hour).
Bond with the stranger: $($req.bond)
SITUATION: $($req.situation)
YOUR STORY (the truth about you; answer personal questions from it, consistent every time; you may lie or dodge to a
stranger if your story says you lie easily or the truth is dangerous, and you may refuse to answer at all): $($req.story)
WHAT YOU REMEMBER ABOUT THE STRANGER (things they did, you saw, your people told you, or word going around; bring it up
when it matters, hold grudges, owe them, be wary): $($req.memory)
Recent talk: $($req.history)
The stranger says: $($req.player)
$(if ($req.force -eq "none") { "This is a personal question about you: choose NONE and answer it in character from YOUR STORY." })$(if ($req.lang -and $req.lang -ne "en") { "The stranger may speak any language: judge the meaning. Keep INTENT / SAY / NOTE labels and intent IDs in English; write the SAY text " + $(if ($req.lang -eq "auto") { "in the stranger's language." } else { "in " + $req.langName + "." }) })
"@
  $body = @{ model = $Model; stream = $false; think = $false; keep_alive = "30m";
    options = @{ num_predict = 100; temperature = 0.3; num_ctx = $script:NumCtx };
    messages = @(@{ role = "system"; content = ($understandRules + "`n" + $catalogText) }, @{ role = "user"; content = $user }) } | ConvertTo-Json -Depth 6
  $rc = LLM $body 20
  $out = [string]$rc
  $intent = "NONE"; $say = ""
  $m = [regex]::Match($out, '(?im)^\s*INTENT\s*:\s*([A-Z_]+)')
  if ($m.Success) { $intent = $m.Groups[1].Value.ToUpper() }
  $m2 = [regex]::Match($out, '(?ims)^\s*SAY\s*:\s*(.+)$')
  if ($m2.Success) { $say = Clean (($m2.Groups[1].Value -split "`n")[0]) }
  $note = ""
  $m3 = [regex]::Match($out, '(?im)^\s*NOTE\s*:\s*(.+)$')
  if ($m3.Success) { $note = Clean $m3.Groups[1].Value; if ($note -eq "-") { $note = "" } }
  if ($intent -ne "NONE" -and -not $catalogIds.ContainsKey($intent)) { $intent = "NONE" }
  if ($req.force -eq "none") { $intent = "NONE" }
  if ($say -eq "-") { $say = "" }
  return @($intent, $say, $note)
}

function Now-Ms { [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }

function Clean([string]$t) {
  if (-not $t) { return "" }
  $t = $t -replace '[‘’]', "'" -replace '[“”]', '' -replace '[–—]', '-' -replace '…', '...'
  $t = $t -replace '\*[^*]*\*', '' -replace '\([^)]*\)', ''
  # 0.5.1: keep letters of every language (accents, Cyrillic, CJK); drop control characters and emoji only
  $t = $t -replace '[\p{C}]', '' -replace '"', '' -replace '\s+', ' '
  $t = $t.Trim()
  if ($t.Length -gt 220) { $t = $t.Substring(0, 220) }
  return $t
}

function Ask($req) {
  $who = if ($req.name) { $req.name } else { "an unnamed survivor" }
  $user = @"
You are $who. Group: $($req.faction). Role: $($req.role) ($($req.register), $($req.temperament)). Sex: $($req.sex).
Voice: $($req.voice). Attitude to the stranger: $($req.stance). Mood: $($req.mood). Day $($req.day) of the outbreak, hour $($req.hour).
Your bond with them: $($req.bond). romance_ok: $($req.romance_ok)
SITUATION: $($req.situation)
YOUR STORY (keep consistent with it, never contradict it): $($req.story)
WHAT YOU REMEMBER ABOUT THE STRANGER (things they did, you saw, your people told you, or word going around; bring it up
when it matters, hold grudges, owe them, be wary): $($req.memory)
Recent talk: $($req.history)
The stranger says: $($req.player)
What they meant (game): $($req.intent). reason: $($req.reason)
GIST: $($req.gist)
$(if ($req.lang -and $req.lang -ne "en" -and $req.lang -ne "auto") { "LANGUAGE: reply in the language of the stranger's line; if you can't tell, speak " + $req.langName + "." } else { "LANGUAGE: reply in the same language the stranger used (English if unsure)." })
Your line:
"@
  $body = @{ model = $Model; stream = $false; think = $false; keep_alive = "30m";
    options = @{ num_predict = 60; temperature = 0.8; num_ctx = $script:NumCtx };
    messages = @(@{ role = "system"; content = $system }, @{ role = "user"; content = $user }) } | ConvertTo-Json -Depth 6
  $rc = LLM $body $script:AskTimeout
  return Clean $rc
}

function Write-Atomic($path, [string]$text) {
  $tmp = "$path.$PID.tmp"
  try { [IO.File]::WriteAllText($tmp, $text, $utf8); Move-Item -LiteralPath $tmp -Destination $path -Force -ErrorAction Stop }
  catch { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
}

if (-not (Test-Path $LuaDir)) { Write-Host "Can't find $LuaDir - is Zomboid installed for this user?"; Read-Host; exit 1 }
if ($script:Cloud) { $Model = $script:Cloud.model; Write-Host ("A-Life AI bridge | CLOUD " + $script:Cloud.model + " at " + $script:Cloud.url + " | " + $LuaDir) } else { Write-Host "A-Life AI bridge | model $Model | $LuaDir" }
# 0.8.11.2: warm-up waits warmup= seconds (model.txt, default 180: a big model's first load is slow). A failure says
# which: Ollama not running (refused) or Ollama up but the model too slow to load (timeout). A model that won't load
# falls back to fallback= (default gemma3:4b, if downloaded) and tells the game (alifeai_model_fallback.txt).
function Ollama-Why($err, [string]$m) {
  $msg = [string]$err.Exception.Message
  $up = $false; try { $null = Invoke-RestMethod "$Ollama/api/tags" -TimeoutSec 3; $up = $true } catch {}
  if (-not $up) { return "Ollama is not running at $Ollama ($msg). Start Ollama (or Restart AI helper.cmd)." }
  if ($msg -match "(?i)timed? ?out") {
    return ("Ollama is running, but model " + $m + " did not answer in " + $script:AskTimeout + " s: still loading, or too big for your video memory " +
            "(run 'ollama ps' - a CPU/GPU split means it spills to the CPU). Real error: " + $msg)
  }
  return ("Ollama is running but answered an error for model " + $m + ": " + $msg)
}
function Warm([string]$m) {
  $script:AskTimeout = $script:WarmupSec
  $Model = $m
  try { $null = Ask @{ name = "Test"; player = "hello"; gist = "Hey."; reason = "answered"; stance = "neutral" }; return $null }
  catch { return (Ollama-Why $_ $m) }
  finally { $script:AskTimeout = 20 }
}
Write-Host ("Warming up the model " + $Model + " (num_ctx " + $script:NumCtx + ", waiting up to " + $script:WarmupSec + " s)...")
if ($script:Cloud) { Write-Host "Cloud AI set up (no test call, to save credits). Leave this window open while you play." }
else {
  try { Remove-Item -LiteralPath (Join-Path $LuaDir "alifeai_model_fallback.txt") -Force -ErrorAction SilentlyContinue } catch {}
  $why = Warm $Model
  if ($why -ne $null) {
    Write-Host ("Model " + $Model + " failed to warm up: " + $why)
    $fb = $script:FallbackModel
    $have = $false
    try { $tags = Invoke-RestMethod "$Ollama/api/tags" -TimeoutSec 3; $names = @($tags.models | ForEach-Object { $_.name }); $have = ($names -contains $fb) -or ($names -contains ($fb + ":latest")) } catch {}
    if ($fb -and $fb -ne $Model -and $have -and $why -notmatch "not running") {
      Write-Host ("Falling back to " + $fb + "...")
      $why2 = Warm $fb
      if ($why2 -eq $null) {
        Write-Atomic (Join-Path $LuaDir "alifeai_model_fallback.txt") ("from=" + $Model + "`nto=" + $fb + "`nwhy=" + ($why -replace "[`r`n]", " ") + "`nat=" + (Now-Ms) + "`n")
        $Model = $fb
        Write-Host ("Model ready (fallback " + $fb + "). Leave this window open while you play.")
      } else { Write-Host ("Fallback " + $fb + " failed too: " + $why2); Write-Host "Start Ollama, then run this again."; exit 1 }
    } else { Write-Host "Start Ollama, then run this again."; exit 1 }
  } else { Write-Host "Model ready. Leave this window open while you play." }
}

$lastBeat = 0
while ($true) {
  $t = Now-Ms
  if ($t - $lastBeat -gt 2000) { Write-Atomic (Join-Path $LuaDir "alifeai_alive.txt") "$t`n"; $lastBeat = $t }

  # who goes first: you talking to someone (priority 1) before background talk and radio (6-9);
  # background requests older than 6 s are dropped - the moment has passed
  $queue = @()
  foreach ($f in Get-ChildItem -LiteralPath $LuaDir -Filter "alifeai_req_*.txt" -ErrorAction SilentlyContinue) {
    $prio = 5
    try { $head = [IO.File]::ReadAllLines($f.FullName, $utf8) | Select-Object -First 3
          foreach ($h in $head) { if ($h -match '^priority=(\d+)') { $prio = [int]$Matches[1] } } } catch {}
    if ($prio -ge 6 -and ((Get-Date) - $f.LastWriteTime).TotalSeconds -gt 6) {
      try { Remove-Item -LiteralPath $f.FullName -Force } catch {}
      continue
    }
    $queue += [pscustomobject]@{ File = $f; Prio = $prio; At = $f.LastWriteTime }
  }
  $queue = $queue | Sort-Object Prio, At
  $didOne = $false
  foreach ($q in $queue) {
    $f = $q.File
    if ($didOne -and $q.Prio -ge 6) { break }       # after any answer, look again: someone may have spoken meanwhile
    try {
      $lines = [IO.File]::ReadAllLines($f.FullName, $utf8)
      if (-not ($lines -contains "end=1")) {
        if (((Get-Date) - $f.LastWriteTime).TotalSeconds -gt 10) { Remove-Item -LiteralPath $f.FullName -Force }
        continue
      }
      $req = @{}
      foreach ($l in $lines) { $i = $l.IndexOf("="); if ($i -gt 0) { $req[$l.Substring(0, $i)] = $l.Substring($i + 1) } }
      Remove-Item -LiteralPath $f.FullName -Force
      $didOne = $true
      if ($req.mode -eq "note") {
        if ($req.kind -eq "sign") { $user = "Kind: sign. The group's name is $($req.group). Write only the words painted on the sign." }
        else { $user = "Kind: $($req.kind). Group: $($req.group) ($($req.squad)). What they are doing: $($req.task). Direction to them from here: $($req.dir), $($req.far). Day $($req.day). Their base name if relevant: $($req.base). What they know about the stranger: $($req.known)" }
        $out = Chat $noteRules $user 90 0.9
        $t = Clean (($out -split "`n" | Where-Object { $_.Trim() }) -join " ")
        if ($req.kind -eq "sign") {
          $t = $t.ToUpper() -replace '\b(KIND|GROUP|WHAT THEY ARE DOING|DIRECTION|DAY|THEIR BASE|SIGN)\s*:.*$', ''
          $t = ($t -replace '[^A-Z0-9 \.\!\'',-]', ' ' -replace '\s+', ' ').Trim(' ', ',', '-')
          $w = $t -split ' '; if ($w.Count -gt 8) { $t = ($w[0..7] -join ' ') }
          if ($t.Length -lt 4) { $t = "" }
        }
        Write-Atomic (Join-Path $LuaDir ("alifeai_resp_" + $req.id + ".txt")) ("id=" + $req.id + "`ntext=" + $t + "`ndone=1`n")
        Write-Host ("  [{0}] {1}" -f $req.kind, $t)
        continue
      }
      if ($req.mode -eq "haggle") {
        $user = @"
You: $($req.name) ($($req.temperament)). Attitude to the stranger: $($req.stance). Needs: $($req.needs).
SITUATION: $($req.situation)
STORY: $($req.story)
REMEMBERS ABOUT THE STRANGER: $($req.memory)
YOUR ITEMS: $($req.theirs)
THE STRANGER'S ITEMS: $($req.yours)
Offer on the table: $($req.offer)
Recent talk: $($req.history)
The stranger says: $($req.player)
"@
        $out = Chat $haggleRules $user 120 0.6
        $say = ""; $give = ""; $take = ""; $status = "offer"
        $m = [regex]::Match($out, '(?im)^\s*SAY\s*:\s*(.+)$'); if ($m.Success) { $say = Clean $m.Groups[1].Value }
        $m = [regex]::Match($out, '(?im)^\s*GIVE\s*:\s*(.+)$'); if ($m.Success) { $give = $m.Groups[1].Value.Trim() }
        $m = [regex]::Match($out, '(?im)^\s*TAKE\s*:\s*(.+)$'); if ($m.Success) { $take = $m.Groups[1].Value.Trim() }
        $m = [regex]::Match($out, '(?im)^\s*STATUS\s*:\s*(\w+)'); if ($m.Success) { $status = $m.Groups[1].Value.ToLower() }
        Write-Atomic (Join-Path $LuaDir ("alifeai_resp_" + $req.id + ".txt")) ("id=" + $req.id + "`ntext=" + $say + "`ngive=" + $give + "`ntake=" + $take + "`nstatus=" + $status + "`ndone=1`n")
        Write-Host ("  [haggle] {0}: {1}  (gives {2} for {3}, {4})" -f $req.name, $say, $give, $take, $status)
        continue
      }
      if ($req.mode -eq "radio") {
        $user = "Group: $($req.group) ($($req.squad)), $($req.members) people. Doing: $($req.task). Supplies: $($req.needs). Morale (0-1): $($req.morale). Day $($req.day). Rumors they have heard: $($req.heard)"
        $out = Chat $radioRules $user 110 0.9
        $resp = "id=" + $req.id + "`n"
        foreach ($l in ($out -split "`n")) { $c = Clean $l; if ($c.Length -gt 1) { $resp += "line=" + $c + "`n"; Write-Host ("  [radio] {0}" -f $c) } }
        Write-Atomic (Join-Path $LuaDir ("alifeai_resp_" + $req.id + ".txt")) ($resp + "done=1`n")
        continue
      }
      if ($req.mode -eq "initiate") {
        $ns = ""
        if (-not $req.story -and $req.seed) { try { $ns = Make-Story $req; $req.story = $ns } catch {} }
        $out = Chat $initiateRules ("Day " + $req.day + ". The stranger is " + $req.distance + " tiles away.`n" + (Person $req "")) 50 0.8
        $line = Clean (($out -split "`n")[0])
        if ($line -match '^\s*-?\s*$') { $line = "-" }
        Write-Atomic (Join-Path $LuaDir ("alifeai_resp_" + $req.id + ".txt")) ("id=" + $req.id + "`ntext=" + $line + $(if ($ns) { "`nstory=" + $ns } else { "" }) + "`ndone=1`n")
        if ($line -ne "-") { Write-Host ("  {0} (unprompted): {1}" -f $req.name, $line) }
        continue
      }
      if ($req.mode -eq "banter") {
        $user = "Day " + $req.day + ". The stranger is " + $req.stranger_distance + " tiles away.`nA: " + (Person $req "a_") + "`nB: " + (Person $req "b_")
        $out = Chat $banterRules $user 160 0.9
        $resp = "id=" + $req.id + "`n"
        foreach ($l in ($out -split "`n")) {
          $m = [regex]::Match($l, '^\s*([AB])\s*:\s*(.+)$')
          if ($m.Success) { $resp += "line=" + $m.Groups[1].Value.ToLower() + "|" + (Clean $m.Groups[2].Value) + "`n"; Write-Host ("  {0}: {1}" -f $(if ($m.Groups[1].Value -eq "A") { $req.a_name } else { $req.b_name }), (Clean $m.Groups[2].Value)) }
        }
        Write-Atomic (Join-Path $LuaDir ("alifeai_resp_" + $req.id + ".txt")) ($resp + "done=1`n")
        continue
      }
      $sw = [Diagnostics.Stopwatch]::StartNew()
      $newStory = ""
      if (-not $req.story -and $req.seed) {
        try { $newStory = Make-Story $req; if ($newStory) { $req.story = $newStory; Write-Host ("  new story for {0}: {1}" -f $req.name, $newStory) } } catch { Write-Host "  story failed: $($_.Exception.Message)" }
      }
      $storyOut = $(if ($newStory) { "`nstory=" + $newStory } else { "" })
      if ($req.mode -eq "understand") {
        $u = Understand $req
        $sw.Stop()
        Write-Atomic (Join-Path $LuaDir ("alifeai_resp_" + $req.id + ".txt")) ("id=" + $req.id + "`nintent=" + $u[0] + "`ntext=" + $u[1] + "`nnote=" + $u[2] + $storyOut + "`n")
        Write-Host ("[{0} ms] heard '{1}' as {2}{3}" -f $sw.ElapsedMilliseconds, $req.player, $u[0], $(if ($u[1]) { " -> " + $u[1] } else { "" }))
        continue
      }
      $line = Ask $req
      $sw.Stop()
      if ($line) {
        Write-Atomic (Join-Path $LuaDir ("alifeai_resp_" + $req.id + ".txt")) ("id=" + $req.id + "`ntext=" + $line + $storyOut + "`n")
        Write-Host ("[{0} ms] {1}: {2}" -f $sw.ElapsedMilliseconds, ($(if ($req.name) { $req.name } else { "NPC" })), $line)
      }
    } catch { Write-Host "request failed: $($_.Exception.Message)" }
  }
  # sweep answered (blanked) or stale responses
  foreach ($f in Get-ChildItem -LiteralPath $LuaDir -Filter "alifeai_resp_*.txt" -ErrorAction SilentlyContinue) {
    try { if ($f.Length -eq 0 -or ((Get-Date) - $f.LastWriteTime).TotalSeconds -gt 30) { Remove-Item -LiteralPath $f.FullName -Force } } catch {}
  }
  Start-Sleep -Milliseconds 100
}
