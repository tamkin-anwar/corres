# Regional pricing

Set in App Store Connect on 2026-10-27 for both Pro subscriptions
(`pro.monthly`, `pro.annual`), in all 175 App Store countries. The US stays
$20 a month and $200 a year. Bangladesh has no App Store, so it has no price;
people there use an account from another country.

## Why

Apple's default prices are the US price at exchange rates, which made Pro
₹1,999 a month in India, Rs 4,900 in Pakistan and EGP 999.99 in Egypt. Music
and video services charge 0.1 to 0.4 of their US price in those markets;
productivity apps mostly don't discount at all. We meet in between, the way
Valve recommends for Steam, the one published method with numbers behind it.

## How each price was chosen

1. Start from Apple's price for that country (it already includes local tax).
2. Multiply by the square root of the country's price level against the US
   (World Bank 2025: PPP conversion factor over the exchange rate).
   - Never below half of Apple's price, never above it.
   - Incomes under $15k a person (at purchasing power): price level at most 0.3.
     $15k to $25k: at most 0.5. This keeps places with costly imports and low
     pay (Pacific islands, Malawi, Haiti) from getting almost no discount.
   - Incomes over $50k: at least 85% of Apple's price. Rich countries with weak
     currencies (Japan, Korea, Singapore) get a small discount, not a large one.
   - Set by hand: Taiwan (level 0.44, income $79k, IMF 2025, not in World Bank
     data), Kosovo (average of Albania, North Macedonia, Serbia), Bulgaria
     (0.5; World Bank's 2025 figures mix currencies after the euro switch),
     Guyana (income treated as $20k; oil output inflates the average),
     Zimbabwe, Venezuela, Yemen, Turkmenistan (half), Anguilla, Montserrat,
     British Virgin Islands (Apple's price).
3. Round to an Apple price point that looks normal there: .99 for most
   currencies, the cents Apple itself uses where they differ (R$89,90,
   S$25.98), whole numbers where those are the norm (₹999, ¥2,600,
   Rp 199.000, MX$299), and endings in 8 in China and Hong Kong (¥98, HK$128).
4. Yearly is ten months of monthly, as in the US, on the nearest normal price.

## Before changing prices after launch

A price cut reaches every subscriber at once and can't be undone for them. A
large rise needs each subscriber's consent. Apple never updates subscription
prices for exchange rates or tax, so look at this again about once a year.

Research, with a source for every benchmark price: [regional-pricing-research.md](regional-pricing-research.md).

## Prices

| Country | Currency | Was (month / year) | Now (month / year) | Share of Apple's price |
|---|---|---|---|---|
| AFG | USD | 20 / 200 | 9.99 / 99.99 | 50% |
| AGO | USD | 20 / 200 | 9.99 / 99.99 | 50% |
| AIA | USD | 20 / 200 | 19.99 / 199.99 | 100% |
| ALB | USD | 25 / 250 | 16.99 / 169.99 | 68% |
| ARE | AED | 79.99 / 799.99 | 69.99 / 699.99 | 87% |
| ARG | USD | 20 / 200 | 12.99 / 129.99 | 65% |
| ARM | USD | 25 / 250 | 14.99 / 149.99 | 60% |
| ATG | USD | 20 / 200 | 16.99 / 169.99 | 85% |
| AUS | AUD | 30 / 300 | 28.99 / 289.99 | 97% |
| AUT | EUR | 22 / 229 | 19.99 / 199.99 | 91% |
| AZE | USD | 25 / 250 | 12.99 / 129.99 | 52% |
| BEL | EUR | 22 / 229 | 19.99 / 199.99 | 91% |
| BEN | USD | 25 / 250 | 13.99 / 139.99 | 56% |
| BFA | USD | 20 / 200 | 9.99 / 99.99 | 50% |
| BGR | EUR | 22 / 229 | 15.99 / 159.99 | 73% |
| BHR | USD | 22 / 200 | 18.99 / 189.99 | 86% |
| BHS | USD | 22 / 200 | 19.99 / 199.99 | 91% |
| BIH | EUR | 22 / 229 | 13.99 / 139.99 | 64% |
| BLR | USD | 25 / 250 | 13.99 / 139.99 | 56% |
| BLZ | USD | 20 / 200 | 9.99 / 99.99 | 50% |
| BMU | USD | 20 / 200 | 19.99 / 199.99 | 100% |
| BOL | USD | 20 / 200 | 9.99 / 99.99 | 50% |
| BRA | BRL | 129.9 / 1,299.9 | 89.9 / 899.9 | 69% |
| BRB | USD | 25 / 250 | 24.99 / 249.99 | 100% |
| BRN | USD | 20 / 200 | 16.99 / 169.99 | 85% |
| BTN | USD | 20 / 200 | 9.99 / 99.99 | 50% |
| BWA | USD | 20 / 200 | 11.99 / 119.99 | 60% |
| CAN | CAD | 25 / 249 | 22.99 / 229.99 | 92% |
| CHE | CHF | 18 / 180 | 18 / 180 | 100% |
| CHL | CLP | 22,990 / 229,990 | 15,990 / 159,900 | 70% |
| CHN | CNY | 148 / 1,298 | 98 / 998 | 66% |
| CIV | USD | 25 / 250 | 13.99 / 139.99 | 56% |
| CMR | USD | 25 / 250 | 13.99 / 139.99 | 56% |
| COD | USD | 20 / 200 | 9.99 / 99.99 | 50% |
| COG | USD | 25 / 250 | 13.99 / 139.99 | 56% |
| COL | COP | 99,900 / 999,900 | 59,900 / 599,000 | 60% |
| CPV | USD | 20 / 200 | 9.99 / 99.99 | 50% |
| CRI | USD | 20 / 200 | 14.99 / 149.99 | 75% |
| CYM | USD | 20 / 200 | 19.99 / 199.99 | 100% |
| CYP | EUR | 22 / 229 | 18.99 / 189.99 | 86% |
| CZE | CZK | 499 / 4,990 | 399 / 3,990 | 80% |
| DEU | EUR | 22 / 229 | 19.99 / 199.99 | 91% |
| DMA | USD | 20 / 200 | 13.99 / 139.99 | 70% |
| DNK | DKK | 179 / 1,799 | 169 / 1,690 | 94% |
| DOM | USD | 20 / 200 | 11.99 / 119.99 | 60% |
| DZA | USD | 20 / 200 | 10.99 / 109.99 | 55% |
| ECU | USD | 20 / 200 | 12.99 / 129.99 | 65% |
| EGY | EGP | 999.99 / 9,999.99 | 499.99 / 4,999.99 | 50% |
| ESP | EUR | 22 / 229 | 18.99 / 189.99 | 86% |
| EST | EUR | 22 / 229 | 18.99 / 189.99 | 86% |
| FIN | EUR | 22 / 229 | 19.99 / 199.99 | 91% |
| FJI | USD | 20 / 200 | 12.99 / 129.99 | 65% |
| FRA | EUR | 22 / 229 | 18.99 / 189.99 | 86% |
| FSM | USD | 20 / 200 | 9.99 / 99.99 | 50% |
| GAB | USD | 20 / 200 | 11.99 / 119.99 | 60% |
| GBR | GBP | 20 / 200 | 18.99 / 189.99 | 95% |
| GEO | USD | 25 / 250 | 13.99 / 139.99 | 56% |
| GHA | USD | 25 / 250 | 13.99 / 139.99 | 56% |
| GMB | USD | 20 / 200 | 9.99 / 99.99 | 50% |
| GNB | USD | 20 / 200 | 9.99 / 99.99 | 50% |
| GRC | EUR | 22 / 229 | 16.99 / 169.99 | 77% |
| GRD | USD | 20 / 200 | 13.99 / 139.99 | 70% |
| GTM | USD | 20 / 200 | 12.99 / 129.99 | 65% |
| GUY | USD | 20 / 200 | 10.99 / 109.99 | 55% |
| HKG | HKD | 148 / 1,488 | 128 / 1,298 | 86% |
| HND | USD | 20 / 200 | 9.99 / 99.99 | 50% |
| HRV | EUR | 22 / 229 | 18.99 / 189.99 | 86% |
| HUN | HUF | 8,990 / 89,990 | 6,490 / 64,900 | 72% |
| IDN | IDR | 399,000 / 3,999,000 | 199,000 / 1,999,000 | 50% |
| IND | INR | 1,999 / 19,900 | 999 / 9,999 | 50% |
| IRL | EUR | 22 / 229 | 19.99 / 199.99 | 91% |
| IRQ | USD | 20 / 200 | 9.99 / 99.99 | 50% |
| ISL | USD | 25 / 250 | 24.99 / 249.99 | 100% |
| ISR | ILS | 59.9 / 599.9 | 59.9 / 599.9 | 100% |
| ITA | EUR | 22 / 229 | 18.99 / 189.99 | 86% |
| JAM | USD | 20 / 200 | 9.99 / 99.99 | 50% |
| JOR | USD | 20 / 200 | 9.99 / 99.99 | 50% |
| JPN | JPY | 3,000 / 30,000 | 2,600 / 26,000 | 87% |
| KAZ | KZT | 11,990 / 119,990 | 6,990 / 69,990 | 58% |
| KEN | USD | 25 / 250 | 13.99 / 139.99 | 56% |
| KGZ | USD | 22 / 200 | 11.99 / 119.99 | 55% |
| KHM | USD | 22 / 200 | 11.99 / 119.99 | 55% |
| KNA | USD | 20 / 200 | 16.99 / 169.99 | 85% |
| KOR | KRW | 33,000 / 349,000 | 28,000 / 280,000 | 85% |
| KWT | USD | 20 / 200 | 16.99 / 169.99 | 85% |
| LAO | USD | 22 / 200 | 9.99 / 99.99 | 45% |
| LBN | USD | 20 / 200 | 9.99 / 99.99 | 50% |
| LBR | USD | 20 / 200 | 9.99 / 99.99 | 50% |
| LBY | USD | 20 / 200 | 11.99 / 119.99 | 60% |
| LCA | USD | 20 / 200 | 13.99 / 139.99 | 70% |
| LKA | USD | 20 / 200 | 9.99 / 99.99 | 50% |
| LTU | EUR | 22 / 229 | 18.99 / 189.99 | 86% |
| LUX | EUR | 22 / 229 | 19.99 / 199.99 | 91% |
| LVA | EUR | 22 / 229 | 16.99 / 169.99 | 77% |
| MAC | USD | 20 / 200 | 16.99 / 169.99 | 85% |
| MAR | USD | 25 / 250 | 13.99 / 139.99 | 56% |
| MDA | USD | 25 / 250 | 15.99 / 159.99 | 64% |
| MDG | USD | 20 / 200 | 9.99 / 99.99 | 50% |
| MDV | USD | 20 / 200 | 13.99 / 139.99 | 70% |
| MEX | MXN | 399 / 3,999 | 299 / 2,999 | 75% |
| MKD | USD | 20 / 200 | 11.99 / 119.99 | 60% |
| MLI | USD | 20 / 200 | 9.99 / 99.99 | 50% |
| MLT | EUR | 22 / 229 | 18.99 / 189.99 | 86% |
| MMR | USD | 20 / 200 | 9.99 / 99.99 | 50% |
| MNE | EUR | 20 / 200 | 12.99 / 129.99 | 65% |
| MNG | USD | 20 / 200 | 11.99 / 119.99 | 60% |
| MOZ | USD | 20 / 200 | 9.99 / 99.99 | 50% |
| MRT | USD | 20 / 200 | 9.99 / 99.99 | 50% |
| MSR | USD | 20 / 200 | 19.99 / 199.99 | 100% |
| MUS | USD | 25 / 250 | 15.99 / 159.99 | 64% |
| MWI | USD | 20 / 200 | 9.99 / 99.99 | 50% |
| MYS | MYR | 99.9 / 999.9 | 49.9 / 499.9 | 50% |
| NAM | USD | 20 / 200 | 9.99 / 99.99 | 50% |
| NER | USD | 20 / 200 | 9.99 / 99.99 | 50% |
| NGA | NGN | 29,900 / 299,900 | 14,900 / 149,000 | 50% |
| NIC | USD | 20 / 200 | 9.99 / 99.99 | 50% |
| NLD | EUR | 22 / 229 | 19.99 / 199.99 | 91% |
| NOR | NOK | 249 / 2,490 | 239 / 2,390 | 96% |
| NPL | USD | 25 / 250 | 11.99 / 119.99 | 48% |
| NRU | USD | 20 / 200 | 9.99 / 99.99 | 50% |
| NZL | NZD | 40 / 400 | 37.99 / 379.99 | 95% |
| OMN | USD | 20 / 200 | 13.99 / 139.99 | 70% |
| PAK | PKR | 4,900 / 49,900 | 2,499 / 24,999 | 51% |
| PAN | USD | 20 / 200 | 12.99 / 129.99 | 65% |
| PER | PEN | 89.9 / 899.9 | 59.9 / 599.9 | 67% |
| PHL | PHP | 1,290 / 12,990 | 699 / 6,990 | 54% |
| PLW | USD | 20 / 200 | 13.99 / 139.99 | 70% |
| PNG | USD | 20 / 200 | 9.99 / 99.99 | 50% |
| POL | PLN | 99.99 / 999.99 | 79.99 / 799.99 | 80% |
| PRT | EUR | 22 / 229 | 18.99 / 189.99 | 86% |
| PRY | USD | 20 / 200 | 11.99 / 119.99 | 60% |
| QAT | QAR | 69.99 / 699.99 | 59.99 / 599.99 | 86% |
| ROU | RON | 99.99 / 999.99 | 79.99 / 799.99 | 80% |
| RUS | RUB | 1,790 / 17,990 | 999 / 9,990 | 56% |
| RWA | USD | 20 / 200 | 9.99 / 99.99 | 50% |
| SAU | SAR | 89.99 / 899.99 | 69.99 / 699.99 | 78% |
| SEN | USD | 25 / 250 | 13.99 / 139.99 | 56% |
| SGP | SGD | 29.98 / 299.98 | 25.98 / 259.98 | 87% |
| SLB | USD | 20 / 200 | 9.99 / 99.99 | 50% |
| SLE | USD | 20 / 200 | 9.99 / 99.99 | 50% |
| SLV | USD | 20 / 200 | 9.99 / 99.99 | 50% |
| SRB | EUR | 22 / 229 | 14.99 / 149.99 | 68% |
| STP | USD | 20 / 200 | 9.99 / 99.99 | 50% |
| SUR | USD | 22 / 200 | 11.99 / 119.99 | 55% |
| SVK | EUR | 22 / 229 | 16.99 / 169.99 | 77% |
| SVN | EUR | 22 / 229 | 18.99 / 189.99 | 86% |
| SWE | SEK | 249 / 2,495 | 239 / 2,390 | 96% |
| SWZ | USD | 20 / 200 | 9.99 / 99.99 | 50% |
| SYC | USD | 20 / 200 | 14.99 / 149.99 | 75% |
| TCA | USD | 20 / 200 | 19.99 / 199.99 | 100% |
| TCD | USD | 20 / 200 | 9.99 / 99.99 | 50% |
| THA | THB | 699 / 6,990 | 390 / 3,900 | 56% |
| TJK | USD | 22 / 200 | 10.99 / 109.99 | 50% |
| TKM | USD | 20 / 200 | 9.99 / 99.99 | 50% |
| TON | USD | 20 / 200 | 9.99 / 99.99 | 50% |
| TTO | USD | 20 / 200 | 13.99 / 139.99 | 70% |
| TUN | USD | 20 / 200 | 9.99 / 99.99 | 50% |
| TUR | TRY | 999.99 / 9,999.99 | 649.99 / 6,499.99 | 65% |
| TWN | TWD | 690 / 6,990 | 599 / 5,990 | 87% |
| TZA | TZS | 59,900 / 599,900 | 29,900 / 299,000 | 50% |
| UGA | USD | 25 / 250 | 13.99 / 139.99 | 56% |
| UKR | USD | 25 / 250 | 13.99 / 139.99 | 56% |
| URY | USD | 20 / 200 | 15.99 / 159.99 | 80% |
| USA | USD | 20 / 200 | 20 / 200 | 100% |
| UZB | USD | 22 / 200 | 11.99 / 119.99 | 55% |
| VCT | USD | 20 / 200 | 13.99 / 139.99 | 70% |
| VEN | USD | 20 / 200 | 9.99 / 99.99 | 50% |
| VGB | USD | 20 / 200 | 19.99 / 199.99 | 100% |
| VNM | VND | 599,000 / 5,999,000 | 299,000 / 2,990,000 | 50% |
| VUT | USD | 20 / 200 | 9.99 / 99.99 | 50% |
| XKS | EUR | 22 / 229 | 13.99 / 139.99 | 64% |
| YEM | USD | 20 / 200 | 9.99 / 99.99 | 50% |
| ZAF | ZAR | 399.99 / 3,999.99 | 249.99 / 2,499.99 | 62% |
| ZMB | USD | 25 / 250 | 13.99 / 139.99 | 56% |
| ZWE | USD | 25 / 250 | 11.99 / 119.99 | 48% |
