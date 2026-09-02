# Shipping a macOS app: demo mode, docs site, notarized release

Written up from doing it for YealinkMonitor on 2 September 2026, so it can be
repeated for another app without rediscovering the same things.

The order matters. Demo mode comes first because the screenshots depend on it,
the site depends on the screenshots, and the release notes link to the site.

**Contents**

1. [What you end up with](#1-what-you-end-up-with)
2. [Build a demo mode first](#2-build-a-demo-mode-first)
3. [Automate the screenshots](#3-automate-the-screenshots)
4. [The documentation site](#4-the-documentation-site)
5. [Signing and notarization](#5-signing-and-notarization)
6. [Publishing](#6-publishing)
7. [Checklist](#7-checklist)
8. [Notes for ApeosManager specifically](#8-notes-for-apeosmanager-specifically)

---

## 1. What you end up with

| Thing | Where it lives |
| --- | --- |
| A demo mode behind a launch flag | `Sources/<App>/DemoFleet.swift` (or `DemoData.swift`) |
| Screenshots taken from it | `docs/screenshots/*.png` |
| A GitHub Pages site | `docs/index.html`, `docs/documentation.html`, `docs/assets/` |
| A release script | `Scripts/release.sh` |
| Release notes | `docs/release-notes/v<version>.md` |
| A notarized zip on the Releases page | GitHub |

Roughly a day's work the first time. Most of it is the demo fixture and the
manual; the signing pipeline is an hour once the certificate exists.

---

## 2. Build a demo mode first

### Why it is not optional

Screenshots of a tool that watches something are only useful if they show
something going wrong. The real system is usually healthy, and when it is not
healthy it is full of real names, real addresses and real customer data.
Redacting it with black rectangles removes exactly the content that made the
screenshot worth taking.

A demo mode solves three problems at once:

- **Publishable screenshots.** Nothing real leaves the machine.
- **Interesting states on demand.** You can show the outage, the half-broken
  device, the never-provisioned one — states you cannot wait around for.
- **Reproducibility.** Next release, run the same command and retake the same
  shots. Hand-redacted PNGs cannot be regenerated.

It is also the best way for someone evaluating the app to look at it without
credentials, which is worth a section on the site by itself.

### The launch flag

Use `UserDefaults`, which reads the argument domain for free:

```swift
enum DemoData {
    /// Read from the argument domain, so `-demoMode YES` on the command line is
    /// enough and nothing is written to the user's preferences.
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: "demoMode") }
}
```

```sh
/Applications/YourApp.app/Contents/MacOS/YourApp -demoMode YES
```

No build flag, no separate scheme, no `#if DEBUG`. The shipping binary can do
it, which is what makes it useful to users and not just to you.

### The five invariants

Demo mode must be inert **by construction**, not by remembering to check a
boolean at each call site. Each of these is a real failure I hit:

**1. Never build the live client.** Guard wherever the polling engine or
network layer is constructed:

```swift
private func rebuildMonitor() {
    guard !isDemo else { return }
    ...
}
```

**2. Make the client factory *throw*, not return.** This is the one that
matters most. The keychain on the machine running the demo very likely holds
real credentials, and a per-item lookup is usually keyed by a fixed account
name — not by whatever fake client ID the demo is using. So a "demo" that hands
back a working client will authenticate as the real account the moment anyone
presses a button the demo did not think to disable.

```swift
/// Throws in a demo run rather than handing back a client. A demo has no
/// credentials of its own, and the keychain on the Mac running it may well
/// hold real ones -- so without this, a diagnostic launched from the demo
/// would authenticate as the real enterprise.
func makeClient() throws -> APIClient {
    guard !isDemo else { throw APIError.notConfigured }
    return APIClient(credentialsProvider: ...)
}
```

Making it `throws` forces the compiler to walk you to every call site. That is
the point: an audit you cannot forget to do. Afterwards, confirm nothing
bypasses it:

```sh
grep -rn 'APIClient(' Sources/YourApp/
```

Every hit should be inside a demo-guarded function.

**3. Substitute settings; do not load them.** People open the Settings window to
screenshot it. If the demo loads the real preferences, that screenshot contains
a real SMTP relay, real recipients, real hostnames. And because settings
usually save on change, merely *opening* the window can overwrite them.

```swift
init(settings: AppSettings? = nil) {
    let isDemo = DemoData.isEnabled
    self.settings = settings ?? (isDemo ? DemoData.settings() : .load())
}

var settings: AppSettings {
    didSet {
        guard settings != oldValue else { return }
        // A demo run must not write over the preferences of whoever is
        // running it -- opening Settings alone would be enough to do that.
        if !isDemo { settings.save() }
        applySettingsChange(from: oldValue)
    }
}
```

**4. Redirect anything that writes to disk.** History logs, caches, exports.
Point them at a scratch file, and empty it each launch or the demo accumulates
a duplicate set every run:

```swift
static func historyURL() -> URL {
    let url = URL.temporaryDirectory.appending(path: "YourAppDemoHistory.json")
    try? FileManager.default.removeItem(at: url)
    return url
}
```

**5. Skip the permission prompts.** Notification authorisation, Screen
Recording, Full Disk Access. A dialog appearing mid-capture ruins a screenshot
and, worse, an awaited permission request can block startup entirely.

### Designing the fixture

Not a random sample — a deliberate catalogue. Put in **one of everything worth
documenting**, because each one justifies a sentence in the manual and a
caption on the site:

- the plain broken case (offline)
- the *differently* broken case (registered but never reported — a different
  problem, and if your app distinguishes them the fixture must too)
- the deceptive case: healthy top-level status, broken underneath (this is
  usually the best screenshot you will get, because it is the whole argument
  for the app)
- a peripheral or child object that is faulty while the parent looks fine
- version or config drift
- an item deliberately excluded from counts (archived / disabled / spare)
- a muted item
- enough healthy ones for the proportions to look real

Twenty-something items is right. Enough to fill a window, few enough to define
by hand.

Make names obviously fictional but plausible — locations and roles ("Reception",
"Goods In", "Branch Desk 3"), never person names. Use documentation IP ranges
(`10.20.30.x`, `203.0.113.x`), `example.net` addresses, and a real vendor OUI
with an invented suffix for MACs.

**Compute timestamps relative to `Date()` at call time.** A fixture with fixed
dates reads as stale five minutes later, and the whole window gets captioned
"out of date":

```swift
static func snapshot(now: Date = Date()) -> Snapshot {
    ...
    snapshot.lastSuccess = now
    detail.lastReportTime = epochMillis(now.addingTimeInterval(-180))
}
```

### Fixtures for decode-only models

API models often have `public let` properties and no public initialiser — the
synthesised memberwise init is internal, so the app target cannot construct
one. Do **not** widen the API for a demo. Go through the real `Codable` path:

```swift
/// Several models are decode-only -- they have no public memberwise
/// initialiser, because nothing outside the client ever needs to build one.
/// Rather than widen that API for a demo, the fixtures go through the real
/// `Codable` path, which has the side benefit of exercising it.
private static func decode<T: Decodable>(_ type: T.Type, _ object: [String: Any]) -> T? {
    guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
    return try? JSONDecoder().decode(T.self, from: data)
}
```

Zero API surface change, and it exercises your decoding.

### A thing to expect

Building the fixture will find bugs. Feeding your UI states the live system
rarely produces is a form of testing. For YealinkMonitor it surfaced a warning
that told you an *offline* phone was "reachable but has a line that is not
registered" — because the condition checked only the line status, and an
offline device reports unregistered lines too. That misfires on real data, not
just on the fixture. Commit those fixes separately from the demo mode.

---

## 3. Automate the screenshots

Manual screenshots are slow, inconsistent, and impossible to redo. Three small
Swift helpers make it repeatable. Compile them once with `swiftc -O`; running
via `swift file.swift` is slower and mangles argument passing.

### Helper 1: list the app's windows

`screencapture -l <windowid>` captures one window with its shadow and rounded
corners and nothing else — no desktop, no other apps. You need the window ID.

```swift
// winlist.swift — usage: winlist [pid]
import CoreGraphics
import Foundation

let target = CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1]) : nil
let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
guard let raw = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { exit(1) }
for w in raw {
    let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
    let pid = w[kCGWindowOwnerPID as String] as? Int ?? -1
    guard owner.contains("YourApp") else { continue }
    if let target, pid != target { continue }
    let id = w[kCGWindowNumber as String] as? Int ?? -1
    let name = w[kCGWindowName as String] as? String ?? ""
    let b = w[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
    let layer = w[kCGWindowLayer as String] as? Int ?? 0
    print("id=\(id)\tpid=\(pid)\tlayer=\(layer)\t\(Int(b["Width"] ?? 0))x\(Int(b["Height"] ?? 0))\t@\(Int(b["X"] ?? 0)),\(Int(b["Y"] ?? 0))\t\(name)")
}
```

The `pid` filter matters: while you screenshot the demo, the real app is
usually still running under the same name. Menu bar popovers show as
`layer=101`; ordinary windows as `layer=0`.

### Helper 2: click at a point

AppleScript's `click at` does not reliably reach a menu bar extra, and
`tell process whose unix id is N` picks the wrong process when two instances
share a name. Post a real HID event instead:

```swift
// click.swift — usage: click <x> <y>
import CoreGraphics
import Foundation

let x = Double(CommandLine.arguments[1])!
let y = Double(CommandLine.arguments[2])!
let point = CGPoint(x: x, y: y)
let source = CGEventSource(stateID: .hidSystemState)
CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
usleep(120_000)
CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
usleep(90_000)
CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
```

### Helper 3: position and size a window

Saved window frames are whatever you last dragged them to, which is never the
right shape for a screenshot. Set the frame through the Accessibility API:

```swift
// axwin.swift — usage: axwin <pid> <title|*> [x y w h]
import ApplicationServices
import Foundation

let pid = pid_t(CommandLine.arguments[1])!
let title = CommandLine.arguments[2]
let app = AXUIElementCreateApplication(pid)

var value: CFTypeRef?
guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
      let windows = value as? [AXUIElement] else {
    FileHandle.standardError.write("no windows\n".data(using: .utf8)!); exit(1)
}

for window in windows {
    var t: CFTypeRef?
    AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &t)
    let name = (t as? String) ?? ""
    guard name == title || title == "*" else { continue }

    if CommandLine.arguments.count >= 7 {
        var origin = CGPoint(x: Double(CommandLine.arguments[3])!, y: Double(CommandLine.arguments[4])!)
        var size = CGSize(width: Double(CommandLine.arguments[5])!, height: Double(CommandLine.arguments[6])!)
        if let p = AXValueCreate(.cgPoint, &origin) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, p)
        }
        if let s = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, s)
        }
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }

    var pv: CFTypeRef?, sv: CFTypeRef?
    AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &pv)
    AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sv)
    var origin = CGPoint.zero, size = CGSize.zero
    if let pv { AXValueGetValue(pv as! AXValue, .cgPoint, &origin) }
    if let sv { AXValueGetValue(sv as! AXValue, .cgSize, &size) }
    print("\(name)\t@\(Int(origin.x)),\(Int(origin.y))\t\(Int(size.width))x\(Int(size.height))")
}
```

Fixed-size windows (SwiftUI `Settings`) ignore the size and keep their own.
Read back the frame it reports rather than assuming yours took.

### The capture loop

```sh
swiftc -O -o bin/winlist tools/winlist.swift
swiftc -O -o bin/click   tools/click.swift
swiftc -O -o bin/axwin   tools/axwin.swift

nohup ./build/YourApp.app/Contents/MacOS/YourApp -demoMode YES >/dev/null 2>&1 &
sleep 4
PID=$(pgrep -f 'build/YourApp.app')

./bin/click 2079 12                       # open the menu bar item
sleep 2
POP=$(./bin/winlist $PID | awk '$3=="layer=101"{print $1}' | sed 's/id=//')
screencapture -x -o -l$POP shots/menu-bar.png

./bin/click 2100 365                      # a button in the popover
sleep 3
./bin/axwin $PID "Main" 200 120 1180 720  # size it for the shot
sleep 1
screencapture -x -o -l<id> shots/main.png
```

`-x` suppresses the shutter sound, `-o` omits the window shadow if you would
rather add your own in CSS. Keep the shadow — it reads better on a page.

**Coordinate arithmetic.** Captures are 2× on Retina. To convert a point in a
screenshot to a screen coordinate:

```
screen = window_origin + (pixel_in_image / 2)
```

Capture, look at the image, compute, click, recapture. Two or three rounds per
window.

**Permissions.** You need Screen Recording (for `screencapture`) and
Accessibility (for the click and AX helpers) granted to the terminal. macOS
prompts once each.

### Choosing the shots

Aim for eight to ten. One of them should be the *argument for the app* — the
deceptive case, where the summary says fine and the detail says otherwise. That
one goes at the top of the landing page and everything else supports it.

---

## 4. The documentation site

### Layout

```
docs/
  .nojekyll                 empty file; stops GitHub running Jekyll over it
  index.html                overview: hero, features, screenshots, quick start
  documentation.html        the manual, with a sticky sidebar
  assets/
    style.css
    icon.png                256px, from the app's iconset
    favicon.png             64px
  screenshots/*.png
  release-notes/v0.1.0.md   where release.sh looks for notes
```

Plain HTML and one stylesheet. No Jekyll, no generator, no npm. What is in the
repository is what gets served, which means you can open `index.html` locally
and see the real thing.

`.nojekyll` is not optional — without it GitHub runs the whole directory
through Jekyll, which will silently drop files starting with `_` and can
mangle things.

### Two pages, not one and not ten

- **index.html** — what it is, why you would want it, the screenshots, and
  enough of a quick start to get going. Somebody deciding whether to care.
- **documentation.html** — the manual. Every section anchored, sticky sidebar,
  scrollspy. Somebody who already installed it.

The README stays short and links to both.

### CSS that behaves

- Define the light palette as custom properties on `:root`, then redefine only
  those properties inside `@media (prefers-color-scheme: dark)`. Never give a
  colour its only definition inside a media query.
- Set an explicit `background` on `body`.
- `max-width: 40rem` on prose. Full width on figures and tables.
- Wrap tables and wide code in `overflow-x: auto` so the page body never
  scrolls sideways on a phone.
- System font stack. A web font is a request, a flash of unstyled text, and a
  privacy footnote for no gain.

### Scrollspy for the sidebar

```js
var observer = new IntersectionObserver(function (entries) {
    entries.forEach(function (entry) {
        if (entry.isIntersecting) visible.add(entry.target.id);
        else visible.delete(entry.target.id);
    });
    // The topmost visible section wins, so scrolling up and down agree.
    var current = sections.filter(function (s) { return visible.has(s.id); })[0];
    links.forEach(function (a) {
        a.classList.toggle('active', current && a.getAttribute('href') === '#' + current.id);
    });
}, { rootMargin: '-72px 0px -70% 0px' });
```

Tracking a *set* of visible sections and taking the topmost is what makes
scrolling up behave the same as scrolling down.

### Validate before pushing

Balanced tags, live anchors, present images, alt text on everything:

```python
# tools/check-site.py
import pathlib
from html.parser import HTMLParser

VOID = {'area','base','br','col','embed','hr','img','input','link','meta','source','track','wbr'}

class Check(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.stack, self.errors = [], []
        self.ids, self.hrefs, self.imgs = set(), [], []
    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if 'id' in a: self.ids.add(a['id'])
        if tag == 'a' and 'href' in a: self.hrefs.append(a['href'])
        if tag == 'img':
            self.imgs.append(a.get('src'))
            if 'alt' not in a: self.errors.append(f'img without alt: {a.get("src")}')
        if tag not in VOID: self.stack.append((tag, self.getpos()))
    def handle_endtag(self, tag):
        if tag in VOID: return
        if not self.stack:
            self.errors.append(f'</{tag}> with nothing open at {self.getpos()}'); return
        open_tag, pos = self.stack.pop()
        if open_tag != tag:
            self.errors.append(f'</{tag}> at {self.getpos()} closes <{open_tag}> opened at {pos}')

for name in ('index.html', 'documentation.html'):
    c = Check(); c.feed(pathlib.Path(name).read_text())
    print(f'--- {name} ---')
    for e in c.errors: print('  ERROR', e)
    if c.stack: print('  UNCLOSED', [t for t, _ in c.stack])
    for h in c.hrefs:
        if h.startswith('#') and h[1:] not in c.ids: print(f'  DEAD ANCHOR {h}')
    for src in c.imgs:
        if src and not pathlib.Path(src).exists(): print(f'  MISSING IMAGE {src}')
    if not c.errors and not c.stack: print('  structure ok')
```

Preview it the way it will be served, not off the filesystem:

```sh
cd docs && python3 -m http.server 8731
```

Headless render to check both themes without opening a browser:

```sh
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
"$CHROME" --headless --disable-gpu --hide-scrollbars \
  --screenshot=out.png --window-size=1280,900 --virtual-time-budget=4000 \
  http://127.0.0.1:8731/index.html
"$CHROME" --headless --force-dark-mode ... # dark
```

---

## 5. Signing and notarization

### Which certificate

There are several and only one works. **Developer ID Application** is the one
for distributing outside the App Store.

- *Apple Development* — build and run on your own machines. **Cannot notarize.**
- *Apple Distribution* / *Mac App Distribution* — App Store.
- *Developer ID Application* — what you need.

Check:

```sh
security find-identity -v -p codesigning | grep "Developer ID"
```

To create one: Keychain Access ▸ Certificate Assistant ▸ **Request a Certificate
From a Certificate Authority** → saved to disk, 2048 bits, RSA. Then
developer.apple.com ▸ Certificates ▸ **+** ▸ **Developer ID Application** →
upload the CSR → download → double-click.

On an **organisation** account only the Account Holder can create it. On an
individual account (`organizationName` is your own name) you can.

### The Team ID trap

`notarytool` needs the Team ID and answers an unhelpful 403 for anything else:

```
Error: HTTP status code: 403. Invalid or inaccessible developer team ID for
the provided Apple ID.
```

**The value in parentheses in an "Apple Development" certificate's name is
*not* the Team ID.** It is the certificate's own id. (On *Developer ID* and
*Distribution* certificates it happens to be the Team ID, which is what makes
this so easy to get wrong.)

The Team ID is the **organizational unit** of the certificate subject:

```sh
security find-certificate -c "Apple Development" -p \
  | openssl x509 -noout -subject -nameopt multiline \
  | grep organizationalUnitName
```

### Notary credentials

An app-specific password from [appleid.apple.com](https://appleid.apple.com) ▸
Sign-In and Security ▸ App-Specific Passwords — not your Apple ID password.

```sh
xcrun notarytool store-credentials YourApp \
    --apple-id you@example.com \
    --team-id <team id from the OU field> \
    --password <app-specific password>
```

Stored in the keychain under that profile name; you never pass it again.

### The release script

Anatomy, with the reasons — these are the parts that are easy to get subtly
wrong:

```sh
# 1. Hardened runtime + secure timestamp. Both are required for notarization;
#    a signature without a timestamp is rejected.
codesign --force --deep \
    --sign "$IDENTITY" \
    --identifier "$BUNDLE_ID" \
    --options runtime \
    --timestamp \
    "$APP"
codesign --verify --strict --verbose=2 "$APP"

# 2. ditto, not zip. It preserves the bundle's symlinks and extended
#    attributes; a plain zip mangles them and the notary service rejects it.
ditto -c -k --keepParent "$APP" "$ZIP"

# 3. Submit and wait.
xcrun notarytool submit "$ZIP" --keychain-profile YourApp --wait

# 4. Staple the APP, not the zip. The ticket has to travel inside the bundle
#    so it is present on a Mac that is offline at first launch.
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

# 5. Repackage now the ticket is inside, then ask Gatekeeper.
rm -f "$ZIP"; ditto -c -k --keepParent "$APP" "$ZIP"
spctl -a -vvv -t install "$APP"
```

If notarization fails, the log tells you why:

```sh
xcrun notarytool log <submission-id> --keychain-profile YourApp
```

### Refusals worth building in

The script should stop rather than produce something wrong:

- **Dirty working tree.** A release should correspond to a commit you can go
  back to.
- **Tag already exists.**
- **No Developer ID certificate** — with the instructions in the error, not a
  bare failure.
- **No notary credentials** under the profile.
- **Embedded secrets.** If your build has a mode that bakes credentials into
  `Info.plist`, refuse to package one:

  ```sh
  if /usr/libexec/PlistBuddy -c "Print :YourSecretKey" "$APP/Contents/Info.plist" >/dev/null 2>&1; then
      echo "error: this bundle has embedded credentials. Refusing to package it." >&2
      exit 1
  fi
  ```

- Offer `--skip-notarize` for a dry run that builds and signs but is explicitly
  not distributable.

### Why this is worth doing at all

Without notarization, a bundle that arrives with the quarantine flag is
rejected, and on macOS 15 the message is **"YourApp is damaged and can't be
opened"**. It sounds like a corrupt download. There is no right-click bypass
for that wording. Anyone downloading from your Releases page will conclude the
file is broken.

### Universal builds

Release builds should be universal so they run natively on both architectures.
With SwiftPM and Command Line Tools only, `--arch` is unavailable (it needs
Xcode's `xcbuild`), so build each slice and `lipo` them:

```sh
swift build -c release                       # native
swift build -c release --triple arm64-apple-macosx14.0 --scratch-path .build/arm64
lipo -create "$NATIVE" "$ARM" -output "$UNIVERSAL"
lipo -archs "$UNIVERSAL"
```

Use a **separate scratch path** per triple. Sharing one `.build` corrupts
SwiftPM's build database and breaks the next native build.

With Xcode, set `ARCHS = "arm64 x86_64"` and `ONLY_ACTIVE_ARCH = NO` instead —
`xcodebuild` handles it.

---

## 6. Publishing

### Authenticate once

```sh
gh auth login          # HTTPS, browser
gh auth status
```

Needs `repo` scope. This also configures the git credential helper, so pushes
work too.

### Push, then enable Pages

```sh
git push origin main

gh api -X POST repos/<owner>/<repo>/pages \
  -f 'source[branch]=main' -f 'source[path]=/docs'
```

Wait for the first build and confirm:

```sh
gh api repos/<owner>/<repo>/pages --jq '.status'          # building -> built
gh api repos/<owner>/<repo>/pages/builds/latest --jq '{status, error: .error.message}'
curl -sS -o /dev/null -w '%{http_code}\n' https://<owner>.github.io/<repo>/
```

First build takes 30–60 seconds. Site lands at
`https://<owner>.github.io/<repo>/`.

### Repo metadata

Easy to forget and it is what people see first:

```sh
gh api -X PATCH repos/<owner>/<repo> \
  -f description='One sentence saying what it does.' \
  -f homepage='https://<owner>.github.io/<repo>/'

gh api -X PUT repos/<owner>/<repo>/topics \
  -f 'names[]=macos' -f 'names[]=swift' -f 'names[]=swiftui'
```

### Cut the release

```sh
./Scripts/release.sh 0.1.0 --skip-notarize   # dry run first
./Scripts/release.sh 0.1.0                   # build + notarize, no publish
./Scripts/release.sh 0.1.0 --publish         # tag, push, create the release
```

**The "Download" button on your site 404s until the first release exists**, so
either cut it the same day or word the button accordingly.

### Order of operations

Site first, release second. The release notes link to the site, so the site
should already resolve. And the site is useful on its own; the release is
blocked on Apple.

---

## 7. Checklist

**Demo mode**
- [ ] Launch flag read from the argument domain
- [ ] Live client/engine never constructed
- [ ] Client factory `throws` — compiler-audited call sites
- [ ] `grep` for direct client construction; every hit guarded
- [ ] Settings substituted, saving suppressed
- [ ] Disk writes redirected to a scratch path, cleared each launch
- [ ] No permission prompts
- [ ] Fixture has one of every documented state
- [ ] Timestamps relative to now
- [ ] Fictional names, documentation IP ranges, `example.net`
- [ ] Tests still pass

**Screenshots**
- [ ] Helpers compiled
- [ ] 8–10 shots, one of them the argument for the app
- [ ] Windows sized so content fills them
- [ ] Reread every image before committing — check for anything real

**Site**
- [ ] `.nojekyll`
- [ ] Light and dark both checked
- [ ] Validator clean: tags, anchors, images, alt text
- [ ] Mobile width has no horizontal scroll
- [ ] README links to it

**Release**
- [ ] Developer ID Application certificate installed
- [ ] Team ID from the OU field, not the certificate name
- [ ] `notarytool store-credentials` succeeds
- [ ] Universal build confirmed with `lipo -archs`
- [ ] Hardened runtime + `--timestamp`
- [ ] `ditto`, not `zip`
- [ ] Stapled the **app**, repackaged after
- [ ] `spctl -a -vvv -t install` passes
- [ ] Release notes written
- [ ] Download link on the site resolves

**Hygiene**
- [ ] App-specific passwords typed into a terminal or chat get rotated after
- [ ] `.gitignore` covers `*.app/` anywhere, not just `build/`

---

## 8. Notes for ApeosManager specifically

Differences from YealinkMonitor worth planning around.

**Two apps from one project.** `ApeosManager` (admin) and `ApeosQuota` (menu
bar). That means:

- The demo flag should live in `Sources/Shared` so both read it, with the
  fixture describing one printer fleet that both render.
- Screenshots need both apps — the fleet view from the admin app and the
  quota popover from the menu bar app. The `winlist` owner filter needs to
  match each in turn.
- **Two releases, or one zip containing both.** One zip with both apps is
  simpler for users and halves the notarization round trips. `release.sh` needs
  a loop over targets, and `ditto -c -k --keepParent` over a staging directory
  containing both bundles rather than over a single `.app`.

**xcodegen + xcodebuild, not SwiftPM.** `build.sh` currently builds Debug with
signing disabled and then signs separately. For releases you want:

```sh
xcodebuild -project ApeosManager.xcodeproj -scheme "$TARGET" \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath ./build \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  build
```

then sign with Developer ID exactly as in §5. Set `ARCHS`/`ONLY_ACTIVE_ARCH` in
`project.yml` for universal, and regenerate with `xcodegen generate`.

**The identifier must not change.** `build.sh` already notes this: keychain
access control is bound to code identity, so `--identifier "nz.co.myers.$TARGET"`
has to stay identical between the dev build and the release build, or saved
passwords become unreadable on upgrade. Keep passing `--identifier` explicitly
in `release.sh` rather than letting it default.

**Printer data is as identifiable as phone data.** User accounts, usage meters,
address books, job logs — a screenshot of the Users or Account Usage window is
a staff list with printing habits attached. The demo fixture matters at least
as much here, and should cover: a printer low on toner, one offline, one with a
fault, a user over their quota, and a user near it.

**The quota app is the better hero screenshot.** "Here is your allowance, in
your menu bar" is a clearer picture than a fleet table.
