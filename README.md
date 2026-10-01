# PTZ Pad

A small macOS app that drives the FoMaKo (Minrray) PTZ camera with an Xbox
controller over Bluetooth. Talks raw VISCA over UDP (port 5678 on the camera).
It also previews the camera's NDI feed, runs it through picture adjustments, a
creative effect and optional face/body/eye detection boxes, and republishes the
result as a Syphon feed for Resolume, TouchDesigner or OBS.

## Build & run

Needs the Xcode Command Line Tools (Swift 5.9+), plus:

- **Syphon.framework** to build — not part of macOS. `Package.swift` links the copy
  inside TouchDesigner or OBS (or `/Library/Frameworks`), and the build scripts copy it
  into the app bundle, the same way segcam does.
- **The NDI runtime** to receive video — install [NDI Tools](https://ndi.video/tools/).
  `libndi.dylib` is loaded at run time (`/usr/local/lib`, `$NDI_RUNTIME_DIR_V6/V5`, NDI
  Tools' apps or Resolume's copy), so the app builds and runs without it, just with no
  video.

```bash
./make-app.sh            # release build → build/PTZPad.app
open build/PTZPad.app
```

For hacking: `swift run` builds and launches it from the terminal, or open
`Package.swift` in Xcode and press Run.

## Release (signed + notarized DMG)

```bash
./release.sh             # universal build → sign → DMG → notarize → staple → dist/PTZPad-1.1.dmg
./release.sh --skip-notarize
```

Needs the "Developer ID Application" certificate in the login keychain and, once,
notarization credentials stored under the keychain profile `PTZPad-Notary`:

```bash
xcrun notarytool store-credentials "PTZPad-Notary" \
    --apple-id "<Apple ID email>" --team-id CM9NHRF538 --password "<app-specific password>"
```

Builds run in `~/Library/Caches/ptz-pad-build`, not `.build/`: this folder lives in
iCloud Drive, and the Swift compiler hangs forever on module-cache files that iCloud
has evicted. Bump `VERSION` / `BUILD_NUMBER` at the top of `release.sh` for new releases.

## Video

The **Video** panel picks an NDI source — on first run it picks the one on the camera's
IP automatically. Each frame then goes through:

1. **Brightness / contrast / saturation** (Core Image `CIColorControls`).
2. **Effect** — edge detect, edge work, sketch, comic, posterize, pixelate, halftone,
   thermal, X-ray, invert, noir, bloom, kaleidoscope — with one **Amount** slider whose
   meaning depends on the effect (its label says which).
3. **Detection boxes** (ported from segcam) — Vision face landmarks and human rectangles
   drawn as green boxes with ID chips (`face#12`, `eye.L#12`, `body#13`). Faces, bodies,
   eyes and mouths switch separately. Detection looks at the adjusted picture *before*
   the effect, on a 960-wide copy on its own queue, so it never stalls the video. Like
   segcam, nothing is tracked: each pass gets fresh numbers.

The preview shows exactly the frame that goes out over **Syphon** (server name
"Camera" by default — in Resolume it appears under Sources › Syphon as
"PTZ Pad – Camera"). Frames are only copied to Syphon while a client is connected.
**Flip** is on by default because Resolume reads Syphon rows bottom-up; untick it if
another client (TouchDesigner, segcam) shows the feed upside down. Rename the feed and press Return to
republish under the new name.

The release build is signed with `com.apple.security.cs.disable-library-validation`:
the hardened runtime would otherwise refuse to load NDI's `libndi.dylib`, which is
signed by NDI's team, not ours.

## Finding the camera after a network move

Under the Camera bar:

- **Follow camera via NDI** (on by default). Once the camera answers VISCA at an IP
  that also announces an NDI source, the app remembers that source's name. If the camera
  later stops answering and the same name is announced at a different IP — new DHCP
  lease, different venue — the VISCA host switches there automatically and the log says
  so. NDI discovery is mDNS, so this works anywhere on the same network, not across
  routers. **Forget** clears the remembered name.
- **Subnet warning.** If the camera's IP isn't on any of this Mac's networks (a fixed
  address from another network), an orange box says so and gives the fixes. The best fix
  is to set the camera to DHCP. Until then, the box offers a copyable
  `sudo ifconfig en0 alias …` command that gives the Mac a second address on the camera's
  subnet, plus the command to remove it.
- **Scan network** sends a VISCA position inquiry to every address on this Mac's
  networks (limited to the Mac's own /24 on networks bigger than a /22) and lists what
  answers, labelled with its NDI name if it has one. **Use** points the app at it.
  Takes about 3 seconds. Works with NDI switched off on the camera.

Nothing can search *every* subnet: discovery doesn't cross routers, and the private
address ranges hold about 17 million addresses. Setting the camera to DHCP, or carrying
a small travel router that always uses the same subnet, avoids the problem entirely.

## Controller mapping

| Control | Action |
|---|---|
| Left stick | Pan (X) and tilt (Y). Speed follows deflection with an expo curve. |
| D-pad | Nudge pan/tilt at speed 1 |
| Right stick ↑↓ | Zoom in / out, proportional |
| RT / LT | Zoom in / out, proportional |
| RB (hold) | Precision mode (all speeds scaled down) |
| A / B / X / Y | Recall preset 1 / 2 / 3 / 4 |
| LB + A / B / X / Y | Save preset 1 / 2 / 3 / 4 |
| Menu ☰ | Home position |
| View ⧉ | Stop everything |
| Right stick click | One-push autofocus |

Input keeps working while another app is frontmost, so it can sit behind
TouchDesigner / OBS during a show.

## Notes

- Camera IP, port, deadzone, speed scale and invert toggles persist across launches.
- The app sends a stop on quit and whenever the controller disconnects.
- Drive commands are only re-sent when direction or speed changes, and no
  faster than every 50 ms, so the camera's command buffer never floods.
- Position (pan / tilt / zoom) is polled twice a second and shown live.
