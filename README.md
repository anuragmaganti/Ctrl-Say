# Ctrl-Say

Ctrl-Say is a native macOS menu-bar app for assigning selected content to numbered or named clipboard slots with your voice, then pasting it later without repeatedly returning to the source.

The app uses Apple’s on-device speech transcription, keeps temporary copies in memory for the current session, and stores explicitly permanent copies locally on the Mac. It supports native clipboard representations such as plain and rich text, images, files, mixed content, and multiple pasteboard items without turning the system clipboard into the app’s storage layer.

## Features

### Voice-Controlled Clipboard Slots

- Say `copy 1` through `copy 10` to capture the current selection into a numbered slot.
- Say `paste 1` through `paste 10` to paste a numbered slot into the frontmost app.
- Use one-to-five-word temporary names such as `copy house`, `copy first paragraph`, or `copy New York address`.
- Paste a named slot by saying its name, such as `paste house`.
- Number and paste aliases are normalized only within command positions, and capitalization and punctuation do not affect command parsing.
- Commands are serialized so rapid copy and paste requests cannot race the native clipboard.

### Temporary And Permanent Copies

- Numbered and ordinary named copies are temporary and clear when Ctrl-Say quits.
- `permanent copy house` stores the selected content under a protected permanent name.
- Permanent names use the same one-to-five-word grammar as temporary names.
- Permanent copies survive app relaunches, Mac restarts, Xcode rebuilds, and app updates until explicitly deleted.
- Temporary commands cannot overwrite a permanent name.
- Permanent copies can be renamed, deleted, pasted, or copied back to the system clipboard from the Clipboard HUD.
- Safe plain-text permanent copies can also be edited without destructively converting rich text, images, files, or mixed content.

### Native Clipboard Fidelity

- Ctrl-Say invokes the frontmost app’s ordinary Copy or Paste action instead of implementing app-specific integrations.
- Copy waits for the native pasteboard change, then snapshots every supported item and representation.
- Stored slots preserve plain text, rich text, images, file URLs and metadata, mixed content, and multiple pasteboard items.
- Paste writes the stored snapshot to `NSPasteboard.general`, invokes the target app’s Paste action, and leaves the pasted value on the native clipboard.
- File slots preserve native references and bookmarks rather than duplicating the referenced file contents.
- Individual representations are limited to 64 MB, one clipboard payload to 128 MB, and total in-memory slot storage to 256 MB.

### Clipboard HUD

- Tap the physical Right Option key to start Listening and show the floating Clipboard HUD.
- Tap Right Option again to stop Listening and hide the HUD.
- Hold Right Option to show or hide the HUD without changing the current Listening state.
- The HUD stays above normal application windows without activating Ctrl-Say or stealing focus from the copy or paste destination.
- Switch between Temporary and Permanent collections from the segmented control.
- Click a row to place its content on the native clipboard, or use its explicit Paste action to send it to the frontmost app.
- Swipe a temporary row to delete it, or clear all temporary copies from the footer.
- Long text previews remain bounded, while images and files receive asynchronous thumbnails outside the copy/paste critical path.
- The panel grows with its contents, becomes scrollable at 75% of the current display’s usable height, and remembers a separate position for each display.

### Menu Bar And Notch Feedback

- Ctrl-Say runs as a menu-bar-only macOS app with native menu-bar presentation.
- Listening can also be started or stopped from the menu-bar window.
- Supported MacBook displays use the camera housing area for subtle listening, success, and failure feedback.
- Displays without a camera housing use the same feedback in a small floating surface.
- Copy and paste success feedback shows only the action and slot name—never clipboard preview content.
- The notch border animation runs through Core Animation and stops when feedback is hidden.

### Local Settings And Recovery

- Optionally open Ctrl-Say automatically at login using macOS Login Items.
- Inspect permanent-storage state and retry failed saves.
- Reset permanent storage explicitly without affecting temporary copies.
- If permanent changes cannot be flushed while quitting, Ctrl-Say offers a choice between canceling the quit and quitting without saving.
- Developer diagnostics are compiled only into Debug builds and remain memory-only.

## Voice Commands

| Action | Examples |
| --- | --- |
| Copy to a numbered slot | `copy 1`, `copy 10` |
| Paste a numbered slot | `paste 1`, `paste 10` |
| Create a temporary named copy | `copy house`, `copy first paragraph` |
| Create a permanent copy | `permanent copy house`, `permanent copy New York address` |
| Paste a named copy | `paste house`, `paste New York address` |
| Delete a copy | `delete 2`, `delete house`, `delete permanent copy house` |
| Promote a temporary name | `make house permanent` |
| Rename a temporary name | `rename house to home address` |
| Clear temporary copies | `clear copies`, `clear temporary copies` |

The v1 command grammar is intentionally English (`en-US`). Names are normalized to lowercase words for lookup, cannot begin with a number or spoken-number alias, and contain between one and five words.

## How The App Works

Ctrl-Say keeps the latency-sensitive path in memory and treats the native clipboard only as the bridge to other apps:

1. Right Option enables Listening and keeps the on-device transcription pipeline warm.
2. `AVAudioEngine` streams microphone buffers into Apple’s `SpeechAnalyzer` and `SpeechTranscriber`.
3. The streaming command scanner evaluates volatile partial results, so safe commands can run before the entire utterance is finalized.
4. A serial command queue preserves spoken order and prevents clipboard operations from overlapping.
5. Copy posts the normal Command-C event to the captured frontmost process and watches `NSPasteboard.changeCount` for bounded completion.
6. Ctrl-Say deep-snapshots the resulting pasteboard items into the in-memory `ClipboardStore`.
7. Temporary slots stop there. Permanent mutations update memory first, then enter an ordered asynchronous SwiftData persistence queue.
8. Paste writes the stored payload to `NSPasteboard.general` and posts Command-V to the same validated target process.
9. HUD thumbnails, notch feedback, diagnostics, and persistence telemetry update outside the critical copy/paste path.

The core storage model is:

```text
ClipboardStore (in memory)
├── numbered[1...10]             temporary, session-only
├── temporaryNamed[name]         temporary, insertion-ordered
└── permanentNamed[name]         restored once at launch, paste-ready in memory

SwiftData (Application Support)
└── PermanentCopyRecord
    └── ordered pasteboard items
        └── ordered type identifiers and original representation bytes
```

Permanent records are stored locally under:

```text
~/Library/Application Support/com.anuragmaganti.CtrlSay/
```

## Key Decisions

- **Latency first:** speech recognition, command parsing, target capture, clipboard work, and UI feedback are measured separately so slow stages can be identified instead of hidden behind fixed delays.
- **Partial-result execution:** safe, complete commands can dispatch from Apple’s volatile results without waiting for utterance finalization.
- **Native clipboard as a bridge:** the general pasteboard is not clipboard-slot storage and Ctrl-Say does not continuously collect clipboard history.
- **Deep clipboard snapshots:** stored slots never retain live `NSPasteboardItem` references that can change underneath the app.
- **Memory-first permanent copies:** a permanent copy appears immediately and stays paste-ready in memory while SwiftData persistence runs afterward in order.
- **No disk access on warm paste:** permanent paste uses the restored in-memory payload rather than querying SwiftData.
- **No immediate clipboard restoration:** restoring an older clipboard value immediately after Paste is timing-sensitive and can corrupt what the destination receives.
- **SwiftUI first, narrow AppKit boundaries:** SwiftUI owns the menu-bar scene, settings, lists, controls, editing, and row interactions. AppKit remains only for nonactivating cross-app panels, global key monitoring, pasteboard/event delivery, and exact display geometry.
- **Local by design:** clipboard contents do not sync to a server or cloud account.
- **System-managed speech assets:** the app uses Apple’s on-device language assets instead of bundling a machine-specific model.

## Tech Stack

- Swift 6 with MainActor-by-default isolation for the application target
- SwiftUI and Observation (`@Observable`) for scenes, state, settings, and interface components
- AppKit for `NSPanel`, `NSPasteboard`, global event monitoring, and frontmost-application integration
- Speech framework with `SpeechAnalyzer` and `SpeechTranscriber`
- AVFoundation for microphone capture and audio conversion
- SwiftData with a versioned schema and external blob storage for permanent copies
- Core Graphics for targeted native Command-C and Command-V event delivery
- Core Animation for low-cost notch border animation
- Quick Look Thumbnailing and ImageIO for file and image previews
- Service Management for Launch at Login
- OSLog for privacy-scoped timing and count telemetry
- XCTest for parser, speech-stream, clipboard, persistence, layout, interaction, and lifecycle coverage

Ctrl-Say has no third-party runtime dependencies and does not require a network service for voice commands.

## Project Structure

```text
CtrlSay/App/         application scenes, lifecycle, HUD panel, and notch panel
CtrlSay/Models/      clipboard payloads, command grammar, speech scanning, schemas
CtrlSay/Services/    speech, audio, clipboard, thumbnails, global key input, login item
CtrlSay/Stores/      observable app state, in-memory slots, SwiftData repository, queues
CtrlSay/Support/     layout calculations, geometry, telemetry, System Settings launcher
CtrlSay/Views/       SwiftUI menu-bar, HUD, rows, settings, and notch feedback
CtrlSayTests/        unit and interaction regression tests
script/              development-only build, run, logging, and stress helpers
```

## Getting Started

### Prerequisites

- A Mac running macOS 26 or later
- The latest stable Xcode with the macOS 26 SDK and Swift 6
- An Apple Development signing team for a stable local app identity and permissions

No account, API key, environment variable, localhost service, or third-party package installation is required.

### Open And Run

1. Clone the repository.
2. Open `CtrlSay.xcodeproj` in Xcode.
3. Select the `CtrlSay` scheme and the local Mac destination.
4. Confirm the app target uses your development team while preserving the bundle identifier.
5. Run the app from Xcode.

On first launch, complete the in-app setup for:

- **Microphone:** captures audio while Listening is enabled.
- **Input Monitoring:** detects the physical Right Option key outside Ctrl-Say.
- **Accessibility:** sends the native Copy and Paste keyboard events to the frontmost app.

The first listening session may ask macOS to install Apple’s English on-device speech asset. Ctrl-Say does not send command audio to its own server.

## Build And Test

Build the Debug app:

```bash
xcodebuild build \
  -project CtrlSay.xcodeproj \
  -scheme CtrlSay \
  -configuration Debug \
  -destination 'platform=macOS'
```

Run the full test suite:

```bash
xcodebuild test \
  -project CtrlSay.xcodeproj \
  -scheme CtrlSay \
  -configuration Debug \
  -destination 'platform=macOS'
```

Build a universal Release app:

```bash
xcodebuild build \
  -project CtrlSay.xcodeproj \
  -scheme CtrlSay \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  ARCHS='arm64 x86_64' \
  ONLY_ACTIVE_ARCH=NO
```

The test suite covers:

- Command grammar, punctuation, aliases, one-to-five-word names, and numbered slots
- Continuous-speech scanning, partial-result revisions, deduplication, and command ordering
- Right Option tap/hold state transitions and Left Option isolation
- Clipboard payload limits, replacement, deletion, ordering, and byte accounting
- Exact permanent-copy round trips, malformed storage, bookmarks, retries, and reset behavior
- Command queue and persistence mutation ordering
- HUD sizing, display placement, row interactions, editing, thumbnails, and notch geometry
- Launch at Login state mapping and failure handling

## Security And Privacy Notes

- Command transcription uses Apple’s on-device Speech framework.
- Ctrl-Say does not continuously monitor or retain native clipboard history.
- Only content explicitly assigned by a copy command is stored in a slot.
- Temporary copies exist only in process memory and disappear when the app quits.
- Permanent copies remain local to the current macOS user account and do not sync to a cloud service.
- Clipboard contents, filenames, preview text, thumbnails, and spoken copied content are never written to application logs.
- Release builds exclude transcript alternatives and the developer diagnostics interface.
- Telemetry contains timings, counts, byte totals, and success state—not clipboard contents.
- File slots store the native file URL and bookmark, not a duplicate of the file itself.

## Distribution

Public builds should preserve the bundle identifier and signing identity so macOS treats updates as the same application and retains permission continuity.

Before external distribution:

- Archive a Release build from a clean checkout and fresh DerivedData.
- Build and verify both `arm64` and `x86_64` unless supported architectures are intentionally narrowed.
- Use Developer ID signing with the hardened runtime.
- Notarize the app and staple the notarization ticket.
- Scan the finished bundle for local paths, non-system dynamic libraries, scripts, or development-only assets.
- Test first-launch permissions, Right Option input, copy/paste targeting, permanent storage, full-screen apps, multiple displays, and non-US keyboard layouts on a clean Mac user account.
- Measure recognition latency, copy/paste latency, idle CPU, memory, and energy on the supported performance-floor Macs.

## Status

Ctrl-Say is in active development. Numbered and named temporary slots, durable permanent copies, on-device streaming recognition, native copy/paste dispatch, the Clipboard HUD, menu-bar controls, notch feedback, settings, and automated tests are implemented. Developer ID distribution, notarization, clean-account permission testing, and the complete hardware performance matrix remain release work.
