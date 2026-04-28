<p align="center">
  <img src="logo.svg" width="80" alt="open-wispr logo">
</p>

<h1 align="center">open-wispr</h1>

<p align="center">
  <strong><a href="https://tarnovski.com">Made by TARNOVSKI</a></strong><br>
  Local, private voice dictation for macOS. Hold a key, speak, release — your words appear at the cursor.<br>
  Everything runs on-device. No audio or text ever leaves your machine.
</p>

<p align="center">
  Powered by <a href="https://github.com/ggml-org/whisper.cpp">whisper.cpp</a> with Metal acceleration on Apple Silicon.<br>
  <strong>Proofreading pipeline</strong> — automatic punctuation, sentence capitalization, filler removal, and contraction repair, all on-device.
</p>

## Install

### Option A: One-liner (recommended)

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/totnormal/open-wispr/feat/proofreading-pipeline/scripts/remote-install.sh)"
```

Clones the repo, installs whisper-cpp via Homebrew, builds from source, downloads `base.en` (or your chosen model), sets up auto-start on login, and starts dictating. Everything is automatic.

### Option B: Portable DMG (for sharing)

```bash
git clone https://github.com/totnormal/open-wispr.git
cd open-wispr
git checkout feat/proofreading-pipeline
bash scripts/build-dmg.sh
```

Produces `open-wispr-v0.37.0.dmg` — drag OpenWispr.app to /Applications like any Mac app. Then `brew install whisper-cpp` and download a model.

After any install: a waveform icon appears in your menu bar. The default hotkey is the **Globe key** (🌐). Hold it, speak, release.

> **[Full installation guide](docs/install-guide.md)** — permissions walkthrough with screenshots, non-English macOS instructions, and troubleshooting.

## Configuration

Edit `~/.config/open-wispr/config.json`:

```json
{
  "hotkey": { "keyCode": 63, "modifiers": [] },
  "modelSize": "base.en",
  "language": "en",
  "spokenPunctuation": false,
  "proofreadingMode": "standard",
  "maxRecordings": 0,
  "toggleMode": false
}
```

| Option | Default | Values |
|---|---|---|
| **hotkey** | `63` | Globe (`63`), Right Option (`61`), F5 (`96`), or any key code |
| **modifiers** | `[]` | `"cmd"`, `"ctrl"`, `"shift"`, `"opt"` — combine for chords |
| **modelSize** | `"base.en"` | See model table below |
| **language** | `"en"` | `"auto"` for auto-detect, or any [ISO 639-1 code](https://en.wikipedia.org/wiki/List_of_ISO_639-1_codes) — e.g. `it`, `fr`, `de`, `es` |
| **spokenPunctuation** | `false` | Say "comma", "period", etc. to insert punctuation instead of auto-punctuation. Note: when `proofreadingMode` is `standard`, spoken punctuation works as a fallback — punctuation marks are only inserted when whisper didn't produce one. |
| **proofreadingMode** | `"standard"` | `"standard"` — always post-process output (filler removal, contraction repair, sentence capitalization, spoken-punctuation fallback). `"minimal"` — raw whisper output with only noise markers stripped. |
| **maxRecordings** | `0` | Optionally store past recordings locally as `.wav` files for re-transcribing from the tray menu. `0` = nothing stored (default). Set 1-100 to keep that many recent recordings. |
| **toggleMode** | `false` | Press hotkey once to start recording, press again to stop. Default is hold-to-talk. |

### Models

Larger models are more accurate but slower and use more memory. The default `base.en` is a good balance for most users.

| Model | Size | Speed | Accuracy | Best for |
|---|---|---|---|---|
| `tiny.en` | 75 MB | Fastest | Lower | Quick notes, short phrases |
| **`base.en`** | 142 MB | **Fast** | **Good** | **Most users (default)** |
| `small.en` | 466 MB | Moderate | Better | Longer dictation, technical terms |
| `medium.en` | 1.5 GB | Slower | Great | Maximum accuracy, complex speech |
| `large-v3-turbo` | 1.6 GB | Moderate | Great | Fast multilingual, near-large accuracy |
| `large-v3` | 3 GB | Slowest | Best | Multilingual, highest accuracy (M1 Pro+ recommended) |

Each model also has quantized `-q5_0` / `-q5_1` / `-q8_0` variants at ~⅓–½ the disk and RAM with minimal quality loss. See **[MODELS.md](MODELS.md)** for the complete list and tradeoffs.

> **Non-English languages:** Models ending in `.en` are English-only. To use another language, switch to the equivalent multilingual model (e.g. `base.en` → `base`, or `large-v3-turbo` for the fastest large-tier option) and set the `language` field to your language code. Multilingual models are slightly less accurate for English but support 99 languages.

If the Globe key opens the emoji picker: **System Settings → Keyboard → "Press 🌐 key to" → "Do Nothing"**

## Menu bar

Click the waveform icon for status and options. **Recent Recordings** lists your last recordings; click one to re-transcribe and copy the result to the clipboard.

| State | Icon |
|---|---|
| Idle | Waveform outline |
| Recording | Bouncing waveform |
| Transcribing | Wave dots |
| Downloading model | Progress ring |
| Waiting for permission | Lock |

Click the menu bar icon to access **Copy Last Dictation** — recovers your most recent transcription if you dictated without a text field focused.

## Privacy

open-wispr is completely local. Audio is recorded to a temp file, transcribed by whisper.cpp on your CPU/GPU, and the temp file is deleted. No network requests are made except to download the Whisper model on first run. Optionally, you can configure open-wispr to store a number of past recordings locally via the `maxRecordings` setting. Those recordings stay private and on your machine, and we default to not storing anything.

## Features

### Proofreading pipeline (post-ASR correction)

After whisper transcribes your speech, the proofreading pipeline cleans up the output — fully on-device, at zero added latency:

- **Filler word removal** — strips "um", "uh", "you know", etc.
- **Repeated word fix** — merges stutters ("I I I think" → "I think")
- **Broken contraction repair** — fixes "do not" → "don't", "I am" → "I'm"
- **Spoken-punctuation fallback** — when whisper misses a comma or period, spoken "comma"/"period" still inserts it
- **Auto-capitalization** — sentences always start with capital letters
- **Prompt priming** — whisper sees your last transcription as context, improving continuity

Toggle between **Standard** (full pipeline) and **Minimal** (raw whisper) in the menu bar.

### Auto model cleanup

When you switch models, old ones are automatically deleted — no wasted disk space. Only your current model stays.

### On-device only

Audio is recorded to a temp file, transcribed locally, and immediately deleted. No network calls except the one-time model download from HuggingFace.

## Build from source

```bash
git clone -b feat/proofreading-pipeline https://github.com/totnormal/open-wispr.git
cd open-wispr
brew install whisper-cpp
swift build -c release
bash scripts/bundle-app.sh .build/release/open-wispr OpenWispr.app dev
open OpenWispr.app
```

## License

MIT
