# SODS Progress

Date: 2026-02-04

## What Changed Today

- Canonical repo structure established under `firmware/`, `apps/`, `cli/`, `tools/`, and `docs/`.
- `node-agent` + `ops-portal` firmware moved into `firmware/`.
- Dev Station app moved into `apps/dev-station`.
- CLI/spine server moved into `cli/sods` and CLI commands updated to use `/v1/events` for IP discovery.
- Ops Portal refactored into `portal-core` + `portal-device-cyd` modules with orientation-as-function (Utility/Watch modes).
- ESP Web Tools staging/flash scripts preserved and wired for repo-root invocation.
- Legacy aliases (`tools/camutil`, `tools/cockpit`) retained as shims.
- Reference PDFs moved to `docs/reference`, archive zip to `docs/archive`, and data logs to `data/strangelab`.
- Spectrum Frame Spec documented and wired across Station + Dev Station + Ops Portal.
- Frame engine now emits field positions (x/y/z) and tool runs inject local tool events into the visualizer stream.
- Dev Station spectrum field now supports tap overlay, node inspector, idle state, and improved depth/repulsion.
- Visualizer upgraded with focus mode, pulses, and field haze for a richer 4D feel.
- Visualizer now renders subtle bin arcs and supports pinning nodes for persistent tracking.
- Added gentle attraction for related sources plus orbital drift to make the field feel alive.
- Quick overlay now surfaces hottest source + current focus for at-a-glance context.
- Added replay scrub (last 60s window), connection lines, and legend overlay for signal families.
- Added replay autoplay + replay progress bar; pinned list now supports focus shortcuts.
- Ghost trails + scrub bar seek make the spectrum replay feel alive and controllable.
- Replay speed control added; ghost trails now decay by real time age.
- Ghost trails now tinted by source color for identity continuity.
- Focus labels now prefer real aliases (hostname/IP) when available.
- Alias resolution now uses station-provided alias map and local event fields (SSID/hostname/IP/BSSID) across the app.
- Added alias override editor in Dev Station; overrides persist locally and flow to portal via station.
- Ops Portal visualizer now renders rings, pulses, and legend text for parity.
- Ops Portal: touch toggles focus mode + replay bar scrub (basic parity).
- Ops Portal status now shows focused source label and replay state.
- Focus label shortened to friendly suffix (last segment or last 6 chars).

## Current Architecture (Locked)

- Tier 0: **Dev Station (macOS)** = primary operator UI.
- Tier 1: **Pi Aux + Logger** = `/v1/events` source of truth.
- Tier 2: **node-agent** (ESP32/ESP32-C3) = sensor nodes emitting `node.announce` + `wifi.status`.
- **Ops Portal (CYD)** = dedicated field UI with Utility (landscape) + Watch (portrait) modes.

## Canonical Paths

- CLI + spine server: `cli/sods`
- Dev Station app: `apps/dev-station/DevStation.xcodeproj`
- Node agent firmware: `firmware/node-agent`
- Ops Portal firmware: `firmware/ops-portal`
- Scripts + shims: `tools`

## Commands (Canonical)

Spine dev:
```bash
cd cli/sods
npm install
npm run dev -- --pi-logger http://pi-logger.local:8088 --port 9123
```

CLI (event-based):
```bash
./tools/sods whereis <node_id>
./tools/sods open <node_id>
./tools/sods tail <node_id>
```

Node agent build + stage:
```bash
cd firmware/node-agent
./tools/build-stage-esp32dev.sh
./tools/build-stage-esp32c3.sh
```

Ops Portal build:
```bash
cd firmware/ops-portal
pio run -e ops-portal
```

Tools are runnable from any working directory. Use an absolute path or `cd` to the repo root before running `./tools/...`.
If executables lose permissions, run `/Users/letsdev/sods/SODS/tools/permfix.sh`.

## Notes

- `/v1/events` only supports `node_id` + `limit`, so CLI filters client-side for `wifi.status` and `node.announce`.
- Ops Portal Watch Mode: tap anywhere to show a 2–3 stat overlay that auto-hides.
- CLI flags split: `--logger` for pi-logger, `--station` for spine endpoints.
- Tool Registry is now shared between CLI and Dev Station (`docs/tool-registry.json`), and only passive tools are exposed.
- Visual model unified: hue=identity, brightness=recency, saturation=confidence, glow=correlation with smooth decay.
- Added launchd LaunchAgent (optional) for station auto-run on login.
- Flash UX: station serves `/api/flash` and `/flash/*` pages; Dev Station popover opens the right flasher URLs.
- Dev Station now uses in-app sheets for tools, API inspector, tool runner, and viewer; only Flash opens external browser.
- Dev Station local paths now default to `~/SODS/*` (inbox/workspace/reports/.shipper/oui).
- Added Tool Builder + Presets system (user registries in `docs/*.user.json`, scripts under `tools/user/`).

## LaunchAgent

Install:
```bash
/Users/letsdev/sods/SODS/tools/launchagent-install.sh
```

Uninstall:
```bash
/Users/letsdev/sods/SODS/tools/launchagent-uninstall.sh
```

Status:
```bash
/Users/letsdev/sods/SODS/tools/launchagent-status.sh
```

Logs:
- `/Users/letsdev/sods/SODS/data/logs/station.launchd.log`

## Flash Button

- Flash popover opens:
  - `http://localhost:9123/flash/esp32`
  - `http://localhost:9123/flash/esp32c3`
- If station is not running, Dev Station starts it and opens the URL once healthy.

## Dev Station Build Log (First 50 Lines)

```
Building Dev Station...
Command line invocation:
    /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild -project /Users/letsdev/sods/SODS/apps/dev-station/DevStation.xcodeproj -scheme DevStation -configuration Release -derivedDataPath /Users/letsdev/sods/SODS/dist/DerivedData CODE_SIGNING_ALLOWED=NO build

Build settings from command line:
    CODE_SIGNING_ALLOWED = NO

ComputePackagePrebuildTargetDependencyGraph

Prepare packages

CreateBuildRequest

SendProjectDescription

CreateBuildOperation

ComputeTargetDependencyGraph
note: Building targets in dependency order
note: Target dependency graph (1 target)
    Target 'DevStation' in project 'DevStation' (no dependencies)

GatherProvisioningInputs

CreateBuildDescription

ClangStatCache /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang-stat-cache /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.2.sdk /Users/letsdev/sods/SODS/dist/DerivedData/SDKStatCaches.noindex/macosx26.2-25C57-00fa09913b459cbbc988d1f6730289ae.sdkstatcache
    cd /Users/letsdev/sods/SODS/apps/dev-station/DevStation.xcodeproj
    /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang-stat-cache /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.2.sdk -o /Users/letsdev/sods/SODS/dist/DerivedData/SDKStatCaches.noindex/macosx26.2-25C57-00fa09913b459cbbc988d1f6730289ae.sdkstatcache

SwiftDriver DevStation normal arm64 com.apple.xcode.tools.swift.compiler (in target 'DevStation' from project 'DevStation')
    cd /Users/letsdev/sods/SODS/apps/dev-station
    builtin-SwiftDriver -- /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc -module-name DevStation -O -enforce-exclusivity\=checked @/Users/letsdev/sods/SODS/dist/DerivedData/Build/Intermediates.noindex/DevStation.build/Release/DevStation.build/Objects-normal/arm64/DevStation.SwiftFileList -enable-bare-slash-regex -enable-experimental-feature DebugDescriptionMacro -sdk /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.2.sdk -target arm64-apple-macos13.0 -g -module-cache-path /Users/letsdev/sods/SODS/dist/DerivedData/ModuleCache.noindex -Xfrontend -serialize-debugging-options -swift-version 5 -I /Users/letsdev/sods/SODS/dist/DerivedData/Build/Products/Release -F /Users/letsdev/sods/SODS/dist/DerivedData/Build/Products/Release -c -j8 -enable-batch-mode -incremental -Xcc -ivfsstatcache -Xcc /Users/letsdev/sods/SODS/dist/DerivedData/SDKStatCaches.noindex/macosx26.2-25C57-00fa09913b459cbbc988d1f6730289ae.sdkstatcache -output-file-map /Users/letsdev/sods/SODS/dist/DerivedData/Build/Intermediates.noindex/DevStation.build/Release/DevStation.build/Objects-normal/arm64/DevStation-OutputFileMap.json -use-frontend-parseable-output -save-temps -no-color-diagnostics -explicit-module-build -module-cache-path /Users/letsdev/sods/SODS/dist/DerivedData/Build/Intermediates.noindex/SwiftExplicitPrecompiledModules -clang-scanner-module-cache-path /Users/letsdev/sods/SODS/dist/DerivedData/ModuleCache.noindex -sdk-module-cache-path /Users/letsdev/sods/SODS/dist/DerivedData/ModuleCache.noindex -serialize-diagnostics -emit-dependencies -emit-module -emit-module-path /Users/letsdev/sods/SODS/dist/DerivedData/Build/Intermediates.noindex/DevStation.build/Release/DevStation.build/Objects-normal/arm64/DevStation.swiftmodule -validate-clang-modules-once -clang-build-session-file /Users/letsdev/sods/SODS/dist/DerivedData/ModuleCache.noindex/Session.modulevalidation -Xcc -I/Users/letsdev/sods/SODS/dist/DerivedData/Build/Intermediates.noindex/DevStation.build/Release/DevStation.build/swift-overrides.hmap -emit-const-values -Xfrontend -const-gather-protocols-file -Xfrontend /Users/letsdev/sods/SODS/dist/DerivedData/Build/Intermediates.noindex/DevStation.build/Release/DevStation.build/Objects-normal/arm64/DevStation_const_extract_protocols.json -Xcc -iquote -Xcc /Users/letsdev/sods/SODS/dist/DerivedData/Build/Intermediates.noindex/DevStation.build/Release/DevStation.build/DevStation-generated-files.hmap -Xcc -I/Users/letsdev/sods/SODS/dist/DerivedData/Build/Intermediates.noindex/DevStation.build/Release/DevStation.build/DevStation-own-target-headers.hmap -Xcc -I/Users/letsdev/sods/SODS/dist/DerivedData/Build/Intermediates.noindex/DevStation.build/Release/DevStation.build/DevStation-all-target-headers.hmap -Xcc -iquote -Xcc /Users/letsdev/sods/SODS/dist/DerivedData/Build/Intermediates.noindex/DevStation.build/Release/DevStation.build/DevStation-project-headers.hmap -Xcc -I/Users/letsdev/sods/SODS/dist/DerivedData/Build/Products/Release/include -Xcc -I/Users/letsdev/sods/SODS/dist/DerivedData/Build/Intermediates.noindex/DevStation.build/Release/DevStation.build/DerivedSources-normal/arm64 -Xcc -I/Users/letsdev/sods/SODS/dist/DerivedData/Build/Intermediates.noindex/DevStation.build/Release/DevStation.build/DerivedSources/arm64 -Xcc -I/Users/letsdev/sods/SODS/dist/DerivedData/Build/Intermediates.noindex/DevStation.build/Release/DevStation.build/DerivedSources -emit-objc-header -emit-objc-header-path /Users/letsdev/sods/SODS/dist/DerivedData/Build/Intermediates.noindex/DevStation.build/Release/DevStation.build/Objects-normal/arm64/DevStation-Swift.h -working-directory /Users/letsdev/sods/SODS/apps/dev-station -experimental-emit-module-separately -disable-cmo

SwiftCompile normal arm64 Compiling\ BLEScanner.swift,\ BLEProber.swift /Users/letsdev/sods/SODS/apps/dev-station/DevStation/BLEScanner.swift /Users/letsdev/sods/SODS/apps/dev-station/DevStation/BLEProber.swift (in target 'DevStation' from project 'DevStation')
```

## Dev Station Build Log (Last 50 Lines)

```
    

SwiftDriverJobDiscovery normal arm64 Compiling Payloads.swift (in target 'DevStation' from project 'DevStation')

SwiftDriverJobDiscovery normal arm64 Compiling BonjourDiscovery.swift (in target 'DevStation' from project 'DevStation')

SwiftDriverJobDiscovery normal arm64 Compiling RTSPHardProbe.swift (in target 'DevStation' from project 'DevStation')

SwiftDriverJobDiscovery normal arm64 Compiling ONVIFDiscovery.swift (in target 'DevStation' from project 'DevStation')

SwiftDriverJobDiscovery normal arm64 Compiling DevStationApp.swift, ContentView.swift, ToolRegistry.swift (in target 'DevStation' from project 'DevStation')

SwiftDriver\ Compilation DevStation normal arm64 com.apple.xcode.tools.swift.compiler (in target 'DevStation' from project 'DevStation')
    cd /Users/letsdev/sods/SODS/apps/dev-station
    builtin-Swift-Compilation -- /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc -module-name DevStation -O -enforce-exclusivity\=checked @/Users/letsdev/sods/SODS/dist/DerivedData/Build/Intermediates.noindex/DevStation.build/Release/DevStation.build/Objects-normal/arm64/DevStation.SwiftFileList -enable-bare-slash-regex -enable-experimental-feature DebugDescriptionMacro -sdk /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.2.sdk -target arm64-apple-macos13.0 -g -module-cache-path /Users/letsdev/sods/SODS/dist/DerivedData/ModuleCache.noindex -Xfrontend -serialize-debugging-options -swift-version 5 -I /Users/letsdev/sods/SODS/dist/DerivedData/Build/Products/Release -F /Users/letsdev/sods/SODS/dist/DerivedData/Build/Products/Release -c -j8 -enable-batch-mode -incremental -Xcc -ivfsstatcache -Xcc /Users/letsdev/sods/SODS/dist/DerivedData/SDKStatCaches.noindex/macosx26.2-25C57-00fa09913b459cbbc988d1f6730289ae.sdkstatcache -output-file-map /Users/letsdev/sods/SODS/dist/DerivedData/Build/Intermediates.noindex/DevStation.build/Release/DevStation.build/Objects-normal/arm64/DevStation-OutputFileMap.json -use-frontend-parseable-output -save-temps -no-color-diagnostics -explicit-module-build -module-cache-path /Users/letsdev/sods/SODS/dist/DerivedData/Build/Intermediates.noindex/SwiftExplicitPrecompiledModules -clang-scanner-module-cache-path /Users/letsdev/sods/SODS/dist/DerivedData/ModuleCache.noindex -sdk-module-cache-path /Users/letsdev/sods/SODS/dist/DerivedData/ModuleCache.noindex -serialize-diagnostics -emit-dependencies -emit-module -emit-module-path /Users/letsdev/sods/SODS/dist/DerivedData/Build/Intermediates.noindex/DevStation.build/Release/DevStation.build/Objects-normal/arm64/DevStation.swiftmodule -validate-clang-modules-once -clang-build-session-file /Users/letsdev/sods/SODS/dist/DerivedData/ModuleCache.noindex/Session.modulevalidation -Xcc -I/Users/letsdev/sods/SODS/dist/DerivedData/Build/Intermediates.noindex/DevStation.build/Release/DevStation.build/swift-overrides.hmap -emit-const-values -Xfrontend -const-gather-protocols-file -Xfrontend /Users/letsdev/sods/SODS/dist/DerivedData/Build/Intermediates.noindex/DevStation.build/Release/DevStation.build/Objects-normal/arm64/DevStation_const_extract_protocols.json -Xcc -iquote -Xcc /Users/letsdev/sods/SODS/dist/DerivedData/Build/Intermediates.noindex/DevStation.build/Release/DevStation.build/DevStation-generated-files.hmap -Xcc -I/Users/letsdev/sods/SODS/dist/DerivedData/Build/Intermediates.noindex/DevStation.build/Release/DevStation.build/DevStation-own-target-headers.hmap -Xcc -I/Users/letsdev/sods/SODS/dist/DerivedData/Build/Intermediates.noindex/DevStation.build/Release/DevStation.build/DevStation-all-target-headers.hmap -Xcc -iquote -Xcc /Users/letsdev/sods/SODS/dist/DerivedData/Build/Intermediates.noindex/DevStation.build/Release/DevStation.build/DevStation-project-headers.hmap -Xcc -I/Users/letsdev/sods/SODS/dist/DerivedData/Build/Products/Release/include -Xcc -I/Users/letsdev/sods/SODS/dist/DerivedData/Build/Intermediates.noindex/DevStation.build/Release/DevStation.build/DerivedSources-normal/arm64 -Xcc -I/Users/letsdev/sods/SODS/dist/DerivedData/Build/Intermediates.noindex/DevStation.build/Release/DevStation.build/DerivedSources/arm64 -Xcc -I/Users/letsdev/sods/SODS/dist/DerivedData/Build/Intermediates.noindex/DevStation.build/Release/DevStation.build/DerivedSources -emit-objc-header -emit-objc-header-path /Users/letsdev/sods/SODS/dist/DerivedData/Build/Intermediates.noindex/DevStation.build/Release/DevStation.build/Objects-normal/arm64/DevStation-Swift.h -working-directory /Users/letsdev/sods/SODS/apps/dev-station -experimental-emit-module-separately -disable-cmo

Ld /Users/letsdev/sods/SODS/dist/DerivedData/Build/Products/Release/DevStation.app/Contents/MacOS/DevStation normal (in target 'DevStation' from project 'DevStation')
    cd /Users/letsdev/sods/SODS/apps/dev-station
    /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang -Xlinker -reproducible -target arm64-apple-macos13.0 -isysroot /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.2.sdk -Os -L/Users/letsdev/sods/SODS/dist/DerivedData/Build/Intermediates.noindex/EagerLinkingTBDs/Release -L/Users/letsdev/sods/SODS/dist/DerivedData/Build/Products/Release -F/Users/letsdev/sods/SODS/dist/DerivedData/Build/Intermediates.noindex/EagerLinkingTBDs/Release -F/Users/letsdev/sods/SODS/dist/DerivedData/Build/Products/Release -filelist /Users/letsdev/sods/SODS/dist/DerivedData/Build/Intermediates.noindex/DevStation.build/Release/DevStation.build/Objects-normal/arm64/DevStation.LinkFileList -Xlinker -rpath -Xlinker /usr/lib/swift -Xlinker -rpath -Xlinker @executable_path/../Frameworks -Xlinker -object_path_lto -Xlinker /Users/letsdev/sods/SODS/dist/DerivedData/Build/Intermediates.noindex/DevStation.build/Release/DevStation.build/Objects-normal/arm64/DevStation_lto.o -Xlinker -dependency_info -Xlinker /Users/letsdev/sods/SODS/dist/DerivedData/Build/Intermediates.noindex/DevStation.build/Release/DevStation.build/Objects-normal/arm64/DevStation_dependency_info.dat -fobjc-link-runtime -L/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/macosx -L/usr/lib/swift -Xlinker -add_ast_path -Xlinker /Users/letsdev/sods/SODS/dist/DerivedData/Build/Intermediates.noindex/DevStation.build/Release/DevStation.build/Objects-normal/arm64/DevStation.swiftmodule @/Users/letsdev/sods/SODS/dist/DerivedData/Build/Intermediates.noindex/DevStation.build/Release/DevStation.build/Objects-normal/arm64/DevStation-linker-args.resp -o /Users/letsdev/sods/SODS/dist/DerivedData/Build/Products/Release/DevStation.app/Contents/MacOS/DevStation

CopySwiftLibs /Users/letsdev/sods/SODS/dist/DerivedData/Build/Products/Release/DevStation.app (in target 'DevStation' from project 'DevStation')
    cd /Users/letsdev/sods/SODS/apps/dev-station
    builtin-swiftStdLibTool --copy --verbose --scan-executable /Users/letsdev/sods/SODS/dist/DerivedData/Build/Products/Release/DevStation.app/Contents/MacOS/DevStation --scan-folder /Users/letsdev/sods/SODS/dist/DerivedData/Build/Products/Release/DevStation.app/Contents/Frameworks --scan-folder /Users/letsdev/sods/SODS/dist/DerivedData/Build/Products/Release/DevStation.app/Contents/PlugIns --scan-folder /Users/letsdev/sods/SODS/dist/DerivedData/Build/Products/Release/DevStation.app/Contents/Library/SystemExtensions --scan-folder /Users/letsdev/sods/SODS/dist/DerivedData/Build/Products/Release/DevStation.app/Contents/Extensions --platform macosx --toolchain /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain --destination /Users/letsdev/sods/SODS/dist/DerivedData/Build/Products/Release/DevStation.app/Contents/Frameworks --strip-bitcode --strip-bitcode-tool /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/bitcode_strip --emit-dependency-info /Users/letsdev/sods/SODS/dist/DerivedData/Build/Intermediates.noindex/DevStation.build/Release/DevStation.build/SwiftStdLibToolInputDependencies.dep --filter-for-swift-os --back-deploy-swift-span
Ignoring --strip-bitcode because --sign was not passed

ExtractAppIntentsMetadata (in target 'DevStation' from project 'DevStation')
    cd /Users/letsdev/sods/SODS/apps/dev-station
    /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/appintentsmetadataprocessor --toolchain-dir /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain --module-name DevStation --sdk-root /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.2.sdk --xcode-version 17C52 --platform-family macOS --deployment-target 13.0 --bundle-identifier com.example.DevStation --output /Users/letsdev/sods/SODS/dist/DerivedData/Build/Products/Release/DevStation.app/Contents/Resources --target-triple arm64-apple-macos13.0 --binary-file /Users/letsdev/sods/SODS/dist/DerivedData/Build/Products/Release/DevStation.app/Contents/MacOS/DevStation --dependency-file /Users/letsdev/sods/SODS/dist/DerivedData/Build/Intermediates.noindex/DevStation.build/Release/DevStation.build/Objects-normal/arm64/DevStation_dependency_info.dat --stringsdata-file /Users/letsdev/sods/SODS/dist/DerivedData/Build/Intermediates.noindex/DevStation.build/Release/DevStation.build/Objects-normal/arm64/ExtractedAppShortcutsMetadata.stringsdata --source-file-list /Users/letsdev/sods/SODS/dist/DerivedData/Build/Intermediates.noindex/DevStation.build/Release/DevStation.build/Objects-normal/arm64/DevStation.SwiftFileList --metadata-file-list /Users/letsdev/sods/SODS/dist/DerivedData/Build/Intermediates.noindex/DevStation.build/Release/DevStation.build/DevStation.DependencyMetadataFileList --static-metadata-file-list /Users/letsdev/sods/SODS/dist/DerivedData/Build/Intermediates.noindex/DevStation.build/Release/DevStation.build/DevStation.DependencyStaticMetadataFileList --swift-const-vals-list /Users/letsdev/sods/SODS/dist/DerivedData/Build/Intermediates.noindex/DevStation.build/Release/DevStation.build/Objects-normal/arm64/DevStation.SwiftConstValuesFileList --compile-time-extraction --deployment-aware-processing --validate-assistant-intents --no-app-shortcuts-localization
2026-02-04 00:29:31.075 appintentsmetadataprocessor[47829:5687169] Starting appintentsmetadataprocessor export
2026-02-04 00:29:31.078 appintentsmetadataprocessor[47829:5687169] warning: Metadata extraction skipped. No AppIntents.framework dependency found.

RegisterExecutionPolicyException /Users/letsdev/sods/SODS/dist/DerivedData/Build/Products/Release/DevStation.app (in target 'DevStation' from project 'DevStation')
    cd /Users/letsdev/sods/SODS/apps/dev-station
    builtin-RegisterExecutionPolicyException /Users/letsdev/sods/SODS/dist/DerivedData/Build/Products/Release/DevStation.app

Validate /Users/letsdev/sods/SODS/dist/DerivedData/Build/Products/Release/DevStation.app (in target 'DevStation' from project 'DevStation')
    cd /Users/letsdev/sods/SODS/apps/dev-station
    builtin-validationUtility /Users/letsdev/sods/SODS/dist/DerivedData/Build/Products/Release/DevStation.app -no-validate-extension -infoplist-subpath Contents/Info.plist

Touch /Users/letsdev/sods/SODS/dist/DerivedData/Build/Products/Release/DevStation.app (in target 'DevStation' from project 'DevStation')
    cd /Users/letsdev/sods/SODS/apps/dev-station
    /usr/bin/touch -c /Users/letsdev/sods/SODS/dist/DerivedData/Build/Products/Release/DevStation.app

RegisterWithLaunchServices /Users/letsdev/sods/SODS/dist/DerivedData/Build/Products/Release/DevStation.app (in target 'DevStation' from project 'DevStation')
    cd /Users/letsdev/sods/SODS/apps/dev-station
    /System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister -f -R -trusted /Users/letsdev/sods/SODS/dist/DerivedData/Build/Products/Release/DevStation.app

** BUILD SUCCEEDED **

Built: /Users/letsdev/sods/SODS/dist/DevStation.app
```
