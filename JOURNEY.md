
# The Professor Alan Journey: From Mobile Web to Native Voice

## Timeline Overview
**July 2025**: Mobile web exploration with Gradio  
**August 2025**: Native iOS as "Plato" (Stoic philosopher)  
**September 2025**: OpenAI Realtime API experiments, and Professor Alan Rebrand 

## Chapter 1: The Mobile Web Dead End (July 2024)

### The Vision
Build a voice-enabled philosophy chatbot accessible via web browser.

### The Reality
- Gradio interface worked on desktop
- iOS Safari's audio permissions killed the experience
- Web Speech API limitations on mobile
- **Lesson**: Voice UX demands native

## Chapter 2: Going Native with Plato (July 2025)

### The Pivot
Rebuilt as native iOS app focused on Stoic philosophy.

### Technical Stack v1
- SwiftUI for UI
- OpenAI Whisper for STT
- GPT-4 for conversation
- System TTS (AVSpeechSynthesizer)

### Why It Wasn't Enough
- Robotic voice killed the mentor experience
- **Lesson**: Personality products need personality voices

## Chapter 3: The Speed vs Quality Dilemma (September 2025)

### OpenAI Realtime API Experiment
Achieved 396ms latency! But...

**The Test** (actual conversation):
User: "What would Aristotle say about social media?"
Plato: [396ms later, in tinny voice] "Aristotle would... [robotic sounds]"

### The Numbers
| Metric | OpenAI Realtime | ElevenLabs |
|--------|----------------|------------|
| First word latency | 396ms | 2.3s |
| Voice quality | 4/10 | 9/10 |
| User reaction | "Impressive tech" | "I want to talk more" |
| Monthly cost | Variable ~$50 | Fixed $99 |

### The Decision
Chose 2-3 second beautiful voice over 400ms robot voice.
**Rationale**: This isn't a timer app. It's a relationship.

## Chapter 4: The Professor Alan Transformation (September 2025)

### Why Rebrand?
- "Plato" felt limiting (just Stoicism?)
- Users wanted broader wisdom
- Oxford professor resonated better than ancient philosopher
- The 3D character brought warmth

### Technical Evolution
- Added Perplexity API for current events
- Implemented echo prevention (AI hearing itself)
- Streaming responses with chunked TTS
- Custom conversation flow management

## Technical Decisions & Trade-offs

### 1. Always-Listening Mode
**Chose**: No button tap required  
**Trade-off**: Battery usage vs natural conversation  
**Result**: Users loved the flow

### 2. ElevenLabs vs Everything Else
**Tried**: 
- System TTS (free, robotic)
- OpenAI Realtime (fast, tinny)
- ElevenLabs ($99/mo, beautiful)

**Chose**: ElevenLabs  
**Why**: The voice IS the product for a mentor app

### 3. Response Length
**Chose**: 2-3 sentences max  
**Trade-off**: Depth vs engagement  
**Result**: Higher conversation completion rates

## Failed Experiments Worth Mentioning

### The 3D Avatar Disaster
- Tried embedding ReadyPlayer.Me avatar
- iOS doesn't support GLB files
- Spent 2 days on SceneKit conversion
- **Solution**: Just use a static image

### The Streaming TTS Saga
- Chunked responses by sentence
- Tried to speak while generating
- Overlapping audio chaos
- **Solution**: Generate complete, then speak

## Metrics That Mattered

- **Time to first word**: 2.3s (acceptable for quality)
- **Conversation completion**: 73% finish 5+ turns
- **User feedback**: "Feels like a real professor"
- **Development time**: 100+ hours over 6 months

## What I'd Do Differently

1. **Start native** - Skip the web experiment
2. **Test voices earlier** - Would have saved weeks
3. **Simpler first** - Shipped too many features initially
4. **Record everything** - Wish I had videos of early versions

## Future Possibilities

- 3D Avatar built natively in Unity
- Different professor personalities
- Saved Conversations or Threads

## Key Takeaways

1. **Voice quality > Speed** for personality-driven apps
2. **Native > Web** for voice interfaces
3. **Character matters** - The 3D professor avatar changed everything
4. **Ship the personality** - Features can come later

## Technical Debt Acknowledged

- Bundle ID still has "Frist" typo
- Local folder still named "Plato"
- Some Stoic references in comments
- **Why not fixed?** Working > Perfect

---

*This project taught me that building a voice AI isn't about the AI—it's about the voice. And the voice isn't about speed—it's about soul.*
