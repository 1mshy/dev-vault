# Secrets Vault

A native macOS password vault. Your secrets live in organizable **markdown documents** inside an encrypted vault that you unlock with a **master password** or **Touch ID**.

## Features

- **AES-256-GCM encryption** — the whole vault is a single encrypted file; nothing is stored in plain text
- **Argon2id key derivation** (libsodium, "moderate" cost: 3 passes / 256 MB) — the master password is never stored; older PBKDF2 vaults are upgraded automatically on the next password unlock
- **Touch ID unlock** — opt-in via Settings; the vault key is kept in the Keychain and released with your fingerprint
- **Markdown documents** — edit in monospace, toggle to a rendered Preview; code blocks get a one-click copy button (handy for passwords and dev commands)
- **Folders** — organize documents; right-click folders/documents for rename, move, delete
- **Search** — full-text search across titles and content
- **Autosave** — changes are re-encrypted and written to disk ~0.7s after you stop typing
- **Backup rotation** — before the vault file is overwritten, the previous (known-good) copy is rotated into `vault.secrets.1`…`.5` next to it, so a corrupted write can never destroy the only copy (at most one rotation every 5 minutes)
- **Recently Deleted** — deleting a document moves it to a Recently Deleted section in the sidebar, where it can be previewed, restored, or deleted permanently; items are purged automatically after 30 days
- **Export & import** — export an encrypted copy of the vault (Settings) for moving machines or off-site backup, and import it on another Mac (Settings, or "Import Existing Vault…" on first launch); an optional plain-markdown export exists behind a loud warning

## Security behaviors

- **Locks automatically** when: the screen locks, the Mac (or its displays) goes to sleep, the vault window closes, or the idle timer fires (1/5/10/30 min or never, default 10). ⌘L locks instantly.
- **Clipboard hygiene** — the Preview copy button marks the pasteboard item as concealed (`org.nspasteboard.ConcealedType`, respected by well-behaved clipboard managers) and clears the clipboard after 30 seconds unless you've copied something else since.
- **Screen-capture protection** — all app windows are excluded from screenshots and screen sharing (`NSWindow.sharingType = .none`). Note this also blanks your own ⇧⌘4 window captures.
- The decrypted vault exists **only in memory** while unlocked; locking discards the key and data.

## Build & install

```
./build.sh
```

This produces `dist/Secrets Vault.app`. To install:

```
cp -R "dist/Secrets Vault.app" /Applications/
```

### Code signing

`build.sh` picks the best available signature automatically:

1. `$CODESIGN_IDENTITY` if set (`CODESIGN_IDENTITY=adhoc` forces ad-hoc)
2. A "Developer ID Application" identity, if present (hardened runtime + timestamp)
3. An "Apple Development" identity, if present (hardened runtime)
4. Ad-hoc

A real identity gives the app a **stable code signature**, so the Keychain stops re-prompting after rebuilds. With only an ad-hoc signature, macOS may show a keychain permission prompt after each rebuild and Touch ID may need re-enabling (Settings → toggle Touch ID off/on).

Touch ID key storage: the app first tries the **data-protection keychain** with an OS-enforced biometry ACL; where the build lacks the required entitlement (ad-hoc, or a certificate without a provisioning profile), it falls back to a **login-keychain item gated by an in-app Touch ID check** — slightly weaker, enforced by the app rather than the OS.

### Self-test

```
"dist/Secrets Vault.app/Contents/MacOS/SecretsVault" --selftest
```

Verifies Argon2id determinism, AES-GCM round-trip, wrong-key rejection, and legacy-envelope decoding. Prints `SELFTEST OK` on success.

## Usage

1. First launch: create a master password (min 8 characters). **It cannot be recovered** — if you forget it, the vault contents are lost.
2. Unlock the vault, then open **Settings (gear icon) → Unlock with Touch ID** to enable fingerprint unlock.
3. ⌘N — new document · ⌘L — lock · right-click in the sidebar for folder/document actions.

## Where data lives

- Vault file: `~/Library/Application Support/SecretsVault/vault.secrets` (encrypted envelope: KDF parameters + salt + AES-GCM ciphertext, file mode 600)
- Rotated backups: `vault.secrets.1` (newest) … `vault.secrets.5` (oldest), same directory, same format and password. Restore one via Settings → Import Vault…, or by copying it over `vault.secrets` while the app is closed.
- Back up off-machine with Settings → Export Encrypted Copy…; importing that file on any machine + your master password restores the vault.
- Changing the master password (or the automatic KDF upgrade) re-encrypts the vault with a fresh salt and key, refreshes the Touch ID keychain entry, and deletes the rotated backups (they are encrypted under the previous password and would silently undermine the change).
