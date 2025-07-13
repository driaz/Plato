"""
ONE-FILE DEMO – Stoic Voice Chat with push-to-talk

• No external JS files
• Works on Gradio ≥ 4.28 (tested on 4.44.1)
• Desktop Chrome/Edge → blue button pulses while recording
• iOS Safari → falls back to native recorder sheet
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
ELEVENLABS_VOICE_ID = "21m00Tcm4TlvDq8ikWAM"  # Default voice, you can change this

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
    """Convert text to speech using ElevenLabs API"""
    if not ELEVENLABS_API_KEY:
        print("ElevenLabs API key not found")
        return None
    
    try:
        url = f"https://api.elevenlabs.io/v1/text-to-speech/{ELEVENLABS_VOICE_ID}"
        headers = {
            "Accept": "audio/mpeg",
            "Content-Type": "application/json",
            "xi-api-key": ELEVENLABS_API_KEY
        }
        data = {
            "text": text,
            "model_id": "eleven_monolingual_v1",
            "voice_settings": {
                "stability": 0.5,
                "similarity_boost": 0.5
            }
        }
        
        response = requests.post(url, json=data, headers=headers)
        
        if response.status_code == 200:
            # Save audio to temporary file
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
        # Transcribe audio using OpenAI Whisper
        downsampled_file = downsample(file)
        with open(downsampled_file, "rb") as audio_file:
            txt = client.audio.transcriptions.create(
                model="whisper-1",
                file=audio_file
            ).text
        
        if txt.strip():  # Only process if we got actual text
            ans = llm(txt, hist)
            hist.append((txt, ans))
            
            # Generate TTS if enabled
            audio_response = None
            if speak_enabled:
                audio_response = text_to_speech(ans)
            
            # Clean up temp file
            if os.path.exists(downsampled_file):
                os.remove(downsampled_file)
                
            return hist, audio_response
            
        # Clean up temp file
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
    
    # Generate TTS if enabled
    audio_response = None
    if speak_enabled:
        audio_response = text_to_speech(ans)
    
    return hist, "", audio_response

def toggle_audio_visibility(visible):
    return gr.Audio(visible=visible)

# ─── UI assets ──────────────────────────────────────────────────────
CSS = """
.audio-container {
    max-width: 400px;
    margin: 0 auto;
    padding: 20px;
    border: 2px solid #2563eb;
    border-radius: 15px;
    background: linear-gradient(135deg, #f0f9ff 0%, #e0f2fe 100%);
    box-shadow: 0 8px 25px rgba(37, 99, 235, 0.15);
}

.audio-container .wrap {
    background: white !important;
    border-radius: 10px !important;
    box-shadow: 0 4px 15px rgba(0, 0, 0, 0.1) !important;
}

.audio-container button {
    background: linear-gradient(135deg, #2563eb 0%, #1d4ed8 100%) !important;
    border: none !important;
    border-radius: 50px !important;
    color: white !important;
    font-weight: 600 !important;
    transition: all 0.3s ease !important;
    box-shadow: 0 4px 15px rgba(37, 99, 235, 0.3) !important;
}

.audio-container button:hover {
    transform: translateY(-2px) !important;
    box-shadow: 0 6px 20px rgba(37, 99, 235, 0.4) !important;
}

.recording-pulse {
    animation: pulse 1.5s infinite;
}

@keyframes pulse {
    0% { box-shadow: 0 0 0 0 rgba(37, 99, 235, 0.7); }
    70% { box-shadow: 0 0 0 20px rgba(37, 99, 235, 0); }
    100% { box-shadow: 0 0 0 0 rgba(37, 99, 235, 0); }
}

.quick-record-btn {
    background: linear-gradient(135deg, #059669 0%, #047857 100%) !important;
    border: none !important;
    border-radius: 50px !important;
    color: white !important;
    font-weight: 600 !important;
    padding: 12px 24px !important;
    margin: 10px 5px !important;
    cursor: pointer !important;
    transition: all 0.3s ease !important;
    box-shadow: 0 4px 15px rgba(5, 150, 105, 0.3) !important;
}

.quick-record-btn:hover {
    transform: translateY(-2px) !important;
    box-shadow: 0 6px 20px rgba(5, 150, 105, 0.4) !important;
}
"""

# ─── build interface ──────────────────────────────────────────────────
def create_interface():
    with gr.Blocks(title="Stoic Voice Chat", css=CSS) as demo:
        gr.Markdown("# 🏛️ Stoic Voice Chat")
        gr.Markdown("*Ancient wisdom for modern challenges. Speak or type to receive guidance from Stoic philosophy.*")
        
        chat = gr.Chatbot(height=400)
        
        # Text input row
        with gr.Row():
            txt = gr.Textbox(
                placeholder="Ask for wisdom or guidance...", 
                container=False, 
                scale=4,
                show_label=False
            )
        
        # Audio recording section
        with gr.Row():
            with gr.Column(scale=1):
                gr.Markdown("### 🎤 Voice Input")
                audio_input = gr.Audio(
                    sources=["microphone"],
                    type="filepath",
                    label="Record your question",
                    elem_classes=["audio-container"]
                )
        
        # Voice settings
        with gr.Row():
            speak_checkbox = gr.Checkbox(
                value=True, 
                label="🔊 Enable voice responses (ElevenLabs TTS)",
                info="Uncheck to disable AI voice responses"
            )
        
        # Audio output for TTS
        audio_output = gr.Audio(
            label="🎧 AI Voice Response",
            autoplay=True,
            visible=True
        )
        
        # Quick action buttons
        with gr.Row():
            gr.Markdown("### 💭 Quick Questions")
        
        with gr.Row():
            btn1 = gr.Button("How do I deal with stress?", elem_classes=["quick-record-btn"])
            btn2 = gr.Button("What would Marcus Aurelius say?", elem_classes=["quick-record-btn"])
            btn3 = gr.Button("How can I be more resilient?", elem_classes=["quick-record-btn"])
        
        with gr.Row():
            btn4 = gr.Button("Stoic view on anger?", elem_classes=["quick-record-btn"])
            btn5 = gr.Button("Finding peace in difficulty?", elem_classes=["quick-record-btn"])
        
        # Event handlers
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
        
        # Quick button handlers
        btn1.click(lambda: ("How do I deal with stress at work?", ""), outputs=[txt, txt]).then(
            handle_text, inputs=[txt, chat, speak_checkbox], outputs=[chat, txt, audio_output]
        )
        btn2.click(lambda: ("What would Marcus Aurelius say about failure?", ""), outputs=[txt, txt]).then(
            handle_text, inputs=[txt, chat, speak_checkbox], outputs=[chat, txt, audio_output]
        )
        btn3.click(lambda: ("How can I be more resilient in the face of adversity?", ""), outputs=[txt, txt]).then(
            handle_text, inputs=[txt, chat, speak_checkbox], outputs=[chat, txt, audio_output]
        )
        btn4.click(lambda: ("What is the Stoic view on dealing with anger?", ""), outputs=[txt, txt]).then(
            handle_text, inputs=[txt, chat, speak_checkbox], outputs=[chat, txt, audio_output]
        )
        btn5.click(lambda: ("How do I find peace in difficult times?", ""), outputs=[txt, txt]).then(
            handle_text, inputs=[txt, chat, speak_checkbox], outputs=[chat, txt, audio_output]
        )
        
        # Instructions
        gr.Markdown("""
        ---
        **How to use:**
        - 💬 **Type** your question in the text box above
        - 🎤 **Record** your question using the microphone (uses OpenAI Whisper for transcription)
        - 🔘 **Quick questions** - click any button below for instant wisdom
        - 🔊 **Voice responses** - toggle the checkbox to enable/disable AI voice responses (ElevenLabs TTS)
        - 🏛️ **Get guidance** from Marcus Aurelius, Epictetus, and Seneca
        
        **Setup Required:**
        - Set `OPENAI_API_KEY` environment variable for Whisper transcription
        - Set `ELEVENLABS_API_KEY` environment variable for voice responses
        """)
        
        # Add environment variable check
        gr.Markdown(f"""
        **Current Setup:**
        - OpenAI API: {'✅ Configured' if os.getenv('OPENAI_API_KEY') else '❌ Missing OPENAI_API_KEY'}
        - ElevenLabs API: {'✅ Configured' if os.getenv('ELEVENLABS_API_KEY') else '❌ Missing ELEVENLABS_API_KEY (voice responses disabled)'}
        """)
    
    return demo

if __name__ == "__main__":
    demo = create_interface()
    demo.launch(share=True)  # remove share=True if you only need local