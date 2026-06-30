# PadLinkVirtualGamepad — DriverKit extension (scaffold)

This folder holds the **DriverKit System Extension** source that publishes a
virtual Xbox-style HID gamepad on macOS. It is **not** part of the app targets —
it must be added as its own **DriverKit Extension** target in Xcode and built
with the DriverKit toolchain. (Your IDE will flag missing `DriverKit/…` and
`*.h` includes here; those headers are the IIG-generated + DriverKit SDK headers
that only resolve inside the dext target — that's expected.)

## Files
| File | Purpose |
|---|---|
| `PadLinkVirtualGamepad.iig/.cpp` | `IOUserHIDDevice` subclass: HID report descriptor + `postInput()` that emits reports |
| `PadLinkUserClient.iig/.cpp` | `IOUserClient`: app opens this; **selector 0** → `device->postInput()` |
| `Info.plist` | `IOKitPersonalities` (virtual device via `IOUserResources`) + `UserClientProperties` |
| `PadLinkVirtualGamepad.entitlements` | the DriverKit HID + userclient-access entitlements |

The app side already exists: `padlink - macos/Controller/DriverKitHIDBackend.swift`
opens this client and calls selector 0 with a **16-byte submit struct**
(`u16 buttons | u8 dpad | u8 pad | i16 lx,ly,rx,ry | u16 lt | u16 rt`), which
`postInput()` parses. `SystemExtensionManager.swift` requests activation.

## Add the target in Xcode
1. **File → New → Target → macOS → DriverKit Driver**, name `PadLinkVirtualGamepad`,
   embed in the `padlink - macos` app.
2. Replace the generated sources with the files in this folder (and set this
   `Info.plist` / `.entitlements` on the target).
3. Bundle ID: `com.stackfinity.padlink.macos.PadLinkVirtualGamepad` (must be
   prefixed by the app ID). Set your Team.
4. App target → **Build Phases → Embed System Extensions** (added automatically
   when you embed during target creation — verify it's present).

## Entitlements (granted by Apple to your team)
- dext: `com.apple.developer.driverkit`, `…driverkit.family.hid.device`,
  `…driverkit.transport.hid`, `…driverkit.userclient-access` (= the app's ID).
- app: `com.apple.developer.system-extension.install` (already set).

## Run / test
1. Build & run the `padlink - macos` app.
2. Click **Enable virtual controller** on the dashboard → approve in
   **System Settings → Privacy & Security**.
   - For local iteration without notarization: `systemextensionsctl developer on`.
3. Verify it loaded: `ioreg -l | grep -i -E "padlink|gamepad"` and the dashboard
   **Backend:** line should read **DriverKit HID** (not `logging`).
4. Open a controller test (e.g. a web gamepad tester) or a game and press buttons
   on the phone.

## Known scaffold caveats (iterate on-device)
- **Matching:** uses `IOUserResources` so the virtual device loads without
  hardware. If it doesn't instantiate, adjust the personality (some setups match
  a HID transport provider instead).
- **Report posting:** `postInput()` builds the report into an
  `IOBufferMemoryDescriptor` and calls `handleReport()`. Confirm the `Map(...)`
  call and report length against the current HIDDriverKit headers.
- **Axis sign / hat encoding:** stick Y polarity and the hat null value
  (`0x0F`) may need tweaking so games read directions correctly.
