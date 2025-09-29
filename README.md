
# Professor Alan 🎓

An iOS voice assistant that brings the warmth and wisdom of an Oxford humanities professor to natural conversation.

<p align="center">
  <a href="https://www.youtube.com/shorts/BBHFOto_Pao">
    <img src="demo/WelcomeView.png" alt="Professor Alan Demo" width="600">
  </a>
</p>

<p align="center">
  <a href="https://www.youtube.com/shorts/BBHFOto_Pao">📹 Watch Demo</a> •
  <a href="#features">Features</a> •
  <a href="#setup">Setup</a> •
  <a href="#architecture">Architecture</a>
</p>

## What Makes This Different

Unlike task-oriented assistants, Professor Alan is designed for meaningful conversation about life's big questions. With response times under 3 seconds and natural voice synthesis, it feels less like querying an AI and more like office hours with a favorite professor.

## Features

- ✅ **Natural Conversations** - No wake words, just start talking
- ✅ **Rich Knowledge** - Philosophy, history, literature, psychology, art
- ✅ **Premium Voice** - ElevenLabs synthesis with British warmth
- ✅ **Smart Context** - Perplexity API for real-time information retrieval
- ✅ **Fast Response** - < 3 second total latency

## Technical Stack

- **iOS Native**: SwiftUI, AVFoundation
- **Speech Recognition**: Apple Speech Framework + OpenAI Whisper
- **Language Model**: OpenAI GPT-4
- **Information Retrieval**: Perplexity API for current events/facts
- **Voice Synthesis**: ElevenLabs API (with system TTS fallback)
- **Audio Pipeline**: Custom echo prevention and conversation management

## Architecture
[Microphone] → [Speech Recognition] → [GPT-4 + Perplexity] → [ElevenLabs] → [Speaker]
↓                      ↓
[Transcript UI]      [Context Enhancement]

## Setup

### Prerequisites
- iOS 18.0+
- Xcode 16+
- API Keys (see Configuration)

### Installation

1. Clone the repository
```bash
git clone https://github.com/yourusername/professor-alan.git
cd professor-alan/iOS

2. Configure API Keys in Config.plist

<key>OpenAI_API_Key</key>
<string>YOUR_OPENAI_KEY</string>
<key>ElevenLabs_API_Key</key>
<string>YOUR_ELEVENLABS_KEY</string>
<key>Perplexity_API_Key</key>
<string>YOUR_PERPLEXITY_KEY</string>

3. Open in Xcode and run

License
MIT
Acknowledgments

Character design created with Chat GPT-5
Inspired by the best humanities professors at Oxford
Originally developed as "Plato" before finding its true identity
