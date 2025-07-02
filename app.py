import os, json, random, tempfile
from pathlib import Path
from typing import List, Tuple

import gradio as gr
from dotenv import load_dotenv
from openai import OpenAI

# ── ENV ----------------------------------------------------------------------
load_dotenv()
client = OpenAI(api_key=os.getenv("OPENAI_API_KEY"))
MODEL = os.getenv("OPENAI_MODEL", "gpt-4o-mini")
TTS_MODEL = os.getenv("OPENAI_TTS_MODEL", "tts-1")  # or tts-1-hd
VOICE = os.getenv("OPENAI_TTS_VOICE", "alloy")      # alloy, echo, fable, onyx, nova, shimmer

# ── QUOTES -------------------------------------------------------------------
QUOTES_PATH = Path("data/quotes.json")
if QUOTES_PATH.exists():
    QUOTES: List[dict] = json.loads(QUOTES_PATH.read_text())
else:
    QUOTES = []

SYSTEM_PROMPT = (
    "You are a concise Stoic chatbot who often cites classical philosophers and poets."
)

# ── HELPERS ------------------------------------------------------------------

def maybe_insert_quote(text: str, p: float = 0.3) -> str:
    if QUOTES and random.random() < p:
        q = random.choice(QUOTES)
        return f"{text}\n\n> \"{q['text']}\" — {q['author']}"
    return text


def llm_reply(msg: str, history: List[Tuple[str, str]]):
    messages = [{"role": "system", "content": SYSTEM_PROMPT}]
    for u, a in history:
        messages += [{"role": "user", "content": u}, {"role": "assistant", "content": a}]
    messages.append({"role": "user", "content": msg})

    resp = client.chat.completions.create(model=MODEL, messages=messages, temperature=0.7)
    ans = resp.choices[0].message.content.strip()
    return maybe_insert_quote(ans)


def text_to_speech(text: str) -> str:
    speech = client.audio.speech.create(model=TTS_MODEL, voice=VOICE, input=text)
    fd, path = tempfile.mkstemp(suffix=".mp3")
    speech.stream_to_file(path)
    return path

# ── GRADIO UI ----------------------------------------------------------------
chatbox = gr.Chatbot()
text_input = gr.Textbox(placeholder="Type a question…", show_label=False)
audio_input = gr.Audio(sources=["microphone"], type="filepath", label="or Speak")
speak_back = gr.Checkbox(value=True, label="Read answer aloud (OpenAI TTS)")
tts_audio = gr.Audio(label="Assistant Voice", autoplay=True, interactive=False)

# ── Handlers ────────────────────────────────────────────────────────────────
def handle_text(msg, history, speak):
    history = history or []
    ans = llm_reply(msg, history)
    history.append((msg, ans))

    audio_update = None
    if speak:
        audio_path = text_to_speech(ans)
        audio_update = gr.update(value=audio_path, autoplay=True)

    return history, audio_update


def handle_audio(file, history, speak):
    history = history or []
    if not file:
        return history, None

    with open(file, "rb") as f:
        transcript = client.audio.transcriptions.create(
            model="whisper-1",
            file=f,
        ).text

    ans = llm_reply(transcript, history)
    history.append((transcript, ans))

    audio_update = None
    if speak:
        audio_path = text_to_speech(ans)
        audio_update = gr.update(value=audio_path, autoplay=True)

    return history, audio_update

with gr.Blocks(title="Stoic Voice Chat") as demo:
    gr.Markdown("# ✨ Stoic Voice Chat (OpenAI Whisper + TTS)")
    chatbox.render()
    with gr.Row():
        text_input.render()
        audio_input.render()
    speak_back.render()
    tts_audio.render()

# ── Event wiring (keep ONLY these two) ──────────────────────────────────────
    text_input.submit(
        fn=handle_text,
        inputs=[text_input, chatbox, speak_back],
        outputs=[chatbox, tts_audio],
    )

    audio_input.change(
        fn=handle_audio,
        inputs=[audio_input, chatbox, speak_back],
        outputs=[chatbox, tts_audio],
    )

if __name__ == "__main__":
    demo.launch()
