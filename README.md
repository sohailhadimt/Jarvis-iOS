# JARVIS for iPhone

A personal voice assistant: you talk, Apple's speech recognition turns it into text on your phone, OpenAI (or another compatible service) writes the reply, and ElevenLabs (or the built-in iPhone voice) speaks it. It has a glowing orb, a Live Activity / Dynamic Island, Action Button support, and a bedside "StandBy" mode.

No passwords or API keys are stored in this code. You type them into the app, and it keeps them in the iPhone Keychain.

---

## 1. What you need

| Thing | Cost | Notes |
|---|---|---|
| A Mac with **Xcode 16 or newer** (Mac App Store) | Free | Xcode 26 is fine too. |
| **Homebrew** (https://brew.sh) | Free | Used to install XcodeGen. |
| An **Apple ID** | Free | Enough to put the app on your own iPhone. |
| iPhone on **iOS 18 or newer** | – | Action Button needs iPhone 15 Pro or later. Dynamic Island needs iPhone 14 Pro or later. |
| OpenAI API key | Pay as you go | platform.openai.com > API keys. |
| ElevenLabs API key | Optional | elevenlabs.io > Profile > API Keys. Without it, the iPhone's own voice is used. |

**Free vs paid Apple account:** with a free Apple ID, apps you install **stop opening after 7 days**. To fix that, plug the phone in and press Run in Xcode again. The **$99/year Apple Developer Program** is only needed for TestFlight, the App Store, or apps that last a year. A free account may also refuse the **App Groups** capability (see Troubleshooting). The app still works without it. Only the StandBy widget's "last reply" text stops updating.

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
- Paste your **OpenAI** key. The model defaults to `gpt-4o-mini`, and you can pick another.
- Optionally paste your **ElevenLabs** key, then go to **Voices** to pick a voice, preview it, and adjust Stability and Similarity.
- **Custom agent endpoint** is an optional second slot for any OpenAI-compatible service: a base URL (for example `https://host/v1`), a bearer key, and a model name. To use it, set the provider picker to it.
- Tap **Save keys to Keychain**.

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

1. Run the app once so iOS learns about its shortcut.
2. Open the iPhone **Settings > Action Button**, swipe to **Shortcut**, tap **Choose a Shortcut**, then pick **JARVIS > Toggle JARVIS**.
3. Press once to start a session. A Live Activity appears on the Lock Screen and in the Dynamic Island, and JARVIS listens. Press again, or tap the red stop button on the Live Activity, to end it.

You can also say "Hey Siri, Toggle JARVIS".

## 8. StandBy

- **In-app StandBy view:** put the phone on charge and turn it sideways (landscape) with JARVIS open. The screen goes black with a large orb. Tap the orb to talk, or tap ∞ for a continuous conversation. You can turn this off in Appearance.
- **iOS StandBy widget:** iOS StandBy (charging, landscape, locked) only shows **widgets and Live Activities**, not full apps. To add the widget: lock the phone, put it on charge in landscape, long-press the StandBy widget stack, tap **+**, and add **JARVIS**. Tapping it opens the in-app StandBy view. The same widget can also go on the Lock Screen (circular, rectangular, or inline) and the Home Screen.

## 9. Talking to other apps (tools)

When you ask JARVIS to *do* something, the AI model chooses a "tool" and the app carries it out. You set this up in **Settings > Integrations & Task agent**.

**Routing (the Task agent setting)**
- *Questions → ChatGPT, actions → tools* (the default). A quick check decides whether you asked a question or asked for an action. Questions go to OpenAI's Responses API with web search, and the sources appear under the reply. Actions go to the tools below.
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

- **Background microphone:** iOS lets the app keep listening only while its audio session is active, meaning a session started from the app or the Action Button with the Live Activity showing. If iOS ends the session (for example a phone call, or another app taking over the audio), press the Action Button again. iOS does not allow an always-on "Hey JARVIS" wake word for third-party apps.
- **Speech recognition** runs on-device when your iPhone supports it for English (UK). Otherwise Apple's servers are used.
- **The Live Activity** updates when the state changes (listening, thinking, speaking), not 60 times a second. The animated orb is only inside the app, because widgets cannot animate continuously.
- **Live Activities** last up to 8 hours on screen.

### Things that would need a newer SDK, or don't exist publicly

Nothing here uses unannounced "iOS 27" APIs. Only public APIs from iOS 18 / Xcode 16+ are used. The following are not possible with current public APIs:
- An always-listening system wake word or Siri replacement.
- A full-screen app inside iOS StandBy (only widgets and Live Activities are allowed).
- Real-time, audio-reactive animation inside the Dynamic Island.

If a future SDK adds these, they could be adopted.

## 11. Troubleshooting

- **"Personal development teams do not support the App Groups capability"**: remove the App Groups capability from both targets (delete the `entitlements` blocks in `project.yml` and run `xcodegen` again). Everything still works except the StandBy widget's last-reply text.
- **Swift 6 concurrency errors after an Xcode update**: as a quick workaround, set *Swift Language Version* to 5 in Build Settings for both targets.
- **No voice from ElevenLabs**: check the key and your quota. The app falls back to the iPhone voice and shows the error.
- **Web search error mentioning `web_search`**: your model may not support it. Choose `gpt-4.1-mini` or `gpt-4o` under Integrations > Search model.
- **Tools don't work with the Custom agent endpoint**: that service must support OpenAI-style function calling. Otherwise set routing to *Chat only*.
- **App won't open after a week**: this is free signing. Connect the phone and press Run again.

## Project layout

- `project.yml`: the XcodeGen spec (2 targets: the JARVIS app and the JARVISWidgets extension).
- `JARVIS/`: app code (engine, services, settings, views, intents).
- `JARVISWidgets/`: Live Activity, Dynamic Island, and the StandBy/Lock Screen widget.
- `Shared/`: code compiled into both targets (Live Activity attributes, the End-session intent, colours, the static orb).

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
