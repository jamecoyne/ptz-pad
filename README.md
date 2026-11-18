# PTZ Pad

A small macOS app that drives the FoMaKo (Minrray) PTZ camera with an Xbox
controller over Bluetooth. Talks raw VISCA over UDP (port 5678 on the camera).
It also previews the camera's NDI feed, runs it through picture adjustments, a
creative effect and optional face/body/eye detection boxes, and republishes the
result as a Syphon feed for Resolume, TouchDesigner or OBS.

## Download

**[Download the latest PTZ Pad for macOS (.dmg)](https://github.com/jamecoyne/ptz-pad/releases/latest)**,
signed and notarized, for macOS 13 or later on Apple silicon and Intel. Open the DMG and
drag PTZ Pad to Applications. To receive video, also install
[NDI Tools](https://ndi.video/tools/).

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

Releases are built, signed and notarized on this Mac and uploaded to GitHub. The version
lives in `version.env`.

```bash
scripts/bump-version.sh 1.3          # edits version.env, commits "Bump version to 1.3 (build 4)", tags v1.3
git push origin main
scripts/publish-release.sh           # ./release.sh, push the tag, draft GitHub release with the DMG + .sha256
```

Check the draft on GitHub and publish it (or pass `--publish` to skip the draft).
`publish-release.sh` refuses to run with uncommitted changes, a branch that differs from
GitHub, or a version that already has a release.

### CI test build

`.github/workflows/build.yml` (Actions → build → Run workflow) builds the DMG on a
GitHub macOS runner and keeps it as the run's artifact, ad-hoc signed. Syphon isn't on
the runner, so `scripts/build-syphon.sh` builds a pinned commit of it universal with Xcode.
It signs with Developer ID too if these optional repository secrets are set:
`MACOS_CERTIFICATES_P12` (base64 .p12 of the certificate and key),
`MACOS_CERTIFICATES_PASSWORD`, and for notarization `APPLE_ID`, `APPLE_TEAM_ID`,
`APPLE_APP_PASSWORD`.

### Releasing from this Mac

The same pipeline runs locally:

```bash
./release.sh                 # universal build → sign → DMG → notarize → staple → dist/PTZPad-<version>.dmg
./release.sh --skip-notarize # signed, not notarized
./release.sh --ad-hoc        # ad-hoc signed test build, no certificate needed
```

Needs the "Developer ID Application" certificate in the login keychain and, once,
notarization credentials stored under the keychain profile `PTZPad-Notary`:

```bash
xcrun notarytool store-credentials "PTZPad-Notary" \
    --apple-id "<Apple ID email>" --team-id CM9NHRF538 --password "<app-specific password>"
```

Builds run in `~/Library/Caches/ptz-pad-build`, not `.build/`: this folder lives in
iCloud Drive, and the Swift compiler hangs forever on module-cache files that iCloud
has evicted.

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
4. **Save faces to Desktop** — crops each detected face (padded, from the full-size
   adjusted picture, no effect or boxes) and writes it as a JPEG to
   `~/Desktop/PTZ Pad Faces/<yyyy-MM-dd>/HH-mm-ss.SSS_face-<n>.jpg`. It runs face
   detection even with the boxes off. Since nothing is tracked, the same person is saved
   again on every interval (1–30 s, picked next to the toggle); faces under 48 px are
   skipped. macOS asks once for access to the Desktop folder.
5. **Blue background** — keeps the picture only inside face, body and eye boxes (hard
   rectangles, after the effect) and fills everything else with solid `#0000FF`. It runs
   that detection itself, whatever the box checkboxes say; with nothing found the frame
   is all blue.
6. **Window trail** (ported from segcam's windowed mode) — every face, body and eye of
   each detection pass becomes a window frozen on that moment's picture (no title bars),
   piled on the blue background newest on top.
   Since every pass gets fresh numbers, windows keep coming and leave a trail; the oldest
   is recycled once the pile holds 25–400 (100 by default). **Clear** empties it.
7. **Censor** — big square pixels over every face and body box (about eight blocks
   across, never finer than 6 px; faces get their own finer blocks on top of a body's).
   It's applied after the effect and before face fill, the trail and the blue
   background, so those carry the pixelation with them. Each box stays up for half a
   second after the pass that found it, so a pass that misses a face doesn't uncover it.
8. **Face fill** — the detected face (with some head around it, widened to the frame's
   shape) fills the whole frame. With several faces it strobes between them left to
   right, a new one every 200 ms. The last faces are held for a second so a missed pass
   doesn't flash the full picture; with no face the other looks show as usual, and
   while a face fills the frame the trail, blue background, pasted faces and boxes are
   off.
9. **Paste saved faces over faces** — a face swap: every detected face gets a random
   crop from that folder (the 500 most recent, rescanned every few seconds), re-picked
   every frame and pasted as a hard-edged rectangle. It's drawn on the output only, so
   saved crops never contain pasted faces.

**Test video when the camera is unavailable** (on by default): once no NDI frames have
arrived for 2 s, the panel loops a movie through the same pipeline — detection, face
saving and Syphon all work on it — and an orange PLAYING TEST VIDEO badge shows. It stops
as soon as camera frames come back. The default file is `crowd sample.mov` at the top of
this repo, found from the source path at build time, so it only works for builds made on
this machine; it isn't copied into the app (it's 640 MB). Use **Choose…** for any other
movie.

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
