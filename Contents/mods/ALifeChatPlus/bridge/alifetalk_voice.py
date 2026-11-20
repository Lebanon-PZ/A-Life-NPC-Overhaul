"""
A-Life Talk 0.5.0 optional voice (the bridge runs fine without any of this installed).

Speech in  (push-to-talk): faster-whisper + sounddevice.
    Trigger 1: the in-game voice key -> the game writes <Zomboid>/Lua/alifetalk_ptt.txt ("down <ms>" / "up <ms>").
    Trigger 2: --ptt-key NAME -> a global hotkey through the optional 'keyboard' package (works while alt-tabbed).
    While held we record the microphone (16 kHz mono), on release we transcribe and push the text to the game
    (push file kind "voice"), which says it through A-Life's own chat path.
Speech out (NPC voices): Piper (piper-tts). One stable voice per NPC from its sex and age, with a small per-NPC
    speed/pitch-feel variation (length_scale). Played by the bridge (winsound on Windows, else sounddevice).
    The game cannot load generated audio at runtime, so volume does not follow distance.
pip install faster-whisper sounddevice numpy piper-tts keyboard      (each is optional; missing ones are reported)
"""
import hashlib
import os
import queue
import tempfile
import threading
import time
import wave

VOICES = {  # Piper voice names (download with: python -m piper.download_voices NAME --download-dir <voices dir>)
    ("f", "young"): ["en_US-amy-medium", "en_US-kristin-medium"],
    ("f", "adult"): ["en_US-lessac-medium", "en_US-hfc_female-medium"],
    ("f", "old"): ["en_US-kathleen-low", "en_US-ljspeech-medium"],
    ("m", "young"): ["en_US-joe-medium", "en_US-bryce-medium"],
    ("m", "adult"): ["en_US-ryan-medium", "en_US-hfc_male-medium", "en_US-mike-medium"],
    ("m", "old"): ["en_US-john-medium", "en_US-norman-medium"],
}
ALL_VOICES = sorted(set(v for vs in VOICES.values() for v in vs))


def _h(s):
    return int(hashlib.sha1(str(s).encode("utf-8")).hexdigest()[:8], 16)


def age_band(age):
    try:
        a = int(age)
    except (TypeError, ValueError):
        return "adult"
    return "young" if a < 28 else "old" if a >= 55 else "adult"


class Voice:
    def __init__(self, args, log, push_fn):
        self.a = args
        self.log = log
        self.push = push_fn
        self.dir = args.dir
        self.voices_dir = args.voices_dir or os.path.join(os.path.dirname(os.path.abspath(__file__)), "voices")
        self.whisper = None
        self.sd = None
        self.np = None
        self.kb = None
        self.piper_cls = None
        self.loaded = {}
        self.say_q = queue.Queue(maxsize=6)
        self.rec = None
        self.frames = []
        self.stop = False
        self.ptt_path = os.path.join(self.dir, "alifetalk_ptt.txt")
        self.ptt_seen = None
        self.stt_ok = self._init_stt() if args.voice in ("in", "both") else False
        self.tts_ok = self._init_tts() if args.voice in ("out", "both") else False
        if self.stt_ok:
            threading.Thread(target=self._ptt_loop, daemon=True).start()
        if self.tts_ok:
            threading.Thread(target=self._say_loop, daemon=True).start()

    # ------------------------------------------------------------------ speech in
    def _init_stt(self):
        try:
            import numpy as np
            import sounddevice as sd
            from faster_whisper import WhisperModel
        except Exception as e:
            self.log(f"voice: push-to-talk off ({e}). pip install faster-whisper sounddevice numpy")
            return False
        self.np, self.sd = np, sd
        dev = self.a.whisper_device
        ct = "float16" if dev == "cuda" else "int8"
        try:
            self.whisper = WhisperModel(self.a.whisper_model, device=dev, compute_type=ct)
        except Exception as e:
            if dev != "cpu":
                self.log(f"voice: whisper on {dev} failed ({e}); using CPU")
                self.whisper = WhisperModel(self.a.whisper_model, device="cpu", compute_type="int8")
            else:
                self.log(f"voice: whisper failed to load ({e})")
                return False
        if self.a.ptt_key:
            try:
                import keyboard
                self.kb = keyboard
            except Exception as e:
                self.log(f"voice: global hotkey off ({e}); the in-game key still works. pip install keyboard")
        self.log(f"voice: push-to-talk ready (whisper {self.a.whisper_model} on {dev}"
                 + (f", hotkey {self.a.ptt_key}" if self.kb else "") + ", in-game key)")
        return True

    def _game_ptt(self):
        try:
            st = os.stat(self.ptt_path)
        except OSError:
            return None
        if time.time() - st.st_mtime > 60:
            return None
        try:
            with open(self.ptt_path, "r", encoding="utf-8") as f:
                return f.read().strip().split(" ")[0] == "down"
        except OSError:
            return None

    def _held(self):
        if self.kb is not None:
            try:
                if self.kb.is_pressed(self.a.ptt_key):
                    return True
            except Exception:
                pass
        return bool(self._game_ptt())

    def _ptt_loop(self):
        recording = False
        started = 0.0
        while not self.stop:
            held = self._held()
            if held and not recording:
                recording, started = True, time.time()
                self._start_rec()
            elif recording and (not held or time.time() - started > 20):
                recording = False
                audio = self._stop_rec()
                if audio is not None and len(audio) > 16000 * 0.3:
                    threading.Thread(target=self._transcribe, args=(audio,), daemon=True).start()
            time.sleep(0.03)

    def _start_rec(self):
        self.frames = []

        def cb(indata, frames, t, status):
            self.frames.append(indata.copy())
        try:
            self.rec = self.sd.InputStream(samplerate=16000, channels=1, dtype="float32", callback=cb)
            self.rec.start()
        except Exception as e:
            self.log(f"voice: microphone error: {e}")
            self.rec = None

    def _stop_rec(self):
        if self.rec is None:
            return None
        try:
            self.rec.stop()
            self.rec.close()
        except Exception:
            pass
        self.rec = None
        if not self.frames:
            return None
        return self.np.concatenate(self.frames, axis=0).flatten()

    def _transcribe(self, audio):
        t0 = time.time()
        try:
            segs, _ = self.whisper.transcribe(audio, language=getattr(self.a, "voice_lang", "en") or "en", vad_filter=True, beam_size=1)
            text = " ".join(s.text.strip() for s in segs).strip()
        except Exception as e:
            self.log(f"voice: transcription failed: {e}")
            return
        if not text:
            self.log("voice: (heard nothing)")
            return
        self.log(f"voice: \"{text}\" ({(time.time() - t0) * 1000:.0f} ms)")
        self.push("voice", "", [str(int(time.time() * 1000)), text])

    # ------------------------------------------------------------------ speech out
    def _init_tts(self):
        try:
            from piper import PiperVoice
        except Exception as e:
            self.log(f"voice: NPC voices off ({e}). pip install piper-tts")
            return False
        self.piper_cls = PiperVoice
        have = [v for v in ALL_VOICES if os.path.exists(os.path.join(self.voices_dir, v + ".onnx"))]
        if not have:
            self.log(f"voice: NPC voices off - no Piper voices in {self.voices_dir} (see SETUP_050.md)")
            return False
        self.have = set(have)
        self.log(f"voice: NPC voices ready ({len(have)} Piper voices in {self.voices_dir})")
        return True

    def voice_for(self, uid, sex, age):
        sex = sex if sex in ("f", "m") else ("f" if _h(uid) % 2 else "m")
        band = age_band(age)
        pool = [v for v in VOICES[(sex, band)] if v in self.have] or \
               [v for k, vs in VOICES.items() if k[0] == sex for v in vs if v in self.have] or sorted(self.have)
        name = pool[_h(uid) % len(pool)]
        scale = 0.92 + (_h(str(uid) + "#len") % 17) / 100.0  # 0.92..1.08: each NPC talks at their own pace
        if band == "old":
            scale += 0.06
        return name, scale

    def speak(self, uid, sex, age, text, radio=False):
        if not self.tts_ok or not text or text.strip() in ("", "..."):
            return
        try:
            self.say_q.put_nowait((uid, sex, age, text, radio))
        except queue.Full:
            pass

    def _load(self, name):
        if name not in self.loaded:
            self.loaded[name] = self.piper_cls.load(os.path.join(self.voices_dir, name + ".onnx"))
        return self.loaded[name]

    def _synth(self, voice, text, path, scale):
        with wave.open(path, "wb") as wf:
            try:
                from piper import SynthesisConfig
                voice.synthesize_wav(text, wf, syn_config=SynthesisConfig(length_scale=scale))
            except ImportError:
                voice.synthesize(text, wf, length_scale=scale)  # older piper-tts
            except TypeError:
                voice.synthesize_wav(text, wf)

    def _play(self, path):
        try:
            import winsound
            winsound.PlaySound(path, winsound.SND_FILENAME)
            return
        except ImportError:
            pass
        try:
            import numpy as np
            import sounddevice as sd
            with wave.open(path, "rb") as wf:
                data = np.frombuffer(wf.readframes(wf.getnframes()), dtype=np.int16)
                sd.play(data, wf.getframerate())
                sd.wait()
        except Exception as e:
            self.log(f"voice: playback failed: {e}")

    def _say_loop(self):
        tmpdir = tempfile.mkdtemp(prefix="alifetalk_tts_")
        n = 0
        while not self.stop:
            try:
                uid, sex, age, text, radio = self.say_q.get(timeout=0.5)
            except queue.Empty:
                continue
            try:
                name, scale = self.voice_for(uid, sex, age)
                clean = text.replace("*kssht*", ", ").replace("*", "")
                n += 1
                path = os.path.join(tmpdir, f"line{n % 4}.wav")
                self._synth(self._load(name), clean, path, scale)
                self._play(path)
            except Exception as e:
                self.log(f"voice: TTS failed: {e}")
