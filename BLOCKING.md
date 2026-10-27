# Wiring Up Network Blocking

## Why this is required

macOS does not let a normal app drop another app's network traffic. The only supported
mechanism is a **content filter system extension** (`NEFilterDataProvider`), which runs
as root inside a sandboxed extension, is installed via `OSSystemExtensionManager`, and
must be explicitly approved by the user in System Settings. It also requires entitlements
(`com.apple.developer.networking.networkextension`) that are only granted to **paid**
Apple Developer Program teams — a free/personal team cannot sign them. That is why the
blocking code in `WatchdogFilterExtension/` ships as an unwired scaffold instead of
being compiled into the app.

## Known limitation: shared UserDefaults do not cross the user→root boundary

The scaffold's `BlockListStore` reads `group.watchdog.shared` via `UserDefaults`, but
sysextd launches the filter extension as **root**, so it resolves the group container
under `/var/root/Library/Group Containers/…`, not your user's. The extension will never
see the block list the app writes, and the KVO reload never fires — step 9 below would
fail silently. Before relying on blocking, change the transport: push the blocked-ID
array through `NEFilterProviderConfiguration.vendorConfiguration` (re-save the filter
preferences in `FilterManager` on every toggle) and read it in the provider, or use XPC.

## Prerequisites

- Paid Apple Developer Program membership (the network extension entitlement is not
  available to free accounts).
- Xcode signed into that team.

## Steps

1. **Add the System Extension target**
   - Xcode > File > New > Target… > macOS > **Network Extension**.
   - Provider type: **Filter Data Provider**. Name it `WatchdogFilterExtension`.
   - If Xcode offers "System Extension" vs "App Extension", choose **System Extension**.
   - Delete the template `FilterDataProvider.swift` Xcode generates and drag in
     `WatchdogFilterExtension/FilterDataProvider.swift` from this repo (add to the
     extension target only).
   - Replace the generated Info.plist's `NetworkExtension` dict with the one in
     `WatchdogFilterExtension/Info.plist` (it should already match:
     `NEProviderClasses` → `com.apple.networkextension.filter-data` →
     `$(PRODUCT_MODULE_NAME).FilterDataProvider`).

2. **Capabilities on the extension target**
   - Signing & Capabilities > + Capability > **Network Extensions** > check
     *Content Filter*.
   - + Capability > **App Groups** > add `group.watchdog.shared`.
   - Compare the result against `WatchdogFilterExtension/extension.entitlements`.

3. **Capabilities on the app target (`watchdog`)**
   - + Capability > **Network Extensions** > check *Content Filter*.
   - + Capability > **App Groups** > add `group.watchdog.shared`.
   - + Capability > **System Extension** (adds
     `com.apple.developer.system-extension.install`).
   - Compare against `WatchdogFilterExtension/app.entitlements`.
   - **Keep the App Sandbox disabled** (`com.apple.security.app-sandbox` must stay
     `false`, `ENABLE_APP_SANDBOX = NO`): sandboxing the app breaks `nettop` spawning
     and `proc_pidpath`, killing all monitoring while blocking setup appears to succeed.
   - Note: on recent macOS, app groups on the Mac are expected to be prefixed with your
     Team ID (`<TEAMID>.group.watchdog.shared`). If you rename the group, update the
     suite name in both `BlockListStore` (extension) and the app's block-list code.

4. **App group registration**
   - Xcode usually auto-registers the group. If signing fails, add the App Group ID in
     the developer portal (Certificates, Identifiers & Profiles > Identifiers >
     App Groups) and enable it on both bundle IDs.

5. **Add the app-side helper**
   - Add a block toggle to the app UI that writes the blocked bundle IDs as a string
     array to the `blockedAppIDs` key of the `group.watchdog.shared` suite (the app has
     no block controls today; they were removed because they had no effect without
     the extension).
   - Drag `WatchdogFilterExtension/FilterManager.swift` into the **app** target.
   - Set `FilterManager.extensionBundleID` to the extension target's actual bundle ID.
   - Call `activateExtension()` from your UI (e.g. an "Enable blocking" button);
     `enableFilter()` runs automatically after activation succeeds.

6. **Embed the extension**
   - App target > Build Phases: ensure the extension is embedded in
     `Contents/Library/SystemExtensions/` (Xcode's "Embed System Extensions" phase —
     added automatically when you create the target as a system extension).

7. **Local development mode**
   - System extensions normally only load from `/Applications` with valid signing.
     For iterating from Xcode's build folder run:

     ```
     systemextensionsctl developer on
     ```

     (Requires SIP-allowed configuration on some setups; `systemextensionsctl list`
     shows what is loaded, `systemextensionsctl reset` clears stuck extensions.)

8. **Approval flow (what the user sees)**
   - On first `activateExtension()`, macOS shows "System Extension Blocked". Approve in
     **System Settings > General > Login Items & Extensions > Network Extensions**.
   - When the filter config is saved, macOS asks to allow the content filter
     ("Watchdog would like to filter network content"). Approve it. The filter then
     appears under **System Settings > Network > Filters**.

9. **Verify**
   - Add an app's bundle ID (e.g. `com.apple.Safari`) to the block list in Watchdog,
     then confirm that app loses connectivity. `log stream --predicate
     'subsystem == "watchdog.filter"'` shows drop decisions.
