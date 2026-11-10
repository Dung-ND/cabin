# Cabin

A macOS menu-bar app that listens to everything your Mac plays and everything you say, and then:

- **Transcribes** it on-device with Whisper (WhisperKit). Audio never leaves your Mac.
- **Tracks which app** the audio came from (Zoom, Chrome, Slack…). For the mic, it notes which app is using the microphone.
- **Separates speakers** (Pyannote via SpeakerKit) into *Speaker 1, Speaker 2…*. Rename a speaker once and Cabin recognizes that voice in later sessions. Your mic is labeled with your name.
- **Summarizes** each session with your LLM (OpenAI/ChatGPT or Google Gemini). The summary has an overview, key points, decisions and action items, and it updates while you listen.
- **Explains uncommon terms** live. Words outside the N most common English words, plus acronyms, are looked up on Wikipedia, and the LLM writes a one-line definition that fits the conversation (or infers one). Each term is cached and only looked up once.
- **Stores everything** in a local SQLite database with full-text search: `~/Library/Application Support/Cabin/cabin.sqlite`.
- **Floats on screen**: an always-on-top overlay that shows on every Space and over full-screen apps. Width, height, opacity, text size and click-through are adjustable.

## Requirements

- Apple Silicon Mac, **macOS 14.2+** (built for M-series; tested in CI on macOS 26 / Xcode 26)
- Xcode 16 or newer
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- An OpenAI or Google AI Studio API key (optional; without one you still get transcripts and Wikipedia definitions)

## Build & run

```bash
git clone https://github.com/Dung-ND/cabin.git
cd cabin
xcodegen generate
open Cabin.xcodeproj
```

In Xcode, pick the **Cabin** scheme and press ⌘R. For stable permissions across rebuilds, set your Team under *Signing & Capabilities*. Ad-hoc signed builds may have to be granted permissions again after each rebuild.

### First launch

1. Cabin appears in the **menu bar** (waveform icon) and Settings opens.
2. **Settings → AI**: choose OpenAI or Gemini, paste your API key, press **Save key**, then **Test connection**. Keys are stored in the macOS Keychain.
3. Press **Start Listening** (menu bar, ⌘L, or ● on the overlay).
   - macOS asks for **Screen & System Audio Recording** (needed to capture system audio) and **Microphone**. After you grant screen recording, quit and reopen Cabin.
   - The first start downloads the Whisper model (~1.6 GB for Large v3 Turbo) and the diarization models from Hugging Face. Progress shows in the overlay.
4. Open **History** (⌘H) to see sessions, summaries, transcripts, speakers (rename/merge) and terms.

## How it works

```
ScreenCaptureKit (system audio) ─┐                       ┌─ SpeakerRegistry (voice embeddings → Speaker N / names)
AVAudioEngine (microphone) ──────┼─ 16 kHz mono ─ VAD ─ chunks ─ WhisperKit + SpeakerKit ─┤
Core Audio process list ─────────┘ (which app is playing / recording)                     ├─ SQLite (GRDB, FTS5)
                                                                                           ├─ Glossary: rare-word filter → Wikipedia → LLM
                                                                                           └─ Summarizer: incremental LLM summary every N min
```

| Folder | Contents |
|---|---|
| `Cabin/Audio` | System audio + mic capture, resampling, voice-activity chunking, per-app attribution |
| `Cabin/Transcription` | WhisperKit/SpeakerKit engine, cross-chunk speaker matching, mic echo de-duplication |
| `Cabin/LLM` | OpenAI (any OpenAI-compatible base URL) and Gemini clients |
| `Cabin/Glossary` | Rare-word detector (bundled `wordfreq` list), Wikipedia lookup, glossary service |
| `Cabin/Summary` | Running session summaries |
| `Cabin/Storage` | GRDB schema and queries |
| `Cabin/UI` | Floating overlay, menu bar, history and settings windows |

## Tips & tuning

- **Speakers vs. headphones**: if you use speakers, the mic also hears the other people. Cabin drops mic lines that match system audio from the same moment. You can also turn on *Echo cancellation* (Settings → Listening).
- **Too many / too few speakers**: adjust *Voice matching* in Settings → Listening. If one person got split into two speakers, use *Merge into* in History.
- **Too many / too few definitions**: change *Treat as common* in Settings → Glossary. To stop a term from showing, delete it in History → Glossary.
- **Models**: the OpenAI and Gemini model names can be edited in Settings. `gpt-5-mini` and `gemini-2.5-flash` are the defaults.
- **Click-through overlay**: turn it off from the menu bar icon.

## Adding a language

1. Add a `SupportedLanguage` entry in `Cabin/Settings/AppSettings.swift`.
2. Add `Cabin/Resources/wordfreq-<code>.txt`, one word per line, most common first. You can generate it with `python -c "from wordfreq import top_n_list; print('\n'.join(top_n_list('<code>', 50000)))"`.
3. Pick a multilingual Whisper model (the Large v3 variants are multilingual; `*.en` are English-only).

## Privacy

Transcription and speaker identification run locally. Only transcript **text** is sent to your chosen LLM, for summaries and definitions, and only candidate **terms** are sent to Wikipedia. Recording people may require their consent where you live.

## Credits

[WhisperKit / SpeakerKit](https://github.com/argmaxinc/argmax-oss-swift) (MIT), [GRDB](https://github.com/groue/GRDB.swift) (MIT). The word frequency list comes from [wordfreq](https://github.com/rspeer/wordfreq) (data CC BY-SA 4.0).
