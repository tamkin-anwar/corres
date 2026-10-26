# Corres logo relay

Company logos beside companies' mail, without telling the company who's reading.

The app sends a sender's domain (`POST {"domain": "email.example.com"}`), never an address or anything from an email. This function looks up the domain's BIMI record (`default._bimi.<domain>`, then the organizational domain), and only shows a logo that comes with a valid mark certificate (`a=`), the proof Gmail requires, so a lookalike domain can't show a real brand's logo. 404 when there's none.

What is checked (`vmc.js`):

- The certificate file is fetched only over https from a public address (the connection uses the address that was checked, so DNS rebinding can't point it inside Google's network), no redirects, at most 128 KB in 4 seconds.
- The chain: every signature up to one of the pinned mark certificate roots (DigiCert Verified Mark Root CA, GlobalSign Verified Mark Root R42, SSL.com VMC RSA and ECC Root CA 2024, which also cover Sectigo's VMCs), every certificate's dates, CA flags, and the mark certificate usage (1.3.6.1.5.5.7.3.31) on the leaf and on every intermediate that names a usage. Entrust's old root isn't pinned: Entrust no longer issues VMCs and the ones it issued have expired.
- The leaf names the domain, the domain the record was found at, or the organizational domain (or `<selector>._bimi.<domain>`), with no wildcards.
- The logo inside the certificate (RFC 3709), whose hash must match. That is the logo drawn, not the `l=` file, so a company can't show a logo its certificate doesn't carry.
- DMARC at quarantine or reject (100%) for the organizational domain, and for a subdomain its own policy or `sp=`, as BIMI requires.
- The SVG has no scripts, entities or outside references (only `#id` links), then it is drawn to a 160px PNG.

Not checked: revocation (OCSP or CRL) and Certificate Transparency proofs.

Concurrent requests for the same domain share one lookup. Nothing is logged or stored except an in-memory cache by domain. The app keeps logos on the device for a month and a "none" for a week (`App/BrandLogos.swift`), and Settings › Private by Design turns them off.

Deploy from this directory (project `corres-509320`):

```bash
npm install
npm run deploy
```
