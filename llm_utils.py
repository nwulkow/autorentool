from typing import Optional

import concurrent.futures
import re
import time

from google import genai
from google.genai import types as genai_types
import httpx
import ollama
import requests
import os

from classes import Character


# ── Gemini model catalogue ────────────────────────────────────────────────────
# The model list is fetched live from ListModels rather than hardcoded: Google
# ships (and retires) models faster than this repo gets touched, and a stale
# constant here shows the user models that 404. The static lists below are only
# the offline fallback and the sort seed.

GEMINI_DEFAULT_MODEL = "gemini-flash-latest"

# Tried in order when the picked model is unavailable. Deliberately the moving
# aliases: Google keeps them pointed at a live model, so this chain can't rot
# the way pinned version names do.
GEMINI_FALLBACK_MODELS = ["gemini-flash-latest", "gemini-pro-latest", "gemini-flash-lite-latest"]

_GEMINI_STATIC_MODELS = ["gemini-flash-latest", "gemini-pro-latest", "gemini-flash-lite-latest"]

_MODELS_URL = "https://generativelanguage.googleapis.com/v1beta/models"

# ListModels returns everything the key may call, most of which is not a text
# chat model (image/audio/video generation, robotics, agentic research
# endpoints). Substring matching so new members of those families are excluded
# on arrival instead of needing another edit here.
_MODEL_EXCLUDE = (
    "image", "banana", "tts", "audio", "omni", "live", "robotics",
    "computer-use", "deep-research", "antigravity", "embedding", "aqa",
    "veo", "imagen", "lyria", "customtools",
)

# Anything older than this is deprecated (2.5 and below) and stays out of the
# picker. Aliases without a version number in the name are always kept.
_MIN_GEMINI_VERSION = 3.0

_models_cache: tuple[float, list[str]] = (0.0, [])
_MODELS_CACHE_TTL = 600  # seconds


def _gemini_version(name: str) -> Optional[float]:
    m = re.match(r"gemini-(\d+(?:\.\d+)?)", name)
    return float(m.group(1)) if m else None


def _is_usable_gemini_model(name: str) -> bool:
    if not name.startswith("gemini-"):
        return False
    if any(bad in name for bad in _MODEL_EXCLUDE):
        return False
    version = _gemini_version(name)
    return version is None or version >= _MIN_GEMINI_VERSION


def _model_sort_key(name: str):
    """Aliases first (they always resolve), then newest version, then stable
    before preview, then alphabetically."""
    version = _gemini_version(name)
    return (
        0 if version is None else 1,
        -(version or 0),
        1 if "preview" in name else 0,
        name,
    )


def list_gemini_models(force: bool = False) -> list[str]:
    """Text-capable Gemini models this API key can call, newest first.
    Cached for `_MODELS_CACHE_TTL` — the picker is re-fetched on every page
    load and the catalogue changes on the order of weeks. Falls back to the
    static alias list when the key is missing or the call fails, so the UI
    always has something selectable."""
    global _models_cache
    cached_at, cached = _models_cache
    if not force and cached and time.time() - cached_at < _MODELS_CACHE_TTL:
        return cached

    api_key = os.environ.get("GEMINI_API_KEY")
    if not api_key:
        return list(_GEMINI_STATIC_MODELS)
    try:
        resp = requests.get(_MODELS_URL, params={"key": api_key, "pageSize": 200}, timeout=10)
        resp.raise_for_status()
        names = []
        for m in resp.json().get("models", []):
            if "generateContent" not in m.get("supportedGenerationMethods", []):
                continue
            name = m.get("name", "").replace("models/", "")
            if _is_usable_gemini_model(name):
                names.append(name)
        if not names:
            return list(_GEMINI_STATIC_MODELS)
        names.sort(key=_model_sort_key)
        _models_cache = (time.time(), names)
        return names
    except Exception as e:
        print(f"[LLM] Gemini model list failed: {e}")
        return list(_GEMINI_STATIC_MODELS)


def _model_chain(model_name: str, fallbacks: Optional[list] = None) -> list[str]:
    """The model to try plus its fallbacks, de-duplicated, order preserved."""
    chain = [model_name] + list(GEMINI_FALLBACK_MODELS if fallbacks is None else fallbacks)
    seen, out = set(), []
    for m in chain:
        if m and m not in seen:
            seen.add(m)
            out.append(m)
    return out


def _is_retryable(exc: Exception) -> bool:
    """True for "this model isn't answering right now" — unknown/retired model
    (404), quota (429), overloaded/outage (5xx), network trouble or a stalled
    connection. A bad API key or a malformed request (401/403/400) is *not*
    retryable: every fallback would fail the same way, so failing fast beats
    three timeouts."""
    if isinstance(exc, (requests.exceptions.RequestException, TimeoutError,
                         httpx.TimeoutException, httpx.ConnectError)):
        return True
    code = getattr(exc, "code", None) or getattr(exc, "status_code", None)
    if isinstance(code, int):
        return code in (404, 408, 409, 429) or code >= 500
    text = str(exc)
    return any(s in text for s in ("404", "429", "500", "502", "503", "504",
                                   "NOT_FOUND", "RESOURCE_EXHAUSTED", "UNAVAILABLE",
                                   "overloaded", "INTERNAL"))


# Per-call timeout, enforced two ways. HttpOptions bounds ordinary HTTP-level
# slowness (a model that's overloaded and slow to answer). The
# ThreadPoolExecutor wall-clock timeout below is the real backstop: testing
# against the live API turned up requests that hang inside the connect()
# syscall — before any httpx/HTTP timeout logic even runs — and no amount of
# client configuration cancels a blocked socket syscall. Wrapping the call in
# a thread we simply stop waiting on (the thread itself is abandoned, not
# killed — Python has no safe way to do that — but the request handler moves
# on to the next model instead of hanging with it) turns a hang into a bounded
# wait no matter which layer it's stuck in.
_GEMINI_TIMEOUT_MS = 20_000
_GEMINI_CALL_TIMEOUT_S = 25


def _gemini_generate(contents, model_name: str, system_text: Optional[str] = None,
                     fallbacks: Optional[list] = None) -> tuple[str, str]:
    """Run one generateContent call, walking the fallback chain until a model
    answers. Returns (text, model_actually_used) so callers can tell the user
    their pick was substituted."""
    api_key = os.environ.get("GEMINI_API_KEY")
    client = genai.Client(api_key=api_key, http_options=genai_types.HttpOptions(timeout=_GEMINI_TIMEOUT_MS))
    kwargs = {"contents": contents}
    if system_text:
        kwargs["config"] = genai_types.GenerateContentConfig(system_instruction=system_text)

    last_error: Optional[Exception] = None
    for model in _model_chain(model_name, fallbacks):
        executor = concurrent.futures.ThreadPoolExecutor(max_workers=1)
        try:
            future = executor.submit(client.models.generate_content, model=model, **kwargs)
            try:
                response = future.result(timeout=_GEMINI_CALL_TIMEOUT_S)
            except concurrent.futures.TimeoutError as e:
                last_error = e
                print(f"[LLM] {model} timed out after {_GEMINI_CALL_TIMEOUT_S}s; trying next model")
                continue
            if not response.text:
                raise RuntimeError(f"{model} returned no text")
            return response.text, model
        except Exception as e:
            last_error = e
            if not _is_retryable(e):
                raise
            print(f"[LLM] {model} unavailable ({e}); trying next model")
        finally:
            executor.shutdown(wait=False)
    raise RuntimeError(f"No Gemini model answered. Last error: {last_error}")



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


def answer_to_prompt(prompt: str, model_name: str, fallbacks: Optional[list] = None) -> tuple[str, str]:
    """Returns (answer, model_actually_used) — the second element differs from
    `model_name` when the pick was unavailable and a fallback answered."""
    if "gemini" in model_name.lower():
        return _gemini_generate(prompt, model_name, fallbacks=fallbacks)
    else:
        start_ollama(url="http://127.0.0.1:11434/v1/models", cpu_only=False)
        response = ollama.chat(
            model=model_name,
            messages=[{"role": "user", "content": prompt}]
        )
        return response['message']['content'], model_name


def check_plausibility(text: str, model_name: str, fallbacks: Optional[list] = None) -> tuple[str, str]:

    return answer_to_prompt("Check whether the following text is plausible (answer in the language the text is written in):\n\n" + text, model_name, fallbacks)

def custom_prompt_about_text(text: str, custom_prompt: str, model_name: str, log_chat_to: Optional[str] = None,
                             fallbacks: Optional[list] = None) -> tuple[str, str]:

    answer, model_used = answer_to_prompt(custom_prompt + "\n\n" + text, model_name, fallbacks)
    if log_chat_to:
        os.makedirs(os.path.dirname(log_chat_to), exist_ok=True)
        with open(log_chat_to, "a", encoding="utf-8") as f:
            f.write(f"---\nPrompt:\n{custom_prompt}\n\nAnswer:\n{answer}\n")

    return answer, model_used


def chat_custom_prompt(text: str, user_prompt: str, model_name: str, history: list, characters: list[Character],
                       fallbacks: Optional[list] = None) -> tuple[str, str]:
    """Multi-turn chat. history = [{role:'user'|'assistant', content:str}].
    Text context is injected into the new user turn only.
    Returns (answer, model_actually_used)."""
    system_text = ("The following characters are present in the story: "
                   + ", ".join([f"{c.name} ({c.description})" for c in characters])) if characters else None
    new_user_content = f"{user_prompt}\n\n[Text context]\n{text}" if text.strip() else user_prompt

    if "gemini" in model_name.lower():
        contents = []
        for msg in history:
            role = "user" if msg["role"] == "user" else "model"
            contents.append({"role": role, "parts": [{"text": msg["content"]}]})
        contents.append({"role": "user", "parts": [{"text": new_user_content}]})
        return _gemini_generate(contents, model_name, system_text=system_text, fallbacks=fallbacks)
    else:
        start_ollama(url="http://127.0.0.1:11434/v1/models", cpu_only=False)
        messages = []
        if system_text:
            messages.append({"role": "system", "content": system_text})
        for m in history:
            messages.append({"role": m["role"], "content": m["content"]})
        messages.append({"role": "user", "content": new_user_content})
        response = ollama.chat(model=model_name, messages=messages)
        return response["message"]["content"], model_name

