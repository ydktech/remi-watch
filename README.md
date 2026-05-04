# Remi — watchOS AI Companion

A watchOS 10 app featuring Remi, a tsundere anime AI assistant that listens, responds, and reacts with emotion.

## Features

- **Voice conversation** — tap to record, tap again to send
- **Emotion-aware face** — 9 facial expressions that change based on Remi's response
- **Breathing animation** — subtle idle animation
- **Low-latency pipeline** — STT → LLM → TTS with connection pre-warming on launch

## Stack

| Role | Service |
|------|---------|
| STT | [xAI Grok](https://docs.x.ai) REST API |
| LLM | xAI Grok 3 |
| TTS | [Fish Audio](https://fish.audio) streaming PCM |

## Setup

1. Clone the repo
2. Install [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
3. Copy `WatchVoiceApp/Sources/Secrets.template.swift` → `Secrets.swift` and fill in your API keys
4. Copy `signing.xcconfig.template` → `signing.xcconfig` and set your Apple Team ID
5. Run `xcodegen generate` then open `WatchVoiceApp.xcodeproj`

```
# signing.xcconfig
DEVELOPMENT_TEAM = YOUR_TEAM_ID
CODE_SIGN_STYLE = Automatic
```

## Project structure

```
WatchVoiceApp/
├── Sources/
│   ├── WatchVoiceApp.swift      # App entry point
│   ├── ContentView.swift        # UI + emotion face switching
│   ├── AudioManager.swift       # STT / LLM / TTS pipeline
│   └── Secrets.template.swift   # API key template
└── Resources/
    ├── layers/                  # Emotion face sprites (9 expressions)
    └── Assets.xcassets/         # App icon
```

## Character

Remi responds in Japanese with tsundere personality. The LLM response format includes emotion tags (`[happy]`, `[annoyed]`, `[embarrassed]`, etc.) that drive face switching.
