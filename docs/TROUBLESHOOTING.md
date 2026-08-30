# KeyLight Troubleshooting

This guide covers the unsigned macOS warning, Input Monitoring, and the optional Screen Recording permission for Physical Refraction.

## macOS Says KeyLight Cannot Be Verified

KeyLight v2.0.0 is ad-hoc signed and not notarized because I do not have an Apple Developer account. Download it only from the official KeyLight GitHub Releases page.

1. Try opening `/Applications/KeyLight.app` once.
2. Click `Done` in the first warning.
3. Open **System Settings › Privacy & Security**.
4. Scroll to the Security section and click **Open Anyway** for KeyLight.
5. Confirm **Open Anyway** again and enter your password or use Touch ID.

You can also Control-click `KeyLight.app`, choose **Open**, and confirm once more.

## KeyLight Does Not React After Updating

An unsigned app receives a new ad-hoc code identity when it is rebuilt. macOS may therefore keep the old Input Monitoring entry without accepting the new app.

1. Quit every copy of KeyLight.
2. Open **System Settings › Privacy & Security › Input Monitoring**.
3. Remove the old KeyLight row.
4. Add `/Applications/KeyLight.app` again and enable it.
5. Reopen KeyLight and choose **Check Again** in its setup window.

If the native prompt still does not appear, reset only KeyLight's Input Monitoring decision:

```bash
killall KeyLight 2>/dev/null || true
tccutil reset ListenEvent com.keylight.app
open "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
```

## Physical Refraction Uses System Glass Instead

Physical Refraction is available on macOS 26 or newer and needs Screen Recording so it can refract what is behind the bottom overlay. Selecting the effect does not request permission by itself.

1. Open **Settings › Appearance** and select **Physical Refraction**.
2. Click **Allow Screen Recording…**.
3. Enable KeyLight in **Privacy & Security › Screen & System Audio Recording**.
4. Return to KeyLight and click **Check Again**.
5. If macOS asks for a relaunch, quit and reopen the same app.

Until access and the first usable frame are available, KeyLight keeps your Physical Refraction choice but temporarily renders System Glass.

If you also have an older Motion Preview installed, make sure you enable the correct copy:

- Normal release: `com.keylight.app`
- Motion Preview: `com.keylight.app.motionpreview`

## Physical Refraction Has Little or No Rainbow

The color separation comes from the captured background instead of a painted tint. A flat, single-color background therefore produces very little separation. Try a high-contrast colored or light/dark boundary behind the glass.

## Updates Say Unavailable

This is expected in the unsigned v2.0.0 release. It has no update feed or update key and makes no update-check requests. Download future versions manually from the GitHub Releases page.
