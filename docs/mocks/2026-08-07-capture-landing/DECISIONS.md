# Capture landing & navigation — IA decisions

2026-08-07. Companion to the three mockups in this directory:

- `a-global-focus.html` — global journal focus, one switcher shared by capture + library
- `b-capture-first.html` — capture knows nothing about journals; filing happens at stop
- `c-journal-first.html` — you enter a journal, then capture inside it

Each is self-contained (open in any browser), phone-sized, lightly interactive: use the
jump pills to walk idle → recording → stopped → the post-move-to-journal landing. All
three keep the recording machine honest — interruption/resume (the ⚡ link while
recording), markers disabled-not-hidden while interrupted, two-voices locked once
recording, per-journal backdate carry-over.

## Why now

The app grew screen-by-screen and the navigation never got designed as a whole. Owner
feedback parked for this session:

- Capture and library each grew their own journal switcher (a `Menu` and a chip row);
  it's unclear where "journal focus" lives as a concept.
- After move-to-journal from the detail screen you stay on the detail screen; expected
  to land in the destination journal's entry list.
- The ¶ button sits below the fold on iPhone — marker controls must be reachable
  without scrolling while reading aloud from a paper journal (the core use).
- Recents on the capture screen is unstyled and pushes content down.
- The capture landing page has had zero design attention overall.

## The questions

1. **Where does journal focus live?** Is "the journal I'm in" app state (one global
   focus), no state at all (each capture files itself), or a place you navigate into?
2. **One switcher pattern or two?** Capture's menu and library's chips are two answers
   to the same question. Do both screens share one component, does one screen lose its
   switcher entirely, or does the switcher become a screen of its own?
3. **What is Recents for?** A receipt ("did that capture land?"), an inbox (filing
   state), or a browse surface (the library's job leaking upstream)?
4. **When does filing happen?** Journal + backdate set before recording (today's
   model), or after stop?
5. **Where do you land after move-to-journal?** All variants answer "the destination
   journal's entry list" — the owner ask. The variants differ in *which surface* that
   list is.

Settled independently of the variant choice (rides whichever wins):

6. **Marker reachability.** While recording, layout flips from scroll to a fixed
   bottom thumb bar — voice switch · stop · ¶, each ≥ 76 pt, glued to the bottom edge.
   Nothing above it scrolls under it; ¶ can never be below the fold again. All three
   mocks share this bar deliberately: it is a decision, not a variant axis.

## How each variant answers

| Question | A — global focus | B — capture first | C — journal first |
|---|---|---|---|
| 1 Journal focus | App state, one global focus | Doesn't exist; entries carry filing | A place: you're *in* the open journal |
| 2 Switcher | One component, identical on capture + library, opens one sheet (#18) | Library chips only; capture has none | The shelf screen *is* the switcher (#18) |
| 3 Recents | Receipt: last 3 captures, compact one-line rows | Inbox: filing state, loud "Unfiled" badge | Dissolves — the journal's own list is the receipt |
| 4 Filing | At record time (as today) | At stop, via pre-filled filing card | At record time, implied by where you stand |
| 5 Post-move landing | Library list; global focus follows the move | Library list, destination chip selected | Destination journal's home screen |
| Two-voices carry | Per journal (as shipped) | **Per last capture — journal unknown at record time** | Per journal, plus a Settings default |
| Backdate carry | Per journal (as shipped) | Only at filing; **kill-before-filing = undated entry** | Per journal (as shipped) |
| Quick present-day capture | 1 tap (capture is home) | 1 tap (capture is home) | 2 taps from shelf, 1 if app reopens in-journal |

## Recommendation: A, borrowing C's journal rows and receipt pattern

**Variant A** fits the app that exists and the way it's actually used:

- The core loop is a *sitting* — one paper journal, many captures in a row. Global
  focus means dialing the journal once per sitting, exactly like today, but with one
  coherent concept instead of two switchers that happen to agree.
- It answers the owner's actual confusion directly: focus lives in one named place, and
  the switcher is one component rendered identically on both screens — #18 gets built
  once, not twice.
- Capture stays the landing screen, so present-day quick capture (user-journeys §2)
  costs nothing.
- Move-to-journal becomes "focus follows the entry": the landing rule falls out of the
  model instead of being a special case.

**B is the wrong fit for this app**, elegant as the filing card is. The paper-reading
loop knows the journal *before* recording starts — deferring filing adds a per-capture
confirmation to the highest-frequency flow to serve the rarer spontaneous one. It also
pays two real data costs: two-voices can't be journal-derived at record time (breaking
the shipped per-journal carry-over, and the frame-0 `bn` opener would have to be written
before the journal is known), and a kill before filing leaves an undated, unfiled
entry — user-journeys §8's open question becomes the normal case. Worth stealing: the
post-stop receipt ("Saved to 1987 Journal · 2:47 · 6 markers"), which A already adopts.

**C is the best-looking answer to #18 and the natural home for #35** — per-journal
Settings with the Easy/Confirm/Locked delete friction and the two-voices default — but
it demotes the flat cross-journal timeline from default to a side surface, and
user-journeys §6 (the payoff journey) wants one timeline. Worth stealing: the designed
journal rows (cover, name, range, count, tags) go straight into A's switcher sheet, and
a journal-info page reachable from that sheet inherits C's Settings layout, giving #35
a home without adopting journal-first navigation.

So the concrete proposal: **A's navigation model + C's switcher-row and journal-settings
design + B's post-stop receipt + the fixed marker thumb bar.**

## Point fixes folded into the winning variant

- **¶ below the fold** — fixed thumb bar (question 6). Ships with any variant; the
  recording state stops being a scroll layout at all.
- **#18 journal switcher** — A's switcher sheet with C's designed rows (cover, name,
  date range, entry count, two-voices/locked tags), replacing the bare `Menu`. Create /
  rename / cover move off the menu into a journal-info page reached from the sheet.
- **#35 delete friction** — the same journal-info page carries C's Settings block:
  Easy / Confirm / Locked segmented control (mocked in C, jump pill 2 → Settings).
  Enforcement stays model-level per the issue; this settles where the *control* lives.
- **#27 swipe-to-trash blink** — independent of variant, but the redesign is the moment
  to decide: recommend Mail's model (full swipe trashes immediately, no dialog — trash
  is 30-day recoverable, so the confirmation is redundant) which also kills the blink.
  Minimal alternative: drop `role: .destructive` from the swipe button only.
- **#17 cover polish** — covers now render in more places (switcher sheet rows, focus
  bar, shelf cards); the decoded-thumbnail cache in #17 moves from "eventually" to a
  prerequisite for whichever variant ships.
- **Recents restyle** — A's answer: three compact receipt rows (one-line serif snippet,
  journal tag), no play/delete affordances, below the record button, gone while
  recording.

## Addendum 2026-08-08: the recommendation, in three stylistic treatments

Owner asked to see the recommended IA rendered three ways — clean and minimal, tiny
rounding on square corners, no serif, subtle, French-pharmacy register. Three more mocks,
identical DOM/JS (the full recommendation: global focus bar, switcher sheet with designed
rows + journal settings for #35, post-stop receipt, fixed marker thumb bar) — only the
treatment differs:

- `d-comptoir.html` — warm chalk paper, ink text, one muted sage accent, hairline
  structure. Breaks the pinned near-black capture rule (deliberately on the table).
- `e-encre.html` — ink monochrome on near-black; the only pigments are record red and a
  pale sage for confirmation/selection; primary buttons invert to ink. The treatment
  that keeps the shipped capture-screen rule.
- `f-croix.html` — clinical white with pharmacy-cross green doing all interactive work;
  uppercase micro-labels everywhere (the packaging register); a 2 px green band under
  the status bar as the single decorative move.

Shared across all three: 2 px corners (including square-knobbed toggles), 1 px
hairlines, no fills-for-decoration, no serif anywhere (the serif snippet/transcript
style from the current app is dropped in these), and the record control as a red circle
inside a square button — the one round thing, on purpose.

## Addendum 2026-08-09: LN/BN transcript type + the icon-blue palette pass

Two mocks, closing items 2 and 3 of `docs/plans/2026-08-08-capture-landing-decisions.md`.

- `g-lnbn-type.html` — **the owed serif-vs-sans mock.** Two phone frames side by side,
  identical content, identical palette; the only difference is the transcript face.
- `h-encre-bleu.html` — **Encre with the accent re-cut off the app icon.** Structure,
  copy and behaviour are identical to `e-encre.html`; only the theme block differs.

### Where the blue came from

Sampled from `Raconte/Assets.xcassets/AppIcon.appiconset/icon-1024.png`. The icon is two
colors: a field of **#092343** — hsv 213.5° / 87% / 26%, and 88% of the icon's pixels —
and a cream **#efdfc6** for the face, the waves and the wordmark. #092343 is far too dark
to be an accent on a near-black screen, so the ramp **holds hue 213.5 and re-cuts
saturation and value only**: accent `#568acc`, pressed `#81b0eb`, hairline `#224673`,
wash `#0d1b2b`. Ink becomes the icon's cream pulled down (`#e7dfd1`) instead of a neutral
gray, so the screen is the icon's own navy-and-cream at low key. The page stays
near-black — the pinned capture rule is untouched. Encre's sage is gone.

One change beyond the swap: primary buttons take the blue fill rather than inverting to
ink. Reverting that is one line if you preferred the inverted-ink primary.

### What to look at in `g-lnbn-type.html`

Both phones render the shipped rules exactly — inline voice prefix, semibold and
secondary, concatenated onto the prose (`EntryDetailView.attributedParagraph`); the whole
BN paragraph italic (`TranscriptAttribution.isItalic`); unattributed paragraphs get no
prefix and are never italic. Three controls, each answering one question:

1. **Content** — *Mixed page* is the decision. Read a full screen on each side; the other
   three scenes are tie-breakers. *Short turns* asks whether the repeating prefix becomes
   texture when turns are one line each. *Long passage* is where BN-italic is actually
   tested — a whole screen of italic, not two lines of it. *Live while recording* puts
   the same prose on the near-black capture screen under the thumb bar, which is where it
   gets read at arm's length.
2. **Prefix** — shipped (prose face, semibold, secondary) against a letterspaced sans
   micro-cap in the accent, still inline. The second reads as a label rather than as a
   word in the sentence; it also survives the italic, where the shipped prefix does not.
3. **BN italic on/off** — what the page looks like if the print-vs-cursive signal moves
   entirely onto the prefix.

Two things that should weigh on the answer:

- **SF italic is an oblique.** As the stand-in for print-vs-cursive it is measurably
  weaker than New York's true italic. Check this on *Long passage* — it is the strongest
  argument the serif has, and it is not a taste argument.
- **The app icon's wordmark is set in a serif.** Choosing sans for the reading surface
  puts the transcript at odds with the mark. Not decisive, but a cost.

The sans side is set one point smaller (16 vs 17) because New York's x-height is smaller
at the same point size; this matches apparent size rather than nominal size. If you want
the literal same-point comparison instead, it is a one-line change.

Still not settled here: a **per-voice typeface**, which is the real answer to
print-vs-cursive and is deferred to T7 by the shipped comment on `isItalic`; the
`hasApproximateBoundary` affordance, still deliberately invisible; and the editing face
(T7, keyboard-first on iPad/Mac) — this is the reading face only.

## What the mocks deliberately do not settle

- Visual polish (type scale, exact colors, motion) — these are IA mocks in the app's
  existing dark idiom, not the M5 design pass.
- The macOS layout — everything here is the 390 pt phone frame; the Mac editorial
  surface (T7) is untouched.
- Whether "All journals" browsing in A is a chip, a switcher row, or a filter — mocked
  as a one-line affordance; decide when building.
