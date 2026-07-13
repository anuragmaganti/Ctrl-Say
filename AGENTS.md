# Ctrl-Say

- Target the latest stable macOS with Swift 6 and current, nondeprecated Apple-native APIs.
- Prioritize measured latency, idle CPU, memory, and energy; avoid unnecessary dependencies and work.
- Treat an 8 GB M1 MacBook Air and 8 GB MacBook Neo as the performance floor.

## Product invariants

- Ctrl-Say is a voice-controlled set of numbered and named clipboard slots. Commands include `copy 1`, `paste 1`, `permanent copy house`, and `paste house`.
- End-to-end perceived latency is the primary product requirement. Optimize the speech-to-command-to-paste path before dashboard polish or additional features.
- Use Apple's on-device transcription. Act on a confidently recognized complete command from partial results instead of waiting for utterance finalization when safe.
- Keep the transcription pipeline warm only while an explicit Listening mode is enabled. Do not require network access for commands.

## Clipboard architecture

- Use `NSPasteboard.general` as the bridge to other apps, not as Ctrl-Say's slot storage.
- For copy, invoke the frontmost app's normal Copy action, detect the pasteboard `changeCount`, and deep-snapshot all supported items and representations. Never retain live `NSPasteboardItem` references as stored slot contents.
- For paste, write the stored items back to the general pasteboard and invoke the frontmost app's normal Paste action. Leave the pasted value on the native clipboard; immediate restoration is timing-sensitive and can corrupt the destination paste.
- Serialize clipboard commands so rapid voice commands cannot race. Detect pasteboard changes with bounded event-driven/asynchronous checks; do not add arbitrary fixed sleeps.
- Preserve multiple pasteboard items and common native representations, including plain and rich text, images, and file URLs/metadata. Avoid transcoding or recompressing in the latency-critical path.
- Add measured per-item and total-memory safeguards for large image or binary payloads. File copies should preserve native references and metadata rather than duplicate file contents.
- Do not depend on Spotlight's native clipboard history. macOS exposes it to users but has no supported public API for addressing historical entries. Ctrl-Say stores only content explicitly assigned by a voice command and does not continuously collect clipboard history.

## Slot lifetime

- Numbered slots are temporary, memory-only working slots. Reusing a number replaces it, and all numbered slots are cleared when the app quits or the user clears them.
- Named "permanent copies" use normalized names in a separate protected namespace. Regular numbered commands cannot overwrite them. For the current scope, they remain until explicitly deleted or the app quits; do not persist them to disk unless persistence is intentionally added later.

## Interaction and UI

- A tap of the physical Right Option key is the global command to start or stop Listening mode. Left Option must remain unaffected.
- The default rule is: if Command-C can copy the current selection in the source app, Ctrl-Say's normal copy command can capture it.
- A Finder item must be selected before copying. A webpage image usually requires the browser's Copy Image action; hover-to-copy is a separate compatibility path to prototype, not behavior to assume from Command-C.
- Run as a menu-bar app. Any optional clipboard dashboard must be passive/non-activating, must not steal focus from the copy or paste target, and must update outside the critical path.
- Normal copy and paste commands should not wait for confirmation. Provide immediate, subtle success/failure feedback and ignore ambiguous commands rather than performing a risky guess.
- Expect microphone, speech-recognition, and Accessibility permissions. Make permission state and failures explicit without blocking unrelated UI.

## Measurement and privacy

- Instrument speech detection, command recognition, native Copy/Paste dispatch, pasteboard change detection, snapshot/write time, and visible completion where measurable.
- Benchmark median and tail latency, idle CPU, memory growth, and energy on the performance-floor Macs from the first prototype.
- Never log clipboard contents or transcripts containing copied content. Keep the dashboard and telemetry out of the latency-critical path.
