import Foundation

/// A self-contained fleet, so the apps can be shown, documented and screenshotted
/// without a printer, a password, or anybody's real print history.
///
///     /Applications/Apeos\ Manager.app/Contents/MacOS/ApeosManager -demoMode YES
///     /Applications/Apeos\ Quota.app/Contents/MacOS/ApeosQuota     -demoMode YES
///
/// Read from `UserDefaults`, which consults the argument domain ahead of anything on
/// disk. So the flag needs no build setting, no separate scheme and no `#if DEBUG`, and
/// nothing is written to the user's preferences to turn it on. The shipping binary can
/// do it, which is what makes it useful to somebody evaluating the app and not just to
/// whoever is writing the manual.
///
/// The rule the rest of the code enforces is that **a demo run must not touch the
/// network, the keychain, or the preferences of whoever is running it.** That is not a
/// nicety here. The Mac being demonstrated on is likely to have real printers on its
/// network and real administrator passwords in its keychain, and both apps key their
/// keychain items by a fixed account name rather than by anything the demo controls --
/// so a "demo" that handed back a working client would sign in as the real
/// administrator the moment anyone pressed a button the fixture had not thought to
/// disable. The guards are therefore structural rather than a boolean remembered at
/// each call site:
///
/// - `ApeosClient.init` throws, so no request can be built at all, and the compiler
///   walks you to every construction site rather than leaving it to a grep.
/// - `PrinterStore` and `QuotaSettings` substitute their contents and suppress every
///   save, so merely opening a window cannot overwrite a real configuration.
/// - `QuotaSettings.passcode` returns a placeholder instead of reading the keychain.
/// - `PrinterDiscovery` answers from the fixture instead of sweeping the subnet.
/// - `SoapLog` writes to a scratch file, emptied at launch.
enum DemoMode {
    /// Resolved once: the flag cannot change while the process is running, and the
    /// guards below are consulted often enough that re-reading defaults is waste.
    static let isEnabled = UserDefaults.standard.bool(forKey: "demoMode")

    /// The demo's stand-in for a stored credential. Never sent anywhere -- the client
    /// refuses to exist in a demo run -- but the settings screens need something
    /// non-nil to report as "signed in".
    static let placeholderPasscode = "demo"
}
