# A-Life Chat Plus - Whisper push-to-talk (accurate, offline, free speech).
# Hold the button, speak, let go: Whisper (whisper.cpp, runs on your CPU) turns it into text and the game
# says it to the nearest NPC, exactly like typing. First run downloads whisper.cpp + an English model (~200 MB).
param(
  [int]$Key = 0,                     # 0 = read ptt_key.txt (next to this script). Or a key code: 0x05/0x06 mouse side buttons, 0x14 Caps Lock
  [string]$Model = "small.en",       # CPU model: small.en (accurate) / base.en (faster, sloppier)
  [string]$GpuModel = "large-v3-turbo-q5_0",   # GPU model: big, accurate, fast on an RTX card
  [switch]$Cpu,                      # force CPU only
  [string]$LuaDir = (Join-Path $env:USERPROFILE "Zomboid\Lua"),
  [string]$WDir = (Join-Path $env:USERPROFILE "Zomboid\alifeai_whisper")
)
$ErrorActionPreference = "Stop"
# 0.5.1: the game's NPC language (Zomboid\Lua\alifeai_language.txt, written at game start). Not English: use the
# multilingual model (small instead of small.en) and tell Whisper the language.
$Lang = "en"
try { $lf = Join-Path $LuaDir "alifeai_language.txt"; if (Test-Path $lf) { $v = (Get-Content $lf -TotalCount 1).Trim().ToLower(); if ($v -match '^[a-z]{2}$') { $Lang = $v } } } catch {}
if ($Lang -ne "en" -and $Model -match '\.en$') { $Model = $Model -replace '\.en$', '' }
$script:single = New-Object System.Threading.Mutex($false, "Local\ALifeChatPlusWhisper")
if (-not $script:single.WaitOne(0)) { Write-Host "Voice is already running. You can close this window."; Start-Sleep 6; exit 0 }
$utf8 = New-Object System.Text.UTF8Encoding($false)
Add-Type @"
using System; using System.Text; using System.Runtime.InteropServices;
public static class W {
  [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vKey);
  [DllImport("winmm.dll", CharSet = CharSet.Auto)] public static extern int mciSendString(string cmd, StringBuilder ret, int len, IntPtr cb);
  // Windows' recorder often ignores the requested format (gives 8-bit 11 kHz). Whisper needs 16-bit 16 kHz mono.
  public static string To16k(string inPath, string outPath) {
    byte[] b = System.IO.File.ReadAllBytes(inPath);
    int ch = 1, rate = 11025, bits = 8, dataOff = -1, dataLen = 0, i = 12;
    while (i + 8 <= b.Length) {
      string id = Encoding.ASCII.GetString(b, i, 4); int len = BitConverter.ToInt32(b, i + 4);
      if (id == "fmt ") { ch = BitConverter.ToInt16(b, i + 10); rate = BitConverter.ToInt32(b, i + 12); bits = BitConverter.ToInt16(b, i + 22); }
      if (id == "data") { dataOff = i + 8; dataLen = Math.Min(len, b.Length - dataOff); break; }
      i += 8 + len + (len & 1);
    }
    if (dataOff < 0) return "no data chunk";
    int bps = bits / 8, frames = dataLen / (bps * ch);
    double[] mono = new double[frames];
    for (int f = 0; f < frames; f++) {
      double sum = 0;
      for (int c = 0; c < ch; c++) {
        int o = dataOff + (f * ch + c) * bps;
        sum += bits == 8 ? (b[o] - 128) / 128.0 : BitConverter.ToInt16(b, o) / 32768.0;
      }
      mono[f] = sum / ch;
    }
    int outFrames = (int)((long)frames * 16000 / rate);
    byte[] o2 = new byte[44 + outFrames * 2];
    Encoding.ASCII.GetBytes("RIFF").CopyTo(o2, 0); BitConverter.GetBytes(36 + outFrames * 2).CopyTo(o2, 4);
    Encoding.ASCII.GetBytes("WAVEfmt ").CopyTo(o2, 8); BitConverter.GetBytes(16).CopyTo(o2, 16);
    BitConverter.GetBytes((short)1).CopyTo(o2, 20); BitConverter.GetBytes((short)1).CopyTo(o2, 22);
    BitConverter.GetBytes(16000).CopyTo(o2, 24); BitConverter.GetBytes(32000).CopyTo(o2, 28);
    BitConverter.GetBytes((short)2).CopyTo(o2, 32); BitConverter.GetBytes((short)16).CopyTo(o2, 34);
    Encoding.ASCII.GetBytes("data").CopyTo(o2, 36); BitConverter.GetBytes(outFrames * 2).CopyTo(o2, 40);
    for (int k = 0; k < outFrames; k++) {
      double pos = (double)k * rate / 16000; int a = (int)pos; double t = pos - a;
      double v = a + 1 < frames ? mono[a] * (1 - t) + mono[a + 1] * t : mono[Math.Min(a, frames - 1)];
      short sv = (short)Math.Max(-32768, Math.Min(32767, v * 32767));
      BitConverter.GetBytes(sv).CopyTo(o2, 44 + k * 2);
    }
    System.IO.File.WriteAllBytes(outPath, o2);
    return "ok " + rate + "Hz " + bits + "bit " + ch + "ch";
  }
}
"@
function Mci([string]$c) { [void][W]::mciSendString($c, $null, 0, [IntPtr]::Zero) }

# push-to-talk key: one word in ptt_key.txt (CapsLock, Mouse4, Mouse5, MiddleMouse, RightCtrl, RightAlt, ScrollLock, Pause, Backtick, F1..F12, or a letter/number)
$KeyNames = @{ capslock=0x14; mouse4=0x05; mouse5=0x06; middlemouse=0x04; rightctrl=0xA3; rightalt=0xA5; leftalt=0xA4; scrolllock=0x91; pause=0x13; backtick=0xC0; tab=0x09; insert=0x2D; home=0x24; end=0x23; pageup=0x21; pagedown=0x22 }
for ($i = 1; $i -le 12; $i++) { $KeyNames["f$i"] = 0x6F + $i }
$KeyLabel = "Caps Lock"
if ($Key -eq 0) {
  $name = "capslock"
  $kf = Join-Path $PSScriptRoot "ptt_key.txt"
  if (Test-Path $kf) { $name = ((Get-Content $kf -TotalCount 1) -replace "[^A-Za-z0-9]", "").ToLower() }
  # 0.8.12: the game's AI tab (Zomboid\Lua\alifeai_setup.txt, ptt=) wins over ptt_key.txt and survives mod updates
  $sf = Join-Path $env:USERPROFILE "Zomboid\Lua\alifeai_setup.txt"
  if (Test-Path -LiteralPath $sf) {
    foreach ($l in (Get-Content -LiteralPath $sf -Encoding UTF8)) { if ($l -match '^\s*ptt\s*=\s*(\S+)') { $name = ($Matches[1] -replace "[^A-Za-z0-9]", "").ToLower() } }
  }
  if ($KeyNames.ContainsKey($name)) { $Key = $KeyNames[$name]; $KeyLabel = $name }
  elseif ($name.Length -eq 1) { $Key = [int][char]$name.ToUpper(); $KeyLabel = $name.ToUpper() }
  else { $Key = 0x14; Write-Host "ptt_key.txt: unknown key '$name', using Caps Lock" }
}
function Down { ([W]::GetAsyncKeyState($Key) -band 0x8000) -ne 0 }
function Now-Ms { [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
function Write-Atomic($path, [string]$text) {
  $tmp = "$path.$PID.tmp"
  try { [IO.File]::WriteAllText($tmp, $text, $utf8); Move-Item -LiteralPath $tmp -Destination $path -Force -ErrorAction Stop }
  catch { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
}

New-Item -ItemType Directory -Force -Path $WDir | Out-Null
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
function Find-Exe {
  $cli = Get-ChildItem -Path $WDir -Recurse -Filter "whisper-cli.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($cli -ne $null) { return $cli }
  return (Get-ChildItem -Path $WDir -Recurse -Filter "main.exe" -ErrorAction SilentlyContinue | Select-Object -First 1)
}
$exe = Find-Exe
if ($exe -eq $null) {
  Write-Host "Downloading whisper.cpp (one time)..."
  $zip = Join-Path $WDir "whisper.zip"
  # ask GitHub which Windows build the recent releases actually ship (the newest one is sometimes empty)
  $rels = Invoke-RestMethod -Uri "https://api.github.com/repos/ggml-org/whisper.cpp/releases?per_page=15" -Headers @{ "User-Agent" = "alifeai" }
  $pick = $null; $tag = ""
  foreach ($rel in $rels) {
    $assets = @($rel.assets | Where-Object { $_.name -like "*.zip" -and $_.name -match "x64" -and $_.name -notmatch "cublas|cuda|vulkan|openvino|arm|xcframework" })
    $pick = ($assets | Where-Object { $_.name -match "^whisper-bin-x64" } | Select-Object -First 1)
    if ($pick -eq $null) { $pick = ($assets | Where-Object { $_.name -match "blas" } | Select-Object -First 1) }
    if ($pick -eq $null) { $pick = $assets | Select-Object -First 1 }
    if ($pick -ne $null) { $tag = $rel.tag_name; break }
  }
  if ($pick -eq $null) { Write-Host "No Windows x64 build in the last 15 releases. Send Claude this list:"; $rels | ForEach-Object { Write-Host ($_.tag_name + ": " + (($_.assets | ForEach-Object { $_.name }) -join ", ")) }; Read-Host; exit 1 }
  Write-Host ("  " + $tag + ": " + $pick.name)
  Invoke-WebRequest -Uri $pick.browser_download_url -OutFile $zip -UseBasicParsing
  Expand-Archive -Path $zip -DestinationPath $WDir -Force
  Remove-Item $zip
  $exe = Find-Exe
  if ($exe -eq $null) { Write-Host "whisper.cpp downloaded but no whisper-cli.exe found in $WDir"; Read-Host; exit 1 }
}
$modelFile = Join-Path $WDir ("ggml-" + $Model + ".bin")
if (-not (Test-Path $modelFile)) {
  Write-Host "Downloading the $Model speech model (one time)..."
  Invoke-WebRequest -Uri ("https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-" + $Model + ".bin") -OutFile $modelFile -UseBasicParsing
}
$ErrorActionPreference = "Continue"
$wav = Join-Path $WDir "ptt.wav"
$wav16 = Join-Path $WDir "ptt16.wav"

# ---- GPU (CUDA) build: much faster, lets us run a far more accurate model ----
$gpuExe = $null
if (-not $Cpu) {
  $gdir = Join-Path $WDir "gpu"
  $gpuExe = Get-ChildItem -Path $gdir -Recurse -Filter "whisper-server.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($gpuExe -eq $null) {
    try {
      Write-Host "Downloading the GPU (CUDA) build of whisper.cpp (one time)..."
      $rels = Invoke-RestMethod -Uri "https://api.github.com/repos/ggml-org/whisper.cpp/releases?per_page=15" -Headers @{ "User-Agent" = "alifeai" }
      $gpick = $null
      foreach ($rel in $rels) {
        $c = @($rel.assets | Where-Object { $_.name -match "cublas" -and $_.name -match "x64" -and $_.name -like "*.zip" } |
          Sort-Object { [version](([regex]::Match($_.name, "(\d+\.\d+)")).Groups[1].Value) } -Descending)
        if ($c.Count -gt 0) { $gpick = $c[0]; Write-Host ("  " + $rel.tag_name + ": " + $gpick.name); break }
      }
      if ($gpick -ne $null) {
        New-Item -ItemType Directory -Force -Path $gdir | Out-Null
        $gz = Join-Path $gdir "gpu.zip"
        Invoke-WebRequest -Uri $gpick.browser_download_url -OutFile $gz -UseBasicParsing
        Expand-Archive -Path $gz -DestinationPath $gdir -Force; Remove-Item $gz
        $gpuExe = Get-ChildItem -Path $gdir -Recurse -Filter "whisper-server.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
      } else { Write-Host "  no CUDA build found; staying on CPU" }
    } catch { Write-Host "  GPU download failed ($($_.Exception.Message)); staying on CPU" }
  }
  if ($gpuExe -ne $null) {
    $gm = Join-Path $WDir ("ggml-" + $GpuModel + ".bin")
    if (-not (Test-Path $gm)) {
      try {
        Write-Host "Downloading the GPU speech model $GpuModel (one time, ~550 MB)..."
        Invoke-WebRequest -Uri ("https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-" + $GpuModel + ".bin") -OutFile $gm -UseBasicParsing
      } catch { Write-Host "  model download failed; staying on CPU"; $gpuExe = $null }
    }
    if ($gpuExe -ne $null) { $modelFile = $gm; $Model = $GpuModel }
  }
}

# Keep the model loaded in whisper-server (no 1-2 s reload per line). Falls back to whisper-cli if it won't start.
$server = $null; $port = 8178; $prompt = "Rough survivors talking during a zombie outbreak. They swear a lot: ass, shit, damn, hell, fuck."
Add-Type -AssemblyName System.Net.Http
$http = New-Object System.Net.Http.HttpClient
$http.Timeout = [TimeSpan]::FromSeconds(30)
$serverExe = if ($gpuExe -ne $null) { $gpuExe.FullName } else { Join-Path $exe.DirectoryName "whisper-server.exe" }
if (Test-Path $serverExe) {
  Get-Process -Name "whisper-server" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  $server = Start-Process -FilePath $serverExe -ArgumentList @("-m", "`"$modelFile`"", "-t", "8", "-l", $Lang, "--host", "127.0.0.1", "--port", "$port") -WindowStyle Hidden -PassThru
  $ready = $false
  for ($i = 0; $i -lt 60 -and -not $ready; $i++) {
    Start-Sleep -Milliseconds 500
    try { $null = $http.GetAsync("http://127.0.0.1:$port/").Result; $ready = $true } catch {}
  }
  if ($ready -and -not $server.HasExited) {
    Write-Host ("Model loaded and kept in memory (fast mode, " + $(if ($gpuExe -ne $null) { "GPU, $GpuModel" } else { "CPU, $Model" }) + ").")
  } else {
    try { $server.Kill() } catch {}; $server = $null
    if ($gpuExe -ne $null) {
      Write-Host "GPU mode didn't start (driver/CUDA mismatch?). Falling back to CPU."
      $gpuExe = $null; $Model = $(if ($Lang -eq "en") { "small.en" } else { "small" }); $modelFile = Join-Path $WDir ("ggml-" + $Model + ".bin")
      if (-not (Test-Path $modelFile)) { Invoke-WebRequest -Uri ("https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-" + $Model + ".bin") -OutFile $modelFile -UseBasicParsing }
      $server = Start-Process -FilePath (Join-Path $exe.DirectoryName "whisper-server.exe") -ArgumentList @("-m", "`"$modelFile`"", "-t", "8", "-l", $Lang, "--host", "127.0.0.1", "--port", "$port") -WindowStyle Hidden -PassThru
      for ($i = 0; $i -lt 60; $i++) { Start-Sleep -Milliseconds 500; try { $null = $http.GetAsync("http://127.0.0.1:$port/").Result; break } catch {} }
      Write-Host "CPU fast mode on."
    } else { Write-Host "Fast mode didn't start; using the slower one-shot mode." }
  }
}
function Transcribe([string]$path) {
  if ($server -ne $null -and -not $server.HasExited) {
    try {
      $form = New-Object System.Net.Http.MultipartFormDataContent
      $bytes = New-Object System.Net.Http.ByteArrayContent(,[IO.File]::ReadAllBytes($path))
      $form.Add($bytes, "file", "ptt.wav")
      $form.Add((New-Object System.Net.Http.StringContent("text")), "response_format")
      $form.Add((New-Object System.Net.Http.StringContent($prompt)), "prompt")
      $form.Add((New-Object System.Net.Http.StringContent("0")), "temperature")
      $resp = $http.PostAsync("http://127.0.0.1:$port/inference", $form).Result
      return $resp.Content.ReadAsStringAsync().Result
    } catch { Write-Host "  (fast mode hiccup, retrying slow: $($_.Exception.Message))" }
  }
  return ((& $exe.FullName -m $modelFile -f $path -l $Lang -nt -np -t 8 --prompt $prompt 2>$null) -join "`n")
}
$seq = [int]((Now-Ms) % 1000000)
Write-Host "A-Life voice | $LuaDir"
Write-Host "Hold $KeyLabel, speak, let go. (change it in ptt_key.txt)"

$lastBeat = 0
while ($true) {
  $t = Now-Ms
  if ($t - $lastBeat -gt 2000) { Write-Atomic (Join-Path $LuaDir "alifeai_voice_alive.txt") "$t`n"; $lastBeat = $t }
  if (-not (Down)) { Start-Sleep -Milliseconds 25; continue }
  Mci "close rec"
  Mci "open new type waveaudio alias rec"
  Mci "set rec format tag pcm"
  Mci "set rec channels 1 samplespersec 16000 bytespersec 32000 alignment 2 bitspersample 16"
  Mci "record rec"
  $started = Now-Ms
  while (Down) {
    Start-Sleep -Milliseconds 25
    if ((Now-Ms) - $lastBeat -gt 2000) { $lastBeat = Now-Ms; Write-Atomic (Join-Path $LuaDir "alifeai_voice_alive.txt") "$lastBeat`n" }
  }
  Start-Sleep -Milliseconds 250          # catch the last syllable
  Mci "stop rec"
  if (Test-Path $wav) { Remove-Item $wav -Force -ErrorAction SilentlyContinue }
  Mci ('save rec "' + $wav + '"')
  Mci "close rec"
  $held = (Now-Ms) - $started
  if ($held -lt 1000) {                  # held under 0.75 s (+0.25 s tail we add): a tap or bump, ignore it completely
    continue
  }
  if (-not (Test-Path $wav)) { continue }
  $conv = [W]::To16k($wav, $wav16)
  if (-not $conv.StartsWith("ok")) { Write-Host "  (recording problem: $conv)"; continue }
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $out = (Transcribe $wav16) -split "`n"
  $sw.Stop()
  $text = (($out | Where-Object { $_ -and $_.Trim() -and $_ -notmatch "^\s*(WARNING|whisper_|main:|system_info)" }) -join " ")
  $text = ($text -replace '\[[^\]]*\]', '' -replace '\([^)]*\)', '' -replace '[^\x20-\x7E]', '' -replace '\s+', ' ').Trim()
  if ($text -match '^(?i)\s*(thank you( very much)?|thanks( for watching)?|you|bye|okay|so)[\.!\s]*$' -and $held -lt 1500) { $text = "" }  # Whisper's stock guesses on near-silence
  if ($text.Length -lt 2) { Write-Host "  (didn't catch that)"; continue }
  $seq++
  Write-Atomic (Join-Path $LuaDir "alifeai_say.txt") ("seq=" + $seq + "`ntext=" + $text + "`n")
  Write-Host ("[{0} ms] you: {1}" -f $sw.ElapsedMilliseconds, $text)
}
