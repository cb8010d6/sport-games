# UI fonts

Both families are licensed under the SIL Open Font License 1.1 (`OFL-1.1`). The full license
texts ship next to the fonts and must stay with them in every build.

| File | Family | Upstream | License |
|---|---|---|---|
| `NotoSansSC-RS.ttf` | Noto Sans SC (variable, `wght` 100–900), subset | <https://github.com/google/fonts/tree/main/ofl/notosanssc> | [OFL-NotoSansSC.txt](OFL-NotoSansSC.txt) |
| `BarlowCondensed-SemiBold.ttf` | Barlow Condensed SemiBold | <https://github.com/google/fonts/tree/main/ofl/barlowcondensed> | [OFL-BarlowCondensed.txt](OFL-BarlowCondensed.txt) |
| `BarlowCondensed-BoldItalic.ttf` | Barlow Condensed Bold Italic | same | same |
| `BarlowCondensed-ExtraBoldItalic.ttf` | Barlow Condensed ExtraBold Italic | same | same |

Downloaded from google/fonts at commit `e7db6ca603fd4862010383ff17ffd6cc4ffac1c0`, 2026-10-24.
Noto Sans SC copyright 2014-2021 Adobe, Reserved Font Name "Source"; Barlow copyright 2017
The Barlow Project Authors.

The Barlow files are unmodified. `NotoSansSC-RS.ttf` is a subset made with
`tools/subset_fonts.py` (fontTools): the characters of the game's own text, GB 2312 level 1,
Latin-1, punctuation and UI symbols, hinting removed. The family name is unchanged and does
not use the Reserved Font Name. Characters outside the subset fall back to the system CJK font.
