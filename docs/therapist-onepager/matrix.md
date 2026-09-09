# Comparison matrix (checked 2026-09-08)

Same data as page 2 of `onepager.pdf`, apps as rows. Sources and verbatim quotes are in `survey.md`; “Not stated” means the vendor’s public pages, as indexed on the check date, do not say. ADP = Apple’s Advanced Data Protection. Prices are US.

| App | Where stored | Who else can read it | Audio kept | On-device transcription | Account required | Export | Therapist sharing | HIPAA claim | Price |
|---|---|---|---|---|---|---|---|---|---|
| **Raconte** | Device + own iCloud | No one; Apple holds keys unless ADP is on | Yes, source of truth | Yes (Apple, iOS 26) | No | Everything: audio, text, checksums, in-app verifier | None built in; client exports and hands over | None | Free; private TestFlight |
| **Day One** | Device + vendor cloud | Vendor: no (E2E claimed) | Yes | iOS 26 with Apple Intelligence; else Apple servers | For sync | JSON + media incl. audio; PDF, TXT, CSV | Shared Journals or export | Not stated | Free; $49.99–$74.99/yr |
| **Journey** | Own Google Drive or vendor cloud | Vendor: no with E2E on; else not stated | Yes, but not transcribed | No; OS dictation only | Yes | ZIP; audio not stated | Export | Not stated | $49.99/yr |
| **Voicenotes** | Vendor cloud (AWS) | Vendor staff (one vetted person); AI providers process notes | Yes | No, cloud | Yes (guest trial) | Per note, audio + text; bulk not stated | Export | Not stated | Free; $99.99/yr |
| **Otter.ai** | Vendor cloud | Staff with consent; trains AI on de-identified data by default | Yes (removable) | No, cloud | Yes | TXT, DOCX, PDF, SRT + audio | Export | Enterprise plan only (BAA) | Free; $16.99/mo |
| **Reflectly** | Vendor cloud | Not stated; shows ads | No audio | No; dictation only | Yes | PDF (paid) | Export | Not stated | $59.99/yr |
| **Rosebud** | Vendor cloud (Google) | AI providers (OpenAI, Anthropic, Groq), anonymised text | Not stated | No, cloud | Yes | Markdown; audio not stated | Weekly summary to share | “HIPAA-aligned”; no BAA to users | Free; $12.99/mo |
| **Daylio** | Device + own iCloud/Drive | Vendor: no | Not stated | Not stated | No | PDF, CSV, backup file; audio not stated | Export | Not stated | Free; premium tiers |
| **Mentalium** | Device only | Not stated | Not stated | Yes (offline model) | Not stated | Excel report; audio not stated | Emailed report | Not stated | $59.99/yr |
| **SimplePractice portal** | Vendor cloud | Therapist + practice staff | No client audio | None | Yes | Client export not stated | Shared portal (clinician forms) | Yes; BAA with the clinician | Clinician pays, $49+/mo |
| **TherapyNotes portal** | Vendor cloud | Practice staff, by group | No client audio | None | Yes | Not stated | Shared portal (no journaling) | Yes; BAA in terms of service | Clinician pays, $69+/mo |
| **Quenza** | Vendor cloud | Therapist, per note the client shares | No client audio | None | Yes | Not stated | Shared portal; client chooses per note | BAA on request | Practitioner pays, $25+/mo |
| **Apple Journal** | Device + own iCloud | No one, incl. Apple (E2E) | Yes | Yes | Apple Account for iCloud | PDF, whole-journal file; audio not stated | Export | Not stated | Free with iOS/macOS |
