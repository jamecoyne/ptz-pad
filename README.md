# PTZ Pad

A small macOS app that drives the FoMaKo (Minrray) PTZ camera with an Xbox
controller over Bluetooth. Talks raw VISCA over UDP (port 5678 on the camera).

## Build & run

Needs only the Xcode Command Line Tools (Swift 5.9+).

```bash
./make-app.sh            # release build → build/PTZPad.app
open build/PTZPad.app
```

For hacking: `swift run` builds and launches it from the terminal, or open
`Package.swift` in Xcode and press Run.

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
