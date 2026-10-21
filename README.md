# JARVIS for iPhone

A personal voice assistant: you talk, Groq Whisper (or Apple's on-device speech recognition) turns it into text on your phone, Gemini, Groq or OpenAI writes the reply, and ElevenLabs (or the built-in iPhone voice) speaks it. It has a glowing orb, a Live Activity / Dynamic Island, Action Button support, and a bedside "StandBy" mode.

No passwords or API keys are stored in this code. You type them into the app, and it keeps them in the iPhone Keychain.

---

## 1. What you need

| Thing | Cost | Notes |
|---|---|---|
| A Mac with **Xcode 16 or newer** (Mac App Store) | Free | Xcode 26 is fine too. |
| **Homebrew** (https://brew.sh) | Free | Used to install XcodeGen. |
| An **Apple ID** | Free | Enough to put the app on your own iPhone. |
| iPhone on **iOS 18 or newer** | – | Action Button needs iPhone 15 Pro or later. Dynamic Island needs iPhone 14 Pro or later. |
| Gemini API key | Free | [aistudio.google.com/apikey](https://aistudio.google.com/apikey). Default model `gemini-3.8-flash`. |
| Groq API key | Free | [console.groq.com/keys](https://console.groq.com/keys). Default model `llama-3.3-70b-versatile`. Also used for speech-to-text. |
| OpenAI API key | Pay as you go | platform.openai.com > API keys. Optional if Gemini or Groq is saved. |
| ElevenLabs API key | Optional | elevenlabs.io > Profile > API Keys. Without it, the iPhone's own voice is used. |

**Free vs paid Apple account:** with a free Apple ID, apps you install **stop opening after 7 days**. To fix that, plug the phone in and press Run in Xcode again. The **$99/year Apple Developer Program** is only needed for TestFlight, the App Store, or apps that last a year. A free account may also refuse the **App Groups** capability (see Troubleshooting). The app still works without it. The StandBy widget's "last reply" text and the Action Button control's on/off state stop updating.

## 2. Create the Xcode project

The project file is generated from `project.yml` using XcodeGen. In Terminal:

```bash
brew install xcodegen
cd path/to/jarvis-ios
xcodegen
open JARVIS.xcodeproj
```

## 3. Signing (one-time setup)

1. In Xcode, sign in with your Apple ID: **Xcode > Settings > Accounts > +**.
2. Click the blue **JARVIS** project icon at the top of the left sidebar.
3. Select the **JARVIS** target, open the **Signing & Capabilities** tab, tick **Automatically manage signing**, and choose your **Team** (it shows as "Your Name (Personal Team)").
4. Bundle IDs must be unique worldwide. If Xcode says `com.sohail.jarvis` is taken, change it to something like `com.sohailhadi.jarvis`. Then select the **JARVISWidgets** target, choose the same Team, and set its bundle ID to **the same prefix plus `.widgets`** (for example `com.sohailhadi.jarvis.widgets`).
5. App Group: both targets list `group.com.sohail.jarvis`. If you changed the bundle ID, change the group in both targets to match (for example `group.com.sohailhadi.jarvis`), **and** update `appGroup` in `Shared/SharedConfig.swift`.

Tip: you can instead put your Team ID into `DEVELOPMENT_TEAM` in `project.yml` and run `xcodegen` again.

## 4. Run it on your iPhone

1. Connect the iPhone with a cable and unlock it. Tap **Trust** if it asks.
2. On the iPhone, turn on **Settings > Privacy & Security > Developer Mode**. The phone restarts.
3. In Xcode, choose your iPhone at the top of the window, then press **▶ Run**.
4. The first time, the iPhone may block the app. Go to **Settings > General > VPN & Device Management**, tap your Apple ID, and tap **Trust**.
5. In the app, allow **Microphone** and **Speech Recognition** when asked.

## 5. Enter your keys

In the app, tap ⚙️ **Settings > API Keys & Provider**:
- Choose **AI Provider**: OpenAI, Gemini, Groq, or a custom endpoint.
- **Gemini** (free): paste a key from aistudio.google.com/apikey. The model defaults to `gemini-3.8-flash`.
- **Groq** (free): paste a key from console.groq.com/keys. The model defaults to `llama-3.3-70b-versatile`. With a Groq key saved, speech-to-text uses Groq Whisper. Without one, the iPhone's on-device speech recognition is used.
- **OpenAI** is optional. Paste a key if you have credit. The model defaults to `gpt-4o-mini`.
- If the provider you picked has no key, JARVIS uses another saved key (Gemini, then Groq, then OpenAI).
- Optionally paste your **ElevenLabs** key, then go to **Voices** to pick a voice, preview it, and adjust Stability and Similarity.
- **Custom agent endpoint** is an optional slot for any OpenAI-compatible service: a base URL (for example `https://host/v1`), a bearer key, and a model name.
- Tap **Save keys to Keychain**. Personality, instructions and memory are sent to whichever provider answers.

Other settings:
- **Personality** has presets (J.A.R.V.I.S. butler, Concise, Friendly) and a fully editable prompt.
- **Instructions** are standing rules.
- **Memory** is a list of facts. You can add, edit, or swipe to delete them. With "auto-save" on, JARVIS adds facts by itself using a hidden `REMEMBER:` line.
- **Appearance** has colour wheels for the orb and accent colours. Reset restores navy, cyan, and gold.

## 6. Using it

- **Hold the mic button** to talk, and let go to send (push-to-talk).
- **Converse** starts hands-free mode: it listens, replies, and listens again. Tap **End** to stop.
- The moon button opens the **StandBy view**.

## 7. Assign the Action Button

The control is in the Action Button's **Controls** list.

1. Run the app and start a session once, then allow **Microphone** and **Speech Recognition**. iOS can only show those prompts while JARVIS is on screen, so the first session has to start from the app (hold the mic, tap Converse, or say the phrase below).
2. Say **Hey Siri, JARVIS** or **Hey Siri, Talk to JARVIS**. JARVIS opens and starts listening.
3. Open the iPhone **Settings > Action Button**, swipe to **Controls**, tap the control, and search **Talk to JARVIS**. Pressing the Action Button uses that same intent: the app opens straight into listening.
4. The **JARVIS** toggle is still there. It starts a session in the Dynamic Island without opening the app. Press it again to end that session. The red stop button on the Live Activity ends it too.

You can also say "Hey Siri, Toggle JARVIS". Lock Screen widgets (circular, rectangular, inline) open listening when tapped. The Home Screen widget still opens StandBy.

## 8. StandBy

- **In-app StandBy view:** put the phone on charge and turn it sideways (landscape) with JARVIS open. The screen goes black with a large orb. Tap the orb to talk, or tap ∞ for a continuous conversation. You can turn this off in Appearance.
- **iOS StandBy widget:** iOS StandBy (charging, landscape, locked) only shows **widgets and Live Activities**, not full apps. To add the widget: lock the phone, put it on charge in landscape, long-press the StandBy widget stack, tap **+**, and add **JARVIS**. On the Home Screen, tapping it opens the in-app StandBy view. On the Lock Screen, tapping the circular, rectangular, or inline widget opens JARVIS listening. Control Center has **Talk to JARVIS** (opens listening) and **JARVIS** (Dynamic Island toggle). Both need iOS 18.

## 9. Talking to other apps (tools)

When you ask JARVIS to *do* something, the AI model chooses a "tool" and the app carries it out. You set this up in **Settings > Integrations & Task agent**.

**Routing (the Task agent setting)**
- *Questions → ChatGPT, actions → tools* (the default). A quick check decides whether you asked a question or asked for an action. With OpenAI selected, questions go to OpenAI's Responses API with web search, and the sources appear under the reply. Gemini and Groq answer questions from their own models. Actions go to the tools below. If a provider rejects the tool format, JARVIS retries that turn once without tools.
- *Smart*: the model decides everything itself, and web search is one of its tools.
- *Chat only*: no tools at all.

### What JARVIS can and can't do with other apps

**It can:**
- **Contacts:** find a person's number or email.
- **Phone / FaceTime:** start a call. You confirm in JARVIS, and iOS then shows its own "Call?" prompt.
- **iMessage / SMS:** open Apple's message sheet with the recipient and text filled in. **You tap Send.**
- **WhatsApp:** open the chat with the text filled in (using a `wa.me` link). **You tap Send.** UK numbers starting 07… are converted to +44 automatically.
- **Calendar & Reminders:** list, create, change and delete events and reminders. Deletes ask for confirmation.
- **Open apps:** Instagram, TikTok, Snapchat, WhatsApp, YouTube, Spotify, X, Maps, Google Maps, Music, Shortcuts, and JARVIS's own page in Settings.
- **Directions:** opens Apple Maps for driving, walking, transit or cycling.
- **Music:** plays songs, artists or albums **from your library** (including Apple Music songs you've added), and can pause, resume and skip. For anything else, set a "Music" Shortcut.
- **Shortcuts:** runs any Shortcut you register by name. The screen briefly switches to the Shortcuts app.
- **Timers and alarms:** iOS doesn't let apps set Clock timers or alarms directly, so JARVIS runs a Shortcut for this. In the Shortcuts app, create:
  - **"JARVIS Timer"**: a *Start Timer* action, with the duration set to the *Shortcut Input* (a number of seconds).
  - **"JARVIS Alarm"**: a *Create Alarm* action, with the time set to the *Shortcut Input* (HH:mm).
- **Agent webhook:** sends `{"task": "..."}` to a URL you choose, with a bearer key.
- **Grok Bot:** sends a task to one of your Grok Bot routines through its webhook (see below).

**It can't:**
- Read your iMessages, WhatsApp, Snapchat, Instagram or TikTok messages or feeds. iOS gives no app access to them.
- Send a message or place a call without you. Every call, message, delete and agent task needs **your confirmation** (say "yes" or tap Confirm). iOS then also requires you to tap **Send**, or confirm the call.
- Open other apps while JARVIS is in the background, for example during an Action Button session from the Lock Screen. iOS only allows this while JARVIS is on screen, and JARVIS will tell you when that's the problem.
- Control the inside of other apps, such as posting to Instagram or picking a TikTok video. Deep links only open the app.
- Stream from Spotify or YouTube Music directly. Use a Shortcut for that.

**Confirming:** after JARVIS asks "Shall I…?", say **yes** (or "go ahead") or **no** (or "cancel"). You can also tap the Confirm or Cancel buttons.

### Grok Bot

Grok Bot doesn't offer a general public API, but its **routines** can be started by a **webhook**:
1. In Grok Bot, ask your Bot to create a routine with a webhook trigger, for example: *"Set up a routine with a webhook trigger: do the task in the request body and post the result here."*
2. Open the routine on desktop. Copy **POST to** (the URL) and **key**.
3. In JARVIS, go to **Settings > Integrations > Grok Bot**, paste both, and tap **Save webhook keys**.
4. Now you can say: "Send Grok Bot a task: summarise my unread email."

JARVIS only learns that the task was **accepted**. The Bot posts its result in its own chat.

### Permissions JARVIS may ask for

| Permission | Why |
|---|---|
| Microphone | Hearing you |
| Speech Recognition | Turning speech into text |
| Contacts | Finding numbers for calls and messages |
| Calendars (Full Access) | Reading and editing events |
| Reminders (Full Access) | Reading and editing reminders |
| Media & Apple Music | Playing music from your library |
| Live Activities | The Lock Screen and Dynamic Island display |

Each one is only asked for the first time a feature needs it. You can change them in iPhone **Settings > JARVIS**.

## 10. What iOS limits (please read)

- **Background work stays on the Cloudflare Worker.** Tasks, call screening, question timeouts, and problem-call checks run on the worker cron, which keeps going when the phone is locked. The iPhone only wakes JARVIS into listening and shows status. It does not run that queue.
- **Background microphone:** iOS lets the app keep listening only while its audio session is active and a Live Activity is showing. That covers a session started from the app or from the JARVIS toggle. If iOS ends the session (for example a phone call, or another app taking over the audio), press the Action Button again. iOS does not allow an always-on "Hey JARVIS" wake word for third-party apps. "Hey Siri, JARVIS" is the system shortcut that opens listening.
- **First Action Button press:** the control cannot show the microphone or speech permission prompts. Start a session in the app once and allow both. After that, the JARVIS toggle can listen without bringing the app forward. Talk to JARVIS opens the app. Live Activities must also be allowed for JARVIS, unless you turn the Live Activity switch off in JARVIS settings.
- **Speech recognition** for a live voice turn streams on the iPhone. A finished sentence is sent as that transcript. A whole-file Groq Whisper upload is not used for hands-free turns. If on-device recognition isn't available, Apple's servers are used.
- **The Live Activity** is optional (Settings > Always available). It updates when the state changes (Listening, Thinking, Responding, or an active call), not 60 times a second. The animated orb is only inside the app, because widgets cannot animate continuously. The Dynamic Island shows a still teal orb, the status, an active call when one is open, and the latest reply.
- **Live Activities** last up to 8 hours on screen.

### Things that would need a newer SDK, or don't exist publicly

Nothing here uses unannounced "iOS 27" APIs. Only public APIs from iOS 18 / Xcode 16+ are used. The following are not possible with current public APIs:
- An always-listening system wake word or Siri replacement.
- A full-screen app inside iOS StandBy (only widgets and Live Activities are allowed).
- Real-time, audio-reactive animation inside the Dynamic Island.

If a future SDK adds these, they could be adopted.

## 11. Troubleshooting

- **"Personal development teams do not support the App Groups capability"**: remove the App Groups capability from both targets (delete the `entitlements` blocks in `project.yml` and run `xcodegen` again). Everything still works except the StandBy widget's last-reply text and the Action Button control's on/off indicator. The control can still start and end a session.
- **Swift 6 concurrency errors after an Xcode update**: as a quick workaround, set *Swift Language Version* to 5 in Build Settings for both targets.
- **No voice from ElevenLabs**: check the key and your quota. The app falls back to the iPhone voice and shows the error.
- **Web search error mentioning `web_search`**: your model may not support it. Choose `gpt-4.1-mini` or `gpt-4o` under Integrations > Search model.
- **Tools don't work with the Custom agent endpoint**: that service must support OpenAI-style function calling. Otherwise set routing to *Chat only*.
- **App won't open after a week**: this is free signing. Connect the phone and press Run again.

## Start-up sequence

JARVIS plays an original sequence when the app opens, and again after it has been in the background for more than five minutes. It is on by default. Settings > This iPhone has **Start-up sequence** and **Short version**. Tap anywhere to skip. Reduce Motion uses a short fade instead of the rings.

The phases are a boot line and loading bar, a collapse to a centre dot, concentric rings with “J.A.R.V.I.S.”, then a power-up that shrinks onto the home orb. Sounds are generated synth tones in `JARVIS/Resources/Startup`. Spoken lines use the George voice. `scripts/bundle-startup-voice.mjs` writes them into the app when `ELEVENLABS_API_KEY` is set at build time. Otherwise the first launch that has a saved ElevenLabs key caches them, and later opens play the cache. The sequence does not call ElevenLabs on every open.

Startup chime turns the synth effects on or off. Spoken lines and effects follow the iPhone silent switch. The sequence waits until Face ID unlock, and it stays off when a voice session is already starting, a briefing is due, or a call-message notification is opening a card.

The next Codemagic `ios-testflight` archive on this branch includes the sequence. GitHub Actions job **iOS compile** builds the app for the simulator without signing, which checks that the Swift compiles. It does not upload a TestFlight build.

## Call interceptor

iOS cannot intercept a normal carrier call. Conditional forwarding sends busy, unanswered, and unreachable calls to the JARVIS Twilio number. The drawer and Calling settings open **Interceptor**.

The switch is on until you turn it off. JARVIS then answers with: "You've reached Sohail Hadi's line. He's unavailable right now. I'm J.A.R.V.I.S., his assistant. May I take a message?" He takes the message and sends the usual call summary by push or text. With the switch off and Busy mode off, he says "Please try again later." and texts who called.

Busy mode answers on its own, including when the switch is off. Settings > Focus > a Focus > Add Filter > JARVIS Busy mode turns it on. The Shortcuts action **Set JARVIS busy mode** does the same. After that Focus ends, busy mode turns off the next time you open the app. The home ring shows BUSY while it is on and JARVIS is idle.

The screen lists the generic GSM codes `**67*`, `**61*`, and `**62*`, then the JARVIS number and `#`, plus `##002#` to cancel. The number comes from the worker's calling config. Some UK networks use a different code. A direct call to the JARVIS number still uses the existing screening greeting.

The next Codemagic `ios-testflight` archive on this branch includes the interceptor. This environment does not upload a TestFlight build.

## Voice mode

In-app voice uses `AVAudioSession` play-and-record in voice-chat mode, and turns on voice processing (echo cancellation, automatic gain, and noise suppression) on the capture engine so JARVIS does not hear himself. The simulator often refuses voice processing. Settings > Voice > Voice timing shows whether it is on.

A Silero model is not in this build, and neither are LiveKit's turn-detector weights. The microphone meter is a small fixed recurrent net on signal-to-noise, speech-band energy, spectral flatness, and level. The first 300 ms learns a noise floor from the quieter samples, so speech in that window does not become the floor. Speech has to last about 250 ms, so a click or a cough does not start a turn. The recogniser is given the real microphone the whole time. Replacing a pause with digital silence was making Apple Speech finalise and drop the rest of the sentence. With Voice ID enrolled, another speaker is still replaced with silence. Without it, a far-field frame does not start a turn, but a loud television can until a voice print is saved.

End of turn follows the published Realtime `semantic_vad` loop and LiveKit's turn-detector control, on the transcript rather than on silence alone. The words get a score for whether the turn is finished. A finished sentence still waits at least 0.8 seconds. An unfinished one, such as a trailing "and" or "uhhm", waits longer. Settings > Voice > Eagerness sets that cap the way the Realtime API documents it: low 8 seconds, medium 4 seconds, high 2 seconds. Medium is the default. If recognition has not produced words yet, the turn stays open, so a breath cannot cut the sentence off.

If you talk while JARVIS is speaking, playback stops after about 300 ms of your own close speech, and only when echo cancellation is actually on. His leftover echo is below that signal-to-noise bar. Turn and barge events are posted to `POST /debug/voice` when the cloud token is set.

The reply streams. Apple Speech partials are the transcript, the model streams tokens, and ElevenLabs (George) starts on the first sentence chunk while the rest of the answer is still arriving. If that key is missing or the stream fails, the iPhone's British voice speaks the same words. Phone calls still use Polly on the worker. If no reply audio has started by 1.2 seconds, JARVIS says a short "Right.", "One moment.", or "Yes." on the iPhone voice and stops it the moment George begins. Connections are opened when a voice session starts. The ring already has a thinking pulse, and it reads the meter on the display link rather than on every audio buffer.

Settings > Voice > Voice timing shows the last end-of-speech to first-audio time, the false-trigger count, and the end-of-turn score. The same synthetic frames run in GitHub Actions as `JARVISVoiceTests`. That checks the timings (speech after 250 ms, a finished sentence after at least 800 ms, an unfinished sentence waiting longer, high eagerness shorter than low, barge-in near 300 ms only with echo cancellation, noise and other speakers ignored). It does not measure a real room. On an iPhone you still need to confirm echo cancellation, Voice ID against a television, and whether the first spoken word arrives within a second of you stopping.

The next Codemagic `ios-testflight` archive on this branch includes this voice path. This environment does not upload a TestFlight build.

## Project layout

- `project.yml`: the XcodeGen spec (the JARVIS app, the JARVISWidgets extension, and the JARVISVoiceTests bundle). The test bundle is not part of the TestFlight archive.
- `JARVIS/`: app code (engine, services, settings, views, intents).
- `JARVISWidgets/`: Live Activity, Dynamic Island, the Control Center / Action Button control, and the StandBy/Lock Screen widget.
- `Shared/`: code compiled into both targets (Live Activity attributes, the control toggle intent, the End-session intent, colours, the static orb).

## Building without a Mac (Codemagic)

You don't need a Mac. Codemagic builds the app in the cloud and sends it to TestFlight, which you then use to install it on your iPhone. The build steps are already set up in `codemagic.yaml`.

1. **Join the Apple Developer Program.** Sign up at developer.apple.com/programs (about £79 a year). Approval can take a day or two. Make a note of your **Team ID** (under Membership).
2. **Register the IDs and App Group.** At developer.apple.com, go to Certificates, Identifiers & Profiles > Identifiers and create:
   - an App Group called `group.com.sohail.jarvis`
   - an App ID `com.sohail.jarvis` with the **App Groups** capability turned on and linked to that group
   - an App ID `com.sohail.jarvis.widgets` with the same App Group
3. **Create the app in App Store Connect.** At appstoreconnect.apple.com, go to My Apps > + > New App. Choose iOS, pick bundle ID `com.sohail.jarvis`, and enter any unique name and SKU. Under App Information, copy the numeric **Apple ID** and paste it in place of `APP_STORE_APPLE_ID` in `codemagic.yaml`.
4. **Create an App Store Connect API key.** In App Store Connect, go to Users and Access > Integrations > App Store Connect API. Create a key with the **Admin** or **App Manager** role and download the `.p8` file. Apple only lets you download it once. Note the **Issuer ID** and **Key ID** too.
5. **Add the key to Codemagic.** Sign up at codemagic.io and go to Teams > (your team) > Integrations > Developer Portal > Connect. Name it `CODEMAGIC_ASC_KEY` (or change the name in `codemagic.yaml` to match), then enter the Issuer ID and Key ID and upload the `.p8` file.
6. **Push this repo to GitHub.** Create an empty private repo on GitHub, then run `git remote add origin <url>` and `git push -u origin main`. You can also upload the files through GitHub's web page.
7. **Add the app in Codemagic.** Choose Add application > GitHub, pick the repo, and select the **codemagic.yaml** configuration.
8. **Start a build.** Click Start new build and pick the `ios-testflight` workflow. Codemagic installs XcodeGen, generates the Xcode project, creates the signing certificate and profiles automatically, increases the build number, builds the app, and uploads it to TestFlight.
9. **Install it with TestFlight.** Apple takes 10–30 minutes to process the upload. Then, in App Store Connect > TestFlight, add yourself as an internal tester. Install the **TestFlight** app on your iPhone and install JARVIS from it.

If a build fails, the full log is on the build page in Codemagic.
