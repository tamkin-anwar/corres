# Corres regional pricing: real-world benchmarks and practice

Collected 2026-10-27. All prices were live-scraped on 2026-10-27 unless noted otherwise.

## How the numbers were collected

- **FX:** open.er-api.com (ExchangeRate-API) USD rates, last updated Tue 27 Oct 2026 00:02 UTC (https://open.er-api.com/v6/latest/USD). For example: INR 95.27, PKR 276.8, IDR 18,149, PHP 63.96, VND 25,832, THB 33.79, MYR 4.087, BRL 5.432, MXN 18.59, ARS 1,540, COP 3,155, CLP 995.8, PEN 3.440, TRY 49.79, EGP 56.27, NGN 1,360, KES 129.9, ZAR 16.64, SAR 3.75, AED 3.6725, RUB 80.79, UAH 45.53, PLN 3.938, JPY 157.4, KRW 1,325, CNY 6.684, TWD 32.59, HKD 7.845, GBP 0.7492, EUR 0.8939, CAD 1.4016, AUD 1.4246, CHF 0.8271, NOK 9.323, LKR 332.0.
- **Ratio to US** = (local price in USD) / (the same service's US price). The US base for each service is in the USA table. Outside the US, prices include VAT/GST. US prices exclude sales tax. So a ratio of about 1.2 in the UK or EU is roughly "the same pre-tax price".
- **Apple Music / Apple One:** each country's apple.com page (footnote or plan card).
- **Spotify:** spotify.com/{country}/premium. In India, Indonesia, South Africa, Saudi Arabia, UAE and Japan, Spotify now sells Premium **Standard**, not Individual (India and Indonesia also have Platinum). I used Standard there. The regular monthly price is shown, not the intro offer.
- **Netflix:** Netflix's own per-country help article, help.netflix.com/en/node/24926/{cc}, **Standard** plan (ad-free, 1080p, 2 screens). In some markets this is the middle tier: India, Pakistan, Indonesia and others also have Mobile and Basic.
- **App Store apps** (ChatGPT, Google Gemini/AI Pro, Microsoft 365, Notion, Spark, Fantastical, Airmail, Proton Mail, Todoist, Day One, YouTube): the in-app purchase list on each storefront's App Store page, apps.apple.com/{cc}/app/id{ID}. That list is what the developer actually charges in that storefront through Apple. It is the most like-for-like comparison with Corres. I took the cheapest matching monthly SKU, so where a legacy SKU is cheaper than the current one, the price may be the legacy one.
- **YouTube Premium** is the iOS in-app price, compared with the US iOS price ($20.99). Google adds a markup on US iOS (US web price is $15.99 since Apr 2026; https://techcrunch.com/2026/04/10/youtube-premium-youtube-music-subscription-price-increase/). Compared with the US web price, YouTube ratios would be about 1.31x higher.
- **Not used:** Duolingo Super. The App Store page shows only 10 SKUs, and the monthly one often isn't among them (US monthly $12.99 / $9.99). The numbers I could see mix annual and monthly, so I dropped it. **Superhuman** has no in-app purchases on iOS. Its web plans page (https://superhuman.com/plans) shows Pro $15/mo monthly ($12 annual) and Business $40/mo ($33 annual) in "$" with no regional pricing. That page may describe the 2026 Superhuman suite rather than the original mail-only product, so treat it as unverified.
- **Raw data** is in this folder: `iap/` (per storefront and app), `spotify/`, `netflix/`, `applemusic/`, `appleone/`, `raw/steam.html`, `raw/fx.json`, `iap_parsed.json`, `scripts/`.

## 1. Summary: median ratio to the US price, per market

"Streaming" = Apple Music, Apple One, Spotify, YouTube Premium (iOS), Netflix Standard. "Productivity/AI" = the 13 App Store subscriptions listed above. "$20 tier" = ChatGPT Plus, Google AI Pro, Microsoft 365 Premium and Spark Pro. These four cost $19.99–$20 in the US, the same US price as Corres. Spark Pro is a premium iOS/Mac mail app at exactly $20.

| Market | Streaming n | Streaming median | Productivity/AI n | Productivity median | $20-tier median (ChatGPT Plus, Google AI Pro, M365 Premium, Spark Pro) | All-services median | Steam multi-variable rec. for $19.99 | Steam pure-PPP rec. | Adapty monthly index (US=1.00) |
|---|---|---|---|---|---|---|---|---|---|
| USA | 5 | 1.00 | 13 | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 |
| India | 4 | 0.12 | 13 | 1.02 | 1.05 | 0.78 | 0.58 | 0.23 | n/a |
| Pakistan | 4 | 0.11 | 13 | 0.89 | 0.95 | 0.83 | n/a | n/a | 0.53 |
| Indonesia | 5 | 0.27 | 13 | 0.91 | 0.94 | 0.87 | 0.51 | 0.28 | n/a |
| Philippines | 5 | 0.22 | 13 | 0.86 | 0.82 | 0.78 | 0.52 | 0.31 | 0.53 |
| Vietnam | 4 | 0.20 | 13 | 0.97 | 0.97 | 0.95 | 0.53 | 0.27 | 0.60 |
| Thailand | 5 | 0.37 | 13 | 1.03 | 1.07 | 0.98 | 0.53 | 0.29 | n/a |
| Malaysia | 5 | 0.37 | 13 | 1.20 | 1.21 | 1.08 | 0.53 | 0.31 | n/a |
| Brazil | 5 | 0.37 | 13 | 0.94 | 0.97 | 0.92 | 0.59 | 0.43 | 0.46 |
| Mexico | 5 | 0.62 | 13 | 1.07 | 1.07 | 1.00 | 0.71 | 0.51 | 0.80 |
| Argentina | 4 | 0.26 | 13 | 1.00 | 1.00 | 1.00 | n/a | n/a | 0.77 |
| Colombia | 5 | 0.49 | 13 | 1.41 | 1.46 | 1.30 | 0.71 | 0.42 | 0.65 |
| Chile | 5 | 0.42 | 13 | 1.09 | 1.08 | 1.04 | 0.65 | 0.43 | 0.57 |
| Peru | 4 | 0.50 | 13 | 1.12 | 1.13 | 1.07 | 0.64 | 0.52 | 0.63 |
| Turkey | 4 | 0.17 | 12 | 0.69 | 0.72 | 0.59 | n/a | n/a | n/a |
| Egypt | 3 | 0.11 | 13 | 0.62 | 0.86 | 0.56 | n/a | n/a | 0.37 |
| Nigeria | 3 | 0.09 | 13 | 1.04 | 1.07 | 0.68 | n/a | n/a | 0.37 |
| Kenya | 3 | 0.25 | 13 | 1.14 | 1.15 | 1.06 | n/a | n/a | n/a |
| South Africa | 3 | 0.32 | 13 | 1.20 | 1.25 | 1.15 | 0.54 | 0.41 | 0.82 |
| Saudi Arabia | 4 | 0.52 | 13 | 1.15 | 1.17 | 1.15 | 0.71 | 0.47 | 0.78 |
| UAE | 4 | 0.53 | 13 | 1.02 | 1.07 | 1.02 | 0.93 | 0.63 | 1.05 |
| Russia | 1 | 0.15 | 4 | 0.88 | n/a | 0.87 | 0.55 | 0.34 | n/a |
| Ukraine | 3 | 0.38 | 13 | 1.11 | 1.18 | 1.00 | 0.52 | 0.30 | 0.77 |
| Poland | 5 | 0.53 | 13 | 1.27 | 1.26 | 1.18 | 1.03 | 0.49 | 0.84 |
| Japan | 5 | 0.51 | 12 | 0.95 | 0.95 | 0.91 | 0.89 | 0.65 | 0.43 |
| South Korea | 5 | 0.56 | 12 | 1.08 | 1.09 | 1.04 | 0.85 | 0.64 | n/a |
| China mainland | 2 | 0.32 | 9 | 1.03 | 1.11 | 1.03 | 0.52 | 0.49 | 0.94 |
| Taiwan | 5 | 0.42 | 13 | 1.00 | 1.04 | 0.97 | 0.53 | 0.43 | 0.89 |
| Hong Kong | 4 | 0.73 | 11 | 1.00 | 1.01 | 0.95 | 0.67 | 0.70 | 0.97 |
| UK | 5 | 1.15 | 13 | 1.33 | 1.30 | 1.33 | 1.07 | 0.89 | 1.21 |
| Germany (eurozone) | 5 | 1.07 | 13 | 1.21 | 1.23 | 1.12 | 1.09 | 0.84 | 1.09 |
| Canada | 5 | 0.71 | 13 | 0.89 | 0.93 | 0.89 | 0.89 | 0.82 | 1.00 |
| Australia | 5 | 0.80 | 13 | 1.14 | 1.11 | 1.05 | 0.99 | 0.90 | 1.03 |
| Switzerland | 5 | 1.39 | 13 | 1.21 | 1.21 | 1.21 | 1.21 | 1.09 | 1.11 |
| Norway | 5 | 1.12 | 13 | 1.33 | 1.36 | 1.32 | 1.13 | 0.94 | 1.06 |
| Sri Lanka | 3 | 0.19 | 13 | 1.00 | 1.00 | 1.00 | n/a | n/a | n/a |
| Nepal | 3 | 0.25 | 13 | 1.00 | 1.00 | 1.00 | n/a | n/a | n/a |

Reading the table: "n" is how many services I could verify in that market. "Steam multi-variable" is Valve's recommended price for a $19.99 item in that currency, dated 2026-10-08. "Steam pure-PPP" is Valve's purchasing-power-only conversion. The Adapty index is the transaction-weighted median of what users actually paid for **monthly** App Store subscriptions in 2024–2025 (US = 1.00). It is read off a chart in the PDF, so treat it as ±1 point. "n/a" means no data for that market.

## 2. What the benchmarks show

1. **Two separate pricing systems.** Consumer media (music, video) is priced by purchasing power: about 0.1–0.4 of US in South and Southeast Asia, Africa and Turkey, 0.4–0.6 in Latin America and the Gulf, and 1.0–1.4 in Western Europe. Productivity and AI apps sold through the App Store mostly are **not** discounted. Their median is about 0.85–1.2 of US in most markets. It is lower in Turkey (0.69) and Egypt (0.62), and higher in Colombia (1.41) and Poland (1.27).
2. **The $20-tier peers price at or near Apple's exchange-rate equalization.** ChatGPT Plus, Google AI Pro, Microsoft 365 Premium and Spark Pro have a median of 0.82–1.25 in every emerging market except Turkey (0.72) and Colombia (1.46). **Corres's current equalized prices match them exactly**:
   - India: ₹1,999, the same as ChatGPT Plus, M365 Premium and Spark Pro (Google AI Pro is ₹1,950).
   - Pakistan: Rs 4,900, the same as ChatGPT Plus and Spark Pro.
   - Brazil: R$129.90, the same as Spark Pro (ChatGPT Plus is R$99.90, Google AI Pro R$96.90, M365 Premium R$109.90).
   - Turkey: ₺999.99, the same as ChatGPT Plus (Google AI Pro is ₺539.99 = 0.54, M365 Premium ₺719.99 = 0.72).
   - Egypt: EGP 999.99, the same as ChatGPT Plus and Spark Pro (M365 Premium is EGP 699 = 0.62).
   So "crazy numbers" like ₹1,999 are today's norm for $20 productivity and AI subscriptions. Spotify and Netflix are not that norm.
3. **Where the big AI companies do discount, they use a cheaper product, not a cheaper price.** ChatGPT Go ($8 in the US) is 0.52–0.64 of its US price in India, Indonesia, the Philippines, Vietnam, Pakistan, Turkey, Egypt, Nigeria and Sri Lanka. Plus stays near 1.0 in the same markets. Spotify (Standard vs Platinum) and Netflix (Mobile/Basic tiers) do the same thing.
4. **Mid-size productivity apps are "low" only where the currency collapsed.** Spark Premium, Fantastical, Airmail and Day One sit near 1.0 almost everywhere. Spark Premium is ₺184.99 / EGP 149.99 / ₦3,700 (0.33–0.47) and Fantastical ₺179.99 / EGP 179.99 / ₦3,200 (0.34–0.52). *Inference, not confirmed:* these look like old equalized prices that were never raised after the TRY, EGP and NGN devaluations, not a deliberate PPP choice. Apple does not update subscription prices for FX (see section 4).
5. **Deliberate PPP among the productivity apps is moderate.** Proton Mail Plus is 0.50–0.80 in most emerging markets (India 0.58, Brazil 0.58, Indonesia 0.54, Turkey 0.50, Egypt 0.55). Todoist Pro is selective (India 0.50, Brazil 0.66, Mexico 0.61, South Africa 0.69, but Pakistan, the Philippines and Vietnam about 1.0). Microsoft 365 Personal is 0.43–0.85 in emerging markets.
6. **Colombia and Poland look expensive at today's FX** (productivity medians 1.41 and 1.27). Colombia's App Store prices include 19% VAT and were set when the peso was weaker (COP is 3,155/USD today). Poland includes 23% VAT. *Inference:* old equalized prices plus VAT, not a deliberate premium.
7. **USD storefronts.** Argentina, Kenya, Ukraine, Sri Lanka and Nepal show App Store prices in **USD**, not local currency. Most apps charge the US price there unchanged (ratio 1.00). A few charge more: ChatGPT Plus is $22.99 in Kenya and Ukraine, and Spark Pro is $25 in Kenya, Ukraine and Nepal. Media services that bill in USD there still discount heavily: Spotify Ukraine US$4.99 and Nepal US$3.29, Netflix Sri Lanka and Nepal US$7.99, and Apple Music Argentina US$3.29. Netflix bills Ukraine in EUR (€7.49).
8. **Russia and China.** Most of the benchmark apps are not available in the Russian storefront: ChatGPT, Notion, Spark, M365, Gemini and Airmail pages returned nothing. Background, not verified here: Apple has not accepted card or Apple Pay payments in Russia since 2022. China has no ChatGPT, Google One or Gemini on the App Store. Where Chinese prices exist, productivity apps are about 1.0–1.1 (M365 Personal ¥38 = 0.57). Spotify and Netflix are not available in either country.

## 3. Published guidance on purchasing-power pricing

**Apple** (App Store Connect Help, "Manage pricing for auto-renewable subscriptions", https://developer.apple.com/help/app-store-connect/manage-subscriptions/manage-pricing-for-auto-renewable-subscriptions)
- Apple gives you "comparable prices for all 175 App Store countries and regions, taking into account taxes and foreign exchange rates", and you may override any storefront. This is exchange-rate equalization, not PPP.
- "Apple will not make price adjustments on your auto-renewable subscription products. Retail price changes initiated by Apple due to tax changes and significant foreign exchange rate movements will exclude auto-renewable subscriptions." Equalized subscription prices are a snapshot taken when you set them, and they drift as currencies move. Apps, one-time in-app purchases and non-base storefronts do get automatic FX/tax updates (WWDC23 "What's new in App Store pricing", https://wwdcnotes.com/documentation/wwdc23-10014-whats-new-in-app-store-pricing/), but subscriptions are excluded.
- Apple gives no PPP formula or recommendation.

**Valve / Steam** (the most transparent published recommendation engine; https://partner.steamgames.com/doc/store/pricing and the public explorer at https://partner.steamgames.com/pricing/explorer, data dated 2026-10-08)
- It offers three conversions: exchange-rate only, purchasing-power only, and a default **multi-variable** method ("local purchasing power, the expected cost of comparable entertainment goods, and exchange rate").
- At $19.99, the multi-variable price is never below **0.51 of US** in any currency, so it has an effective floor of about 50%. It is roughly the **square root of Valve's own PPP ratio**: fitting ratio_multi = ratio_PPP^k gives a median k ≈ 0.50–0.54 across the $9.99, $19.99 and $49.99 tiers. Examples for $19.99:
  - India ₹1,099 (0.58; pure PPP ₹439 = 0.23)
  - Brazil R$63.99 (0.59; PPP 0.43)
  - Indonesia Rp185,999 (0.51)
  - Philippines ₱659 (0.52)
  - Mexico MX$264.99 (0.71)
  - Japan ¥2,800 (0.89)
  - UK £15.99 (1.07)
  - Switzerland CHF 19.99 (1.21)
- Steam's USD-priced regions (South Asia, LATAM, CIS and MENA, which cover Pakistan, Argentina, Turkey and Egypt) get $10.49 or $12.49 at the $19.99 tier (0.52–0.62). The page data doesn't say which region gets $12.49.
- These are recommendations for games, a discretionary entertainment purchase. They are a good model for "dampened PPP with a ~50% floor".

**Adapty Pricing Index** (https://uploads.adapty.io/adapty_pricing_index.pdf; anonymized App Store subscription transactions, 11,000+ apps, $1.9B revenue, full-year 2024–2025, transaction-weighted medians, gross prices including VAT and Apple's commission)
- Monthly plans run from +62% (Netherlands) to −63% (Nigeria, Egypt) versus the US. Japan is −57%. The Philippines and Pakistan are −47%. Brazil is −54%.
- Annual plans "stay pretty stable": most countries are at 75–110% of the US, except Nigeria and Egypt at about −70%.
- Its advice: weigh market presence, conversion signals ("low conversion rates might mean your price is too high"), product-market fit and local competitors. It also says: "Don't blindly trust Apple or Google's suggested local prices."
- Caveat: these are medians across all apps and categories, so cheaper apps in poorer markets pull them down. They describe what people pay, not what is optimal.

**RevenueCat blog**, "5 quick fixes for bad default global pricing on app stores" (29 Aug 2025, by Demian Voorhagen, founder of the pricing tool Mirava; https://www.revenuecat.com/blog/growth/5-quick-fixes-for-bad-default-global-pricing-on-app-stores)
- "Purchasing Power Parity (PPP) is your friend." It suggests cutting prices in Southeast Asia, Latin America and parts of Eastern Europe, citing cuts of 70% in India and 60% in the Philippines.
- Round to local-looking endings (₱199, ₹349, R$49), check local competitors, and start with your top 3 regions outside your home market.
- Results are anecdotal and come from a vendor: a meditation app "doubled subscriptions in LatAm in 14 days", a wellness tracker got +38% conversion in Southeast Asia, and a 60% cut produced "3x more paying users". There are no sample sizes and no revenue-per-user data.
- RevenueCat's State of Subscription Apps report (https://www.revenuecat.com/state-of-subscription-apps-2025) is gated. I could **not** confirm the "15–40% conversion lift from PPP" or the "60-day revenue per install $0.55 North America vs $0.11 India/SEA" figures that third-party blogs (appsops.store, a vendor) attribute to it. **Unverified.**

**Superwall** (https://superwall.com/solutions/localization-international-pricing): tooling for region-specific paywalls and price tests with holdout groups. It publishes no ratios. Its only "evidence" is an unquantified testimonial.

**Phiture:** I found no published PPP pricing guidance or case study.

**No vendor publishes a formula.** No source I found gives a concrete dampened-PPP formula or floor, other than what Steam's data implies. A defensible synthesis would be: target ratio = max(floor, PLI^k), where PLI is your World Bank price-level ratio. Steam's behaviour suggests k ≈ 0.5 and a floor of about 0.5. The live $20-tier peers suggest a premium productivity app can sit much higher than Steam (about 0.8–1.0) in most emerging markets without being an outlier. This is my synthesis, not a published recommendation.

**Evidence on conversion and revenue effects:** All of it is vendor-reported and anecdotal (RevenueCat/Mirava, Superwall, PricePush). None of it is independent or peer-reviewed. Adapty's annual-plan finding (75–110% of US in most countries) suggests annual buyers are less price-sensitive than monthly buyers. That supports discounting the monthly plan more than the annual one in emerging markets, or making the annual plan the main emerging-market offer.

## 4. Apple constraints

- **Price grid.** You get 800 price points per currency by default, and the Account Holder can request more higher points (ASC Help). WWDC23 calls it 900 in total (800 + 100 on request). In USD the range is **$0.29 to $10,000**, with the top on request. Steps are $0.10 up to $9.99, $0.50 from $10 to $49.99, $1 from $50 to $199.99, $5 from $200 to $499.99, $10 from $500 to $999.99, and $100 from $1,000 to $9,999.99. Prices may end in .00, .90 or .95 as well as .99. Sources: https://www.revenuecat.com/blog/growth/app-store-pricing-system-november-changes and https://www.apple.com/newsroom/2022/12/apple-announces-biggest-upgrade-to-app-store-pricing-adding-700-new-price-points/.
- **Per-territory minimum and maximum.** I could not find a public per-territory table. Each currency's grid is a locally rounded version of the USD grid, so the minimum is the local equivalent of about $0.29 and the maximum about $10k. **The authoritative source is the App Store Connect API:** `GET /v1/subscriptions/{id}/pricePoints?filter[territory]=IND` lists every point with `customerPrice` and `proceeds` (https://developer.apple.com/documentation/appstoreconnectapi/get-v1-subscriptions-_id_-pricepoints), and `/v1/subscriptionPricePoints/{id}/equalizations` gives the equivalents in other territories. That is how to get the exact INR, PKR and other steps before choosing prices. The existing `asc-listing.mjs` tooling could do this.
- **India's steps.** I found no official INR list. Live INR subscription prices I saw on 2026-10-27 include ₹139, ₹195, ₹199, ₹329, **₹330**, ₹399, ₹669, ₹689, ₹699, ₹769, ₹1,199, **₹1,950**, ₹1,999, ₹4,099, **₹5,800**, ₹10,699 and **₹19,900**. So INR points are fine-grained (both ₹329 and ₹330 exist, as do ₹1,950 and ₹1,999) and round endings are allowed. A third-party claim that INR prices must end in 9 or 99 (pricepush.app) is contradicted by these live prices.
- **USD storefronts.** Argentina, Kenya, Ukraine, Sri Lanka and Nepal show USD on the App Store, so they use the USD grid: $0.10 steps under $10, then $0.50 steps.
- **Lowering a price for existing subscribers is automatic.** "If you decrease the price of your auto-renewable subscription, existing subscriptions will automatically renew at the lower price. You don't have the option to preserve the higher price for existing subscribers." Once a decrease takes effect it can't be reversed, but you can schedule an increase later.
- **Increases.** You choose either to keep the current price for existing subscribers (lapsed subscribers can come back at the kept price within 60 days) or to apply the increase to them. Apple asks for **consent** when any of these apply:
  - the region requires consent for any price change;
  - the increase is more than 50% **and** more than about US$5 per period (non-annual) or US$50 per year (annual);
  - the subscriber had another increase in the past 12 months.
  Otherwise Apple notifies subscribers about 27 days before renewal.
- **Scheduling.** You can have one future change at a time per storefront per billing plan type; a new one overwrites the old. The earliest start is generally 1–2 days ahead.
- **FX drift.** Apple never updates subscription prices for FX or tax (quoted above), so every regional price you set needs a periodic review.
- **Subscriptions not yet approved.** Apple's subscription pricing help page says nothing specific about this. What I could confirm: through the API, a price whose `startDate` is null "goes live immediately in that region", and Apple's WWDC23 session recommends testing price setup with an app not yet on the App Store. While Corres has no live subscribers, the rules about existing subscribers (preserve, consent, 27-day notice) affect nobody. *Unverified:* that App Store Connect lets you overwrite the starting price per territory freely before the first approval. This matches common developer experience, but I could not find it in Apple's documentation, so check in App Store Connect. **There is an asymmetry to plan for:** after launch, a decrease is instant and automatic for everyone, but an increase of more than 50% and more than about $5 needs subscriber consent. Prices set too low at launch are harder to fix than prices set a little high.
- **Russia (not verified here):** App Store payments for Russian accounts have been largely unavailable since 2022. Most of the peer apps are absent from the Russian storefront.

## 5. Gaps (not verified, not guessed)

- **Apple Music:** no price for Egypt, Nigeria, Kenya, South Africa, Russia, Ukraine, Sri Lanka or Nepal. The apple.com pages either redirect or have no price. Pakistan Rs 379 comes from a third-party news report (propakistani.pk, Aug 2026), not Apple.
- **Apple One:** the India page redirects to iCloud. It may no longer be sold there, but this is unconfirmed. There is no data for Pakistan, Vietnam, Turkey, Egypt, Nigeria, Kenya, South Africa, Saudi Arabia, UAE, Russia, Ukraine, Hong Kong, China, Argentina, Peru, Sri Lanka or Nepal. Apple's Latin America page shows a generic "USD 12.95" Individual price. I did not use it for Argentina or Peru because the page says prices vary by country.
- **Not available:** Spotify in China and Russia. Netflix in China and Russia. ChatGPT in China and Hong Kong. Google AI Pro in China. ChatGPT, Notion, Spark, M365, Gemini and Airmail in Russia. Spark Pro in Turkey (no Pro SKU among the 10 listed).
- **YouTube Premium:** there are App Store prices for China (¥68) and Russia (249 ₽), even though YouTube is blocked in mainland China. These prices may not be purchasable, so treat them as unverified.
- **App Store page limit:** each page shows at most 10 in-app purchases, so a few minimums may be a legacy SKU or miss the current monthly SKU.
- **Duolingo Super:** excluded (unreliable monthly SKU, see above).
- **Superhuman:** iOS has no regional or App Store pricing. The web price is USD only.

## 6. Per-market tables

### USA (`us`)

| Service | Local monthly price | USD | Ratio to US | Source |
|---|---|---|---|---|
| Apple Music | $11.99 | 11.99 | 1.00 | https://www.apple.com/apple-music/ |
| Apple One | $21.95 | 21.95 | 1.00 | https://www.apple.com/apple-one/ |
| Spotify Premium | $12.99 | 12.99 | 1.00 | https://www.spotify.com/us/premium/ |
| Netflix Standard | $19.99 | 19.99 | 1.00 | https://help.netflix.com/en/node/24926/us |
| YouTube Premium (iOS IAP) | $20.99 | 20.99 | 1.00 | https://apps.apple.com/us/app/id544007664 |
| ChatGPT Plus (mo) | $19.99 | 19.99 | 1.00 | https://apps.apple.com/us/app/id6448311069 |
| ChatGPT Go (mo) | $8.00 | 8.00 | 1.00 | https://apps.apple.com/us/app/id6448311069 |
| Google AI Pro (mo) | $19.99 | 19.99 | 1.00 | https://apps.apple.com/us/app/id6477489729 |
| M365 Personal (mo) | $9.99 | 9.99 | 1.00 | https://apps.apple.com/us/app/id541164041 |
| M365 Premium (mo) | $19.99 | 19.99 | 1.00 | https://apps.apple.com/us/app/id541164041 |
| Notion Plus (mo) | $11.99 | 11.99 | 1.00 | https://apps.apple.com/us/app/id1232780281 |
| Spark Premium (mo) | $7.99 | 7.99 | 1.00 | https://apps.apple.com/us/app/id997102246 |
| Spark Pro (mo) | $20.00 | 20.00 | 1.00 | https://apps.apple.com/us/app/id997102246 |
| Fantastical Premium (mo) | $6.99 | 6.99 | 1.00 | https://apps.apple.com/us/app/id718043190 |
| Airmail Pro (mo) | $3.99 | 3.99 | 1.00 | https://apps.apple.com/us/app/id993160329 |
| Proton Mail Plus (mo) | $5.99 | 5.99 | 1.00 | https://apps.apple.com/us/app/id979659905 |
| Todoist Pro (mo) | $6.99 | 6.99 | 1.00 | https://apps.apple.com/us/app/id572688855 |
| Day One Silver (mo) | $8.99 | 8.99 | 1.00 | https://apps.apple.com/us/app/id1044867788 |
| (reference) Steam multi-variable recommendation for a $19.99 item | 19.99 USD | 19.99 | 1.00 | https://partner.steamgames.com/pricing/explorer |

### India (`in`)

| Service | Local monthly price | USD | Ratio to US | Source |
|---|---|---|---|---|
| Apple Music | ₹139 | 1.46 | 0.12 | https://www.apple.com/in/apple-music/ |
| Spotify Premium | ₹139 (Premium Standard) | 1.46 | 0.11 | https://www.spotify.com/in-en/premium/ |
| Netflix Standard | ₹499 | 5.24 | 0.26 | https://help.netflix.com/en/node/24926/in |
| YouTube Premium (iOS IAP) | ₹ 195 | 2.05 | 0.10 | https://apps.apple.com/in/app/id544007664 |
| ChatGPT Plus (mo) | ₹ 1,999 | 20.98 | 1.05 | https://apps.apple.com/in/app/id6448311069 |
| ChatGPT Go (mo) | ₹ 399 | 4.19 | 0.52 | https://apps.apple.com/in/app/id6448311069 |
| Google AI Pro (mo) | ₹ 1,950 | 20.47 | 1.02 | https://apps.apple.com/in/app/id6477489729 |
| M365 Personal (mo) | ₹ 689 | 7.23 | 0.72 | https://apps.apple.com/in/app/id541164041 |
| M365 Premium (mo) | ₹ 1,999 | 20.98 | 1.05 | https://apps.apple.com/in/app/id541164041 |
| Notion Plus (mo) | ₹ 1,199 | 12.59 | 1.05 | https://apps.apple.com/in/app/id1232780281 |
| Spark Premium (mo) | ₹ 769 | 8.07 | 1.01 | https://apps.apple.com/in/app/id997102246 |
| Spark Pro (mo) | ₹ 1,999 | 20.98 | 1.05 | https://apps.apple.com/in/app/id997102246 |
| Fantastical Premium (mo) | ₹ 699 | 7.34 | 1.05 | https://apps.apple.com/in/app/id718043190 |
| Airmail Pro (mo) | ₹ 399 | 4.19 | 1.05 | https://apps.apple.com/in/app/id993160329 |
| Proton Mail Plus (mo) | ₹ 329 | 3.45 | 0.58 | https://apps.apple.com/in/app/id979659905 |
| Todoist Pro (mo) | ₹ 330 | 3.46 | 0.50 | https://apps.apple.com/in/app/id572688855 |
| Day One Silver (mo) | ₹ 669 | 7.02 | 0.78 | https://apps.apple.com/in/app/id1044867788 |
| (reference) Steam multi-variable recommendation for a $19.99 item | 1,099.00 INR | 11.54 | 0.58 | https://partner.steamgames.com/pricing/explorer |

### Pakistan (`pk`)

| Service | Local monthly price | USD | Ratio to US | Source |
|---|---|---|---|---|
| Apple Music | Rs 379 | 1.37 | 0.11 | https://propakistani.pk/2026/08/12/apple-music-to-officially-launch-in-pakistan-soon/ |
| Spotify Premium | Rs 379 | 1.37 | 0.11 | https://www.spotify.com/pk-en/premium/ |
| Netflix Standard | Rs 800 | 2.89 | 0.14 | https://help.netflix.com/en/node/24926/pk |
| YouTube Premium (iOS IAP) | Rs 649.00 | 2.34 | 0.11 | https://apps.apple.com/pk/app/id544007664 |
| ChatGPT Plus (mo) | Rs 4,900.00 | 17.70 | 0.89 | https://apps.apple.com/pk/app/id6448311069 |
| ChatGPT Go (mo) | Rs 1,400.00 | 5.06 | 0.63 | https://apps.apple.com/pk/app/id6448311069 |
| Google AI Pro (mo) | Rs 5,600.00 | 20.23 | 1.01 | https://apps.apple.com/pk/app/id6477489729 |
| M365 Personal (mo) | Rs 2,299.00 | 8.31 | 0.83 | https://apps.apple.com/pk/app/id541164041 |
| M365 Premium (mo) | Rs 5,599.00 | 20.23 | 1.01 | https://apps.apple.com/pk/app/id541164041 |
| Notion Plus (mo) | Rs 3,500.00 | 12.64 | 1.05 | https://apps.apple.com/pk/app/id1232780281 |
| Spark Premium (mo) | Rs 1,750.00 | 6.32 | 0.79 | https://apps.apple.com/pk/app/id997102246 |
| Spark Pro (mo) | Rs 4,900.00 | 17.70 | 0.89 | https://apps.apple.com/pk/app/id997102246 |
| Fantastical Premium (mo) | Rs 1,500.00 | 5.42 | 0.78 | https://apps.apple.com/pk/app/id718043190 |
| Airmail Pro (mo) | Rs 1,100.00 | 3.97 | 1.00 | https://apps.apple.com/pk/app/id993160329 |
| Proton Mail Plus (mo) | Rs 1,149.00 | 4.15 | 0.69 | https://apps.apple.com/pk/app/id979659905 |
| Todoist Pro (mo) | Rs 1,900.00 | 6.86 | 0.98 | https://apps.apple.com/pk/app/id572688855 |
| Day One Silver (mo) | Rs 2,500.00 | 9.03 | 1.00 | https://apps.apple.com/pk/app/id1044867788 |

### Indonesia (`id`)

| Service | Local monthly price | USD | Ratio to US | Source |
|---|---|---|---|---|
| Apple Music | Rp 59.000 | 3.25 | 0.27 | https://www.apple.com/id/apple-music/ |
| Apple One | Rp 149.000 | 8.21 | 0.37 | https://www.apple.com/id/apple-one/ |
| Spotify Premium | Rp 59.900 (Premium Standard) | 3.30 | 0.25 | https://www.spotify.com/id-en/premium/ |
| Netflix Standard | IDR 120,000 | 6.61 | 0.33 | https://help.netflix.com/en/node/24926/id |
| YouTube Premium (iOS IAP) | Rp 89ribu | 4.90 | 0.23 | https://apps.apple.com/id/app/id544007664 |
| ChatGPT Plus (mo) | Rp 349ribu | 19.23 | 0.96 | https://apps.apple.com/id/app/id6448311069 |
| ChatGPT Go (mo) | Rp 75ribu | 4.13 | 0.52 | https://apps.apple.com/id/app/id6448311069 |
| Google AI Pro (mo) | Rp 309ribu | 17.03 | 0.85 | https://apps.apple.com/id/app/id6477489729 |
| M365 Personal (mo) | Rp 136ribu | 7.49 | 0.75 | https://apps.apple.com/id/app/id541164041 |
| M365 Premium (mo) | Rp 330ribu | 18.18 | 0.91 | https://apps.apple.com/id/app/id541164041 |
| Notion Plus (mo) | Rp 199ribu | 10.96 | 0.91 | https://apps.apple.com/id/app/id1232780281 |
| Spark Premium (mo) | Rp 129ribu | 7.11 | 0.89 | https://apps.apple.com/id/app/id997102246 |
| Spark Pro (mo) | Rp 349ribu | 19.23 | 0.96 | https://apps.apple.com/id/app/id997102246 |
| Fantastical Premium (mo) | Rp 129ribu | 7.11 | 1.02 | https://apps.apple.com/id/app/id718043190 |
| Airmail Pro (mo) | Rp 69ribu | 3.80 | 0.95 | https://apps.apple.com/id/app/id993160329 |
| Proton Mail Plus (mo) | Rp 59ribu | 3.25 | 0.54 | https://apps.apple.com/id/app/id979659905 |
| Todoist Pro (mo) | Rp 119ribu | 6.56 | 0.94 | https://apps.apple.com/id/app/id572688855 |
| Day One Silver (mo) | Rp 149ribu | 8.21 | 0.91 | https://apps.apple.com/id/app/id1044867788 |
| (reference) Steam multi-variable recommendation for a $19.99 item | 185,999.00 IDR | 10.25 | 0.51 | https://partner.steamgames.com/pricing/explorer |

### Philippines (`ph`)

| Service | Local monthly price | USD | Ratio to US | Source |
|---|---|---|---|---|
| Apple Music | ₱169 | 2.64 | 0.22 | https://www.apple.com/ph/apple-music/ |
| Apple One | ₱499 | 7.80 | 0.36 | https://www.apple.com/ph/apple-one/ |
| Spotify Premium | ₱169 | 2.64 | 0.20 | https://www.spotify.com/ph-en/premium/ |
| Netflix Standard | PHP 449 | 7.02 | 0.35 | https://help.netflix.com/en/node/24926/ph |
| YouTube Premium (iOS IAP) | ₱ 249.00 | 3.89 | 0.19 | https://apps.apple.com/ph/app/id544007664 |
| ChatGPT Plus (mo) | ₱ 999.00 | 15.62 | 0.78 | https://apps.apple.com/ph/app/id6448311069 |
| ChatGPT Go (mo) | ₱ 300.00 | 4.69 | 0.59 | https://apps.apple.com/ph/app/id6448311069 |
| Google AI Pro (mo) | ₱ 1,100.00 | 17.20 | 0.86 | https://apps.apple.com/ph/app/id6477489729 |
| M365 Personal (mo) | ₱ 369.00 | 5.77 | 0.58 | https://apps.apple.com/ph/app/id541164041 |
| M365 Premium (mo) | ₱ 1,090.00 | 17.04 | 0.85 | https://apps.apple.com/ph/app/id541164041 |
| Notion Plus (mo) | ₱ 699.00 | 10.93 | 0.91 | https://apps.apple.com/ph/app/id1232780281 |
| Spark Premium (mo) | ₱ 449.00 | 7.02 | 0.88 | https://apps.apple.com/ph/app/id997102246 |
| Spark Pro (mo) | ₱ 999.00 | 15.62 | 0.78 | https://apps.apple.com/ph/app/id997102246 |
| Fantastical Premium (mo) | ₱ 399.00 | 6.24 | 0.89 | https://apps.apple.com/ph/app/id718043190 |
| Airmail Pro (mo) | ₱ 249.00 | 3.89 | 0.98 | https://apps.apple.com/ph/app/id993160329 |
| Proton Mail Plus (mo) | ₱ 229.00 | 3.58 | 0.60 | https://apps.apple.com/ph/app/id979659905 |
| Todoist Pro (mo) | ₱ 449.00 | 7.02 | 1.00 | https://apps.apple.com/ph/app/id572688855 |
| Day One Silver (mo) | ₱ 599.00 | 9.37 | 1.04 | https://apps.apple.com/ph/app/id1044867788 |
| (reference) Steam multi-variable recommendation for a $19.99 item | 659.00 PHP | 10.30 | 0.52 | https://partner.steamgames.com/pricing/explorer |

### Vietnam (`vn`)

| Service | Local monthly price | USD | Ratio to US | Source |
|---|---|---|---|---|
| Apple Music | 65.000đ | 2.52 | 0.21 | https://www.apple.com/vn/apple-music/ |
| Spotify Premium | ₫65,000 | 2.52 | 0.19 | https://www.spotify.com/vn-en/premium/ |
| Netflix Standard | VND 231,000 | 8.94 | 0.45 | https://help.netflix.com/en/node/24926/vn |
| YouTube Premium (iOS IAP) | 105.000đ | 4.06 | 0.19 | https://apps.apple.com/vn/app/id544007664 |
| ChatGPT Plus (mo) | 499.000đ | 19.32 | 0.97 | https://apps.apple.com/vn/app/id6448311069 |
| ChatGPT Go (mo) | 132.000đ | 5.11 | 0.64 | https://apps.apple.com/vn/app/id6448311069 |
| Google AI Pro (mo) | 489.000đ | 18.93 | 0.95 | https://apps.apple.com/vn/app/id6477489729 |
| M365 Personal (mo) | 159.000đ | 6.16 | 0.62 | https://apps.apple.com/vn/app/id541164041 |
| M365 Premium (mo) | 510.000đ | 19.74 | 0.99 | https://apps.apple.com/vn/app/id541164041 |
| Notion Plus (mo) | 299.000đ | 11.57 | 0.97 | https://apps.apple.com/vn/app/id1232780281 |
| Spark Premium (mo) | 189.000đ | 7.32 | 0.92 | https://apps.apple.com/vn/app/id997102246 |
| Spark Pro (mo) | 499.000đ | 19.32 | 0.97 | https://apps.apple.com/vn/app/id997102246 |
| Fantastical Premium (mo) | 199.000đ | 7.70 | 1.10 | https://apps.apple.com/vn/app/id718043190 |
| Airmail Pro (mo) | 119.000đ | 4.61 | 1.15 | https://apps.apple.com/vn/app/id993160329 |
| Proton Mail Plus (mo) | 98.000đ | 3.79 | 0.63 | https://apps.apple.com/vn/app/id979659905 |
| Todoist Pro (mo) | 199.000đ | 7.70 | 1.10 | https://apps.apple.com/vn/app/id572688855 |
| Day One Silver (mo) | 299.000đ | 11.57 | 1.29 | https://apps.apple.com/vn/app/id1044867788 |
| (reference) Steam multi-variable recommendation for a $19.99 item | 275,000.00 VND | 10.65 | 0.53 | https://partner.steamgames.com/pricing/explorer |

### Thailand (`th`)

| Service | Local monthly price | USD | Ratio to US | Source |
|---|---|---|---|---|
| Apple Music | ฿149 | 4.41 | 0.37 | https://www.apple.com/th/apple-music/ |
| Apple One | ฿369 | 10.92 | 0.50 | https://www.apple.com/th/apple-one/ |
| Spotify Premium | THB 149 | 4.41 | 0.34 | https://www.spotify.com/th-en/premium/ |
| Netflix Standard | THB 349 | 10.33 | 0.52 | https://help.netflix.com/en/node/24926/th |
| YouTube Premium (iOS IAP) | ฿259.00 | 7.67 | 0.37 | https://apps.apple.com/th/app/id544007664 |
| ChatGPT Plus (mo) | ฿699.00 | 20.69 | 1.03 | https://apps.apple.com/th/app/id6448311069 |
| ChatGPT Go (mo) | ฿259.00 | 7.67 | 0.96 | https://apps.apple.com/th/app/id6448311069 |
| Google AI Pro (mo) | ฿750.00 | 22.20 | 1.11 | https://apps.apple.com/th/app/id6477489729 |
| M365 Personal (mo) | ฿299.00 | 8.85 | 0.89 | https://apps.apple.com/th/app/id541164041 |
| M365 Premium (mo) | ฿749.00 | 22.17 | 1.11 | https://apps.apple.com/th/app/id541164041 |
| Notion Plus (mo) | ฿399.00 | 11.81 | 0.98 | https://apps.apple.com/th/app/id1232780281 |
| Spark Premium (mo) | ฿319.00 | 9.44 | 1.18 | https://apps.apple.com/th/app/id997102246 |
| Spark Pro (mo) | ฿699.00 | 20.69 | 1.03 | https://apps.apple.com/th/app/id997102246 |
| Fantastical Premium (mo) | ฿249.00 | 7.37 | 1.05 | https://apps.apple.com/th/app/id718043190 |
| Airmail Pro (mo) | ฿149.00 | 4.41 | 1.11 | https://apps.apple.com/th/app/id993160329 |
| Proton Mail Plus (mo) | ฿150.00 | 4.44 | 0.74 | https://apps.apple.com/th/app/id979659905 |
| Todoist Pro (mo) | ฿249.00 | 7.37 | 1.05 | https://apps.apple.com/th/app/id572688855 |
| Day One Silver (mo) | ฿299.00 | 8.85 | 0.98 | https://apps.apple.com/th/app/id1044867788 |
| (reference) Steam multi-variable recommendation for a $19.99 item | 359.00 THB | 10.63 | 0.53 | https://partner.steamgames.com/pricing/explorer |

### Malaysia (`my`)

| Service | Local monthly price | USD | Ratio to US | Source |
|---|---|---|---|---|
| Apple Music | RM 17.90 | 4.38 | 0.37 | https://www.apple.com/my/apple-music/ |
| Apple One | RM 34.90 | 8.54 | 0.39 | https://www.apple.com/my/apple-one/ |
| Spotify Premium | RM 17.50 | 4.28 | 0.33 | https://www.spotify.com/my-en/premium/ |
| Netflix Standard | MYR 55.90 | 13.68 | 0.68 | https://help.netflix.com/en/node/24926/my |
| YouTube Premium (iOS IAP) | RM26.90 | 6.58 | 0.31 | https://apps.apple.com/my/app/id544007664 |
| ChatGPT Plus (mo) | RM99.90 | 24.44 | 1.22 | https://apps.apple.com/my/app/id6448311069 |
| ChatGPT Go (mo) | RM23.99 | 5.87 | 0.73 | https://apps.apple.com/my/app/id6448311069 |
| Google AI Pro (mo) | RM97.90 | 23.95 | 1.20 | https://apps.apple.com/my/app/id6477489729 |
| M365 Personal (mo) | RM43.99 | 10.76 | 1.08 | https://apps.apple.com/my/app/id541164041 |
| M365 Premium (mo) | RM97.90 | 23.95 | 1.20 | https://apps.apple.com/my/app/id541164041 |
| Notion Plus (mo) | RM59.90 | 14.66 | 1.22 | https://apps.apple.com/my/app/id1232780281 |
| Spark Premium (mo) | RM37.90 | 9.27 | 1.16 | https://apps.apple.com/my/app/id997102246 |
| Spark Pro (mo) | RM99.90 | 24.44 | 1.22 | https://apps.apple.com/my/app/id997102246 |
| Fantastical Premium (mo) | RM34.90 | 8.54 | 1.22 | https://apps.apple.com/my/app/id718043190 |
| Airmail Pro (mo) | RM19.90 | 4.87 | 1.22 | https://apps.apple.com/my/app/id993160329 |
| Proton Mail Plus (mo) | RM18.50 | 4.53 | 0.76 | https://apps.apple.com/my/app/id979659905 |
| Todoist Pro (mo) | RM29.90 | 7.32 | 1.05 | https://apps.apple.com/my/app/id572688855 |
| Day One Silver (mo) | RM39.90 | 9.76 | 1.09 | https://apps.apple.com/my/app/id1044867788 |
| (reference) Steam multi-variable recommendation for a $19.99 item | 42.99 MYR | 10.52 | 0.53 | https://partner.steamgames.com/pricing/explorer |

### Brazil (`br`)

| Service | Local monthly price | USD | Ratio to US | Source |
|---|---|---|---|---|
| Apple Music | R$ 23,90 | 4.40 | 0.37 | https://www.apple.com/br/apple-music/ |
| Apple One | R$ 47,90 | 8.82 | 0.40 | https://www.apple.com/br/apple-one/ |
| Spotify Premium | R$23.90 | 4.40 | 0.34 | https://www.spotify.com/br-en/premium/ |
| Netflix Standard | R$51,90 | 9.55 | 0.48 | https://help.netflix.com/en/node/24926/br |
| YouTube Premium (iOS IAP) | R$ 34,90 | 6.43 | 0.31 | https://apps.apple.com/br/app/id544007664 |
| ChatGPT Plus (mo) | R$ 99,90 | 18.39 | 0.92 | https://apps.apple.com/br/app/id6448311069 |
| ChatGPT Go (mo) | R$ 39,90 | 7.35 | 0.92 | https://apps.apple.com/br/app/id6448311069 |
| Google AI Pro (mo) | R$ 96,90 | 17.84 | 0.89 | https://apps.apple.com/br/app/id6477489729 |
| M365 Personal (mo) | R$ 50,90 | 9.37 | 0.94 | https://apps.apple.com/br/app/id541164041 |
| M365 Premium (mo) | R$ 109,90 | 20.23 | 1.01 | https://apps.apple.com/br/app/id541164041 |
| Notion Plus (mo) | R$ 59,90 | 11.03 | 0.92 | https://apps.apple.com/br/app/id1232780281 |
| Spark Premium (mo) | R$ 40,90 | 7.53 | 0.94 | https://apps.apple.com/br/app/id997102246 |
| Spark Pro (mo) | R$ 129,90 | 23.91 | 1.20 | https://apps.apple.com/br/app/id997102246 |
| Fantastical Premium (mo) | R$ 39,90 | 7.35 | 1.05 | https://apps.apple.com/br/app/id718043190 |
| Airmail Pro (mo) | R$ 24,90 | 4.58 | 1.15 | https://apps.apple.com/br/app/id993160329 |
| Proton Mail Plus (mo) | R$ 18,99 | 3.50 | 0.58 | https://apps.apple.com/br/app/id979659905 |
| Todoist Pro (mo) | R$ 24,90 | 4.58 | 0.66 | https://apps.apple.com/br/app/id572688855 |
| Day One Silver (mo) | R$ 59,90 | 11.03 | 1.23 | https://apps.apple.com/br/app/id1044867788 |
| (reference) Steam multi-variable recommendation for a $19.99 item | 63.99 BRL | 11.78 | 0.59 | https://partner.steamgames.com/pricing/explorer |

### Mexico (`mx`)

| Service | Local monthly price | USD | Ratio to US | Source |
|---|---|---|---|---|
| Apple Music | $139 MXN | 7.48 | 0.62 | https://www.apple.com/mx/apple-music/ |
| Apple One | $279 MXN | 15.01 | 0.68 | https://www.apple.com/mx/apple-one/ |
| Spotify Premium | MX$139 | 7.48 | 0.58 | https://www.spotify.com/mx-en/premium/ |
| Netflix Standard | MXN 269 | 14.47 | 0.72 | https://help.netflix.com/en/node/24926/mx |
| YouTube Premium (iOS IAP) | $209.00 | 11.24 | 0.54 | https://apps.apple.com/mx/app/id544007664 |
| ChatGPT Plus (mo) | $399.00 | 21.46 | 1.07 | https://apps.apple.com/mx/app/id6448311069 |
| ChatGPT Go (mo) | $129.00 | 6.94 | 0.87 | https://apps.apple.com/mx/app/id6448311069 |
| Google AI Pro (mo) | $395.00 | 21.25 | 1.06 | https://apps.apple.com/mx/app/id6477489729 |
| M365 Personal (mo) | $184.00 | 9.90 | 0.99 | https://apps.apple.com/mx/app/id541164041 |
| M365 Premium (mo) | $375.00 | 20.17 | 1.01 | https://apps.apple.com/mx/app/id541164041 |
| Notion Plus (mo) | $249.00 | 13.39 | 1.12 | https://apps.apple.com/mx/app/id1232780281 |
| Spark Premium (mo) | $185.00 | 9.95 | 1.25 | https://apps.apple.com/mx/app/id997102246 |
| Spark Pro (mo) | $399.00 | 21.46 | 1.07 | https://apps.apple.com/mx/app/id997102246 |
| Fantastical Premium (mo) | $149.00 | 8.01 | 1.15 | https://apps.apple.com/mx/app/id718043190 |
| Airmail Pro (mo) | $89.00 | 4.79 | 1.20 | https://apps.apple.com/mx/app/id993160329 |
| Proton Mail Plus (mo) | $75.00 | 4.03 | 0.67 | https://apps.apple.com/mx/app/id979659905 |
| Todoist Pro (mo) | $79.00 | 4.25 | 0.61 | https://apps.apple.com/mx/app/id572688855 |
| Day One Silver (mo) | $199.00 | 10.70 | 1.19 | https://apps.apple.com/mx/app/id1044867788 |
| (reference) Steam multi-variable recommendation for a $19.99 item | 264.99 MXN | 14.25 | 0.71 | https://partner.steamgames.com/pricing/explorer |

### Argentina (`ar`)

| Service | Local monthly price | USD | Ratio to US | Source |
|---|---|---|---|---|
| Apple Music | USD 3.29 | 3.29 | 0.27 | https://www.apple.com/la/apple-music/ |
| Spotify Premium | ARS 4,499 + taxes | 2.92 | 0.22 | https://www.spotify.com/ar/premium/ |
| Netflix Standard | ARS 14,999 | 9.74 | 0.49 | https://help.netflix.com/en/node/24926/ar |
| YouTube Premium (iOS IAP) | USD 4.99 | 4.99 | 0.24 | https://apps.apple.com/ar/app/id544007664 |
| ChatGPT Plus (mo) | USD 19.99 | 19.99 | 1.00 | https://apps.apple.com/ar/app/id6448311069 |
| ChatGPT Go (mo) | USD 5.99 | 5.99 | 0.75 | https://apps.apple.com/ar/app/id6448311069 |
| Google AI Pro (mo) | USD 19.99 | 19.99 | 1.00 | https://apps.apple.com/ar/app/id6477489729 |
| M365 Personal (mo) | USD 6.99 | 6.99 | 0.70 | https://apps.apple.com/ar/app/id541164041 |
| M365 Premium (mo) | USD 19.99 | 19.99 | 1.00 | https://apps.apple.com/ar/app/id541164041 |
| Notion Plus (mo) | USD 11.99 | 11.99 | 1.00 | https://apps.apple.com/ar/app/id1232780281 |
| Spark Premium (mo) | USD 7.99 | 7.99 | 1.00 | https://apps.apple.com/ar/app/id997102246 |
| Spark Pro (mo) | USD 20.00 | 20.00 | 1.00 | https://apps.apple.com/ar/app/id997102246 |
| Fantastical Premium (mo) | USD 6.99 | 6.99 | 1.00 | https://apps.apple.com/ar/app/id718043190 |
| Airmail Pro (mo) | USD 3.99 | 3.99 | 1.00 | https://apps.apple.com/ar/app/id993160329 |
| Proton Mail Plus (mo) | USD 5.99 | 5.99 | 1.00 | https://apps.apple.com/ar/app/id979659905 |
| Todoist Pro (mo) | USD 6.99 | 6.99 | 1.00 | https://apps.apple.com/ar/app/id572688855 |
| Day One Silver (mo) | USD 8.99 | 8.99 | 1.00 | https://apps.apple.com/ar/app/id1044867788 |

### Colombia (`co`)

| Service | Local monthly price | USD | Ratio to US | Source |
|---|---|---|---|---|
| Apple Music | $18.500 COP | 5.86 | 0.49 | https://www.apple.com/co/apple-music/ |
| Apple One | $45.900 COP | 14.55 | 0.66 | https://www.apple.com/co/apple-one/ |
| Spotify Premium | COP 18,500 | 5.86 | 0.45 | https://www.spotify.com/co-en/premium/ |
| Netflix Standard | COP 32,900 | 10.43 | 0.52 | https://help.netflix.com/en/node/24926/co |
| YouTube Premium (iOS IAP) | $ 30.900,00 | 9.79 | 0.47 | https://apps.apple.com/co/app/id544007664 |
| ChatGPT Plus (mo) | $ 99.900,00 | 31.66 | 1.58 | https://apps.apple.com/co/app/id6448311069 |
| ChatGPT Go (mo) | $ 24.900,00 | 7.89 | 0.99 | https://apps.apple.com/co/app/id6448311069 |
| Google AI Pro (mo) | $ 79.000,00 | 25.04 | 1.25 | https://apps.apple.com/co/app/id6477489729 |
| M365 Personal (mo) | $ 36.900,00 | 11.69 | 1.17 | https://apps.apple.com/co/app/id541164041 |
| M365 Premium (mo) | $ 84.900,00 | 26.91 | 1.35 | https://apps.apple.com/co/app/id541164041 |
| Notion Plus (mo) | $ 59.900,00 | 18.98 | 1.58 | https://apps.apple.com/co/app/id1232780281 |
| Spark Premium (mo) | $ 41.900,00 | 13.28 | 1.66 | https://apps.apple.com/co/app/id997102246 |
| Spark Pro (mo) | $ 99.900,00 | 31.66 | 1.58 | https://apps.apple.com/co/app/id997102246 |
| Fantastical Premium (mo) | $ 39.900,00 | 12.65 | 1.81 | https://apps.apple.com/co/app/id718043190 |
| Airmail Pro (mo) | $ 19.900,00 | 6.31 | 1.58 | https://apps.apple.com/co/app/id993160329 |
| Proton Mail Plus (mo) | $ 17.900,00 | 5.67 | 0.95 | https://apps.apple.com/co/app/id979659905 |
| Todoist Pro (mo) | $ 29.900,00 | 9.48 | 1.36 | https://apps.apple.com/co/app/id572688855 |
| Day One Silver (mo) | $ 39.900,00 | 12.65 | 1.41 | https://apps.apple.com/co/app/id1044867788 |
| (reference) Steam multi-variable recommendation for a $19.99 item | 44,499.00 COP | 14.10 | 0.71 | https://partner.steamgames.com/pricing/explorer |

### Chile (`cl`)

| Service | Local monthly price | USD | Ratio to US | Source |
|---|---|---|---|---|
| Apple Music | $4.990 CLP | 5.01 | 0.42 | https://www.apple.com/cl/apple-music/ |
| Apple One | $10.390 CLP | 10.43 | 0.48 | https://www.apple.com/cl/apple-one/ |
| Spotify Premium | CLP 4.950 | 4.97 | 0.38 | https://www.spotify.com/cl/premium/ |
| Netflix Standard | CLP 9,990 | 10.03 | 0.50 | https://help.netflix.com/en/node/24926/cl |
| YouTube Premium (iOS IAP) | $7.200 | 7.23 | 0.34 | https://apps.apple.com/cl/app/id544007664 |
| ChatGPT Plus (mo) | $19.990 | 20.07 | 1.00 | https://apps.apple.com/cl/app/id6448311069 |
| ChatGPT Go (mo) | $7.990 | 8.02 | 1.00 | https://apps.apple.com/cl/app/id6448311069 |
| Google AI Pro (mo) | $21.490 | 21.58 | 1.08 | https://apps.apple.com/cl/app/id6477489729 |
| M365 Personal (mo) | $8.490 | 8.53 | 0.85 | https://apps.apple.com/cl/app/id541164041 |
| M365 Premium (mo) | $21.490 | 21.58 | 1.08 | https://apps.apple.com/cl/app/id541164041 |
| Notion Plus (mo) | $12.990 | 13.04 | 1.09 | https://apps.apple.com/cl/app/id1232780281 |
| Spark Premium (mo) | $8.700 | 8.74 | 1.09 | https://apps.apple.com/cl/app/id997102246 |
| Spark Pro (mo) | $22.990 | 23.09 | 1.15 | https://apps.apple.com/cl/app/id997102246 |
| Fantastical Premium (mo) | $7.990 | 8.02 | 1.15 | https://apps.apple.com/cl/app/id718043190 |
| Airmail Pro (mo) | $4.990 | 5.01 | 1.26 | https://apps.apple.com/cl/app/id993160329 |
| Proton Mail Plus (mo) | $4.190 | 4.21 | 0.70 | https://apps.apple.com/cl/app/id979659905 |
| Todoist Pro (mo) | $7.990 | 8.02 | 1.15 | https://apps.apple.com/cl/app/id572688855 |
| Day One Silver (mo) | $9.990 | 10.03 | 1.12 | https://apps.apple.com/cl/app/id1044867788 |
| (reference) Steam multi-variable recommendation for a $19.99 item | 12,999.00 CLP | 13.05 | 0.65 | https://partner.steamgames.com/pricing/explorer |

### Peru (`pe`)

| Service | Local monthly price | USD | Ratio to US | Source |
|---|---|---|---|---|
| Apple Music | S/20.90 | 6.08 | 0.51 | https://www.apple.com/la/apple-music/ |
| Spotify Premium | S/ 20.90 | 6.08 | 0.47 | https://www.spotify.com/pe/premium/ |
| Netflix Standard | PEN 44.90 | 13.05 | 0.65 | https://help.netflix.com/en/node/24926/pe |
| YouTube Premium (iOS IAP) | S/ 34.90 | 10.15 | 0.48 | https://apps.apple.com/pe/app/id544007664 |
| ChatGPT Plus (mo) | S/ 79.90 | 23.23 | 1.16 | https://apps.apple.com/pe/app/id6448311069 |
| ChatGPT Go (mo) | S/ 19.90 | 5.78 | 0.72 | https://apps.apple.com/pe/app/id6448311069 |
| Google AI Pro (mo) | S/ 73.90 | 21.48 | 1.07 | https://apps.apple.com/pe/app/id6477489729 |
| M365 Personal (mo) | S/ 23.90 | 6.95 | 0.70 | https://apps.apple.com/pe/app/id541164041 |
| M365 Premium (mo) | S/ 74.99 | 21.80 | 1.09 | https://apps.apple.com/pe/app/id541164041 |
| Notion Plus (mo) | S/ 49.90 | 14.51 | 1.21 | https://apps.apple.com/pe/app/id1232780281 |
| Spark Premium (mo) | S/ 30.90 | 8.98 | 1.12 | https://apps.apple.com/pe/app/id997102246 |
| Spark Pro (mo) | S/ 89.90 | 26.13 | 1.31 | https://apps.apple.com/pe/app/id997102246 |
| Fantastical Premium (mo) | S/ 24.90 | 7.24 | 1.04 | https://apps.apple.com/pe/app/id718043190 |
| Airmail Pro (mo) | S/ 17.90 | 5.20 | 1.30 | https://apps.apple.com/pe/app/id993160329 |
| Proton Mail Plus (mo) | S/ 14.99 | 4.36 | 0.73 | https://apps.apple.com/pe/app/id979659905 |
| Todoist Pro (mo) | S/ 29.90 | 8.69 | 1.24 | https://apps.apple.com/pe/app/id572688855 |
| Day One Silver (mo) | S/ 39.90 | 11.60 | 1.29 | https://apps.apple.com/pe/app/id1044867788 |
| (reference) Steam multi-variable recommendation for a $19.99 item | 43.99 PEN | 12.79 | 0.64 | https://partner.steamgames.com/pricing/explorer |

### Turkey (`tr`)

| Service | Local monthly price | USD | Ratio to US | Source |
|---|---|---|---|---|
| Apple Music | ₺89,99 | 1.81 | 0.15 | https://www.apple.com/tr/apple-music/ |
| Spotify Premium | TRY 115 | 2.31 | 0.18 | https://www.spotify.com/tr-en/premium/ |
| Netflix Standard | TRY 389.99 | 7.83 | 0.39 | https://help.netflix.com/en/node/24926/tr |
| YouTube Premium (iOS IAP) | ₺159,99 | 3.21 | 0.15 | https://apps.apple.com/tr/app/id544007664 |
| ChatGPT Plus (mo) | ₺999,99 | 20.08 | 1.00 | https://apps.apple.com/tr/app/id6448311069 |
| ChatGPT Go (mo) | ₺249,99 | 5.02 | 0.63 | https://apps.apple.com/tr/app/id6448311069 |
| Google AI Pro (mo) | ₺539,99 | 10.85 | 0.54 | https://apps.apple.com/tr/app/id6477489729 |
| M365 Personal (mo) | ₺329,99 | 6.63 | 0.66 | https://apps.apple.com/tr/app/id541164041 |
| M365 Premium (mo) | ₺719,99 | 14.46 | 0.72 | https://apps.apple.com/tr/app/id541164041 |
| Notion Plus (mo) | ₺499,99 | 10.04 | 0.84 | https://apps.apple.com/tr/app/id1232780281 |
| Spark Premium (mo) | ₺184,99 | 3.72 | 0.47 | https://apps.apple.com/tr/app/id997102246 |
| Fantastical Premium (mo) | ₺179,99 | 3.61 | 0.52 | https://apps.apple.com/tr/app/id718043190 |
| Airmail Pro (mo) | ₺199,99 | 4.02 | 1.01 | https://apps.apple.com/tr/app/id993160329 |
| Proton Mail Plus (mo) | ₺149,99 | 3.01 | 0.50 | https://apps.apple.com/tr/app/id979659905 |
| Todoist Pro (mo) | ₺249,99 | 5.02 | 0.72 | https://apps.apple.com/tr/app/id572688855 |
| Day One Silver (mo) | ₺399,99 | 8.03 | 0.89 | https://apps.apple.com/tr/app/id1044867788 |

### Egypt (`eg`)

| Service | Local monthly price | USD | Ratio to US | Source |
|---|---|---|---|---|
| Spotify Premium | EGP 79 | 1.40 | 0.11 | https://www.spotify.com/eg-en/premium/ |
| Netflix Standard | EGP 190 | 3.38 | 0.17 | https://help.netflix.com/en/node/24926/eg |
| YouTube Premium (iOS IAP) | EGP 114.99 | 2.04 | 0.10 | https://apps.apple.com/eg/app/id544007664 |
| ChatGPT Plus (mo) | EGP 999.99 | 17.77 | 0.89 | https://apps.apple.com/eg/app/id6448311069 |
| ChatGPT Go (mo) | EGP 249.99 | 4.44 | 0.56 | https://apps.apple.com/eg/app/id6448311069 |
| Google AI Pro (mo) | EGP 939.99 | 16.71 | 0.84 | https://apps.apple.com/eg/app/id6477489729 |
| M365 Personal (mo) | EGP 239.00 | 4.25 | 0.43 | https://apps.apple.com/eg/app/id541164041 |
| M365 Premium (mo) | EGP 699.00 | 12.42 | 0.62 | https://apps.apple.com/eg/app/id541164041 |
| Notion Plus (mo) | EGP 599.99 | 10.66 | 0.89 | https://apps.apple.com/eg/app/id1232780281 |
| Spark Premium (mo) | EGP 149.99 | 2.67 | 0.33 | https://apps.apple.com/eg/app/id997102246 |
| Spark Pro (mo) | EGP 999.99 | 17.77 | 0.89 | https://apps.apple.com/eg/app/id997102246 |
| Fantastical Premium (mo) | EGP 179.99 | 3.20 | 0.46 | https://apps.apple.com/eg/app/id718043190 |
| Airmail Pro (mo) | EGP 199.99 | 3.55 | 0.89 | https://apps.apple.com/eg/app/id993160329 |
| Proton Mail Plus (mo) | EGP 185.00 | 3.29 | 0.55 | https://apps.apple.com/eg/app/id979659905 |
| Todoist Pro (mo) | EGP 399.99 | 7.11 | 1.02 | https://apps.apple.com/eg/app/id572688855 |
| Day One Silver (mo) | EGP 284.99 | 5.06 | 0.56 | https://apps.apple.com/eg/app/id1044867788 |

### Nigeria (`ng`)

| Service | Local monthly price | USD | Ratio to US | Source |
|---|---|---|---|---|
| Spotify Premium | ₦1,600 | 1.18 | 0.09 | https://www.spotify.com/ng/premium/ |
| Netflix Standard | NGN 6,500 | 4.78 | 0.24 | https://help.netflix.com/en/node/24926/ng |
| YouTube Premium (iOS IAP) | ₦ 2,200.00 | 1.62 | 0.08 | https://apps.apple.com/ng/app/id544007664 |
| ChatGPT Plus (mo) | ₦ 31,500.00 | 23.16 | 1.16 | https://apps.apple.com/ng/app/id6448311069 |
| ChatGPT Go (mo) | ₦ 6,900.00 | 5.07 | 0.63 | https://apps.apple.com/ng/app/id6448311069 |
| Google AI Pro (mo) | ₦ 28,500.00 | 20.96 | 1.05 | https://apps.apple.com/ng/app/id6477489729 |
| M365 Personal (mo) | ₦ 7,200.00 | 5.29 | 0.53 | https://apps.apple.com/ng/app/id541164041 |
| M365 Premium (mo) | ₦ 17,000.00 | 12.50 | 0.63 | https://apps.apple.com/ng/app/id541164041 |
| Notion Plus (mo) | ₦ 19,900.00 | 14.63 | 1.22 | https://apps.apple.com/ng/app/id1232780281 |
| Spark Premium (mo) | ₦ 3,700.00 | 2.72 | 0.34 | https://apps.apple.com/ng/app/id997102246 |
| Spark Pro (mo) | ₦ 29,900.00 | 21.99 | 1.10 | https://apps.apple.com/ng/app/id997102246 |
| Fantastical Premium (mo) | ₦ 3,200.00 | 2.35 | 0.34 | https://apps.apple.com/ng/app/id718043190 |
| Airmail Pro (mo) | ₦ 6,900.00 | 5.07 | 1.27 | https://apps.apple.com/ng/app/id993160329 |
| Proton Mail Plus (mo) | ₦ 5,900.00 | 4.34 | 0.72 | https://apps.apple.com/ng/app/id979659905 |
| Todoist Pro (mo) | ₦ 9,900.00 | 7.28 | 1.04 | https://apps.apple.com/ng/app/id572688855 |
| Day One Silver (mo) | ₦ 14,900.00 | 10.96 | 1.22 | https://apps.apple.com/ng/app/id1044867788 |

### Kenya (`ke`)

| Service | Local monthly price | USD | Ratio to US | Source |
|---|---|---|---|---|
| Spotify Premium | Ksh 419 | 3.23 | 0.25 | https://www.spotify.com/ke-en/premium/ |
| Netflix Standard | KES 700 | 5.39 | 0.27 | https://help.netflix.com/en/node/24926/ke |
| YouTube Premium (iOS IAP) | USD 4.99 | 4.99 | 0.24 | https://apps.apple.com/ke/app/id544007664 |
| ChatGPT Plus (mo) | USD 22.99 | 22.99 | 1.15 | https://apps.apple.com/ke/app/id6448311069 |
| ChatGPT Go (mo) | USD 5.99 | 5.99 | 0.75 | https://apps.apple.com/ke/app/id6448311069 |
| Google AI Pro (mo) | USD 19.99 | 19.99 | 1.00 | https://apps.apple.com/ke/app/id6477489729 |
| M365 Personal (mo) | USD 9.99 | 9.99 | 1.00 | https://apps.apple.com/ke/app/id541164041 |
| M365 Premium (mo) | USD 22.99 | 22.99 | 1.15 | https://apps.apple.com/ke/app/id541164041 |
| Notion Plus (mo) | USD 14.99 | 14.99 | 1.25 | https://apps.apple.com/ke/app/id1232780281 |
| Spark Premium (mo) | USD 7.99 | 7.99 | 1.00 | https://apps.apple.com/ke/app/id997102246 |
| Spark Pro (mo) | USD 25.00 | 25.00 | 1.25 | https://apps.apple.com/ke/app/id997102246 |
| Fantastical Premium (mo) | USD 7.99 | 7.99 | 1.14 | https://apps.apple.com/ke/app/id718043190 |
| Airmail Pro (mo) | USD 4.99 | 4.99 | 1.25 | https://apps.apple.com/ke/app/id993160329 |
| Proton Mail Plus (mo) | USD 5.99 | 5.99 | 1.00 | https://apps.apple.com/ke/app/id979659905 |
| Todoist Pro (mo) | USD 7.99 | 7.99 | 1.14 | https://apps.apple.com/ke/app/id572688855 |
| Day One Silver (mo) | USD 9.99 | 9.99 | 1.11 | https://apps.apple.com/ke/app/id1044867788 |

### South Africa (`za`)

| Service | Local monthly price | USD | Ratio to US | Source |
|---|---|---|---|---|
| Spotify Premium | R 69,99 (Premium Standard) | 4.21 | 0.32 | https://www.spotify.com/za-en/premium/ |
| Netflix Standard | ZAR 179 | 10.76 | 0.54 | https://help.netflix.com/en/node/24926/za |
| YouTube Premium (iOS IAP) | R104.99 | 6.31 | 0.30 | https://apps.apple.com/za/app/id544007664 |
| ChatGPT Plus (mo) | R399.99 | 24.04 | 1.20 | https://apps.apple.com/za/app/id6448311069 |
| ChatGPT Go (mo) | R149.99 | 9.02 | 1.13 | https://apps.apple.com/za/app/id6448311069 |
| Google AI Pro (mo) | R429.99 | 25.85 | 1.29 | https://apps.apple.com/za/app/id6477489729 |
| M365 Personal (mo) | R159.00 | 9.56 | 0.96 | https://apps.apple.com/za/app/id541164041 |
| M365 Premium (mo) | R429.00 | 25.79 | 1.29 | https://apps.apple.com/za/app/id541164041 |
| Notion Plus (mo) | R249.99 | 15.03 | 1.25 | https://apps.apple.com/za/app/id1232780281 |
| Spark Premium (mo) | R154.99 | 9.32 | 1.17 | https://apps.apple.com/za/app/id997102246 |
| Spark Pro (mo) | R399.99 | 24.04 | 1.20 | https://apps.apple.com/za/app/id997102246 |
| Fantastical Premium (mo) | R129.99 | 7.81 | 1.12 | https://apps.apple.com/za/app/id718043190 |
| Airmail Pro (mo) | R79.99 | 4.81 | 1.21 | https://apps.apple.com/za/app/id993160329 |
| Proton Mail Plus (mo) | R74.99 | 4.51 | 0.75 | https://apps.apple.com/za/app/id979659905 |
| Todoist Pro (mo) | R79.99 | 4.81 | 0.69 | https://apps.apple.com/za/app/id572688855 |
| Day One Silver (mo) | R199.99 | 12.02 | 1.34 | https://apps.apple.com/za/app/id1044867788 |
| (reference) Steam multi-variable recommendation for a $19.99 item | 179.99 ZAR | 10.82 | 0.54 | https://partner.steamgames.com/pricing/explorer |

### Saudi Arabia (`sa`)

| Service | Local monthly price | USD | Ratio to US | Source |
|---|---|---|---|---|
| Apple Music | SAR 23.99 | 6.40 | 0.53 | https://www.apple.com/sa/apple-music/ |
| Spotify Premium | SAR 23.99 (Premium Standard) | 6.40 | 0.49 | https://www.spotify.com/sa-en/premium/ |
| Netflix Standard | SAR 49 | 13.07 | 0.65 | https://help.netflix.com/en/node/24926/sa |
| YouTube Premium (iOS IAP) | SAR 39.99 | 10.66 | 0.51 | https://apps.apple.com/sa/app/id544007664 |
| ChatGPT Plus (mo) | SAR 89.99 | 24.00 | 1.20 | https://apps.apple.com/sa/app/id6448311069 |
| ChatGPT Go (mo) | SAR 35.00 | 9.33 | 1.17 | https://apps.apple.com/sa/app/id6448311069 |
| Google AI Pro (mo) | SAR 85.99 | 22.93 | 1.15 | https://apps.apple.com/sa/app/id6477489729 |
| M365 Personal (mo) | SAR 42.99 | 11.46 | 1.15 | https://apps.apple.com/sa/app/id541164041 |
| M365 Premium (mo) | SAR 85.99 | 22.93 | 1.15 | https://apps.apple.com/sa/app/id541164041 |
| Notion Plus (mo) | SAR 49.99 | 13.33 | 1.11 | https://apps.apple.com/sa/app/id1232780281 |
| Spark Premium (mo) | SAR 34.99 | 9.33 | 1.17 | https://apps.apple.com/sa/app/id997102246 |
| Spark Pro (mo) | SAR 89.99 | 24.00 | 1.20 | https://apps.apple.com/sa/app/id997102246 |
| Fantastical Premium (mo) | SAR 29.99 | 8.00 | 1.14 | https://apps.apple.com/sa/app/id718043190 |
| Airmail Pro (mo) | SAR 17.99 | 4.80 | 1.20 | https://apps.apple.com/sa/app/id993160329 |
| Proton Mail Plus (mo) | SAR 18.49 | 4.93 | 0.82 | https://apps.apple.com/sa/app/id979659905 |
| Todoist Pro (mo) | SAR 29.99 | 8.00 | 1.14 | https://apps.apple.com/sa/app/id572688855 |
| Day One Silver (mo) | SAR 39.99 | 10.66 | 1.19 | https://apps.apple.com/sa/app/id1044867788 |
| (reference) Steam multi-variable recommendation for a $19.99 item | 52.99 SAR | 14.13 | 0.71 | https://partner.steamgames.com/pricing/explorer |

### UAE (`ae`)

| Service | Local monthly price | USD | Ratio to US | Source |
|---|---|---|---|---|
| Apple Music | AED 23.99 | 6.53 | 0.54 | https://www.apple.com/ae/apple-music/ |
| Spotify Premium | AED 23.99 (Premium Standard) | 6.53 | 0.50 | https://www.spotify.com/ae-en/premium/ |
| Netflix Standard | AED 49 | 13.34 | 0.67 | https://help.netflix.com/en/node/24926/ae |
| YouTube Premium (iOS IAP) | AED 38.99 | 10.62 | 0.51 | https://apps.apple.com/ae/app/id544007664 |
| ChatGPT Plus (mo) | AED 79.99 | 21.78 | 1.09 | https://apps.apple.com/ae/app/id6448311069 |
| ChatGPT Go (mo) | AED 29.99 | 8.17 | 1.02 | https://apps.apple.com/ae/app/id6448311069 |
| Google AI Pro (mo) | AED 76.99 | 20.96 | 1.05 | https://apps.apple.com/ae/app/id6477489729 |
| M365 Personal (mo) | AED 36.99 | 10.07 | 1.01 | https://apps.apple.com/ae/app/id541164041 |
| M365 Premium (mo) | AED 76.99 | 20.96 | 1.05 | https://apps.apple.com/ae/app/id541164041 |
| Notion Plus (mo) | AED 49.99 | 13.61 | 1.14 | https://apps.apple.com/ae/app/id1232780281 |
| Spark Premium (mo) | AED 29.99 | 8.17 | 1.02 | https://apps.apple.com/ae/app/id997102246 |
| Spark Pro (mo) | AED 79.99 | 21.78 | 1.09 | https://apps.apple.com/ae/app/id997102246 |
| Fantastical Premium (mo) | AED 24.99 | 6.80 | 0.97 | https://apps.apple.com/ae/app/id718043190 |
| Airmail Pro (mo) | AED 14.99 | 4.08 | 1.02 | https://apps.apple.com/ae/app/id993160329 |
| Proton Mail Plus (mo) | AED 18.99 | 5.17 | 0.86 | https://apps.apple.com/ae/app/id979659905 |
| Todoist Pro (mo) | AED 24.99 | 6.80 | 0.97 | https://apps.apple.com/ae/app/id572688855 |
| Day One Silver (mo) | AED 34.99 | 9.53 | 1.06 | https://apps.apple.com/ae/app/id1044867788 |
| (reference) Steam multi-variable recommendation for a $19.99 item | 67.99 AED | 18.51 | 0.93 | https://partner.steamgames.com/pricing/explorer |

### Russia (`ru`)

| Service | Local monthly price | USD | Ratio to US | Source |
|---|---|---|---|---|
| YouTube Premium (iOS IAP) | 249,00 ₽ | 3.08 | 0.15 | https://apps.apple.com/ru/app/id544007664 |
| Fantastical Premium (mo) | 499,00 ₽ | 6.18 | 0.88 | https://apps.apple.com/ru/app/id718043190 |
| Proton Mail Plus (mo) | 399,00 ₽ | 4.94 | 0.82 | https://apps.apple.com/ru/app/id979659905 |
| Todoist Pro (mo) | 490,00 ₽ | 6.07 | 0.87 | https://apps.apple.com/ru/app/id572688855 |
| Day One Silver (mo) | 799,00 ₽ | 9.89 | 1.10 | https://apps.apple.com/ru/app/id1044867788 |
| (reference) Steam multi-variable recommendation for a $19.99 item | 890.00 RUB | 11.02 | 0.55 | https://partner.steamgames.com/pricing/explorer |

### Ukraine (`ua`)

| Service | Local monthly price | USD | Ratio to US | Source |
|---|---|---|---|---|
| Spotify Premium | US$4.99 | 4.99 | 0.38 | https://www.spotify.com/ua-en/premium/ |
| Netflix Standard | €7.49 | 8.38 | 0.42 | https://help.netflix.com/en/node/24926/ua |
| YouTube Premium (iOS IAP) | 4,99 USD | 4.99 | 0.24 | https://apps.apple.com/ua/app/id544007664 |
| ChatGPT Plus (mo) | 22,99 USD | 22.99 | 1.15 | https://apps.apple.com/ua/app/id6448311069 |
| ChatGPT Go (mo) | 6,99 USD | 6.99 | 0.87 | https://apps.apple.com/ua/app/id6448311069 |
| Google AI Pro (mo) | 19,99 USD | 19.99 | 1.00 | https://apps.apple.com/ua/app/id6477489729 |
| M365 Personal (mo) | 6,99 USD | 6.99 | 0.70 | https://apps.apple.com/ua/app/id541164041 |
| M365 Premium (mo) | 23,99 USD | 23.99 | 1.20 | https://apps.apple.com/ua/app/id541164041 |
| Notion Plus (mo) | 14,99 USD | 14.99 | 1.25 | https://apps.apple.com/ua/app/id1232780281 |
| Spark Premium (mo) | 7,99 USD | 7.99 | 1.00 | https://apps.apple.com/ua/app/id997102246 |
| Spark Pro (mo) | 25,00 USD | 25.00 | 1.25 | https://apps.apple.com/ua/app/id997102246 |
| Fantastical Premium (mo) | 7,99 USD | 7.99 | 1.14 | https://apps.apple.com/ua/app/id718043190 |
| Airmail Pro (mo) | 4,99 USD | 4.99 | 1.25 | https://apps.apple.com/ua/app/id993160329 |
| Proton Mail Plus (mo) | 5,99 USD | 5.99 | 1.00 | https://apps.apple.com/ua/app/id979659905 |
| Todoist Pro (mo) | 6,99 USD | 6.99 | 1.00 | https://apps.apple.com/ua/app/id572688855 |
| Day One Silver (mo) | 9,99 USD | 9.99 | 1.11 | https://apps.apple.com/ua/app/id1044867788 |
| (reference) Steam multi-variable recommendation for a $19.99 item | 470.00 UAH | 10.32 | 0.52 | https://partner.steamgames.com/pricing/explorer |

### Poland (`pl`)

| Service | Local monthly price | USD | Ratio to US | Source |
|---|---|---|---|---|
| Apple Music | 26,99 zł | 6.85 | 0.57 | https://www.apple.com/pl/apple-music/ |
| Apple One | 42,99 zł | 10.92 | 0.50 | https://www.apple.com/pl/apple-one/ |
| Spotify Premium | 26,99 zł | 6.85 | 0.53 | https://www.spotify.com/pl/premium/ |
| Netflix Standard | PLN 55 | 13.97 | 0.70 | https://help.netflix.com/en/node/24926/pl |
| YouTube Premium (iOS IAP) | 38,99 zł | 9.90 | 0.47 | https://apps.apple.com/pl/app/id544007664 |
| ChatGPT Plus (mo) | 99,99 zł | 25.39 | 1.27 | https://apps.apple.com/pl/app/id6448311069 |
| ChatGPT Go (mo) | 34,99 zł | 8.89 | 1.11 | https://apps.apple.com/pl/app/id6448311069 |
| Google AI Pro (mo) | 97,99 zł | 24.88 | 1.24 | https://apps.apple.com/pl/app/id6477489729 |
| M365 Personal (mo) | 42,99 zł | 10.92 | 1.09 | https://apps.apple.com/pl/app/id541164041 |
| M365 Premium (mo) | 97,99 zł | 24.88 | 1.24 | https://apps.apple.com/pl/app/id541164041 |
| Notion Plus (mo) | 69,99 zł | 17.77 | 1.48 | https://apps.apple.com/pl/app/id1232780281 |
| Spark Premium (mo) | 47,99 zł | 12.19 | 1.53 | https://apps.apple.com/pl/app/id997102246 |
| Spark Pro (mo) | 99,99 zł | 25.39 | 1.27 | https://apps.apple.com/pl/app/id997102246 |
| Fantastical Premium (mo) | 39,99 zł | 10.15 | 1.45 | https://apps.apple.com/pl/app/id718043190 |
| Airmail Pro (mo) | 19,99 zł | 5.08 | 1.27 | https://apps.apple.com/pl/app/id993160329 |
| Proton Mail Plus (mo) | 14,99 zł | 3.81 | 0.64 | https://apps.apple.com/pl/app/id979659905 |
| Todoist Pro (mo) | 24,00 zł | 6.09 | 0.87 | https://apps.apple.com/pl/app/id572688855 |
| Day One Silver (mo) | 49,99 zł | 12.69 | 1.41 | https://apps.apple.com/pl/app/id1044867788 |
| (reference) Steam multi-variable recommendation for a $19.99 item | 80.99 PLN | 20.57 | 1.03 | https://partner.steamgames.com/pricing/explorer |

### Japan (`jp`)

| Service | Local monthly price | USD | Ratio to US | Source |
|---|---|---|---|---|
| Apple Music | ¥1,180 | 7.50 | 0.63 | https://www.apple.com/jp/apple-music/ |
| Apple One | ¥1,350 | 8.57 | 0.39 | https://www.apple.com/jp/apple-one/ |
| Spotify Premium | ¥1,080 (Standard) | 6.86 | 0.53 | https://www.spotify.com/jp/premium/ |
| Netflix Standard | ¥1,590 | 10.10 | 0.51 | https://help.netflix.com/en/node/24926/jp |
| YouTube Premium (iOS IAP) | ¥1,680 | 10.67 | 0.51 | https://apps.apple.com/jp/app/id544007664 |
| ChatGPT Plus (mo) | ¥3,000 | 19.06 | 0.95 | https://apps.apple.com/jp/app/id6448311069 |
| ChatGPT Go (mo) | ¥1,400 | 8.89 | 1.11 | https://apps.apple.com/jp/app/id6448311069 |
| Google AI Pro (mo) | ¥2,900 | 18.42 | 0.92 | https://apps.apple.com/jp/app/id6477489729 |
| M365 Personal (mo) | ¥2,100 | 13.34 | 1.34 | https://apps.apple.com/jp/app/id541164041 |
| M365 Premium (mo) | ¥3,200 | 20.33 | 1.02 | https://apps.apple.com/jp/app/id541164041 |
| Spark Premium (mo) | ¥1,100 | 6.99 | 0.87 | https://apps.apple.com/jp/app/id997102246 |
| Spark Pro (mo) | ¥3,000 | 19.06 | 0.95 | https://apps.apple.com/jp/app/id997102246 |
| Fantastical Premium (mo) | ¥1,000 | 6.35 | 0.91 | https://apps.apple.com/jp/app/id718043190 |
| Airmail Pro (mo) | ¥600 | 3.81 | 0.96 | https://apps.apple.com/jp/app/id993160329 |
| Proton Mail Plus (mo) | ¥720 | 4.57 | 0.76 | https://apps.apple.com/jp/app/id979659905 |
| Todoist Pro (mo) | ¥890 | 5.65 | 0.81 | https://apps.apple.com/jp/app/id572688855 |
| Day One Silver (mo) | ¥1,500 | 9.53 | 1.06 | https://apps.apple.com/jp/app/id1044867788 |
| (reference) Steam multi-variable recommendation for a $19.99 item | 2,800.00 JPY | 17.78 | 0.89 | https://partner.steamgames.com/pricing/explorer |

### South Korea (`kr`)

| Service | Local monthly price | USD | Ratio to US | Source |
|---|---|---|---|---|
| Apple Music | ₩8,900 | 6.72 | 0.56 | https://www.apple.com/kr/apple-music/ |
| Apple One | ₩14,900 | 11.24 | 0.51 | https://www.apple.com/kr/apple-one/ |
| Spotify Premium | ₩11,990 | 9.05 | 0.70 | https://www.spotify.com/kr-en/premium/ |
| Netflix Standard | KRW 13,500 | 10.19 | 0.51 | https://help.netflix.com/en/node/24926/kr |
| YouTube Premium (iOS IAP) | ￦19,500 | 14.71 | 0.70 | https://apps.apple.com/kr/app/id544007664 |
| ChatGPT Plus (mo) | ￦29,000 | 21.88 | 1.09 | https://apps.apple.com/kr/app/id6448311069 |
| ChatGPT Go (mo) | ￦13,000 | 9.81 | 1.23 | https://apps.apple.com/kr/app/id6448311069 |
| Google AI Pro (mo) | ￦29,000 | 21.88 | 1.09 | https://apps.apple.com/kr/app/id6477489729 |
| M365 Personal (mo) | ￦9,500 | 7.17 | 0.72 | https://apps.apple.com/kr/app/id541164041 |
| M365 Premium (mo) | ￦29,000 | 21.88 | 1.09 | https://apps.apple.com/kr/app/id541164041 |
| Spark Premium (mo) | ￦11,500 | 8.68 | 1.09 | https://apps.apple.com/kr/app/id997102246 |
| Spark Pro (mo) | ￦29,000 | 21.88 | 1.09 | https://apps.apple.com/kr/app/id997102246 |
| Fantastical Premium (mo) | ￦9,900 | 7.47 | 1.07 | https://apps.apple.com/kr/app/id718043190 |
| Airmail Pro (mo) | ￦5,500 | 4.15 | 1.04 | https://apps.apple.com/kr/app/id993160329 |
| Proton Mail Plus (mo) | ￦5,900 | 4.45 | 0.74 | https://apps.apple.com/kr/app/id979659905 |
| Todoist Pro (mo) | ￦9,900 | 7.47 | 1.07 | https://apps.apple.com/kr/app/id572688855 |
| Day One Silver (mo) | ￦12,000 | 9.06 | 1.01 | https://apps.apple.com/kr/app/id1044867788 |
| (reference) Steam multi-variable recommendation for a $19.99 item | 22,500.00 KRW | 16.98 | 0.85 | https://partner.steamgames.com/pricing/explorer |

### China mainland (`cn`)

| Service | Local monthly price | USD | Ratio to US | Source |
|---|---|---|---|---|
| Apple Music | RMB 12 | 1.80 | 0.15 | https://www.apple.com/cn/apple-music/ |
| YouTube Premium (iOS IAP) | ¥68.00 | 10.17 | 0.48 | https://apps.apple.com/cn/app/id544007664 |
| M365 Personal (mo) | ¥38.00 | 5.69 | 0.57 | https://apps.apple.com/cn/app/id541164041 |
| Notion Plus (mo) | ¥88.00 | 13.17 | 1.10 | https://apps.apple.com/cn/app/id1232780281 |
| Spark Premium (mo) | ¥58.00 | 8.68 | 1.09 | https://apps.apple.com/cn/app/id997102246 |
| Spark Pro (mo) | ¥148.00 | 22.14 | 1.11 | https://apps.apple.com/cn/app/id997102246 |
| Fantastical Premium (mo) | ¥48.00 | 7.18 | 1.03 | https://apps.apple.com/cn/app/id718043190 |
| Airmail Pro (mo) | ¥28.00 | 4.19 | 1.05 | https://apps.apple.com/cn/app/id993160329 |
| Proton Mail Plus (mo) | ¥37.00 | 5.54 | 0.92 | https://apps.apple.com/cn/app/id979659905 |
| Todoist Pro (mo) | ¥48.00 | 7.18 | 1.03 | https://apps.apple.com/cn/app/id572688855 |
| Day One Silver (mo) | ¥58.00 | 8.68 | 0.97 | https://apps.apple.com/cn/app/id1044867788 |
| (reference) Steam multi-variable recommendation for a $19.99 item | 70.00 CNY | 10.47 | 0.52 | https://partner.steamgames.com/pricing/explorer |

### Taiwan (`tw`)

| Service | Local monthly price | USD | Ratio to US | Source |
|---|---|---|---|---|
| Apple Music | NT$165 | 5.06 | 0.42 | https://www.apple.com/tw/apple-music/ |
| Apple One | NT$390 | 11.97 | 0.55 | https://www.apple.com/tw/apple-one/ |
| Spotify Premium | NT$168 | 5.15 | 0.40 | https://www.spotify.com/tw/premium/ |
| Netflix Standard | TWD 380 | 11.66 | 0.58 | https://help.netflix.com/en/node/24926/tw |
| YouTube Premium (iOS IAP) | $260.00 | 7.98 | 0.38 | https://apps.apple.com/tw/app/id544007664 |
| ChatGPT Plus (mo) | $690.00 | 21.17 | 1.06 | https://apps.apple.com/tw/app/id6448311069 |
| ChatGPT Go (mo) | $270.00 | 8.28 | 1.04 | https://apps.apple.com/tw/app/id6448311069 |
| Google AI Pro (mo) | $650.00 | 19.94 | 1.00 | https://apps.apple.com/tw/app/id6477489729 |
| M365 Personal (mo) | $310.00 | 9.51 | 0.95 | https://apps.apple.com/tw/app/id541164041 |
| M365 Premium (mo) | $670.00 | 20.56 | 1.03 | https://apps.apple.com/tw/app/id541164041 |
| Notion Plus (mo) | $390.00 | 11.97 | 1.00 | https://apps.apple.com/tw/app/id1232780281 |
| Spark Premium (mo) | $260.00 | 7.98 | 1.00 | https://apps.apple.com/tw/app/id997102246 |
| Spark Pro (mo) | $690.00 | 21.17 | 1.06 | https://apps.apple.com/tw/app/id997102246 |
| Fantastical Premium (mo) | $220.00 | 6.75 | 0.97 | https://apps.apple.com/tw/app/id718043190 |
| Airmail Pro (mo) | $120.00 | 3.68 | 0.92 | https://apps.apple.com/tw/app/id993160329 |
| Proton Mail Plus (mo) | $150.00 | 4.60 | 0.77 | https://apps.apple.com/tw/app/id979659905 |
| Todoist Pro (mo) | $220.00 | 6.75 | 0.97 | https://apps.apple.com/tw/app/id572688855 |
| Day One Silver (mo) | $290.00 | 8.90 | 0.99 | https://apps.apple.com/tw/app/id1044867788 |
| (reference) Steam multi-variable recommendation for a $19.99 item | 348.00 TWD | 10.68 | 0.53 | https://partner.steamgames.com/pricing/explorer |

### Hong Kong (`hk`)

| Service | Local monthly price | USD | Ratio to US | Source |
|---|---|---|---|---|
| Apple Music | HK$78 | 9.94 | 0.83 | https://www.apple.com/hk/en/apple-music/ |
| Spotify Premium | HK$78 | 9.94 | 0.77 | https://www.spotify.com/hk-en/premium/ |
| Netflix Standard | HKD 98 | 12.49 | 0.62 | https://help.netflix.com/en/node/24926/hk |
| YouTube Premium (iOS IAP) | HK$ 113.00 | 14.40 | 0.69 | https://apps.apple.com/hk/app/id544007664 |
| Google AI Pro (mo) | HK$ 158.00 | 20.14 | 1.01 | https://apps.apple.com/hk/app/id6477489729 |
| M365 Personal (mo) | HK$ 78.00 | 9.94 | 1.00 | https://apps.apple.com/hk/app/id541164041 |
| M365 Premium (mo) | HK$ 158.00 | 20.14 | 1.01 | https://apps.apple.com/hk/app/id541164041 |
| Notion Plus (mo) | HK$ 88.00 | 11.22 | 0.94 | https://apps.apple.com/hk/app/id1232780281 |
| Spark Premium (mo) | HK$ 63.00 | 8.03 | 1.01 | https://apps.apple.com/hk/app/id997102246 |
| Spark Pro (mo) | HK$ 148.00 | 18.87 | 0.94 | https://apps.apple.com/hk/app/id997102246 |
| Fantastical Premium (mo) | HK$ 52.00 | 6.63 | 0.95 | https://apps.apple.com/hk/app/id718043190 |
| Airmail Pro (mo) | HK$ 32.00 | 4.08 | 1.02 | https://apps.apple.com/hk/app/id993160329 |
| Proton Mail Plus (mo) | HK$ 37.00 | 4.72 | 0.79 | https://apps.apple.com/hk/app/id979659905 |
| Todoist Pro (mo) | HK$ 58.00 | 7.39 | 1.06 | https://apps.apple.com/hk/app/id572688855 |
| Day One Silver (mo) | HK$ 68.00 | 8.67 | 0.96 | https://apps.apple.com/hk/app/id1044867788 |
| (reference) Steam multi-variable recommendation for a $19.99 item | 105.00 HKD | 13.38 | 0.67 | https://partner.steamgames.com/pricing/explorer |

### UK (`gb`)

| Service | Local monthly price | USD | Ratio to US | Source |
|---|---|---|---|---|
| Apple Music | £11.99 | 16.00 | 1.33 | https://www.apple.com/uk/apple-music/ |
| Apple One | £18.95 | 25.29 | 1.15 | https://www.apple.com/uk/apple-one/ |
| Spotify Premium | £12.99 | 17.34 | 1.33 | https://www.spotify.com/uk/premium/ |
| Netflix Standard | £13.99 | 18.67 | 0.93 | https://help.netflix.com/en/node/24926/gb |
| YouTube Premium (iOS IAP) | £16.99 | 22.68 | 1.08 | https://apps.apple.com/gb/app/id544007664 |
| ChatGPT Plus (mo) | £19.99 | 26.68 | 1.33 | https://apps.apple.com/gb/app/id6448311069 |
| ChatGPT Go (mo) | £6.99 | 9.33 | 1.17 | https://apps.apple.com/gb/app/id6448311069 |
| Google AI Pro (mo) | £18.99 | 25.35 | 1.27 | https://apps.apple.com/gb/app/id6477489729 |
| M365 Personal (mo) | £8.49 | 11.33 | 1.13 | https://apps.apple.com/gb/app/id541164041 |
| M365 Premium (mo) | £18.99 | 25.35 | 1.27 | https://apps.apple.com/gb/app/id541164041 |
| Notion Plus (mo) | £11.99 | 16.00 | 1.33 | https://apps.apple.com/gb/app/id1232780281 |
| Spark Premium (mo) | £7.99 | 10.66 | 1.33 | https://apps.apple.com/gb/app/id997102246 |
| Spark Pro (mo) | £20.00 | 26.69 | 1.33 | https://apps.apple.com/gb/app/id997102246 |
| Fantastical Premium (mo) | £6.99 | 9.33 | 1.33 | https://apps.apple.com/gb/app/id718043190 |
| Airmail Pro (mo) | £3.99 | 5.33 | 1.33 | https://apps.apple.com/gb/app/id993160329 |
| Proton Mail Plus (mo) | £4.89 | 6.53 | 1.09 | https://apps.apple.com/gb/app/id979659905 |
| Todoist Pro (mo) | £6.99 | 9.33 | 1.33 | https://apps.apple.com/gb/app/id572688855 |
| Day One Silver (mo) | £8.99 | 12.00 | 1.33 | https://apps.apple.com/gb/app/id1044867788 |
| (reference) Steam multi-variable recommendation for a $19.99 item | 15.99 GBP | 21.34 | 1.07 | https://partner.steamgames.com/pricing/explorer |

### Germany (eurozone) (`de`)

| Service | Local monthly price | USD | Ratio to US | Source |
|---|---|---|---|---|
| Apple Music | 11,99 € | 13.41 | 1.12 | https://www.apple.com/de/apple-music/ |
| Apple One | 19,95 € | 22.32 | 1.02 | https://www.apple.com/de/apple-one/ |
| Spotify Premium | €12.99 | 14.53 | 1.12 | https://www.spotify.com/de-en/premium/ |
| Netflix Standard | €15.99 | 17.89 | 0.89 | https://help.netflix.com/en/node/24926/de |
| YouTube Premium (iOS IAP) | 19,99 € | 22.36 | 1.07 | https://apps.apple.com/de/app/id544007664 |
| ChatGPT Plus (mo) | 22,99 € | 25.72 | 1.29 | https://apps.apple.com/de/app/id6448311069 |
| ChatGPT Go (mo) | 7,99 € | 8.94 | 1.12 | https://apps.apple.com/de/app/id6448311069 |
| Google AI Pro (mo) | 21,99 € | 24.60 | 1.23 | https://apps.apple.com/de/app/id6477489729 |
| M365 Personal (mo) | 10,00 € | 11.19 | 1.12 | https://apps.apple.com/de/app/id541164041 |
| M365 Premium (mo) | 22,00 € | 24.61 | 1.23 | https://apps.apple.com/de/app/id541164041 |
| Notion Plus (mo) | 12,99 € | 14.53 | 1.21 | https://apps.apple.com/de/app/id1232780281 |
| Spark Premium (mo) | 7,99 € | 8.94 | 1.12 | https://apps.apple.com/de/app/id997102246 |
| Spark Pro (mo) | 22,00 € | 24.61 | 1.23 | https://apps.apple.com/de/app/id997102246 |
| Fantastical Premium (mo) | 7,99 € | 8.94 | 1.28 | https://apps.apple.com/de/app/id718043190 |
| Airmail Pro (mo) | 3,99 € | 4.46 | 1.12 | https://apps.apple.com/de/app/id993160329 |
| Proton Mail Plus (mo) | 5,99 € | 6.70 | 1.12 | https://apps.apple.com/de/app/id979659905 |
| Todoist Pro (mo) | 6,99 € | 7.82 | 1.12 | https://apps.apple.com/de/app/id572688855 |
| Day One Silver (mo) | 9,99 € | 11.18 | 1.24 | https://apps.apple.com/de/app/id1044867788 |
| (reference) Steam multi-variable recommendation for a $19.99 item | 19.49 EUR | 21.80 | 1.09 | https://partner.steamgames.com/pricing/explorer |

### Canada (`ca`)

| Service | Local monthly price | USD | Ratio to US | Source |
|---|---|---|---|---|
| Apple Music | $11.99 CAD | 8.55 | 0.71 | https://www.apple.com/ca/apple-music/ |
| Apple One | $22.95 CAD | 16.37 | 0.75 | https://www.apple.com/ca/apple-one/ |
| Spotify Premium | $13.99 CAD | 9.98 | 0.77 | https://www.spotify.com/ca-en/premium/ |
| Netflix Standard | CAD 18.99 | 13.55 | 0.68 | https://help.netflix.com/en/node/24926/ca |
| YouTube Premium (iOS IAP) | $16.99 | 12.12 | 0.58 | https://apps.apple.com/ca/app/id544007664 |
| ChatGPT Plus (mo) | $24.99 | 17.83 | 0.89 | https://apps.apple.com/ca/app/id6448311069 |
| ChatGPT Go (mo) | $12.99 | 9.27 | 1.16 | https://apps.apple.com/ca/app/id6448311069 |
| Google AI Pro (mo) | $26.99 | 19.26 | 0.96 | https://apps.apple.com/ca/app/id6477489729 |
| M365 Personal (mo) | $11.49 | 8.20 | 0.82 | https://apps.apple.com/ca/app/id541164041 |
| M365 Premium (mo) | $26.99 | 19.26 | 0.96 | https://apps.apple.com/ca/app/id541164041 |
| Notion Plus (mo) | $14.99 | 10.69 | 0.89 | https://apps.apple.com/ca/app/id1232780281 |
| Spark Premium (mo) | $9.99 | 7.13 | 0.89 | https://apps.apple.com/ca/app/id997102246 |
| Spark Pro (mo) | $25.00 | 17.84 | 0.89 | https://apps.apple.com/ca/app/id997102246 |
| Fantastical Premium (mo) | $9.99 | 7.13 | 1.02 | https://apps.apple.com/ca/app/id718043190 |
| Airmail Pro (mo) | $4.99 | 3.56 | 0.89 | https://apps.apple.com/ca/app/id993160329 |
| Proton Mail Plus (mo) | $7.49 | 5.34 | 0.89 | https://apps.apple.com/ca/app/id979659905 |
| Todoist Pro (mo) | $9.99 | 7.13 | 1.02 | https://apps.apple.com/ca/app/id572688855 |
| Day One Silver (mo) | $11.99 | 8.55 | 0.95 | https://apps.apple.com/ca/app/id1044867788 |
| (reference) Steam multi-variable recommendation for a $19.99 item | 24.99 CAD | 17.83 | 0.89 | https://partner.steamgames.com/pricing/explorer |

### Australia (`au`)

| Service | Local monthly price | USD | Ratio to US | Source |
|---|---|---|---|---|
| Apple Music | A$14.99 | 10.52 | 0.88 | https://www.apple.com/au/apple-music/ |
| Apple One | A$24.95 | 17.51 | 0.80 | https://www.apple.com/au/apple-one/ |
| Spotify Premium | A$15.99 | 11.22 | 0.86 | https://www.spotify.com/au/premium/ |
| Netflix Standard | AU$20.99 | 14.73 | 0.74 | https://help.netflix.com/en/node/24926/au |
| YouTube Premium (iOS IAP) | $22.99 | 16.14 | 0.77 | https://apps.apple.com/au/app/id544007664 |
| ChatGPT Plus (mo) | $29.99 | 21.05 | 1.05 | https://apps.apple.com/au/app/id6448311069 |
| ChatGPT Go (mo) | $13.00 | 9.13 | 1.14 | https://apps.apple.com/au/app/id6448311069 |
| Google AI Pro (mo) | $32.99 | 23.16 | 1.16 | https://apps.apple.com/au/app/id6477489729 |
| M365 Personal (mo) | $11.49 | 8.07 | 0.81 | https://apps.apple.com/au/app/id541164041 |
| M365 Premium (mo) | $33.00 | 23.16 | 1.16 | https://apps.apple.com/au/app/id541164041 |
| Notion Plus (mo) | $19.99 | 14.03 | 1.17 | https://apps.apple.com/au/app/id1232780281 |
| Spark Premium (mo) | $12.99 | 9.12 | 1.14 | https://apps.apple.com/au/app/id997102246 |
| Spark Pro (mo) | $30.00 | 21.06 | 1.05 | https://apps.apple.com/au/app/id997102246 |
| Fantastical Premium (mo) | $9.99 | 7.01 | 1.00 | https://apps.apple.com/au/app/id718043190 |
| Airmail Pro (mo) | $5.99 | 4.20 | 1.05 | https://apps.apple.com/au/app/id993160329 |
| Proton Mail Plus (mo) | $9.79 | 6.87 | 1.15 | https://apps.apple.com/au/app/id979659905 |
| Todoist Pro (mo) | $11.99 | 8.42 | 1.20 | https://apps.apple.com/au/app/id572688855 |
| Day One Silver (mo) | $14.99 | 10.52 | 1.17 | https://apps.apple.com/au/app/id1044867788 |
| (reference) Steam multi-variable recommendation for a $19.99 item | 28.30 AUD | 19.87 | 0.99 | https://partner.steamgames.com/pricing/explorer |

### Switzerland (`ch`)

| Service | Local monthly price | USD | Ratio to US | Source |
|---|---|---|---|---|
| Apple Music | CHF 14.90 | 18.02 | 1.50 | https://www.apple.com/chde/apple-music/ |
| Apple One | CHF 23.90 | 28.90 | 1.32 | https://www.apple.com/chde/apple-one/ |
| Spotify Premium | CHF 15.95 | 19.29 | 1.48 | https://www.spotify.com/ch-de/premium/ |
| Netflix Standard | CHF 22,90 | 27.69 | 1.39 | https://help.netflix.com/en/node/24926/ch |
| YouTube Premium (iOS IAP) | CHF 23.90 | 28.90 | 1.38 | https://apps.apple.com/ch/app/id544007664 |
| ChatGPT Plus (mo) | CHF 20.00 | 24.18 | 1.21 | https://apps.apple.com/ch/app/id6448311069 |
| ChatGPT Go (mo) | CHF 7.00 | 8.46 | 1.06 | https://apps.apple.com/ch/app/id6448311069 |
| Google AI Pro (mo) | CHF 17.00 | 20.55 | 1.03 | https://apps.apple.com/ch/app/id6477489729 |
| M365 Personal (mo) | CHF 9.95 | 12.03 | 1.20 | https://apps.apple.com/ch/app/id541164041 |
| M365 Premium (mo) | CHF 19.95 | 24.12 | 1.21 | https://apps.apple.com/ch/app/id541164041 |
| Notion Plus (mo) | CHF 12.00 | 14.51 | 1.21 | https://apps.apple.com/ch/app/id1232780281 |
| Spark Premium (mo) | CHF 8.50 | 10.28 | 1.29 | https://apps.apple.com/ch/app/id997102246 |
| Spark Pro (mo) | CHF 20.00 | 24.18 | 1.21 | https://apps.apple.com/ch/app/id997102246 |
| Fantastical Premium (mo) | CHF 7.00 | 8.46 | 1.21 | https://apps.apple.com/ch/app/id718043190 |
| Airmail Pro (mo) | CHF 3.00 | 3.63 | 0.91 | https://apps.apple.com/ch/app/id993160329 |
| Proton Mail Plus (mo) | CHF 6.40 | 7.74 | 1.29 | https://apps.apple.com/ch/app/id979659905 |
| Todoist Pro (mo) | CHF 7.00 | 8.46 | 1.21 | https://apps.apple.com/ch/app/id572688855 |
| Day One Silver (mo) | CHF 9.00 | 10.88 | 1.21 | https://apps.apple.com/ch/app/id1044867788 |
| (reference) Steam multi-variable recommendation for a $19.99 item | 19.99 CHF | 24.17 | 1.21 | https://partner.steamgames.com/pricing/explorer |

### Norway (`no`)

| Service | Local monthly price | USD | Ratio to US | Source |
|---|---|---|---|---|
| Apple Music | kr 139 | 14.91 | 1.24 | https://www.apple.com/no/apple-music/ |
| Apple One | kr 219 | 23.49 | 1.07 | https://www.apple.com/no/apple-one/ |
| Spotify Premium | 139 kr | 14.91 | 1.15 | https://www.spotify.com/no-en/premium/ |
| Netflix Standard | NOK 149 | 15.98 | 0.80 | https://help.netflix.com/en/node/24926/no |
| YouTube Premium (iOS IAP) | 219,00 kr | 23.49 | 1.12 | https://apps.apple.com/no/app/id544007664 |
| ChatGPT Plus (mo) | 249,00 kr | 26.71 | 1.34 | https://apps.apple.com/no/app/id6448311069 |
| ChatGPT Go (mo) | 99,00 kr | 10.62 | 1.33 | https://apps.apple.com/no/app/id6448311069 |
| Google AI Pro (mo) | 259,00 kr | 27.78 | 1.39 | https://apps.apple.com/no/app/id6477489729 |
| M365 Personal (mo) | 120,00 kr | 12.87 | 1.29 | https://apps.apple.com/no/app/id541164041 |
| M365 Premium (mo) | 259,00 kr | 27.78 | 1.39 | https://apps.apple.com/no/app/id541164041 |
| Notion Plus (mo) | 149,00 kr | 15.98 | 1.33 | https://apps.apple.com/no/app/id1232780281 |
| Spark Premium (mo) | 99,00 kr | 10.62 | 1.33 | https://apps.apple.com/no/app/id997102246 |
| Spark Pro (mo) | 249,00 kr | 26.71 | 1.34 | https://apps.apple.com/no/app/id997102246 |
| Fantastical Premium (mo) | 99,00 kr | 10.62 | 1.52 | https://apps.apple.com/no/app/id718043190 |
| Airmail Pro (mo) | 49,00 kr | 5.26 | 1.32 | https://apps.apple.com/no/app/id993160329 |
| Proton Mail Plus (mo) | 63,00 kr | 6.76 | 1.13 | https://apps.apple.com/no/app/id979659905 |
| Todoist Pro (mo) | 89,00 kr | 9.55 | 1.37 | https://apps.apple.com/no/app/id572688855 |
| Day One Silver (mo) | 99,00 kr | 10.62 | 1.18 | https://apps.apple.com/no/app/id1044867788 |
| (reference) Steam multi-variable recommendation for a $19.99 item | 210.00 NOK | 22.52 | 1.13 | https://partner.steamgames.com/pricing/explorer |

### Sri Lanka (`lk`)

| Service | Local monthly price | USD | Ratio to US | Source |
|---|---|---|---|---|
| Spotify Premium | LKR 749 | 2.26 | 0.17 | https://www.spotify.com/lk-en/premium/ |
| Netflix Standard | US$7.99 | 7.99 | 0.40 | https://help.netflix.com/en/node/24926/lk |
| YouTube Premium (iOS IAP) | USD 3.99 | 3.99 | 0.19 | https://apps.apple.com/lk/app/id544007664 |
| ChatGPT Plus (mo) | USD 19.99 | 19.99 | 1.00 | https://apps.apple.com/lk/app/id6448311069 |
| ChatGPT Go (mo) | USD 5.00 | 5.00 | 0.62 | https://apps.apple.com/lk/app/id6448311069 |
| Google AI Pro (mo) | USD 19.99 | 19.99 | 1.00 | https://apps.apple.com/lk/app/id6477489729 |
| M365 Personal (mo) | USD 9.99 | 9.99 | 1.00 | https://apps.apple.com/lk/app/id541164041 |
| M365 Premium (mo) | USD 22.99 | 22.99 | 1.15 | https://apps.apple.com/lk/app/id541164041 |
| Notion Plus (mo) | USD 11.99 | 11.99 | 1.00 | https://apps.apple.com/lk/app/id1232780281 |
| Spark Premium (mo) | USD 7.99 | 7.99 | 1.00 | https://apps.apple.com/lk/app/id997102246 |
| Spark Pro (mo) | USD 20.00 | 20.00 | 1.00 | https://apps.apple.com/lk/app/id997102246 |
| Fantastical Premium (mo) | USD 6.99 | 6.99 | 1.00 | https://apps.apple.com/lk/app/id718043190 |
| Airmail Pro (mo) | USD 3.99 | 3.99 | 1.00 | https://apps.apple.com/lk/app/id993160329 |
| Proton Mail Plus (mo) | USD 5.99 | 5.99 | 1.00 | https://apps.apple.com/lk/app/id979659905 |
| Todoist Pro (mo) | USD 6.99 | 6.99 | 1.00 | https://apps.apple.com/lk/app/id572688855 |
| Day One Silver (mo) | USD 8.99 | 8.99 | 1.00 | https://apps.apple.com/lk/app/id1044867788 |

### Nepal (`np`)

| Service | Local monthly price | USD | Ratio to US | Source |
|---|---|---|---|---|
| Spotify Premium | US$3.29 | 3.29 | 0.25 | https://www.spotify.com/np-en/premium/ |
| Netflix Standard | US$7.99 | 7.99 | 0.40 | https://help.netflix.com/en/node/24926/np |
| YouTube Premium (iOS IAP) | USD 5.29 | 5.29 | 0.25 | https://apps.apple.com/np/app/id544007664 |
| ChatGPT Plus (mo) | USD 19.99 | 19.99 | 1.00 | https://apps.apple.com/np/app/id6448311069 |
| ChatGPT Go (mo) | USD 5.69 | 5.69 | 0.71 | https://apps.apple.com/np/app/id6448311069 |
| Google AI Pro (mo) | USD 19.99 | 19.99 | 1.00 | https://apps.apple.com/np/app/id6477489729 |
| M365 Personal (mo) | USD 7.99 | 7.99 | 0.80 | https://apps.apple.com/np/app/id541164041 |
| M365 Premium (mo) | USD 19.99 | 19.99 | 1.00 | https://apps.apple.com/np/app/id541164041 |
| Notion Plus (mo) | USD 14.99 | 14.99 | 1.25 | https://apps.apple.com/np/app/id1232780281 |
| Spark Premium (mo) | USD 9.99 | 9.99 | 1.25 | https://apps.apple.com/np/app/id997102246 |
| Spark Pro (mo) | USD 25.00 | 25.00 | 1.25 | https://apps.apple.com/np/app/id997102246 |
| Fantastical Premium (mo) | USD 6.99 | 6.99 | 1.00 | https://apps.apple.com/np/app/id718043190 |
| Airmail Pro (mo) | USD 4.99 | 4.99 | 1.25 | https://apps.apple.com/np/app/id993160329 |
| Proton Mail Plus (mo) | USD 5.99 | 5.99 | 1.00 | https://apps.apple.com/np/app/id979659905 |
| Todoist Pro (mo) | USD 7.99 | 7.99 | 1.14 | https://apps.apple.com/np/app/id572688855 |
| Day One Silver (mo) | USD 9.99 | 9.99 | 1.11 | https://apps.apple.com/np/app/id1044867788 |
