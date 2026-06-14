# AGENT_TASKS_UI.md — Auren Notch Bar UI Redesign
<!-- Replaces Milestone 5, 6, and 7 in BACKLOG.md entirely. -->
<!-- Read AGENTS.md + REQUIREMENTS.md before starting any session. -->
<!-- One milestone = one Claude Code session. Commit before moving to next. -->

---

## Design Overview (Read Before Any Session)

The notch bar is a horizontally-expanding black panel that lives at the top of the screen, precisely over the hardware notch. It is the only UI surface Auren has — no floating response text, no full-screen overlay, no cursor indicator.

**State machine:**

```
idle → [hotkey down] → expanded (listening) → [key up] → expanded (thinking)
     → expanded (speaking) → [model done] → idle
```

The bar stays expanded for the entire duration of an interaction — from hotkey press through model output completion. It collapses to idle only when voiceState returns to `.idle`.

**Layout of expanded bar (480pt wide):**

```
|-- 175pt left zone --|-- 130pt center (notch camera) --|-- 175pt right zone --|
      status text                  black                    audio visualization
```

The center zone is left black — the camera housing sits there. Content only lives in the left and right zones.

---

## Notch Geometry (Used Across All Milestones)

Get notch dimensions dynamically — never hardcode:

```swift
// Notch width from actual menubar geometry
let notchLeft = NSScreen.main?.auxiliaryTopLeftArea?.maxX ?? 0
let notchRight = NSScreen.main?.auxiliaryTopRightArea?.minX ?? NSScreen.main?.frame.width ?? 0
let notchWidth = notchRight - notchLeft   // ~126pt on all current notch Macs

// Menubar / notch height
let notchHeight = NSStatusBar.system.thickness  // ~37pt

// Detect if this screen has a notch
let hasNotch = (NSScreen.main?.safeAreaInsets.top ?? 0) > 0

// Panel x position when expanded to targetWidth
func panelX(for width: CGFloat, screen: NSScreen) -> CGFloat {
    return screen.frame.midX - width / 2
}

// Panel y position (AppKit coordinates: y=0 is bottom)
func panelY(screen: NSScreen) -> CGFloat {
    return screen.frame.maxY - notchHeight
}
```

---

## Milestone UI-1: Notch Panel Foundation

**Goal**: Kill the existing full-screen cursor overlay. Replace it with a small NSPanel that sits exactly over the hardware notch — invisible at idle, blending perfectly with the black notch hardware.

**This milestone produces zero visible change on a notch Mac.** The panel is there but invisible. That's the correct outcome.

**Architecture context**:
- Delete `OverlayWindow.swift`. Create `NotchPanelController.swift` which owns the single NSPanel for the notch bar.
- NSPanel config:
  ```swift
  panel.styleMask = [.borderless, .nonactivatingPanel]
  panel.level = NSWindow.Level(rawValue: Int(NSWindow.Level.statusBar.rawValue) + 1)
  panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
  panel.backgroundColor = .black
  panel.isOpaque = true
  panel.hasShadow = false
  panel.ignoresMouseEvents = true
  panel.hidesOnDeactivate = false
  panel.isReleasedWhenClosed = false
  ```
- Panel frame at idle: `NSRect(x: panelX(notchWidth, screen), y: panelY(screen), width: notchWidth, height: notchHeight)`
- On non-notch displays (hasNotch == false): width = 200pt, corner radius = 8pt on all four corners (pill floating bar), same y position.
- Host an `NSHostingView<NotchBarView>` as the panel's `contentView`. `NotchBarView` at this milestone is just a black `Color.black` fill — nothing rendered.
- `NotchPanelController` is instantiated in `leanring_buddyApp.swift` on launch and kept alive for the app's lifetime. Do not create it from CompanionManager.
- Remove all instantiation of the old OverlayWindow and CompanionResponseOverlay from the app lifecycle.

**Files**:
- Create: `leanring-buddy/NotchPanelController.swift` — owns NSPanel, handles frame geometry, exposes `expand()` and `collapse()` methods (implemented but empty/no-op in this milestone)
- Create: `leanring-buddy/NotchBarView.swift` — the SwiftUI root view hosted inside the panel. Black fill only in this milestone.
- Delete: `leanring-buddy/OverlayWindow.swift`
- Delete: `leanring-buddy/CompanionResponseOverlay.swift` (or stop using it — do not touch its code, just remove the instantiation)
- Modify: `leanring-buddy/leanring_buddyApp.swift` — instantiate `NotchPanelController` on launch, remove old overlay setup

**Done when**:
- App launches and the notch looks like the hardware notch (invisible black panel, no flicker)
- On a non-notch display, a small rounded black bar appears at top center
- Console confirms panel is created and positioned at the correct frame
- No cursor overlay, no floating response text anywhere on screen
- Old OverlayWindow code is gone

**Do not**:
- Add any SwiftUI content to NotchBarView yet (Milestone UI-2)
- Add animations yet (Milestone UI-2)
- Touch CompanionManager, BuddyDictationManager, RealtimeClient, or any audio/voice logic
- Fix or touch GlobalPushToTalkShortcutMonitor.swift

---

## Milestone UI-2: Horizontal Expansion + Shape

**Goal**: When the hotkey is pressed, the panel expands horizontally from 126pt to 480pt, animating outward symmetrically from center. The expanded bar has the Mac notch's visual profile — flat top (against screen edge), rounded bottom corners. The bar stays expanded until voiceState returns to `.idle`, then collapses.

**Architecture context**:

### Panel resize strategy
The NSPanel frame is updated directly on expansion/collapse. Animate using `NSAnimationContext`:
```swift
NSAnimationContext.runAnimationGroup { ctx in
    ctx.duration = 0.35
    ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.34, 1.56, 0.64, 1.0) // spring-ish
    panel.animator().setFrame(targetFrame, display: true)
}
```
Do NOT use SwiftUI animation on the NSPanel frame — use NSAnimationContext for the window resize. SwiftUI animations drive content INSIDE the panel only.

### Expanded width
480pt. This leaves enough room for the notch camera area plus content zones on each side. Defined as a constant in `NotchPanelController`:
```swift
static let expandedWidth: CGFloat = 480
static let idleWidth: CGFloat   // computed from auxiliaryTopLeftArea/auxiliaryTopRightArea
```

### Shape
`NotchBarView` uses a custom `NotchBarShape` as its background, not a plain rectangle:

```swift
struct NotchBarShape: Shape {
    var cornerRadius: CGFloat = 10
    
    func path(in rect: CGRect) -> Path {
        var path = Path()
        // Flat top-left, flat top-right (flush against screen edge)
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        // Straight right side
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - cornerRadius))
        // Bottom-right rounded corner
        path.addArc(center: CGPoint(x: rect.maxX - cornerRadius, y: rect.maxY - cornerRadius),
                    radius: cornerRadius, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        // Bottom edge
        path.addLine(to: CGPoint(x: rect.minX + cornerRadius, y: rect.maxY))
        // Bottom-left rounded corner
        path.addArc(center: CGPoint(x: rect.minX + cornerRadius, y: rect.maxY - cornerRadius),
                    radius: cornerRadius, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        path.closeSubpath()
        return path
    }
}
```

Apply it: `Color.black.clipShape(NotchBarShape())` as the view background. The NSPanel itself remains `.black` and square — the visual rounding is done purely in SwiftUI.

### Trigger + collapse logic
`NotchPanelController` observes `CompanionManager.voiceState` via Combine:
```swift
companionManager.$voiceState
    .receive(on: DispatchQueue.main)
    .sink { [weak self] state in
        if state == .idle {
            self?.collapse()
        } else {
            self?.expand()
        }
    }
    .store(in: &cancellables)
```
`expand()` sets panel frame to expandedWidth, `collapse()` sets back to idleWidth, both using `NSAnimationContext`.

When expanded: `panel.ignoresMouseEvents = false` (needed for hover in Milestone UI-4).
When idle: `panel.ignoresMouseEvents = true`.

### Tool call pulse
Add a `@Published var toolCallActive: Bool` to `CompanionManager`. When a tool call fires, set it true briefly. `NotchBarView` observes this and animates a height swell:
```swift
@State private var pulseOffset: CGFloat = 0

// In view body — a subtle shadow/glow at the bottom edge when toolCallActive
.scaleEffect(y: toolCallActive ? 1.15 : 1.0, anchor: .top)
.animation(.spring(response: 0.25, dampingFraction: 0.5), value: toolCallActive)
```
This animates the SwiftUI content inside the panel, not the NSPanel frame itself. The visual effect is a quick vertical stretch-and-snap at the bottom edge of the bar.

**Files**:
- Modify: `leanring-buddy/NotchPanelController.swift` — add `expand()`, `collapse()`, observe voiceState, NSAnimationContext resize
- Modify: `leanring-buddy/NotchBarView.swift` — add `NotchBarShape`, tool call pulse, observe `toolCallActive`
- Modify: `leanring-buddy/CompanionManager.swift` — add `@Published var toolCallActive: Bool = false`, set to `true` on tool dispatch, `false` after tool handler resolves

**Done when**:
- Hotkey down → bar animates outward to 480pt, rounded bottom corners visible
- Model still talking after key up → bar stays expanded
- Model finishes (`voiceState → .idle`) → bar collapses back to notch width
- Tool call fires → quick vertical stretch-and-snap on the bar, returns immediately
- No content inside bar yet (that's UI-3), just the correct shape and animation

**Do not**:
- Add text labels or waveforms yet (Milestone UI-3)
- Animate the NSPanel frame with SwiftUI modifiers — use NSAnimationContext only for window resize
- Touch GlobalPushToTalkShortcutMonitor.swift
- Change any audio logic

---

## Milestone UI-3: Content Layer — Status Text + Audio Visualizations

**Goal**: Left zone of the expanded bar shows dynamic state text. Right zone shows an audio visualization that changes with voiceState. Wire everything to `CompanionManager.voiceState` and audio level publishers.

**Architecture context**:

### Layout
`NotchBarView` is a `ZStack` with `Color.black.clipShape(NotchBarShape())` as background, then an `HStack(spacing: 0)`:
```swift
HStack(spacing: 0) {
    statusTextZone    // 175pt wide
    Spacer()          // 130pt — leaves camera area empty
    audioVisualization // 175pt wide
}
.frame(maxWidth: .infinity)
.padding(.horizontal, 12)
```

### Status text (left zone)
```swift
struct StatusTextView: View {
    let voiceState: VoiceState
    let narrationText: String?

    private var displayText: String {
        if let narration = narrationText, !narration.isEmpty {
            return narration   // e.g. "opening slack"
        }
        switch voiceState {
        case .idle:       return ""
        case .listening:  return "listening"
        case .processing: return "thinking"
        case .responding: return "speaking"
        }
    }

    var body: some View {
        Text(displayText)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundColor(.white.opacity(0.85))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: 165, alignment: .leading)
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .offset(x: -4, y: 0)),
                removal:   .opacity
            ))
            .animation(.easeInOut(duration: 0.2), value: displayText)
    }
}
```

`narrationText` comes from `CompanionManager`. Set by `RealtimeClient` when it parses a narration phrase from a `conversation.item.created` event before a tool call fires. Cleared when the tool call completes.

```swift
// In CompanionManager.swift
@Published var narrationText: String? = nil
```

### Audio visualization (right zone)

**Listening state** — `WaveformView`:
- 14 vertical bars, each 2pt wide, 3pt gap between
- Heights driven by `BuddyDictationManager.audioLevel` (0.0–1.0) with randomized per-bar multipliers for visual variation
- Color: white, opacity 0.8
- Animate with `.animation(.spring(response: 0.15), value: audioLevel)`
- Max bar height: 22pt. Minimum: 3pt (never fully flat while listening)

```swift
struct WaveformView: View {
    let audioLevel: Float
    let barCount: Int = 14
    
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<barCount, id: \.self) { index in
                let multiplier = barMultipliers[index]
                let height = max(3, CGFloat(audioLevel) * 22 * multiplier)
                RoundedRectangle(cornerRadius: 1)
                    .frame(width: 2, height: height)
                    .foregroundColor(.white.opacity(0.8))
                    .animation(.spring(response: 0.12, dampingFraction: 0.6), value: height)
            }
        }
    }
    
    // Pre-generated multipliers so bars have different heights
    private let barMultipliers: [CGFloat] = [0.5, 0.8, 0.6, 1.0, 0.7, 0.9, 0.4, 0.85, 0.6, 1.0, 0.7, 0.5, 0.9, 0.6]
}
```

**Thinking state** — slow 3-dot pulse:
```swift
struct ThinkingIndicatorView: View {
    @State private var phase: Double = 0
    
    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3) { index in
                Circle()
                    .frame(width: 5, height: 5)
                    .foregroundColor(.white)
                    .opacity(0.3 + 0.7 * pulse(for: index))
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: false)) {
                phase = 1
            }
        }
    }
    
    private func pulse(for index: Int) -> Double {
        let offset = Double(index) / 3.0
        return abs(sin((phase + offset) * .pi))
    }
}
```

**Speaking state** — reuse `WaveformView` driven by `playbackAudioLevel` from `RealtimeClient`. Add `@Published var playbackAudioLevel: Float = 0` to `RealtimeClient`. Set it from the AVAudioEngine output tap while model audio is playing.

**State → visualization routing** (inside right zone of `NotchBarView`):
```swift
Group {
    switch voiceState {
    case .idle:
        EmptyView()
    case .listening:
        WaveformView(audioLevel: audioLevel)
    case .processing:
        ThinkingIndicatorView()
    case .responding:
        WaveformView(audioLevel: playbackAudioLevel)
    }
}
.frame(width: 165, alignment: .trailing)
.transition(.opacity.animation(.easeInOut(duration: 0.15)))
.animation(.easeInOut(duration: 0.15), value: voiceState)
```

### CompanionManager additions
```swift
@Published var narrationText: String? = nil
```

### RealtimeClient additions
```swift
@Published var playbackAudioLevel: Float = 0
// Update this from AVAudioEngine output node install tap while audio is playing
```

**Files**:
- Modify: `leanring-buddy/NotchBarView.swift` — add HStack layout, StatusTextView, WaveformView, ThinkingIndicatorView
- Create: `leanring-buddy/WaveformView.swift` — the bar chart waveform component
- Create: `leanring-buddy/ThinkingIndicatorView.swift` — the 3-dot pulse
- Modify: `leanring-buddy/CompanionManager.swift` — add `narrationText`
- Modify: `leanring-buddy/RealtimeClient.swift` — add `playbackAudioLevel`, set from audio output tap, set `narrationText` on CompanionManager from conversation events

**Done when**:
- Hotkey → "listening" on left, active waveform on right reacting to voice
- Key up → "thinking" on left, 3-dot pulse on right
- Model speaks → "speaking" on left, waveform on right
- Model narrates tool call ("opening slack") → narration text overrides state text on left
- All transitions between states animate smoothly with no jump

**Do not**:
- Touch the drop panel (Milestone UI-4)
- Change NSPanel resize logic from UI-2
- Touch GlobalPushToTalkShortcutMonitor.swift or BuddyDictationManager audio capture logic

---

## Milestone UI-4: Drop Panel

**Goal**: Hovering over or clicking the expanded notch bar reveals a panel that slides down from underneath it. The panel shows recent interaction history. Users can drag or paste files into it to attach context to the next voice interaction.

**Architecture context**:

### Drop panel window
A second NSPanel owned by `NotchPanelController`, always created but hidden when not in use:
```swift
panel.styleMask = [.borderless, .nonactivatingPanel]
panel.level = NSWindow.Level(rawValue: Int(NSWindow.Level.statusBar.rawValue) + 1)
panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
panel.backgroundColor = .clear   // NSVisualEffectView handles background
panel.isOpaque = false
panel.hasShadow = true
panel.ignoresMouseEvents = false
panel.hidesOnDeactivate = false
panel.isReleasedWhenClosed = false
panel.alphaValue = 0   // hidden initially
```

Drop panel dimensions: 480pt wide × 280pt tall. Positioned directly below the notch bar:
```swift
let dropPanelFrame = NSRect(
    x: notchBarPanel.frame.minX,
    y: notchBarPanel.frame.minY - 280,
    width: 480,
    height: 280
)
```

The drop panel's top corners are flat (flush with the notch bar's bottom edge). Bottom corners have 12pt radius. Implemented in SwiftUI with a `RoundedRectangle(cornerRadii: .init(topLeading: 0, bottomLeading: 12, bottomTrailing: 12, topTrailing: 0))`.

Background: `NSVisualEffectView` with `.hudWindow` material and `.active` state, hosted via `NSHostingView`. Use `ZStack` with the visual effect below and content above:
```swift
struct DropPanelView: View {
    var body: some View {
        ZStack {
            VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
                .clipShape(RoundedRectangle(cornerRadii: ...))
            VStack(spacing: 0) {
                historySection
                Divider().opacity(0.3)
                fileDropZone
            }
        }
    }
}
```

### Show/hide
Use `NSAnimationContext` to animate `alphaValue` and a vertical offset:
```swift
func showDropPanel() {
    guard dropPanel.alphaValue == 0 else { return }
    let targetFrame = ... // positioned below bar
    dropPanel.setFrame(targetFrame, display: false)
    NSAnimationContext.runAnimationGroup { ctx in
        ctx.duration = 0.25
        ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
        dropPanel.animator().alphaValue = 1
    }
}

func hideDropPanel() {
    NSAnimationContext.runAnimationGroup { ctx in
        ctx.duration = 0.2
        dropPanel.animator().alphaValue = 0
    }
}
```

### Hover trigger
Add `NSTrackingArea` to the notch bar's `contentView`:
```swift
let trackingArea = NSTrackingArea(
    rect: contentView.bounds,
    options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
    owner: self,
    userInfo: nil
)
contentView.addTrackingArea(trackingArea)
```

`mouseEntered` → schedule `showDropPanel()` after 0.25s delay (cancel on `mouseExited` if it fires before that). `mouseExited` from BOTH panels → schedule `hideDropPanel()` after 0.8s delay. Cancel the hide timer if mouse re-enters either panel before 0.8s.

Also add a tracking area to the drop panel's contentView so hover on the drop panel itself doesn't dismiss it.

Click on the notch bar toggles the drop panel.

### History section
`CompanionManager` stores last 5 interactions:
```swift
struct Interaction {
    let userPhrase: String       // what the user said (from conversation transcript)
    let modelSummary: String     // first sentence of model's response
    let timestamp: Date
}

@Published var recentInteractions: [Interaction] = []
```

`RealtimeClient` appends to `recentInteractions` when a full conversation turn completes (`response.done` event).

In the drop panel, a `ScrollView` with `VStack` of rows. Each row: small timestamp on left, user phrase and model summary on right. Font: SF Pro, 11pt. Soft gray text on dark background. Max 5 rows.

### File drop zone
Bottom section of the drop panel (~80pt tall). A dashed rounded rectangle with "drop files here" label.

```swift
struct FileDropZone: View {
    @State private var isDragOver = false

    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4]))
            .foregroundColor(.white.opacity(isDragOver ? 0.5 : 0.2))
            .overlay(
                Text("drop files for context")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.4))
            )
            .frame(height: 70)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            .onDrop(of: [.fileURL, .plainText, .pdf], isTargeted: $isDragOver) { providers in
                handleDrop(providers)
                return true
            }
    }
}
```

`handleDrop`: for each dropped item, load the file content as text (for txt/md/code files) or extract visible text (for PDFs using `PDFDocument`). Attach to `CompanionManager.pendingFileContext: [String]`. On the next voice interaction, `RealtimeClient` injects this as a `conversation.item.create` with `type: "message"` and the file content as text before sending `response.create`. Clear `pendingFileContext` after injection.

For image files: convert to base64 PNG. Inject as an image input in the conversation.

If the drop panel is shown while the bar is in idle state (not expanded), it should still work — user can hover over the idle notch and get the panel. The idle notch's `ignoresMouseEvents` must be `false` when the drop panel can be triggered.

**Files**:
- Create: `leanring-buddy/DropPanelView.swift` — the SwiftUI view with history list + file drop zone
- Create: `leanring-buddy/FileDropZone.swift` — the drag-drop component
- Modify: `leanring-buddy/NotchPanelController.swift` — add second NSPanel for drop panel, NSTrackingArea setup, show/hide logic, hover timer management
- Modify: `leanring-buddy/CompanionManager.swift` — add `recentInteractions: [Interaction]`, `pendingFileContext: [String]`, `Interaction` struct
- Modify: `leanring-buddy/RealtimeClient.swift` — append to recentInteractions on response.done, inject pendingFileContext before response.create

**Done when**:
- Hovering over the notch bar (expanded or idle) shows the drop panel sliding down after 0.25s
- Moving cursor away from both panels dismisses after 0.8s
- Clicking bar toggles panel
- Recent interactions show correctly (last 5 turns)
- Dragging a text file onto the zone shows a filename confirmation, queues content for next interaction
- Next voice interaction with a queued file: model clearly has access to the file contents
- Dropping an image: base64 encoded and injected as image input

**Do not**:
- Add PDF text extraction if it requires a new Swift Package dependency — fall back to filename-only for PDFs and flag it for later
- Show the drop panel while the app is in fullscreen mode (check `NSApp.presentationOptions` and suppress)
- Touch GlobalPushToTalkShortcutMonitor.swift
- Change the audio pipeline in any way
