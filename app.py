"""
MOBILE-OPTIMIZED Stoic Voice Chat with improved UX

• Responsive design for mobile devices
• Better touch targets and button sizing
• Auto-play with user gesture handling
• Improved mobile navigation and layout
"""

import os, tempfile
import gradio as gr
from openai import OpenAI
from pydub import AudioSegment
import requests
import io

# ─── OpenAI setup ───────────────────────────────────────────────────
client = OpenAI(api_key=os.getenv("OPENAI_API_KEY"))
MODEL  = "gpt-4o-mini"
SYSTEM = """You are a wise Stoic philosopher and mentor. Draw from the teachings of Marcus Aurelius, Epictetus, and Seneca. 
Provide practical wisdom and guidance rooted in Stoic principles. Keep responses concise but profound, 
helping users apply ancient wisdom to modern challenges."""

# ─── ElevenLabs setup ────────────────────────────────────────────────
ELEVENLABS_API_KEY = os.getenv("ELEVENLABS_API_KEY")
ELEVENLABS_VOICE_ID = "JBFqnCBsd6RMkjVDRZzb"  # Updated voice ID

def llm(msg, hist):
    msgs=[{"role":"system","content":SYSTEM}]
    for u,a in hist: msgs+= [{"role":"user","content":u},{"role":"assistant","content":a}]
    msgs.append({"role":"user","content":msg})
    return client.chat.completions.create(model=MODEL,messages=msgs).choices[0].message.content.strip()

# ─── audio helpers ──────────────────────────────────────────────────
def downsample(fp):
    out=tempfile.mktemp(suffix=".wav")
    (AudioSegment.from_file(fp)
        .set_channels(1).set_frame_rate(16_000)
        .export(out,format="wav"))
    return out

def text_to_speech(text):
    """Convert text to speech using ElevenLabs API with optimized settings for speed"""
    if not ELEVENLABS_API_KEY:
        print("ElevenLabs API key not found")
        return None
    
    try:
        # Use the faster turbo model for reduced latency
        url = f"https://api.elevenlabs.io/v1/text-to-speech/{ELEVENLABS_VOICE_ID}"
        headers = {
            "Accept": "audio/mpeg",
            "Content-Type": "application/json",
            "xi-api-key": ELEVENLABS_API_KEY
        }
        data = {
            "text": text,
            "model_id": "eleven_turbo_v2_5",  # Faster model for lower latency
            "voice_settings": {
                "stability": 0.5,           # Reduced for speed
                "similarity_boost": 0.6,    # Reduced for speed
                "style": 0.1,               # Minimal style for speed
                "use_speaker_boost": False  # Disabled for speed
            },
            "optimize_streaming_latency": 4,  # Maximum optimization
            "output_format": "mp3_22050_32"   # Lower quality for faster processing
        }
        
        response = requests.post(url, json=data, headers=headers, timeout=10)
        
        if response.status_code == 200:
            temp_file = tempfile.mktemp(suffix=".mp3")
            with open(temp_file, 'wb') as f:
                f.write(response.content)
            return temp_file
        else:
            print(f"ElevenLabs API error: {response.status_code}")
            return None
            
    except Exception as e:
        print(f"TTS error: {e}")
        return None

def handle_audio(file, hist, speak_enabled):
    if not file:
        return hist, None
    
    hist = hist or []
    try:
        downsampled_file = downsample(file)
        with open(downsampled_file, "rb") as audio_file:
            txt = client.audio.transcriptions.create(
                model="whisper-1",
                file=audio_file
            ).text
        
        if txt.strip():
            ans = llm(txt, hist)
            hist.append((txt, ans))
            
            audio_response = None
            if speak_enabled:
                audio_response = text_to_speech(ans)
            
            if os.path.exists(downsampled_file):
                os.remove(downsampled_file)
                
            return hist, audio_response
            
        if os.path.exists(downsampled_file):
            os.remove(downsampled_file)
            
    except Exception as e:
        print(f"Audio processing error: {e}")
        hist.append(("Audio processing failed", "I apologize, but I couldn't process your audio. Please try again."))
    
    return hist, None

def handle_text(q, hist, speak_enabled):
    if not q.strip():
        return hist, "", None
    
    hist = hist or []
    ans = llm(q, hist)
    hist.append((q, ans))
    
    audio_response = None
    if speak_enabled:
        audio_response = text_to_speech(ans)
    
    return hist, "", audio_response

# ─── Mobile-Optimized CSS ──────────────────────────────────────────────────
CSS = """
/* Mobile-first responsive design */
* {
    box-sizing: border-box;
}

/* Base mobile styles */
.gradio-container {
    max-width: 100% !important;
    margin: 0 !important;
    padding: 10px !important;
}

/* Mobile-optimized chat */
.chat-container {
    height: 50vh !important;
    min-height: 300px !important;
    border-radius: 15px !important;
    border: 2px solid #2563eb !important;
    background: white !important;
    margin-bottom: 15px !important;
}

/* Mobile-friendly text input */
.text-input-container {
    margin-bottom: 15px !important;
}

.text-input-container .wrap {
    border-radius: 25px !important;
    border: 2px solid #2563eb !important;
    box-shadow: 0 4px 15px rgba(37, 99, 235, 0.1) !important;
}

.text-input-container input {
    font-size: 16px !important; /* Prevents zoom on iOS */
    padding: 15px 20px !important;
    border: none !important;
    border-radius: 25px !important;
}

/* Mobile-optimized audio container */
.audio-container {
    background: linear-gradient(135deg, #f0f9ff 0%, #e0f2fe 100%) !important;
    border: 2px solid #2563eb !important;
    border-radius: 20px !important;
    padding: 20px !important;
    margin: 15px 0 !important;
    box-shadow: 0 8px 25px rgba(37, 99, 235, 0.15) !important;
}

.audio-container .wrap {
    background: white !important;
    border-radius: 15px !important;
    padding: 15px !important;
    box-shadow: 0 4px 15px rgba(0, 0, 0, 0.1) !important;
}

.audio-container button {
    background: linear-gradient(135deg, #2563eb 0%, #1d4ed8 100%) !important;
    border: none !important;
    border-radius: 50px !important;
    color: white !important;
    font-weight: 600 !important;
    font-size: 16px !important;
    padding: 15px 25px !important;
    min-height: 50px !important;
    width: 100% !important;
    transition: all 0.3s ease !important;
    box-shadow: 0 4px 15px rgba(37, 99, 235, 0.3) !important;
    touch-action: manipulation !important; /* Better mobile touch */
}

.audio-container button:hover,
.audio-container button:active {
    transform: translateY(-2px) !important;
    box-shadow: 0 6px 20px rgba(37, 99, 235, 0.4) !important;
}

/* Mobile-optimized quick buttons */
.quick-buttons-container {
    margin: 20px 0 !important;
}

.quick-buttons-grid {
    display: grid !important;
    grid-template-columns: 1fr !important; /* Single column on mobile */
    gap: 12px !important;
    margin: 15px 0 !important;
}

.quick-record-btn {
    background: linear-gradient(135deg, #059669 0%, #047857 100%) !important;
    border: none !important;
    border-radius: 25px !important;
    color: white !important;
    font-weight: 600 !important;
    font-size: 15px !important;
    padding: 18px 24px !important;
    cursor: pointer !important;
    transition: all 0.3s ease !important;
    box-shadow: 0 4px 15px rgba(5, 150, 105, 0.3) !important;
    touch-action: manipulation !important;
    min-height: 55px !important;
    width: 100% !important;
    text-align: center !important;
    display: flex !important;
    align-items: center !important;
    justify-content: center !important;
}

.quick-record-btn:hover,
.quick-record-btn:active {
    transform: translateY(-2px) !important;
    box-shadow: 0 6px 20px rgba(5, 150, 105, 0.4) !important;
}

/* Voice settings */
.voice-settings {
    background: #f8fafc !important;
    border: 1px solid #e2e8f0 !important;
    border-radius: 15px !important;
    padding: 15px !important;
    margin: 15px 0 !important;
}

.voice-settings label {
    font-size: 16px !important;
    font-weight: 600 !important;
    color: #1e293b !important;
}

/* Mobile-friendly audio output with manual play button */
.audio-output {
    background: linear-gradient(135deg, #fef3c7 0%, #fbbf24 100%) !important;
    border: 2px solid #f59e0b !important;
    border-radius: 20px !important;
    padding: 15px !important;
    margin: 15px 0 !important;
    box-shadow: 0 4px 15px rgba(245, 158, 11, 0.2) !important;
}

.audio-output .wrap {
    background: white !important;
    border-radius: 15px !important;
    padding: 10px !important;
}

/* Custom play button for mobile Safari */
.mobile-play-btn {
    background: linear-gradient(135deg, #f59e0b 0%, #d97706 100%) !important;
    border: none !important;
    border-radius: 25px !important;
    color: white !important;
    font-weight: 600 !important;
    font-size: 16px !important;
    padding: 15px 25px !important;
    width: 100% !important;
    margin: 10px 0 !important;
    cursor: pointer !important;
    transition: all 0.3s ease !important;
    box-shadow: 0 4px 15px rgba(245, 158, 11, 0.3) !important;
    touch-action: manipulation !important;
}

.mobile-play-btn:hover,
.mobile-play-btn:active {
    transform: translateY(-1px) !important;
    box-shadow: 0 6px 20px rgba(245, 158, 11, 0.4) !important;
}

/* Loading indicator styles */
.loading-indicator {
    animation: fadeInOut 2s infinite;
}

@keyframes fadeInOut {
    0%, 100% { opacity: 0.7; }
    50% { opacity: 1; }
}

/* Instructions styling */
.instructions {
    background: #f1f5f9 !important;
    border-left: 4px solid #2563eb !important;
    border-radius: 10px !important;
    padding: 15px !important;
    margin: 20px 0 !important;
    font-size: 14px !important;
}

.setup-status {
    background: #ecfdf5 !important;
    border: 1px solid #10b981 !important;
    border-radius: 10px !important;
    padding: 15px !important;
    margin: 15px 0 !important;
    font-size: 14px !important;
}

/* Tablet and larger screens */
@media (min-width: 768px) {
    .gradio-container {
        max-width: 800px !important;
        margin: 0 auto !important;
        padding: 20px !important;
    }
    
    .quick-buttons-grid {
        grid-template-columns: 1fr 1fr !important; /* Two columns on tablet+ */
    }
    
    .chat-container {
        height: 60vh !important;
    }
}

/* Desktop screens */
@media (min-width: 1024px) {
    .quick-buttons-grid {
        grid-template-columns: repeat(3, 1fr) !important; /* Three columns on desktop */
    }
}

/* Accessibility improvements */
@media (prefers-reduced-motion: reduce) {
    * {
        animation-duration: 0.01ms !important;
        animation-iteration-count: 1 !important;
        transition-duration: 0.01ms !important;
    }
}

/* Dark mode support */
@media (prefers-color-scheme: dark) {
    .instructions {
        background: #1e293b !important;
        color: #f1f5f9 !important;
    }
    
    .setup-status {
        background: #064e3b !important;
        color: #d1fae5 !important;
    }
    
    .voice-settings {
        background: #1e293b !important;
        color: #f1f5f9 !important;
        border-color: #475569 !important;
    }
}

/* Recording pulse animation */
.recording-pulse {
    animation: pulse 1.5s infinite;
}

@keyframes pulse {
    0% { box-shadow: 0 0 0 0 rgba(37, 99, 235, 0.7); }
    70% { box-shadow: 0 0 0 20px rgba(37, 99, 235, 0); }
    100% { box-shadow: 0 0 0 0 rgba(37, 99, 235, 0); }
}

/* Mobile Safari audio fix */
.mobile-audio-container {
    text-align: center;
    padding: 15px;
    background: #fff3cd;
    border: 1px solid #ffeaa7;
    border-radius: 10px;
    margin: 10px 0;
}

.mobile-audio-container audio {
    width: 100%;
    max-width: 300px;
}
"""

# ─── Mobile-Optimized Interface ──────────────────────────────────────
def create_interface():
    with gr.Blocks(title="Stoic Voice Chat", css=CSS) as demo:
        
        # Header with mobile-friendly sizing
        gr.Markdown("# 🏛️ Stoic Voice Chat", elem_classes=["header"])
        gr.Markdown("*Ancient wisdom for modern challenges*", elem_classes=["subtitle"])
        
        # Chat interface with mobile optimization
        chat = gr.Chatbot(
            height=400,
            elem_classes=["chat-container"],
            show_label=False,
            avatar_images=("🤔", "🏛️")
        )
        
        # Mobile-optimized text input
        with gr.Row():
            txt = gr.Textbox(
                placeholder="Ask for wisdom or guidance...", 
                container=False, 
                scale=1,
                show_label=False,
                elem_classes=["text-input-container"]
            )
        
        # Mobile-friendly audio section
        with gr.Row():
            with gr.Column():
                gr.Markdown("### 🎤 Voice Input", elem_classes=["section-header"])
                audio_input = gr.Audio(
                    sources=["microphone"],
                    type="filepath",
                    label="Tap to record your question",
                    elem_classes=["audio-container"]
                )
        
        # Voice settings with better mobile layout
        with gr.Row():
            speak_checkbox = gr.Checkbox(
                value=True, 
                label="🔊 Enable voice responses",
                info="Get spoken wisdom from ancient philosophers",
                elem_classes=["voice-settings"]
            )
        
        # Audio output with cross-browser compatibility and manual play
        audio_output = gr.Audio(
            label="🎧 Philosophical Wisdom - Click Play to Listen",
            autoplay=False,  # Disabled for all browsers due to auto-play policies
            elem_classes=["audio-output"],
            show_download_button=True,
            interactive=True,
            visible=True
        )
        
        # Add JavaScript to attempt auto-play after user interaction
        gr.HTML("""
        <script>
        function tryAutoPlay() {
            // Find the audio element
            const audioElements = document.querySelectorAll('audio');
            if (audioElements.length > 0) {
                const latestAudio = audioElements[audioElements.length - 1];
                if (latestAudio && latestAudio.src) {
                    // Try to play, but catch any errors silently
                    latestAudio.play().catch(e => {
                        console.log('Auto-play blocked - user will need to click play');
                    });
                }
            }
        }
        
        // Watch for new audio content
        const observer = new MutationObserver(function(mutations) {
            mutations.forEach(function(mutation) {
                if (mutation.type === 'childList') {
                    // Check if new audio was added
                    const addedNodes = Array.from(mutation.addedNodes);
                    const hasAudio = addedNodes.some(node => 
                        node.tagName === 'AUDIO' || 
                        (node.querySelector && node.querySelector('audio'))
                    );
                    if (hasAudio) {
                        setTimeout(tryAutoPlay, 500);
                    }
                }
            });
        });
        
        // Start observing
        observer.observe(document.body, {
            childList: true,
            subtree: true
        });
        </script>
        """, visible=False)
        
        # Mobile-optimized quick questions
        gr.Markdown("### 💭 Quick Questions", elem_classes=["section-header"])
        
        # Mobile-first grid layout for buttons
        with gr.Column(elem_classes=["quick-buttons-container"]):
            with gr.Column(elem_classes=["quick-buttons-grid"]):
                btn1 = gr.Button("How do I deal with stress?", elem_classes=["quick-record-btn"])
                btn2 = gr.Button("What would Marcus Aurelius say about failure?", elem_classes=["quick-record-btn"])
                btn3 = gr.Button("How can I be more resilient?", elem_classes=["quick-record-btn"])
                btn4 = gr.Button("Stoic view on dealing with anger?", elem_classes=["quick-record-btn"])
                btn5 = gr.Button("How do I find peace in difficult times?", elem_classes=["quick-record-btn"])
        
        # Event handlers fixed for correct number of outputs
        txt.submit(
            handle_text,
            inputs=[txt, chat, speak_checkbox],
            outputs=[chat, txt, audio_output]
        )
        
        audio_input.change(
            handle_audio,
            inputs=[audio_input, chat, speak_checkbox],
            outputs=[chat, audio_output]
        )
        
        # Quick button handlers - simplified to avoid argument errors
        def quick_question_1():
            return "How do I deal with stress at work?", ""
        
        def quick_question_2():
            return "What would Marcus Aurelius say about failure?", ""
            
        def quick_question_3():
            return "How can I be more resilient in the face of adversity?", ""
            
        def quick_question_4():
            return "What is the Stoic view on dealing with anger?", ""
            
        def quick_question_5():
            return "How do I find peace in difficult times?", ""
        
        btn1.click(
            quick_question_1,
            outputs=[txt]
        ).then(
            handle_text, 
            inputs=[txt, chat, speak_checkbox], 
            outputs=[chat, txt, audio_output]
        )
        
        btn2.click(
            quick_question_2,
            outputs=[txt]
        ).then(
            handle_text, 
            inputs=[txt, chat, speak_checkbox], 
            outputs=[chat, txt, audio_output]
        )
        
        btn3.click(
            quick_question_3,
            outputs=[txt]
        ).then(
            handle_text, 
            inputs=[txt, chat, speak_checkbox], 
            outputs=[chat, txt, audio_output]
        )
        
        btn4.click(
            quick_question_4,
            outputs=[txt]
        ).then(
            handle_text, 
            inputs=[txt, chat, speak_checkbox], 
            outputs=[chat, txt, audio_output]
        )
        
        btn5.click(
            quick_question_5,
            outputs=[txt]
        ).then(
            handle_text, 
            inputs=[txt, chat, speak_checkbox], 
            outputs=[chat, txt, audio_output]
        )
        
        # Mobile-friendly instructions with auto-play info
        gr.Markdown("""
        ---
        ### 📱 How to Use
        
        **Voice Chat:**
        - 🎤 Tap "Record" to ask your question
        - 🎧 **Audio will try to auto-play, or click the play button**
        - 💬 Or type your questions in the text box
        
        **Quick Start:**
        - 🔘 Tap any question button for instant guidance
        - 🔊 Toggle voice responses on/off as needed
        
        **Browser Tips:**
        - 🔊 **First interaction**: After your first click/tap, audio should auto-play
        - 🎵 **If no auto-play**: Look for the play button in the audio player
        - 📱 Works best in landscape mode for typing
        - 🎧 Use headphones for better audio quality
        
        **Performance:**
        - ⚡ Optimized for ~4 second response time
        - 🚀 Uses ElevenLabs Turbo model for faster speech generation
        """, elem_classes=["instructions"])
        
        # Setup status with mobile formatting
        gr.Markdown(f"""
        **📋 Setup Status:**
        - OpenAI (Voice Recognition): {'✅ Ready' if os.getenv('OPENAI_API_KEY') else '❌ Missing API Key'}
        - ElevenLabs (Voice Responses): {'✅ Ready' if os.getenv('ELEVENLABS_API_KEY') else '❌ Missing API Key'}
        """, elem_classes=["setup-status"])
    
    return demo

if __name__ == "__main__":
    demo = create_interface()
    demo.launch(
        share=True,
        inbrowser=True,
        show_error=True
    )