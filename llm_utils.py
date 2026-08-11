from typing import Optional

from google import genai
import ollama
import requests
import os

from classes import Character



def _is_server_running(url: str) -> bool:
    try:
        return requests.get(url, timeout=1).status_code == 200
    except Exception:
        return False

def start_ollama(url: str = "http://127.0.0.1:11434/v1/models", cpu_only: bool = False):

    import subprocess
    import time
    import atexit
    import os

    # Skip startup if the server is already running
    if _is_server_running(url):
        return

    # --- 1. Start Ollama server ---
    server_cmd = ["ollama", "serve"]
    env = os.environ.copy()
    env["OLLAMA_KEEP_ALIVE"] = "-1"  # keep models loaded indefinitely
    if cpu_only:
        env["OLLAMA_NUM_GPU"] = "0"
        env["OLLAMA_LLM_LIBRARY"] = "cpu"
    server_proc = subprocess.Popen(
        server_cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env,
    )

    # Ensure server is terminated on exit
    atexit.register(lambda: server_proc.terminate())

    # --- 2. Wait for server to be ready ---
    def wait_for_server(url=url, timeout=30):
        start = time.time()
        while time.time() - start < timeout:
            try:
                resp = requests.get(url)
                if resp.status_code == 200:
                    print("Ollama server ready!")
                    return True
            except requests.exceptions.ConnectionError:
                pass
            time.sleep(1)
        raise RuntimeError("Ollama server did not start in time")

    wait_for_server()

    # --- 3. Use the model ---
    # Pull model if needed
    # subprocess.run(["ollama", "pull", "llama3:3b"])


#start_ollama(url="http://127.0.0.1:11434/v1/models")



# --- 4. The server will auto-close on exit via atexit ---


def answer_to_prompt(prompt: str, model_name: str) -> str:
    if "gemini" in model_name.lower():
        api_key = os.environ.get("GEMINI_API_KEY")
        client = genai.Client(api_key=api_key)

        response = client.models.generate_content(
            model="gemini-flash-latest",
            contents=prompt
        )
        return response.text
    else:
        start_ollama(url="http://127.0.0.1:11434/v1/models", cpu_only=False)
        response = ollama.chat(
            model=model_name,
            messages=[{"role": "user", "content": prompt}]
        )
        return response['message']['content']


def check_plausibility(text: str, model_name: str) -> str:

    return answer_to_prompt("Check whether the following text is plausible (answer in the language the text is written in):\n\n" + text, model_name)

def custom_prompt_about_text(text: str, custom_prompt: str, model_name: str, log_chat_to: Optional[str] = None) -> str:

    answer = answer_to_prompt(custom_prompt + "\n\n" + text, model_name)
    if log_chat_to:
        os.makedirs(os.path.dirname(log_chat_to), exist_ok=True)
        with open(log_chat_to, "a", encoding="utf-8") as f:
            f.write(f"---\nPrompt:\n{custom_prompt}\n\nAnswer:\n{answer}\n")

    return answer


def chat_custom_prompt(text: str, user_prompt: str, model_name: str, history: list, characters: list[Character]) -> str:
    """Multi-turn chat. history = [{role:'user'|'assistant', content:str}].
    Text context is injected into the new user turn only."""
    system_text = ("The following characters are present in the story: "
                   + ", ".join([f"{c.name} ({c.description})" for c in characters])) if characters else None
    new_user_content = f"{user_prompt}\n\n[Text context]\n{text}" if text.strip() else user_prompt

    if "gemini" in model_name.lower():
        api_key = os.environ.get("GEMINI_API_KEY")
        client = genai.Client(api_key=api_key)
        contents = []
        for msg in history:
            role = "user" if msg["role"] == "user" else "model"
            contents.append({"role": role, "parts": [{"text": msg["content"]}]})
        contents.append({"role": "user", "parts": [{"text": new_user_content}]})
        kwargs = {"model": "gemini-flash-latest", "contents": contents}
        if system_text:
            from google.genai import types
            kwargs["config"] = types.GenerateContentConfig(system_instruction=system_text)
            print("System instruction:", system_text)
        response = client.models.generate_content(**kwargs)
        return response.text
    else:
        start_ollama(url="http://127.0.0.1:11434/v1/models", cpu_only=False)
        messages = []
        if system_text:
            messages.append({"role": "system", "content": system_text})
        for m in history:
            messages.append({"role": m["role"], "content": m["content"]})
        messages.append({"role": "user", "content": new_user_content})
        response = ollama.chat(model=model_name, messages=messages)
        return response["message"]["content"]

