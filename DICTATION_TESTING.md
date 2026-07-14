# Macky Dictation validation

Dictation uses **Ctrl + Fn**. The assistant's configurable shortcut remains independent, but it cannot be set to that reserved chord.

## Development setup

1. In `worker/`, set `ASSEMBLYAI_API_KEY` as a Worker secret. Do not add it to the app, `wrangler.toml`, Keychain, source control, or analytics.
2. Keep `DICTATION_PRIVACY_MODE = "development"` while using the AssemblyAI free-credit account. This is an explicit development exception: account-level zero retention is not enabled on that tier.
3. Open `leanring-buddy.xcodeproj` in Xcode, select the `leanring-buddy` scheme, and build/run with **⌘R**. Do not use terminal `xcodebuild` on a development Mac.
4. Grant Microphone and Accessibility access. Accessibility is required both for the global chord and for validation of the exact focused field.
5. In Macky Settings → Dictation, choose Literal, Clean, or Smart and enter optional keyterms. Literal and Clean skip Luna entirely. Smart requires the existing Azure Worker configuration.

## Required manual cases in Xcode

- Hold Ctrl + Fn over a normal text field, speak, and release. Confirm one final insertion only; no partial text appears while speaking.
- Start dictation, move focus to a second text field before release, then release. Confirm neither field is changed and the notch offers **Copy**. Confirm the clipboard changes only after pressing that button.
- Focus a password/secure field. Confirm recording never begins and nothing is inserted.
- Focus non-editable browser page text. Confirm recording never begins. Then test editable composers in Safari/Chrome, Gmail-in-browser, and Slack-in-browser; verify the local style classifier chooses Email/Chat without sending title, URL, or content to the Worker.
- Dictate into TextEdit/Pages, an editor such as Xcode or VS Code, and Terminal. Confirm Terminal only stages text and never posts Return.
- Deny the microphone prompt, then retry after granting it. Confirm no AssemblyAI session starts while permission is denied.
- Tap Ctrl + Fn and release before the AssemblyAI `Begin` message. Confirm no buffered microphone audio is sent after release and no text is inserted.
- Disable the network or force the Worker/AssemblyAI socket closed while dictating. Confirm the app shows a safe failure/Copy result and the provider session closes; do not retry in the background.
- Use silence/empty audio. Confirm no final insertion or assistant response is generated.
- Test malformed provider traffic with the Worker fixture or a temporary proxy. Confirm no insertion occurs unless an exact `universal-3-5-pro` `Begin`, formatted final `Turn`, and terminal `Termination` are received.
- Force `/dictation/polish` to return an error in Smart mode. Confirm Macky does not silently fall back to local insertion and offers the raw final transcription as Copy instead.

## Timing and release gate

`dictation_timing` contains only numeric timings: AssemblyAI finalization, Worker connection, optional Smart polish, target insertion, and total release-to-result time. `dictation_outcome` contains only a coarse surface kind, formatting mode, and outcome. Neither event includes audio, transcript, keyterms, field text, titles, URLs, or recipients.

Capture representative Macky speech samples locally (including names, domains, code identifiers, email/chat/document/terminal contexts) and evaluate transcription quality plus release-to-verified-insertion latency. The target remains P50 ≤500 ms and P95 ≤1.2 s; treat a measured P50 above 700 ms as a performance failure to fix before declaring dictation ready. Do not commit recordings, transcripts, or benchmark references.

Before a release, enable AssemblyAI streaming zero-retention opt-out on the paid account, set `DICTATION_PRIVACY_MODE = "production"`, and set `DICTATION_ZERO_RETENTION_CONFIRMED = "true"` in the Worker configuration. Re-run the Xcode cases above against that deployment. `scripts/release.sh` also refuses to publish unless its operator explicitly confirms that deployment with `MACKY_DICTATION_RELEASE_PRIVACY_CONFIRMED=true`.
