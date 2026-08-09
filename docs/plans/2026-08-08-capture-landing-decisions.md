# Capture-landing mocks — owner decisions (2026-08-08 evening)

Owner reviewed all six mocks from `origin/design/capture-landing-mocks`
(`docs/mocks/2026-08-07-capture-landing/`, gallery-viewed side by side; DECISIONS.md on
that branch is the companion). Decisions, verbatim intent:

1. **IA approved as recommended**: A's global-focus navigation + C's journal rows/settings
   + B's post-stop receipt + the fixed marker thumb bar. BUT the owner wants to **iterate
   again on the capture interface specifically** (later, not now) — "that's the main one
   really, unless the edit one comes in big too." And the **look discussion should happen
   on a larger screen (iPad/Mac)** — owner may prefer a **keyboard when reading journals,
   for the typing/editing bit** → feed directly into the T7 editor plan (Mac/iPad
   editorial surface, keyboard-first editing is a live preference).
2. **Treatment: liked (dark direction), with a palette shift** — "slightly different color
   palette, connected to the blue of the app icon." Sample the actual blue from
   `Raconte/Assets.xcassets/AppIcon.appiconset/icon-1024.png` and re-cut the accent
   (replacing the sage) before calling the treatment settled. (Owner did not explicitly
   pick D/E/F by letter; E is the one that keeps the shipped near-black capture rule and
   the reviewed direction was dark — confirm E-with-blue when showing the palette pass.)
3. **Serif question unresolved → owed a mock**: "show me a mock of LN/BN back and forth
   in the font of choice." Build a small HTML mock of the voice-attributed transcript
   (inline `BN:`/`LN:` labels semibold-secondary, BN italic — the shipped rendering) in
   the candidate typography, ideally serif-content vs sans-content side by side, dark
   treatment, icon-blue accent. Owner picks from that.
4. **#27 swipe-to-trash: Mail model approved WITH a carve-out** — full swipe trashes
   immediately, no dialog, EXCEPT a journal's #35 friction setting can make deleting
   harder (Confirm) or impossible (Locked). The lock integration "can come later, but
   not too much later" — sequence #35's friction setting soon after #27's swipe change,
   not someday.

Housekeeping note: `design/capture-landing-mocks` accidentally carries committed
`.build/` Xcode cache junk — clean before merging anything from it (cherry-pick the
`docs/mocks/` files rather than merging the branch).
