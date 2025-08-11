#  # Core Question-Answer Flow Trace


## Starting Conditions
- App is running
- Always-listening is ON
- User sees blue gradient (listening state)

## Flow Begins: User Speaks "What would Marcus Aurelius say?"

Flow Path:
User Speaks → Speech Recognition → Echo Detection → Question Processing → 
API Call (with optional web search) → TTS Response → Return to Listening

1. USER SPEAKS: "What would Marcus Aurelius say?"
   
2. SPEECH RECOGNITION (SpeechRecognizer.swift)
   - handleRecognition() → fireTurn() → onAutoUpload callback
   
3. ECHO CHECK (ContentView.swift)
   - 🛡️ Prints only if echo detected
   
4. PROCESS QUESTION (ContentView.swift - askQuestion)
   - No prints (silent state updates)
   - Stops any ongoing TTS
   - Updates UI with user message
   
5. API CALL (PhilosophyService.swift)
   - 🔎 Print if web search needed
   - ⚠️ Print if search fails
   - Silent OpenAI streaming
   
6. TTS SPEAKS (ElevenLabsService.swift)
   - 🔊 "TTS Starting - isSpeaking = true"
   - Stops speech recognition
   - Streams audio
   - 🔊 "TTS Complete - isSpeaking = false"
   - Calls notifyTTSComplete()
   
7. RETURN TO LISTENING
   - 📢 "TTS completed, setting grace period"
   - [Verbose state logging]
   - 🎤 "Resuming speech recognition after TTS"
   
8. CYCLE COMPLETE - Ready for next question



## Bugs Discovered During Audit
1. **Echo Detection Too Aggressive**
   - File: ContentView.swift
   - Method: isEcho()
   - Issue: Drops legitimate responses that repeat AI's words
   - Fix: Add timing check (echoes happen within 2-3 seconds)
   - Example: User says "Yes, life is filled with change" gets dropped
