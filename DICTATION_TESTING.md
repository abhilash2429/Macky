# Macky Dictation validation

Dictation uses **Ctrl + Fn**. The assistant's configurable shortcut remains independent, but it cannot be set to that reserved chord.

## Development setup

1. Confirm the existing Azure AI Foundry deployment named `gpt-realtime-2.1-mini` is available to the Worker through `AZURE_OPENAI_API_KEY`. Do not add keys to the app, `wrangler.toml`, Keychain, source control, or analytics.
2. Open `leanring-buddy.xcodeproj` in Xcode, select the `leanring-buddy` scheme, and build/run with **⌘R**. Do not use terminal `xcodebuild` on a development Mac.
3. Grant Microphone and Accessibility access. Accessibility is required both for the global chord and for validation of the exact focused field.
4. In Macky Settings → Dictation, choose Literal, Clean, or Smart and enter optional keyterms. Every style is rendered by the same isolated Azure Realtime text response; none uses Luna or MCP.

## Required manual cases in Xcode

- Hold Ctrl + Fn over a normal text field, speak, and release. Confirm one final insertion only; no partial text appears while speaking.
- Start dictation, move focus to a second text field before release, then release. Confirm neither field is changed and the notch offers **Copy**. Confirm the clipboard changes only after pressing that button.
- Focus a password/secure field. Confirm recording never begins and nothing is inserted.
- Focus non-editable browser page text. Confirm recording never begins. Then test editable composers in Safari/Chrome, Gmail-in-browser, and Slack-in-browser; verify the local style classifier chooses Email/Chat without sending title, URL, or content to the Worker.
- Dictate into TextEdit/Pages, an editor such as Xcode or VS Code, and Terminal. Confirm Terminal only stages text and never posts Return.
- Deny the microphone prompt, then retry after granting it. Confirm no Azure Realtime dictation session starts while permission is denied.
- Tap Ctrl + Fn and release before the Worker reports `session.updated`. Confirm no buffered microphone audio is sent after release and no text is inserted.
- Disable the network or force the Worker/Azure socket closed while dictating. Confirm the app shows a safe failure/Copy result and the provider session closes; do not retry in the background.
- Use silence/empty audio. Confirm no final insertion or assistant response is generated.
- Test malformed provider traffic with the Worker fixture or a temporary proxy. Confirm no insertion occurs unless an exact `gpt-realtime-2.1-mini` `session.updated` and a completed `response.done` with final text are received.
- Confirm the Worker accepts only `dictation.audio` and one `dictation.commit` after `dictation.start`; it must reject any client tool, response, or audio-output event.

## Timing and release gate

`dictation_timing` contains only numeric timings: Realtime finalization, Worker connection, target insertion, and total release-to-result time. `dictation_outcome` contains only a coarse surface kind, formatting mode, and outcome. Neither event includes audio, transcript, keyterms, field text, titles, URLs, or recipients.

Capture representative Macky speech samples locally (including names, domains, code identifiers, email/chat/document/terminal contexts) and evaluate transcription quality plus release-to-verified-insertion latency. The target remains P50 ≤500 ms and P95 ≤1.2 s; treat a measured P50 above 700 ms as a performance failure to fix before declaring dictation ready. Do not commit recordings, transcripts, or benchmark references.

Before a release, re-run the Xcode cases above against the production Azure deployment and confirm the deployment's data-handling configuration meets the release policy.
