# A-Life Chat Plus - voice. Speak to the nearest NPC; your words go through the same path as typing in chat.
#   -Mode ptt   hold the push-to-talk button while you speak (default: mouse side button "back", XButton1)
#   -Mode open  always listening: anything you say is sent (best with a headset mic and a quiet room)
# Uses Windows' built-in offline speech recognition (System.Speech). No install needed.
param(
  [ValidateSet("ptt","open")][string]$Mode = "ptt",
  [int]$Key = 0x14,                 # 0x05 = mouse side "back" button. 0x06 = side "forward". 0x56 = V. 0x14 = Caps Lock
  [double]$MinConfidence = 0.6,
  [switch]$ShowLevel,
  [switch]$Dictation,
  [string]$LuaDir = (Join-Path $env:USERPROFILE "Zomboid\Lua")
)
$ErrorActionPreference = "Continue"
$utf8 = New-Object System.Text.UTF8Encoding($false)
Add-Type -AssemblyName System.Speech
Add-Type @"
using System; using System.Runtime.InteropServices;
public static class KeyState { [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vKey); }
"@
function Down { return ([KeyState]::GetAsyncKeyState($Key) -band 0x8000) -ne 0 }
function Now-Ms { [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
function Write-Atomic($path, [string]$text) {
  $tmp = "$path.$PID.tmp"
  try { [IO.File]::WriteAllText($tmp, $text, $utf8); Move-Item -LiteralPath $tmp -Destination $path -Force -ErrorAction Stop }
  catch { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
}

if (-not (Test-Path $LuaDir)) { Write-Host "Can't find $LuaDir"; Read-Host; exit 1 }
try {
  $engine = New-Object System.Speech.Recognition.SpeechRecognitionEngine
  $phraseFile = Join-Path $LuaDir "alifeai_phrases.txt"
  $usePhrases = (-not $Dictation) -and (Test-Path $phraseFile)
  if ($usePhrases) {
    $phrases = [IO.File]::ReadAllLines($phraseFile) | Where-Object { $_.Trim().Length -gt 1 } | Select-Object -Unique
    $choices = New-Object System.Speech.Recognition.Choices
    $choices.Add([string[]]$phrases)
    $gb = New-Object System.Speech.Recognition.GrammarBuilder
    $gb.Culture = $engine.RecognizerInfo.Culture
    $gb.Append($choices)
    $engine.LoadGrammar((New-Object System.Speech.Recognition.Grammar($gb)))
    Write-Host ("Phrase mode: " + $phrases.Count + " phrases A-Life understands (accurate). Add -Dictation for free speech.")
  } else {
    $engine.LoadGrammar((New-Object System.Speech.Recognition.DictationGrammar))
    Write-Host "Free dictation mode (less accurate). Start the game once so the phrase list gets written."
  }
  $engine.SetInputToDefaultAudioDevice()
} catch {
  Write-Host "Windows speech recognition isn't available: $($_.Exception.Message)"
  Write-Host "Settings > Time & language > Speech: install an English speech pack, and check your default microphone."
  Read-Host; exit 1
}
Write-Host ("Recognizer: " + $engine.RecognizerInfo.Name + " (" + $engine.RecognizerInfo.Culture + ")")
$engine.InitialSilenceTimeout = [TimeSpan]::FromSeconds(3)
$engine.EndSilenceTimeout = [TimeSpan]::FromMilliseconds(600)
$seq = [int]((Now-Ms) % 1000000)
Write-Host "A-Life voice | mode $Mode | $LuaDir"
if ($Mode -eq "ptt") { Write-Host "Hold your push-to-talk button and speak. Release when done." } else { Write-Host "Listening. Just talk." }
Write-Host "Tip: speak clearly, short sentences work best."

function Send([string]$text, [double]$conf) {
  $t = ($text -replace '[^\x20-\x7E]', '' -replace '\s+', ' ').Trim()
  if ($t.Length -lt 2) { return }
  $script:seq++
  Write-Atomic (Join-Path $LuaDir "alifeai_say.txt") ("seq=" + $script:seq + "`ntext=" + $t + "`n")
  Write-Host ("[{0:P0}] you: {1}" -f $conf, $t)
}

$lastBeat = 0
while ($true) {
  $t = Now-Ms
  if ($t - $lastBeat -gt 2000) { Write-Atomic (Join-Path $LuaDir "alifeai_voice_alive.txt") "$t`n"; $lastBeat = $t }
  if ($Mode -eq "ptt") {
    if (-not (Down)) { Start-Sleep -Milliseconds 30; continue }
    $parts = @(); $conf = 1.0
    while (Down) {
      $r = $engine.Recognize([TimeSpan]::FromSeconds(4))
      if ($r -ne $null -and $r.Confidence -ge $MinConfidence) { $parts += $r.Text; $conf = [Math]::Min($conf, $r.Confidence) }
      elseif ($r -ne $null) { Write-Host ("  (too unsure {0:P0}: {1})" -f $r.Confidence, $r.Text) }
      Write-Atomic (Join-Path $LuaDir "alifeai_voice_alive.txt") ("" + (Now-Ms) + "`n")
    }
    if ($parts.Count -gt 0) { Send ($parts -join " ") $conf }
  } else {
    $r = $engine.Recognize([TimeSpan]::FromSeconds(5))
    if ($r -ne $null -and $r.Confidence -ge $MinConfidence) { Send $r.Text $r.Confidence }
    elseif ($r -ne $null) { Write-Host ("  (too unsure {0:P0}: {1})" -f $r.Confidence, $r.Text) }
  }
  if ($ShowLevel) { Write-Host ("  mic level " + $engine.AudioLevel + "  state " + $engine.AudioState) }
}
