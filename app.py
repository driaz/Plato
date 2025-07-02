import os
import gradio as gr
import openai
from dotenv import load_dotenv

load_dotenv()
openai.api_key = os.getenv("OPENAI_API_KEY")

SYSTEM_PROMPT = (
    "You are a voice-ready Stoic chatbot. "
    "Respond concisely, often citing Marcus Aurelius, Seneca, or Epictetus."
)

def chat(user_message, history=None):
    history = history or []
    messages = [{"role": "system", "content": SYSTEM_PROMPT}]
    for user, bot in history:
        messages.append({"role": "user", "content": user})
        messages.append({"role": "assistant", "content": bot})
    messages.append({"role": "user", "content": user_message})

    response = openai.ChatCompletion.create(
        model="gpt-4o-mini",
        messages=messages,
        temperature=0.7,
    )["choices"][0]["message"]["content"]

    history.append((user_message, response))
    return history, history

with gr.Blocks() as demo:
    gr.Markdown("# ✨ Stoic Chat (Week‑1 MVP)")
    chatbox = gr.Chatbot()
    txt = gr.Textbox(placeholder="Ask your question…")
    txt.submit(chat, [txt, chatbox], [chatbox, chatbox]).then(lambda: "", None, txt)

if __name__ == "__main__":
    demo.launch()
