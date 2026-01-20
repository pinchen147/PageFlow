Below is a concise, repeatable procedure that keeps your App Store build and direct‑download build cleanly separated and ensures Sparkle updates work reliably. It follows the best practices you’ve implemented and is supported by official guidelines.

---

## 1. Maintain two build variants

1. **Create two build configurations:** `Release` (App Store) and `Release‑Direct` (direct distribution with Sparkle).
2. **Add `ENABLE_SPARKLE` compilation flag** to the `Release‑Direct` configuration only.
3. **Maintain two Info.plist files:**

   * **Info.plist** for the App Store build (no Sparkle keys).
   * **Info‑Direct.plist** for the direct build (includes `SUFeedURL` and `SUPublicEDKey`).
4. **Set `INFOPLIST_FILE` per configuration**: `Info.plist` for `Release`, `Info‑Direct.plist` for `Release‑Direct`.
   This avoids runtime scripts and keeps your build setup explicit.

With this setup, the App Store version never links Sparkle, while the direct version embeds Sparkle and knows where to look for updates.

---

## 2. Prepare a new release

1. **Bump the version numbers**:

   * Update `CFBundleShortVersionString` (e.g., `1.2` → `1.3`) and **increment** `CFBundleVersion` (Sparkle uses this as its `sparkle:version`) in both plist files.
2. **Clean and archive** the project in Xcode:

   * Product → Clean Build Folder.
   * Product → Archive.
   * In the Organizer, choose **Distribute App** → **Developer ID** (not App Store) and follow the wizard to notarize and export the `.app`.  Apple’s documentation confirms that distributing outside the store requires Developer ID signing and notarization.
3. **Export the notarized app** to a folder (e.g., `/Users/pinchen/Developer/PageFlow.app`).

---

## 3. Create and sign the DMG

1. **Generate DMG** using `create‑dmg`:

   ```bash
   rm -f ~/Developer/PageFlow-new.dmg
   create-dmg \
     --volname "PageFlow" \
     --volicon "/Users/pinchen/Developer/PageFlow.app/Contents/Resources/AppIcon.icns" \
     --window-pos 200 120 \
     --window-size 600 400 \
     --icon-size 100 \
     --icon "PageFlow.app" 150 185 \
     --app-drop-link 450 185 \
     --background "/Users/pinchen/Developer/dmg-background.png" \
     "/Users/pinchen/Developer/PageFlow-new.dmg" \
     "/Users/pinchen/Developer/PageFlow.app"
   ```

   The `create-dmg` tool packages the app and sets up a friendly drop‑link background; the DEV guide shows how to use it in combination with signing and notarization.
2. **Sign the DMG** with Sparkle’s `sign_update`:

   ```bash
   ~/Library/Developer/Xcode/DerivedData/PageFlow-*/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update \
     "/Users/pinchen/Developer/PageFlow-new.dmg"
   ```

   This command outputs a new `sparkle:edSignature` and file length; keep these values.  They authenticate your update for all existing users.
3. **Do not change `SUFeedURL` or `SUPublicEDKey`.**  All future updates must use the same feed URL and public key.  Changing either will break updates for existing installations.

---

## 4. Update `appcast.xml`

1. **Edit the feed** (e.g. `/Users/pinchen/Developer/pageflow-landing/public/appcast.xml`):

   * Update `<sparkle:version>` to the new `CFBundleVersion`.
   * Update `<sparkle:shortVersionString>` to the new `CFBundleShortVersionString`.
   * Replace `sparkle:edSignature` and `length` with the values from `sign_update`.
   * Adjust `<pubDate>` and `<description>` to reflect the new release.
2. **Make sure the enclosure URL** still points to your hosted DMG (`https://pageflow.pinchen.me/downloads/PageFlow.dmg`).
3. As Sparkle’s docs note, run `generate_appcast` when you have multiple versions to automatically generate delta updates.

---

## 5. Deploy the update files

1. **Copy the new DMG** to your static site:

   ```bash
   cp ~/Developer/PageFlow-new.dmg \
     ~/Developer/pageflow-landing/public/downloads/PageFlow.dmg
   ```
2. **Commit and push** `PageFlow.dmg` and the updated `appcast.xml` to your `pageflow-landing` repository.  Cloudflare Pages will automatically redeploy and make the files available on `pageflow.pinchen.me`.
3. **Upload the same DMG** to Gumroad so that new customers download the up‑to‑date installer.  Replace the old file in your Gumroad product.

---

## 6. Verify before release

1. **Install the previous version** of PageFlow (from your backup or Gumroad).
2. **Check for updates** via the PageFlow “Check for Updates…” menu.  Sparkle should detect the new version and install it.  If it fails, double‑check the version numbers, signature, and feed URL.
3. **Test the new build** manually to ensure there are no regressions.  Release notes can mention any major changes or bug fixes.

---

## 7. Publish the App Store update

Your App Store submission uses the `Release` configuration without Sparkle:

1. Select the `PageFlow` (App Store) scheme in Xcode.
2. Archive and distribute via **App Store Connect**.
3. In App Store Connect, fill in release notes and submit for review.

---

### Trade‑offs and confirmation

* **Two plist files with conditional flags** keep the build process simple and explicit, avoiding fragile scripts.  You only need to edit the Sparkle keys once, and the risk of divergence is low.
* **Sparkle and macOS 14 compatibility:** Sparkle 2.x is designed for macOS Sonoma.  Version 2.5.2, for example, replaces deprecated APIs and uses the new cooperative app activation API required on macOS 14.
* **Never rotate the Sparkle key** unless you intentionally break compatibility.  Back up your private key; losing it means existing users cannot verify future updates.

By following this procedure each time you release a new version—incrementing versions, regenerating the notarized DMG, signing it, updating the appcast, deploying to your site, and replacing the Gumroad file—you ensure a smooth update experience for both new and existing users.