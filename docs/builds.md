# Builds

One line per build the owner is handed, smoke or TestFlight. `N` is `CFBundleVersion`
in `project.yml`; About → App → Build shows `build N: <link date>`. Bump N and add a
line here in the same commit as the build. Not retroactive — starts at 14 (#141).

| N | date | branch / SHA | what it is |
|---|------|--------------|------------|
| 14 | 2026-09-06 | `main` `28dbf0c2` | first numbered build; Mac owner smoke, 8/8 pass. #140 Discard removal, #122 finalize fix, #139/#75/#77/#47/#105 small fixes, #141 this row, #43/#51/#70 core hardening, #136 live ¶ break |
| 15 | 2026-09-06 | `main` `e000ac24` | first TestFlight upload of the overnight slate; same source as 14, iOS. For the iPhone device smoke. |
| 16 | 2026-09-07 | `main` `35bbc068` | Mac owner smoke of the merged overnight slate: #150 park/refetch, #152 quarantine, #153 out-of-span glyph + one clock, #151 archive export + verifier |
| 17 | 2026-09-07 | `main` `05c19d88` | Mac owner smoke of Batch A: #158 Verify archive… + parked rows (#154/#156), #159 capture tick containment + entry→journal link (#155/#148) |
| 18 | 2026-09-08 | `main` `dce1837a` | Mac owner smoke AND iOS TestFlight upload of Batch B: #165 (#161 warning glyph, #163 Trash quarantine block, #162 partial), #166 (#106 cover lightbox, #164 live voice labels), #160 overview refresh |
| 19 | 2026-09-08 | `main` `52e95f6e` | Mac owner smoke of Batch C: #169 (#162 batch 1 TypeRole sweep, #168 Trash headers) |
| 20 | 2026-09-09 | `feat/157-export-scope` `dd25c4e8` | Mac owner smoke of PR #174 (#157 export confirmation sheet + journal-scoped export), on top of merged #172 |
