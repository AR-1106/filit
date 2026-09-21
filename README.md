# Filit

<img src="docs/app-icon.png" width="128" alt="Filit">

Filit is a macOS menu bar app that pastes the *right* value into the field you are sitting in.

Copy a resume, a bio, or a contact block once. Click into a form — name, email, company, phone, whatever the label is — and press **⌥⌘V**. Filit reads the field, gathers candidates from your pinned source, clipboard history, and snippets, then asks [TypeSafe](https://typesafe.ai) which value belongs there. It pastes that string. Nothing else.

Regular **⌘V** is untouched. Filit lives in the menu bar with no Dock icon. History, snippets, and pinned source stay on your Mac.

## Why it exists

Forms want the same facts in slightly different shapes: “Full name” vs “First name”, “Mobile” vs “Phone”, “Company” vs “Organization”. You already have the answers in a document you copied. Filit is the step that matches the field in front of you to a value you already have, instead of you hunting through clipboard history by hand.

## How smart paste works

1. You pin a source (or just copy it) — a resume, an email signature, a job application dump.
2. You focus a text field in any app.
3. **⌥⌘V** reads the field label, placeholder, and nearby context via Accessibility.
4. Filit builds a capped candidate list from:
   - the pinned source
   - recent clipboard items
   - your snippet library
5. TypeSafe returns one choice (or none). Filit pastes that value verbatim.

You cap how much is sent: max candidates per request, how many history items are eligible, whether snippets and the pinned source participate. Settings shows an estimate before you paste, and the actual token usage after.

TypeSafe / Jev pricing: **$0.042 per million input tokens**. Output is free. Typical pastes are a fraction of a cent.

## Clipboard history

**⌘⇧D** opens a searchable history of what you have copied — plain text, rich text, images, files, and colors. Hover for a preview, then paste. History restores the original pasteboard formats (carbon copy), so an image pastes as an image.

Smart paste only sends **text** candidates to TypeSafe. Images and files stay local and never go to Jev.

History size is yours to set (default 200 on disk; 20 text items considered for smart paste). Transient / concealed pasteboard items (passwords) are ignored.

## Snippets

Add named snippets in Settings. Give one a keyword (`!sig`, `/addr`) and typing that keyword in any text field expands it.

Placeholders inside snippet text:

| Token | Expands to |
| --- | --- |
| `{clipboard}` | Current clipboard string |
| `{selection}` | Selected text in the focused field |
| `{date}` | Today’s date |
| `{time}` | Current time |
| `{datetime}` | Date and time |
| `{day}` | Weekday name |
| `{uuid}` | A new UUID |
| `{cursor}` | Removed; caret stays at that point |

You can also import a JSON file of snippets (`[{ "name", "keyword", "text" }]` or `{ "snippets": [...] }`).

## Install

```bash
brew tap AR-1106/tap
brew install --cask filit
```

Or grab `Filit-0.1.0.zip` from [Releases](https://github.com/AR-1106/filit/releases) and move `Filit.app` into Applications.

## First launch

Open Filit from Applications or Spotlight. A welcome window walks through:

1. **Accessibility** — Allow Access so Filit can read the focused field and paste
2. **TypeSafe API key** — paste it in and Save (stored in Keychain)
3. **Get started** — then copy something useful, click a field, and press **⌥⌘V**

Hotkeys are remappable in Settings.

## What leaves your Mac

| Stays local | Sent on smart paste |
| --- | --- |
| Full clipboard history | Field label / placeholder / nearby text |
| Snippet library | A capped candidate list you budgeted |
| Pinned source file | A short source excerpt, only if pinning is on |
| API key (Keychain) | — |

Data lives under `~/Library/Application Support/Filit/`. Smart paste never uploads your entire history.

## Build from source

macOS 14+, Xcode 16+.

```bash
brew install xcodegen
xcodegen generate
xcodebuild -scheme Filit -configuration Release -derivedDataPath build \
  -destination 'platform=macOS,arch=arm64' build
open build/Build/Products/Release/Filit.app
```

## License

MIT. See [LICENSE](LICENSE).
