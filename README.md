# PadLink — Apple platforms (iOS sender + macOS receiver)

PadLink turns a phone into a **game controller** for a computer. This Xcode
project contains two targets that share one wire protocol:

- **`padlink - ios`** — the iOS *sender*: an on-screen gamepad (and gyro/haptics)
  that streams controller input to a paired computer.
- **`padlink - macos`** — the macOS *receiver*: discovers itself on the local
  network, pairs with a phone, and presents a **virtual game controller** to the
  system so games detect a real gamepad and switch to controller prompts.

> The Android sender and a Windows receiver live in sibling folders
> (`padlink - android/`, `padlink - windows/`) and speak the same protocol
> (`../PROTOCOL.md`). This README focuses on the Apple targets and, in
> particular, the **DriverKit System Extension** the macOS receiver uses.

---

## Why this project needs a DriverKit entitlement

To present a **system-wide gamepad** that every macOS game detects (via
`IOHIDManager` / `GameController.framework`), the macOS app embeds a **DriverKit
System Extension** that publishes a **virtual HID gamepad**. A kext is not an
option (deprecated / blocked on Apple Silicon), and `GameController.framework`
can only *read* controllers, not *create* one. A DriverKit `IOUserHIDDevice` is
the only supported way to expose a virtual gamepad to other apps.

The project is three components: the macOS host app, its embedded DriverKit
extension (the dext bundle ID is prefixed by the app's, as DriverKit requires),
and the iOS sender app. Exact identifiers and team are configured in the Xcode
project / signing settings.

### Entitlements requested (and exactly how each is used)
**On the DriverKit extension:**
- `com.apple.developer.driverkit` — base DriverKit capability.
- `com.apple.developer.driverkit.family.hid.device` — the dext is an
  `IOUserHIDDevice` that registers **one virtual HID gamepad** with an
  Xbox-style report descriptor (16 buttons, one 8-way hat, two thumbsticks,
  two analog triggers).
- `com.apple.developer.driverkit.transport.hid` — HID transport for that device.
- `com.apple.developer.driverkit.userclient-access` — scoped to **only** the
  macOS host app, the single signed app allowed to open the dext's `IOUserClient`.

**On the macOS app:**
- `com.apple.developer.system-extension.install` — to install/activate the dext
  via `OSSystemExtensionManager` (user approves once in System Settings).

### How the app talks to the driver
The app and dext communicate **only** through a dedicated `IOUserClient`. When
the macOS app receives an input packet from the paired phone, it calls a single
`externalMethod` — **selector 0, `submitReport`** — passing a packed HID report
struct; the dext then calls `handleReport()` on the virtual device. There is no
other interface. (App-side client: `padlink - macos/Controller/DriverKitHIDBackend.swift`.)

### Scope & safety (what the driver does *not* do)
- It generates **only HID gamepad reports**, and only from a device the user has
  **explicitly paired** (PIN pairing, see `../PROTOCOL.md` §4).
- It does **not** synthesize keyboard or mouse input.
- It does **not** read, observe, or intercept any system or user input.
- It exposes **no** functionality beyond the single virtual gamepad.
- The whole app is **Developer ID–signed and notarized**; the dext is embedded in
  `Contents/Library/SystemExtensions/`.

A development fallback (`LoggingBackend`) lets the rest of the app (discovery,
pairing, networking, UI) run before the signed dext is installed, so input is
logged rather than injected until the extension is approved.

---

## Architecture

```
 ┌─────────────┐        Wi-Fi (LAN) or USB         ┌──────────────────────────┐
 │  Phone app  │  ── mDNS discover ───────────────▶ │   macOS receiver app     │
 │ (sender)    │  ── TCP control (JSON, pairing) ──▶│  • Bonjour advertise     │
 │  on-screen  │  ── UDP / TCP input (32-byte) ───▶ │  • input server + auth   │
 │  controls   │                                    │  • DriverKit virtual HID │
 └─────────────┘                                    │    gamepad (this dext)   │
                                                     └──────────────────────────┘
```

- **Input** is a fixed 32-byte packet (buttons, d-pad, two sticks, two triggers),
  authenticated per-packet by session ID + token. See `../PROTOCOL.md` §5.
- **Control/pairing** is newline-delimited JSON over TCP. See `../PROTOCOL.md` §4.
- The receiver maps every packet onto a standard Xbox-style virtual pad,
  regardless of the on-screen layout (Xbox / PlayStation / Switch) the phone
  displays — the layout is cosmetic only.

## Build & run

Open **`padlink - ios.xcodeproj`** in Xcode (26+). Two targets:
- `padlink - ios` → run on an iPhone.
- `padlink - macos` → run on the Mac; press **Start Receiver**, then pair the
  phone with the shown PIN.

DriverKit setup (target creation, entitlements, signing, notarization, and the
`OSSystemExtensionManager` activation flow) is documented in
[`../docs/macos-driverkit.md`](../docs/macos-driverkit.md).

## Repository

- `../PROTOCOL.md` — the shared wire protocol (source of truth for all apps).
- `../docs/macos-driverkit.md` — DriverKit extension implementation guide.
- `padlink - macos/Controller/` — virtual-controller backends (`DriverKitHIDBackend`,
  logging fallback) and the layout model.
