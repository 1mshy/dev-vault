# Secrets Vault

A native macOS password vault. Your secrets live in organizable **markdown documents** inside an encrypted vault that you unlock with a **master password** or **Touch ID**.

## Features

- **AES-256-GCM encryption** — the whole vault is a single encrypted file; nothing is stored in plain text
- **Master password** — key derived with PBKDF2-HMAC-SHA256 (600,000 iterations, random salt); the password itself is never stored
- **Touch ID unlock** — opt-in via Settings; the vault key is kept in the Keychain and released with your fingerprint
- **Markdown documents** — edit in monospace, toggle to a rendered Preview; code blocks get a one-click copy button (handy for passwords and dev commands)
- **Folders** — organize documents; right-click folders/documents for rename, move, delete
- **Search** — full-text search across titles and content
- **Auto-lock** — locks after inactivity (1/5/10/30 min or never, default 10); ⌘L locks instantly
- **Autosave** — changes are re-encrypted and written to disk ~0.7s after you stop typing

## Build & install

```
./build.sh
```

This produces `dist/Secrets Vault.app` (ad-hoc signed). To install:

```
cp -R "dist/Secrets Vault.app" /Applications/
```

## Usage

1. First launch: create a master password (min 8 characters). **It cannot be recovered** — if you forget it, the vault contents are lost.
2. Unlock the vault, then open **Settings (gear icon) → Unlock with Touch ID** to enable fingerprint unlock.
3. ⌘N — new document · ⌘L — lock · right-click in the sidebar for folder/document actions.

## Where data lives

- Vault file: `~/Library/Application Support/SecretsVault/vault.secrets` (encrypted envelope: salt + iterations + AES-GCM ciphertext, file mode 600)
- Back up by copying that file; restoring it on any machine + your master password restores the vault.

## Security model & caveats

- The decrypted vault exists **only in memory** while unlocked; locking discards the key and data.
- Touch ID: the app first tries the **data-protection keychain** with an OS-enforced biometry ACL. Ad-hoc-signed local builds can't use that keychain, so it falls back to a **login-keychain item gated by an in-app Touch ID check** (slightly weaker: enforced by the app, not the OS). Signing the app with a real Developer ID upgrades this automatically.
- Because the build is ad-hoc signed, macOS may show a keychain permission prompt after rebuilds, and Touch ID unlock may need re-enabling (Settings → toggle Touch ID off/on).
- Changing the master password re-encrypts the vault with a fresh salt and key and updates the Touch ID keychain entry.
