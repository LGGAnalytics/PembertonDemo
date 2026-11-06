# Brand tokens used in the dashboard mockup

Taken from the public stylesheet of pembertonam.com (theme `main.css`, `theme-color` meta), Nov 2026.

| Role | Hex | Source token |
|---|---|---|
| Navy (headings, header band, primary bars) | `#192C50` | `--headings`, `--text`, `theme-color` |
| Primary blue | `#3D7CC9` | `--primary`, `--link` |
| Secondary blue | `#195094` | `--secondary` |
| Slate | `#474D70` | `--background-color` |
| Stone (warm neutral) | `#D7D2CB` | theme CSS |
| Light blue / ice | `#B9D9EB` / `#EAF3F9` | theme CSS |
| Green accent | `#6BBD4A` | theme CSS |
| Purple accent | `#7D63BD` | theme CSS |

Typography on their site: GFS Didot (display), Libre Baskerville (headings), Helvetica Neue Light (body).
Mockup uses Didot for the title, Baskerville for card titles and Inter for numbers.

Fund series palette (in order): `#3D7CC9`, `#6BBD4A`, `#7D63BD`. It passes the colorblind-separation
checks; green is below 3:1 contrast on white, so its lines always carry direct labels.
Status colors (watchlist and non-accrual) use the fixed red/amber set and always come with a text label.
