# Translating EeveeSpotify

Thank you for helping translate EeveeSpotify! All UI strings live in `.strings` files inside the tweak's bundle, and every locale is community-maintained. This guide explains the layout, the rules, and how to check your work before opening a PR.

---

## Where translations live

```
layout/Library/Application Support/EeveeSpotify.bundle/<locale>.lproj/Localizable.strings
```

Examples:

- `layout/Library/Application Support/EeveeSpotify.bundle/en.lproj/Localizable.strings` — the **baseline** every locale is checked against
- `layout/Library/Application Support/EeveeSpotify.bundle/uk.lproj/Localizable.strings`
- `layout/Library/Application Support/EeveeSpotify.bundle/zh-CN.lproj/Localizable.strings`

The `<locale>` folder name is a standard Apple language ID: a language code, optionally with a region/script suffix (`pt-BR`, `zh-TW`, `ar-EG`). Use an existing folder if one matches your language; otherwise create a new `<locale>.lproj` directory containing one `Localizable.strings` file.

> Note: some locales appear with different region suffixes (e.g. `pt` and `pt-BR`). If both exist, pick the more general one (`pt`) unless your translation genuinely differs by region.

---

## Adding a new locale

1. Copy the baseline as your starting point:

   ```bash
   mkdir -p "layout/Library/Application Support/EeveeSpotify.bundle/xx.lproj"
   cp "layout/Library/Application Support/EeveeSpotify.bundle/en.lproj/Localizable.strings" \
      "layout/Library/Application Support/EeveeSpotify.bundle/xx.lproj/Localizable.strings"
   ```

2. Translate the **value** on the right of each `=`. **Never change the key** on the left.

3. Run the linter (see below) and fix anything it reports.

4. Open a PR with your locale code in the title, e.g. `Add xx-XX localization`.

---

## The rules (enforced by the linter)

### 1. Keys are immutable

The key (`left side`) is what the code looks up:

```
reset_data = "Скинути дані";      ✅ correct
"reset_data" = "Скинути дані";    ❌ no — key changed
reset_dataDescription = "...";    ❌ no — key renamed
```

### 2. Keep format placeholders intact

Strings used with `.localizeWithFormat(...)` contain placeholders like `%@`, `%d`, or positional `%1$@`. These are substituted at runtime — **a missing placeholder will garble the sentence for users of that language** (this exact bug shipped at least once, which is why the linter checks it).

```
patching_description = "...";                        ❌ no — the English version ends with %@
patching_description = "... \n\n%@";                 ✅ correct — same number of %@ as English
```

Keep the placeholder in the position that reads naturally in your language; for multiple placeholders, keep the same order (or use positional ones like `%1$@` / `%2$@` if the grammar requires reordering).

### 3. Escape quotes and keep newlines

Inside values, escape double quotes as `\"` and keep literal line breaks as written in English (multi-line values are fine and intentional).

```
lyrics_additional_info = "... you'll see a \"Couldn't load the lyrics for this song\" message ...";
```

### 4. Escape sequences and special characters carry over

If the English value contains `\n`, `\t`, or similar, your translation must too.

### 5. Don't translate brand names or proper nouns

Keep these as-is: `EeveeSpotify`, `Spotify`, `Musixmatch`, `PetitLyrics`, `LRCLIB`, `Genius`, `SponsorBlock`, `TrollStore`, `SideStore`, `CarPlay`, `Siri`, `Jam`, `SpicyLyrics` `AI DJ`.

### 6. Delete nothing, reorder nothing

- Missing keys are reported as **errors** — the app falls back to English for missing keys, and it makes the locale look broken in reports.
- Extra keys that don't exist in `en.lproj` are also **errors** (they're stale leftovers).
- Key order doesn't matter to the app, but keeping the same order as `en.lproj` makes diffs reviewable.

### 7. Content style

- Keep it short — settings rows truncate long text.
- Use the tone of the English original: friendly, direct, no slang.
- Don't add disclaimers, credit lines, or URLs that aren't in the English source.
- Section comments (`/* MARK: ... */`, `// ...`) in the file are for humans; you can keep or translate them, the app ignores them.

---

## Checking your work

A linter ships in this repo; it compares your locale against the English baseline and the Swift sources:

```bash
python3 Tools/l10n_lint.py --locale xx      # only your locale
python3 Tools/l10n_lint.py                  # all locales (full report)
python3 Tools/l10n_lint.py --quiet          # only locales with problems
```

What it reports:

| Check | Severity | Meaning |
|---|---|---|
| Missing keys | **error** | Key exists in `en.lproj` but not yours — app shows English |
| Extra keys | **error** | Key not in `en.lproj` — stale/renamed leftover |
| Format-arg mismatch | **error** | Placeholder count differs from English — will break at runtime |
| Unused keys | warning | Defined but never referenced in Swift — ask before removing |

Your PR should introduce **zero new errors** for your locale. If the linter reports pre-existing errors in other locales, ignore them — those are not yours to fix (unless you want to!).

No local Python? Note in your PR that you couldn't run it, and a maintainer will run it for you.

---

## Updating an existing locale

New strings appear whenever features are added; locales drift behind the baseline over time. To catch up:

1. Run `python3 Tools/l10n_lint.py --locale xx` to get the exact missing-key list.
2. Find each key in `en.lproj` and add a translated entry in the same spot in your file.
3. Re-run the linter until your locale is clean.
4. Partial updates are welcome — even a PR that fills in one section (e.g. all SponsorBlock strings) helps.

---

## Registering the locale (one extra step)

The tweak's bundle ships an `Info.plist`. New `.lproj` folders are picked up by iOS automatically in most cases, but if your language doesn't show up in testing, add your locale to `CFBundleLocalizations` in:

```
layout/Library/Application Support/EeveeSpotify.bundle/Info.plist
```

---

## Questions

- General usage and install questions: see [common_issues.md](common_issues.md) or the [Telegram channel](https://t.me/compiledipas).
- For anything about this guide itself, open an issue or PR against this file.
