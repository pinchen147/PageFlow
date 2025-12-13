# Sparkle Auto-Update Integration

PageFlow uses [Sparkle](https://sparkle-project.org/) for auto-updates when distributed outside the Mac App Store. The feature is compile-time optional via the `ENABLE_SPARKLE` flag.

## Architecture

```
UpdateManager (@Observable)
    └── SPUStandardUpdaterController
            ├── Reads SUFeedURL from Info.plist
            ├── Checks appcast.xml for updates
            └── Downloads, verifies, and installs updates
```

The `UpdateManager` is gated behind `#if ENABLE_SPARKLE` so offline builds exclude all update code.

## Enabling Sparkle in Your Build

### 1. Add Sparkle Package (Xcode)

1. File → Add Package Dependencies
2. Enter: `https://github.com/sparkle-project/Sparkle`
3. Select version 2.x
4. Add to PageFlow target with "Embed & Sign"

### 2. Add Compiler Flag

1. Select PageFlow target → Build Settings
2. Search for "Swift Compiler - Custom Flags"
3. Add `-DENABLE_SPARKLE` to **Release** configuration

### 3. Configure Info.plist

Add these keys via Target → Info → Custom macOS Application Target Properties:

| Key | Value |
|-----|-------|
| `SUFeedURL` | `https://yourdomain.com/appcast.xml` |
| `SUPublicEDKey` | Your EdDSA public key (see below) |
| `SUEnableAutomaticChecks` | `YES` |

## Setting Up Your Appcast Server

### Step 1: Generate EdDSA Keys

Run this once per project. **Keep your private key secure!**

```bash
# Download Sparkle tools
curl -L https://github.com/sparkle-project/Sparkle/releases/latest/download/Sparkle-2.6.4.tar.xz -o sparkle.tar.xz
tar xJf sparkle.tar.xz

# Generate key pair
./Sparkle.framework/Versions/B/Resources/generate_keys
```

Output:
```
A]key has been generated and saved in your keychain.
Add the `SUPublicEDKey` key to your Info.plist; its value is:
<YOUR_PUBLIC_KEY_HERE>
```

Copy the public key to your `SUPublicEDKey` Info.plist entry.

### Step 2: Create appcast.xml

Create an XML file with your update feed:

```xml
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>PageFlow Updates</title>
    <link>https://yourdomain.com/appcast.xml</link>
    <description>PageFlow release feed</description>
    <language>en</language>

    <item>
      <title>Version 1.1</title>
      <description><![CDATA[
        <h2>What's New</h2>
        <ul>
          <li>New feature X</li>
          <li>Bug fix Y</li>
        </ul>
      ]]></description>
      <pubDate>Wed, 01 Jan 2025 12:00:00 +0000</pubDate>
      <sparkle:version>2</sparkle:version>
      <sparkle:shortVersionString>1.1</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>12.0</sparkle:minimumSystemVersion>
      <enclosure
        url="https://yourdomain.com/releases/PageFlow-1.1.zip"
        length="15728640"
        type="application/octet-stream"
        sparkle:edSignature="YOUR_SIGNATURE_HERE"
      />
    </item>

  </channel>
</rss>
```

**Key fields:**
- `sparkle:version`: Must match `CFBundleVersion` (build number, integer)
- `sparkle:shortVersionString`: Must match `CFBundleShortVersionString` (e.g., "1.1")
- `sparkle:edSignature`: EdDSA signature of your zip file

### Step 3: Archive and Sign Your Release

```bash
# 1. Archive in Xcode: Product → Archive
# 2. Export: Distribute App → Copy App → Export

# 3. Create zip
cd /path/to/exported/app
zip -r PageFlow-1.1.zip PageFlow.app

# 4. Sign the zip
/path/to/Sparkle.framework/Versions/B/Resources/sign_update PageFlow-1.1.zip
```

Output:
```
sparkle:edSignature="BASE64_SIGNATURE_HERE" length="15728640"
```

Copy the signature to your appcast.xml `enclosure` element.

### Step 4: Host Your Files

You need to host:
1. `appcast.xml` - The update feed
2. `PageFlow-X.X.zip` - The signed app archives

**Hosting Options:**

| Option | Pros | Setup |
|--------|------|-------|
| GitHub Pages | Free, HTTPS, reliable | Enable in repo settings, push to `gh-pages` branch |
| GitHub Releases | Free, handles large files | Upload zip as release asset |
| S3 + CloudFront | Scalable, fast CDN | Create bucket, enable static hosting |
| Netlify/Vercel | Free tier, easy deploy | Connect repo or drag-drop |

**GitHub Pages Example:**

```bash
# In your repo
mkdir -p docs/releases
cp appcast.xml docs/
cp PageFlow-1.1.zip docs/releases/

# Update appcast.xml URLs:
# SUFeedURL: https://username.github.io/pageflow/appcast.xml
# Download URL: https://username.github.io/pageflow/releases/PageFlow-1.1.zip

git add docs/
git commit -m "Add release 1.1"
git push
```

## Release Workflow

For each new release:

1. **Increment version numbers** in Xcode:
   - `MARKETING_VERSION` (CFBundleShortVersionString): `1.2`
   - `CURRENT_PROJECT_VERSION` (CFBundleVersion): `3`

2. **Archive and export** the app

3. **Create and sign** the zip:
   ```bash
   zip -r PageFlow-1.2.zip PageFlow.app
   sign_update PageFlow-1.2.zip
   ```

4. **Update appcast.xml** with new `<item>` entry

5. **Upload** zip and appcast.xml to your host

6. **Test** by running the previous version and checking for updates

## Testing Updates

To test the update flow:

1. Build a "previous" version (e.g., version 1.0)
2. Create and host a "new" version in your appcast
3. Run the old version and trigger "Check for Updates…"
4. Verify the update dialog appears and installation works

**Debug tip:** Set `SUEnableSystemProfiling` to `NO` and check Console.app for Sparkle logs.

## Offline Builds

To create an offline build without any update functionality:

1. Remove `-DENABLE_SPARKLE` from Swift Compiler Flags
2. Build → All Sparkle code is excluded at compile time

The `UpdateManager` class compiles to an empty shell, and no network code is included.

## Troubleshooting

| Issue | Solution |
|-------|----------|
| "No updates available" | Verify `sparkle:version` > current `CFBundleVersion` |
| Signature verification failed | Re-sign zip with `sign_update`, update appcast |
| Update doesn't download | Check `enclosure url` is accessible over HTTPS |
| Menu item always disabled | Ensure `startingUpdater: true` in `UpdateManager` |

## Security Notes

- **Private key**: Never commit to version control. It's stored in your macOS Keychain.
- **HTTPS required**: Sparkle 2.x requires HTTPS for both appcast and downloads.
- **Code signing**: Your app must be code-signed for Sparkle to work correctly.
