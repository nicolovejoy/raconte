# Builds

One line per build the owner is handed, smoke or TestFlight. `N` is `CFBundleVersion`
in `project.yml`; About → App → Build shows `build N: <link date>`. Bump N and add a
line here in the same commit as the build. Not retroactive — starts at 14 (#141).

| N | date | branch / SHA | what it is |
|---|------|--------------|------------|
| 14 | 2026-09-06 | `main` `28dbf0c2` | first numbered build; Mac owner smoke, 8/8 pass. #140 Discard removal, #122 finalize fix, #139/#75/#77/#47/#105 small fixes, #141 this row, #43/#51/#70 core hardening, #136 live ¶ break |
