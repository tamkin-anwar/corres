# Corres logo relay

Company logos beside companies' mail, without telling the company who's reading.

The app sends a sender's domain (`POST {"domain": "email.example.com"}`), never an address or anything from an email. This function looks up the domain's BIMI record (`default._bimi.<domain>`, then the organizational domain), and only uses a logo that comes with a mark certificate (`a=`), the proof Gmail requires, so a lookalike domain can't show a real brand's logo. The SVG is fetched only from a public https address, refused if it has scripts or outside references, drawn to a 160px PNG and returned. 404 when there's none.

Nothing is logged or stored except an in-memory cache by domain. The app keeps logos on the device for a month and a "none" for a week (`App/BrandLogos.swift`), and Settings › Private by Design turns them off.

Deploy from this directory (project `corres-509320`):

```bash
npm install
npm run deploy
```
