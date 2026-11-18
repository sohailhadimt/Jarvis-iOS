#!/usr/bin/env python3
"""Creates (or updates) the in-app JARVIS voice agent on ElevenLabs.

Reads ELEVENLABS_API_KEY from the environment. Never prints it. Prints the agent id only.
The agent requires a signed URL (auth on), outputs 24 kHz PCM, and ends idle sessions
quickly so Starter-plan minutes are not wasted. Client tools run on the phone.

Usage: python3 -I scripts/provision-eleven-agent.py [existing_agent_id]
"""
import json, os, sys, urllib.request, urllib.error

KEY = os.environ["ELEVENLABS_API_KEY"]
BASE = "https://api.elevenlabs.io/v1/convai"
GEORGE = "JBFqnCBsd6RMkjVDRZzb"


def call(method, path, body=None):
    req = urllib.request.Request(BASE + path, method=method, data=json.dumps(body).encode() if body is not None else None,
                                 headers={"xi-api-key": KEY, "content-type": "application/json", "user-agent": "curl/8"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        print("HTTP", e.code, e.read().decode()[:600], file=sys.stderr)
        raise SystemExit(1)


def s(desc): return {"type": "string", "description": desc}
def n(desc): return {"type": "number", "description": desc}
def b(desc): return {"type": "boolean", "description": desc}

ISO = "Local date-time, ISO 8601, e.g. 2026-11-15T14:30"
TOOLS = {
    "contacts_search": ("Search the user's contacts by name. Returns names and phone numbers.", {"query": s("Name or part of a name")}, ["query"]),
    "send_imessage_or_sms": ("Prepare an iMessage/SMS with the body prefilled. The user taps Send.", {"contact_name": s("Contact name"), "phone_number": s("Number if no contact"), "body": s("Message text")}, ["body"]),
    "whatsapp_message": ("Open WhatsApp with a prefilled message. The user taps Send.", {"contact_name": s("Contact name"), "phone_number": s("Number if no contact"), "body": s("Message text")}, ["body"]),
    "send_email": ("Prepare an email in Mail. The user taps Send.", {"contact_name": s("Contact name"), "email": s("Address if no contact"), "subject": s("Subject"), "body": s("Body")}, ["body"]),
    "maps_directions": ("Open Apple Maps with directions.", {"destination": s("Address or place"), "mode": s("driving, walking, transit or cycling")}, ["destination"]),
    "play_music": ("Play music from the user's library, or control playback.", {"query": s("Song, artist or album"), "action": s("play, pause, resume, next or previous")}, []),
    "set_timer": ("Start a timer.", {"duration_seconds": n("Length in seconds"), "label": s("Optional label")}, ["duration_seconds"]),
    "set_alarm": ("Set an alarm.", {"time": s("24h HH:mm"), "label": s("Optional label")}, ["time"]),
    "calendar_list_events": ("List calendar events.", {"start": s(ISO), "days": n("How many days, default 1")}, []),
    "calendar_create_event": ("Create a calendar event.", {"title": s("Title"), "start": s(ISO), "end": s(ISO), "location": s("Location"), "notes": s("Notes")}, ["title", "start"]),
    "reminders_list": ("List reminders.", {"include_completed": b("Include completed")}, []),
    "reminder_create": ("Create a reminder.", {"title": s("Title"), "due": s(ISO), "notes": s("Notes")}, ["title"]),
    "web_search": ("Search the web for current facts, news, prices, weather, sport, opening times.", {"query": s("The question to research")}, ["query"]),
    "create_cloud_task": ("Create a background task on JARVIS Cloud. It is planned on the backend and nothing is sent, published or paid without approval.", {"goal": s("What the cloud should do"), "schedule": s("Optional 5-field UTC cron for a routine. Omit to run once.")}, ["goal"]),
    "get_briefing": ("Read the stored JARVIS Cloud briefing. Speak facts first, then recommendations.", {}, []),
    "list_tasks": ("List background and scheduled tasks.", {"status": s("planning, running, awaiting_approval, completed or failed")}, []),
    "get_task": ("Read one task, with progress and findings.", {"task_id": s("Task id from list_tasks")}, ["task_id"]),
    "list_approvals": ("List pending approvals.", {"status": s("pending, approved or rejected")}, []),
    "search_memory": ("Search stored memory.", {"query": s("Substring to search")}, []),
    "save_memory": ("Store one fact in memory.", {"content": s("Fact to store"), "key": s("Optional key"), "tags": s("Optional comma-separated tags")}, ["content"]),
    "pipeline_summary": ("Summarise the stored sales pipeline.", {}, []),
    "place_outbound_call": ("Place a call from the JARVIS Twilio number. Nothing is dialled until the user taps Approve. Do not say it is ringing until the result says so.", {"to": s("Phone number"), "contact_name": s("Who is being called"), "brief": s("What to say. Start with Ask them, Tell them, or Book.")}, ["to", "brief"]),
    "shop_around": ("Draft a shop-around list of businesses. Nothing is rung until the user taps Approve.", {"goal": s("What to shop for"), "providers": s("Optional business names and numbers")}, ["goal"]),
    "send_sms": ("Send an SMS from the JARVIS number. Nothing is sent until the user taps Approve.", {"to": s("Destination number"), "contact_name": s("Who it is for"), "body": s("Message text")}, ["to", "body"]),
}

PROMPT = ("You are J.A.R.V.I.S., Master Hadi's personal AI chief of staff, speaking aloud on his iPhone. "
          "Calm, refined British voice; precise, discreet, lightly dry-witted. Address him as Sir. "
          "Speak one to three short sentences, no markdown or lists. Act decisively: when asked to do something, "
          "use the right tool at once instead of asking permission. Calls, texts and anything sent wait for his Approve "
          "tap on the phone; never claim they happened until the tool result says so. Never invent facts.")


def main():
    existing = sys.argv[1] if len(sys.argv) > 1 else None
    have = {t["tool_config"]["name"]: t["id"] for t in call("GET", "/tools?page_size=100").get("tools", [])
            if t.get("tool_config", {}).get("type") == "client"} if True else {}
    ids = []
    for name, (desc, props, req) in TOOLS.items():
        cfg = {"type": "client", "name": name, "description": desc, "expects_response": True, "response_timeout_secs": 25,
               "parameters": {"type": "object", "required": req, "properties": props} if props else None}
        if not props: cfg.pop("parameters")
        body = {"tool_config": cfg}
        if name in have:
            call("PATCH", "/tools/" + have[name], body); ids.append(have[name])
        else:
            ids.append(call("POST", "/tools", body)["id"])
    conv = {
        "agent": {"first_message": "", "language": "en", "prompt": {"prompt": PROMPT, "llm": "gemini-2.5-flash", "tool_ids": ids}},
        "tts": {"voice_id": GEORGE, "model_id": "eleven_flash_v2", "agent_output_audio_format": "pcm_24000",
                "optimize_streaming_latency": 3, "stability": 0.5, "similarity_boost": 0.75},
        "asr": {"user_input_audio_format": "pcm_16000"},
        "turn": {"turn_timeout": 8, "turn_eagerness": "eager", "silence_end_call_timeout": 45},
        "conversation": {"max_duration_seconds": 600, "client_events": ["audio", "interruption", "user_transcript", "agent_response", "agent_response_correction", "client_tool_call"]},
    }
    platform = {"auth": {"enable_auth": True},
                "overrides": {"conversation_config_override": {"agent": {"first_message": True, "language": False, "prompt": {"prompt": True}}, "tts": {"voice_id": True}}}}
    body = {"name": "JARVIS App Voice", "conversation_config": conv, "platform_settings": platform}
    if existing:
        call("PATCH", "/agents/" + existing, body); print(existing)
    else:
        print(call("POST", "/agents/create", body)["agent_id"])

main()
