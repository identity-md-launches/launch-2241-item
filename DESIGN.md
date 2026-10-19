# DESIGN.md: ITEM token logo page

Source of truth: `web/src/style.css` (tokens and every component class), `web/src/main.ts` (markup),
`web/index.html` (document head, header). The export in `dist/` is built from these files.

## Overview

A one-page reference for the Item (ITEM) token's logo on Robinhood Chain. It is for people who need the
logo files: wallet and explorer maintainers, and the token's own team submitting the logo to RobinScan or
Blockscout. It is a tool page, not a marketing page: the logo and its download come first, then the
four files with their CIDs and hashes, a hash check, and the token facts.

The page is quiet on purpose. A warm off-white page, black ink, and the logo as the only colour on the
first screen. The hierarchy comes from size and weight, not colour. One filled button marks the main action
(download the 256 px PNG). Everything else is outlined or a plain link. Sections are separated by space
and a single hairline. There are no cards, shadows or gradients.

The logo files are never restyled, recoloured, cropped or re-encoded. They are shown at their own aspect
ratio on a white tile and served from `dist/logo/` byte for byte (Vite copies its public dir,
`assets/`, without transforming it).

## Colors

Hex notation throughout. Primitives are defined in `:root` in `web/src/style.css`. Components use only the
role tokens.

| Role token | Primitive | Value | Use |
| --- | --- | --- | --- |
| `--color-bg` | `--paper-50` | `#fbf8ef` | Page background, hover fill of outlined buttons |
| `--color-surface` | `--paper-0` | `#ffffff` | Logo tile, file thumbnails, command block, outlined button fill |
| `--color-border` | `--paper-200` | `#e6dfcd` | Hairlines between sections and file rows |
| `--color-text` | `--ink-900` | `#1c1a17` | Body text, headings, outlined button border and label |
| `--color-text-secondary` | `--ink-600` | `#5a554c` | Lede, intros, labels (`dt`), metadata, idle status text |
| `--color-action-solid` | `--ink-900` | `#1c1a17` | Fill of the one primary button |
| `--color-on-action-solid` | `--paper-50` | `#fbf8ef` | Label on the primary button |
| `--color-link` | `--blue-700` | `#1f4fbf` | Text links (header, IPFS, RobinScan) |
| `--color-focus` | `--blue-700` | `#1f4fbf` | `:focus-visible` outline |
| `--color-success` | `--green-700` | `#17643a` | "Address copied", "SHA-256 matches" (`[data-state="ok"]`) |
| `--color-danger` | `--red-700` | `#a8151d` | Copy failure, hash mismatch, load failure (`[data-state="error"]`) |

Status is never colour alone: every state is a full sentence ("SHA-256 does not match. …").
Contrast ratios computed from the declared hex pairs (WCAG 2): ink-900 on paper-50 16.35:1, ink-600 on
paper-50 6.97:1, paper-50 on ink-900 16.35:1, blue-700 on paper-50 6.75:1, green-700 on paper-50 6.77:1,
red-700 on paper-50 7.09:1. The taste@1 probe also measured all rendered text at 4.5:1 or better.

The logo's own yellow (`#ffdb29`) and red (`#df2029`) are not interface tokens. Do not reuse them for
controls or status; they belong to the artwork.

No dark theme is implemented.

## Typography

- Families: `--font-sans` = `system-ui, -apple-system, "Segoe UI", Roboto, "Helvetica Neue", Arial,
  sans-serif` for all prose and UI; `--font-mono` = `ui-monospace, "SF Mono", Menlo, Consolas,
  "Liberation Mono", monospace` for data only (addresses, CIDs, hashes, the shell command). No web fonts
  are loaded; the system faces render.
- Weights: 400 (body) and 600 (headings, button labels, brand name, file names, per-file status).
- Scale, four sizes:

| Token | Size | Line height | Used by |
| --- | --- | --- | --- |
| `--text-caption` | 0.8125rem (13px) | inherits 1.5 | Monospace data: address, CID, SHA-256, command |
| `--text-body` | 1rem (16px) | 1.5 (buttons 1.25, file name 1.3) | Body, buttons, links, file names (`h3`) |
| `--text-heading` | 1.25rem (20px) | 1.2 | Section headings (`h2`) |
| `--text-display` | 2.25rem (36px) | 1.1, letter-spacing −0.02em | Page title (`h1`), the only display text |

- Wrapping: `h1` and `h2` use `text-wrap: balance`; the lede and section intros use `text-wrap: pretty`
  and are capped at 34rem and 40rem. Long hex and CID values use `overflow-wrap: anywhere` so they wrap
  instead of overflowing or being cut. They are never truncated.
- Sentence case everywhere. No all-caps labels and no tracked text.
- Font smoothing is set once on `html`.

## Layout

- Spacing steps: `--space-1` 4px, `--space-2` 8px, `--space-3` 12px, `--space-4` 16px, `--space-6` 24px,
  `--space-8` 32px, `--space-12` 48px. Gaps inside a group are 8 to 12px. Gaps between groups are 24px
  or more.
- `.container`: max width `--page-max` 68rem, centred, inline padding `--page-gutter` (16px, 24px from
  40rem), never less than the safe-area inset.
- Logical properties throughout (`padding-inline`, `border-block-start`, `inset-inline-start`).
- Order: header (brand left, RobinScan link right) → hero → Logo files → Check the hashes → Token →
  footer.

Responsive behaviour (breakpoints come from where the content stops fitting):

| Width | Hero | File rows | Definition lists |
| --- | --- | --- | --- |
| < 40rem (phones, 320 and 390 checked) | One column: title, lede, logo tile (logo 10rem), buttons (wrap), address with copy button | Thumbnail + text in two columns; actions on their own row below | Label above value |
| ≥ 40rem | as above | Actions move to a third column, stacked | Label column 6rem, value beside it |
| ≥ 52rem (1440 checked) | Two columns: text, buttons and address on the left; logo tile (logo 16rem) on the right, vertically centred | as above | as above |

At 390 the title, lede, logo, both download buttons and the address fit in the first screen (checked in
`test/scratch` screenshots at 390×844). No width scrolls horizontally (checked at 320, 390, 1440).

## Elevation & Depth

Flat. There are no shadows. Depth comes from tone: white (`--color-surface`) tiles on the off-white page.
Hairline borders (`--color-border`) only separate sections and file rows. Buttons carry a 1px ink border
because it marks them as controls.

## Shapes

- `--radius-control` 0.5rem: buttons, file thumbnails, command block, skip link.
- `--radius-tile` 1rem: the hero logo tile.
- The logo image itself is never clipped or rounded.

## Components

All classes are in `web/src/style.css`; markup is in `web/src/main.ts` unless noted.

- **Header** (`.site-header__inner`, `.brand`, `.header-link`, in `web/index.html`). The brand is the
  32 px SVG plus "Item" and links home. The RobinScan token link is plain HTML, so it works without
  JavaScript. Both are at least 44px tall.
- **Skip link** (`.skip-link`): the first Tab stop, 44px tall. It is hidden above the viewport until
  focused and moves focus to `<main tabindex="-1">`.
- **Button** (`.button`): an outlined `<a download>` or `<button>`, at least 44px tall, label weight 600.
  - `.button--primary`: the filled ink variant. Use it once per view; here it is the 256 px PNG download.
  - States: hover (pointer devices only, `@media (hover: hover)`) fills outlined buttons with
    `--color-bg`; `:active` scales to 0.96 (150ms ease-out, `transition-property: scale,
    background-color`); under `prefers-reduced-motion: reduce` there is no scaling. `:disabled` gives
    opacity 0.7 and the progress cursor (the hash check while it runs). There is no `transition: all`.
  - Labels start with a verb and name the file ("Download item-64.svg"), so each link makes sense out of
    context.
- **Text link** (`.text-link`): blue, underlined with `from-font` thickness, at least 44px tall. External
  links open in a new tab with `rel="noopener noreferrer"`.
- **Focus** (`:focus-visible`): a 2px solid `--color-focus` outline offset by 2px, on every focusable
  element.
- **Logo tile** (`.hero__logo`): a white tile with 24px padding and a 1rem radius. It holds the 256 px
  PNG at 10rem (16rem from 52rem).
- **Address block** (`.address`): a label, the monospace address, an outlined Copy address button and a polite
  `role="status"` line (`#copy-status`). It reads "Address copied." on success. If the clipboard fails,
  it selects the address and asks you to press Ctrl+C or Cmd+C.
- **File row** (`.file` in `.file-list`): one row per entry in `assets/logo/logo.json`. It shows a
  thumbnail (`.file__thumb`, 4rem; each file at most 64px), the file name (`h3.file__name`), metadata
  (`.file__meta`: role · dimensions and type · bytes), and a CID and SHA-256 `dl` (`.ids`). After a check,
  a status line (`.file__status`, hidden until then) appears, followed by the actions (`.file__actions`:
  a Download button and an "Open … on IPFS" link).
- **Hash check** (`.check`): the "Check SHA-256 hashes" button and a polite status line
  (`#check-status`). It fetches each file from `./logo/`, hashes it with `crypto.subtle`, and writes
  per-row and summary results. States:
  - idle: empty
  - running: the button is disabled and reads "Checking hashes…"; the status reads "Checking 4 files…"
  - success: "All 4 files match their SHA-256."
  - partial: "N of 4 files match. See the files marked above.", with the mismatch or load error written
    in the affected row
  - unsupported (no `crypto.subtle` outside HTTPS): a sentence saying to use HTTPS or `sha256sum`
- **Command block** (`pre.command`): a monospace shell command on a white surface. It scrolls
  horizontally only inside itself.
- **Facts list** (`dl.facts`): label/value pairs for the token (name, symbol, decimals, chain, contract).

## Do's and Don'ts

- Do serve logo files from `assets/logo/` unchanged. Never redraw, recolour, compress or crop them.
- Do keep one filled button per view. Additional actions are outlined buttons or text links.
- Do use monospace only for data (addresses, hashes, CIDs, commands), at `--text-caption`.
- Do let long values wrap with `overflow-wrap: anywhere`. Never ellipsize an address or hash.
- Do write every state as a sentence; colour only reinforces it.
- Don't add sizes beyond the four in the scale, weights beyond 400 and 600, or a third font family.
- Don't add shadows, gradients, cards inside cards, kicker labels or all-caps text.
- Don't add an address that is not in the launch's verified deployment record. The page takes the token
  from `assets/logo/logo.json`; the header's RobinScan link in `web/index.html` repeats the same token
  address; chain facts in `web/src/config.ts` come from the pinned network file.
