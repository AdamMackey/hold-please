# Hold Please

⌘Q only quits when you hold it.

A quick ⌘Q does nothing at all — the key never reaches the app, so there's no
menu flash and no quit. Keep it held for 0.6 seconds and the app in front quits
the normal, polite way: anything with unsaved work still gets to put its sheet
up. A small bar shows what's about to quit while you hold.

Left alone on purpose:

- **⌥⌘Q** and **⇧⌘Q**, so there's still an instant quit when you want one.
- **Finder**, which has no Quit item.
- **Password fields.** macOS hides keystrokes from every app while secure input
  is on, so ⌘Q there quits the old way.

## Install

Download the zip from [Releases](../../releases), unzip it, drag **Hold Please**
to Applications and open it. It adds itself to Login Items, then asks for
**Accessibility** permission — an event tap is how a key gets caught and
swallowed. Allow it in System Settings → Privacy & Security → Accessibility,
and it starts watching within a couple of seconds, no relaunch needed.

Or build it yourself (you'll need Xcode or the Command Line Tools). `build.sh`
installs it to `/Applications` and opens it:

```sh
git clone https://github.com/AdamMackey/hold-please.git
cd hold-please
./build.sh
```

There's no Dock icon and no menu bar icon. Open the app again to reach Quit.

```sh
./build.sh uninstall     # quit it, drop the login item, delete the app
```

## Settings

```sh
defaults write com.adammackey.holdplease holdSeconds -float 1.0
defaults write com.adammackey.holdplease excludedBundleIDs -array com.some.app
```

`holdSeconds` is clamped to 0.2–3 seconds. Apps in `excludedBundleIDs` keep
plain ⌘Q — useful for a VM or a remote desktop that wants the key itself.
Both are read on each press, but a running copy caches `defaults` for a few
seconds, so give it a moment or restart it.

## Why an event tap

Rebinding Quit in System Settings → Keyboard → Keyboard Shortcuts can take ⌘Q
away, but it matches menu items by exact title ("Quit Safari", "Quit Mail"), so
it's one entry per app and it can't tell a tap from a hold. A session-level
`CGEventTap` sees the key on its way to the app in front, so it can swallow the
tap and let the hold through — for every app at once, without touching a single
system binding.

## Support

Hold Please is free. If it saves you one unsaved draft, you can
[buy me a coffee](https://buymeacoffee.com/adammackey).

## License

MIT. See [LICENSE](LICENSE).
