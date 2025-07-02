import os
from typing import List, Tuple
import gradio as gr
from dotenv import load_dotenv
from openai import OpenAI

load_dotenv()
client = OpenAI(api_key=os.getenv("OPENAI_API_KEY"))

SYSTEM_PROMPT = (
    "You are a voice-ready Stoic chatbot. "
    "Respond concisely, often citing Marcus Aurelius, Seneca, or Epictetus."
)


def chat_fn(message: str, history: List[Tuple[str, str]]):
    messages = [{"role": "system", "content": SYSTEM_PROMPT}]
    for user, assistant in history:
        messages.append({"role": "user", "content": user})
        messages.append({"role": "assistant", "content": assistant})
    messages.append({"role": "user", "content": message})

    response = client.chat.completions.create(
        model="gpt-4o-mini",
        messages=messages,
        temperature=0.7,
    )
    return response.choices[0].message.content


demo = gr.ChatInterface(
    fn=chat_fn,
    title="✨ Stoic Chat (Week-1 MVP)",
    chatbot=gr.Chatbot(),
    textbox=gr.Textbox(placeholder="Ask your question…", show_label=False),
)

if __name__ == "__main__":
    demo.launch()
