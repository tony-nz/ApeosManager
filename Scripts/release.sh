#!/bin/bash
# Builds, signs, notarises and (optionally) publishes a release of both apps.
#
#   ./Scripts/release.sh 1.0.0 --skip-notarize   # build and sign; NOT distributable
#   ./Scripts/release.sh 1.0.0                   # build, sign, notarise, staple
#   ./Scripts/release.sh 1.0.0 --publish         # ...then tag, push and create the release
#
# Both apps go into one zip. That is simpler for whoever downloads it and halves the
# notarisation round trips, which are the slow part.
#
# Why notarising is not optional: a bundle that arrives with the quarantine flag and no
# ticket is refused by Gatekeeper, and on macOS 15 the wording is "is damaged and can't
# be opened". That reads as a corrupt download, there is no right-click bypass for it,
# and anyone who sees it will conclude the file is broken.
#
# One-off setup:
#   security find-identity -v -p codesigning | grep "Developer ID"
#   xcrun notarytool store-credentials ApeosManager \
#       --apple-id you@example.com --team-id <OU field of the cert> --password <app-specific>
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
shift || true
SKIP_NOTARIZE=0
PUBLISH=0
for arg in "$@"; do
    case "$arg" in
        --skip-notarize) SKIP_NOTARIZE=1 ;;
        --publish)       PUBLISH=1 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

if [ -z "$VERSION" ]; then
    echo "usage: $0 <version> [--skip-notarize] [--publish]" >&2
    exit 2
fi
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "error: version should look like 1.0.0, not '$VERSION'." >&2
    exit 2
fi

TARGETS=(ApeosManager ApeosQuota)
PROFILE=ApeosManager
TAG="v$VERSION"
STAGE="build/release/Apeos $VERSION"
ZIP="build/release/Apeos-$VERSION.zip"
NOTES="docs/release-notes/$TAG.md"
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}

step() { printf '\n== %s\n' "$1"; }
die()  { printf 'error: %s\n' "$1" >&2; exit 1; }

# ---------------------------------------------------------------- refusals
#
# Each of these stops the script rather than letting it produce something subtly wrong.

step "Checks"

# A release must correspond to a commit you can go back to.
if [ -n "$(git status --porcelain)" ]; then
    die "the working tree is dirty. Commit or stash first:
$(git status --short | sed 's/^/       /')"
fi

if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    die "tag $TAG already exists. Bump the version, or delete the tag."
fi

IDENTITY=$(security find-identity -v -p codesigning \
           | grep "Developer ID Application" | head -1 \
           | sed -E 's/.*"(.*)"/\1/') || true
if [ -z "${IDENTITY:-}" ]; then
    die "no Developer ID Application certificate in the keychain.

  This is the only certificate that can notarise. 'Apple Development' cannot, and
  'Apple Distribution' is for the App Store.

  To create one:
    Keychain Access > Certificate Assistant > Request a Certificate From a Certificate
    Authority, saved to disk, 2048 bits, RSA. Then developer.apple.com > Certificates >
    + > Developer ID Application, upload the CSR, download it and double-click.

  On an organisation account only the Account Holder may create it."
fi
echo "  identity: $IDENTITY"

# The Team ID is the certificate's organizational unit. The value in parentheses in the
# certificate *name* is the certificate's own id on an Apple Development cert -- reading
# the Team ID from there is what earns the unhelpful 403 from notarytool.
TEAM_ID=$(security find-certificate -c "Developer ID Application" -p \
          | openssl x509 -noout -subject -nameopt multiline \
          | sed -n 's/.*organizationalUnitName *= *//p' | head -1)
echo "  team id:  ${TEAM_ID:-unknown}"

if [ "$SKIP_NOTARIZE" -eq 0 ]; then
    xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 || die \
"no notary credentials stored under the profile '$PROFILE'.

  Create an app-specific password at appleid.apple.com (Sign-In and Security >
  App-Specific Passwords) -- not your Apple ID password -- then:

    xcrun notarytool store-credentials $PROFILE \\
        --apple-id you@example.com \\
        --team-id ${TEAM_ID:-<team id>} \\
        --password <app-specific password>"
    echo "  notary:   profile '$PROFILE' works"
fi

[ -f "$NOTES" ] || die "no release notes at $NOTES. Write them first; the release links to them."

command -v xcodegen >/dev/null || die "xcodegen is not installed (brew install xcodegen)."

# ---------------------------------------------------------------- build

step "Building $VERSION (universal)"
rm -rf "build/release"
mkdir -p "$STAGE"
xcodegen generate >/dev/null

for TARGET in "${TARGETS[@]}"; do
    echo "  $TARGET"
    xcodebuild -project ApeosManager.xcodeproj -scheme "$TARGET" \
        -configuration Release -destination 'platform=macOS' \
        -derivedDataPath ./build \
        MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$VERSION" \
        ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
        CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
        build 2>&1 | grep -E 'error:|BUILD FAILED' && die "$TARGET failed to build" || true

    APP="build/Build/Products/Release/$TARGET.app"
    [ -d "$APP" ] || die "$APP was not produced."
    cp -R "$APP" "$STAGE/"
done

# ---------------------------------------------------------------- sign

step "Signing"
for TARGET in "${TARGETS[@]}"; do
    APP="$STAGE/$TARGET.app"

    # Hardened runtime and a secure timestamp are both required for notarisation; a
    # signature without a timestamp is rejected outright.
    #
    # --identifier is passed explicitly and must never change between builds: keychain
    # access control is bound to code identity, so a different identifier makes every
    # password saved by an earlier version unreadable after an upgrade.
    codesign --force --deep \
        --sign "$IDENTITY" \
        --identifier "nz.co.myers.$TARGET" \
        --options runtime \
        --timestamp \
        "$APP"
    codesign --verify --strict --verbose=2 "$APP" 2>&1 | sed 's/^/    /'

    got=$(codesign -dv "$APP" 2>&1 | sed -n 's/^Identifier=//p')
    [ "$got" = "nz.co.myers.$TARGET" ] \
        || die "$TARGET signed as '$got', expected 'nz.co.myers.$TARGET'. Saved passwords would break."

    archs=$(lipo -archs "$APP/Contents/MacOS/$TARGET")
    case "$archs" in
        *arm64*x86_64*|*x86_64*arm64*) echo "    $TARGET: universal ($archs)" ;;
        *) die "$TARGET is not universal (lipo reports: $archs)." ;;
    esac
done

# ---------------------------------------------------------------- package

step "Packaging"
# ditto, not zip: it preserves the bundles' symlinks and extended attributes. A plain
# zip mangles them and the notary service rejects the result.
ditto -c -k --keepParent "$STAGE" "$ZIP"
echo "  $ZIP ($(du -h "$ZIP" | cut -f1))"

if [ "$SKIP_NOTARIZE" -eq 1 ]; then
    printf '\n%s\n' "Built and signed, NOT notarised. This zip is not distributable:
macOS will refuse it as \"damaged\" on any machine but this one."
    exit 0
fi

# ---------------------------------------------------------------- notarise

step "Notarising (this takes a few minutes)"
if ! xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait 2>&1 | tee /tmp/notary.log; then
    id=$(sed -n 's/^ *id: *//p' /tmp/notary.log | head -1)
    die "notarisation failed. What Apple objected to:
       xcrun notarytool log $id --keychain-profile $PROFILE"
fi
grep -q "status: Accepted" /tmp/notary.log || {
    id=$(sed -n 's/^ *id: *//p' /tmp/notary.log | head -1)
    die "notarisation was not accepted. Details:
       xcrun notarytool log $id --keychain-profile $PROFILE"
}

step "Stapling"
# Staple the apps, not the zip: the ticket has to travel inside each bundle so it is
# present on a Mac that is offline the first time the app is opened.
for TARGET in "${TARGETS[@]}"; do
    xcrun stapler staple "$STAGE/$TARGET.app" | sed 's/^/    /'
    xcrun stapler validate "$STAGE/$TARGET.app" | sed 's/^/    /'
done

step "Repackaging with the tickets inside"
rm -f "$ZIP"
ditto -c -k --keepParent "$STAGE" "$ZIP"

step "Asking Gatekeeper"
for TARGET in "${TARGETS[@]}"; do
    spctl -a -vvv -t install "$STAGE/$TARGET.app" 2>&1 | sed 's/^/    /'
done

# ---------------------------------------------------------------- publish

if [ "$PUBLISH" -eq 0 ]; then
    printf '\n%s\n' "Ready: $ZIP
Publish it with:  $0 $VERSION --publish"
    exit 0
fi

step "Publishing $TAG"
command -v gh >/dev/null || die "gh is not installed."
gh auth status >/dev/null 2>&1 || die "gh is not authenticated (gh auth login)."

git tag -a "$TAG" -m "Apeos Manager $VERSION"
git push origin HEAD
git push origin "$TAG"
gh release create "$TAG" "$ZIP" --title "Apeos $VERSION" --notes-file "$NOTES"

printf '\n%s\n' "Released: $(gh release view "$TAG" --json url --jq .url)"
