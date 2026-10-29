---
name: meta-ads-campaign
description: Use when setting up, reviewing or scaling a Meta (Facebook/Instagram) ad campaign — "run ads to this URL", "set up a Facebook campaign", "how are my ads doing". Interviews, drafts the campaign, then builds it paused via the meta-ads-api skill.
---

# Meta Ads Campaign

Interview → draft the spec → hand to `meta-ads-api` to build it **paused** → report the Ads Manager link and stop.

This skill holds the judgment and issues no API calls. The `meta-ads-api` skill owns the mechanism and ships from the `meta-ads-setup` repo's seed, not from here — **if it isn't installed, say so and stop.** Never hand-roll Graph API calls; that discards the paused-by-default guarantee everything below rests on.

It runs in reverse too, judging live results against the same three tests: is the destination instrumented, is the ad set out of learning, is the sample big enough to act on.

## Priority

- `§ Preflight the destination — before anything else`
- `§ Interview`
- `§ Objective, and the volume math that picks it`
- `§ Hand off, and stop`

## Preflight the destination — before anything else

Drive the destination in a real browser — the `playwright` skill reads console and network — and confirm, in order:

- **Accept** any consent banner first, not dismiss it — closing the banner leaves the pixel gated, so a silent network panel proves nothing.
- Triggering the paid-for action emits a **conversion** request (`/tr?ev=Lead`-class), not just the base `PageView`. Grepping the HTML for `fbq` shows the pixel is present, never that it fires; that is not evidence.
- The event that fires is the one being paid for (Lead / Purchase / Contact).
- The CTA resolves to what the copy promises. A "book a call" ad landing on a homepage is a broken funnel, not a copy problem.

Run this against the **real destination the ad will point at** — a staging clone proves the wiring exists somewhere, not that the URL you are buying traffic to is instrumented, which is the whole question. Use Meta's test-event code so the fired event is attributable and excluded from optimization.

Two different limits, split by who bears the result. **Ask first** for anything landing in the operator's own world — a form that emails them, a lead in their CRM — since the mess is theirs to clean up and theirs to authorize. **Never complete** anything that commits them or reaches someone else — a purchase, a booking, a message to a third party — **consent or not**. Their permission does not unlock this half: not for a charge they will only see on a statement, and not at all for a stranger, whose consent is not theirs to give. Fire the safe step before it instead (`InitiateCheckout`, `AddPaymentInfo`, opening the booking form) — but that proves the funnel *runs*, not that the paid-for event fires; that evidence still has to come from their console.

**What you need is evidence that the paid-for event fires for this destination, now.** Watch it leave the browser where you can. Where you cannot — a Conversions API destination emits nothing client-side, and some events cannot be fired without a real side effect — the evidence lives in the operator's Events Manager, which this skill cannot read: ask, take the artifact rather than an assurance, and say plainly in your report which part you observed and which you took on trust. Weigh it honestly; a count from before the current checkout shipped is not evidence about the funnel you are buying traffic to.

**If you cannot establish that the event fires for this destination, it is unresolved** — blocked, gated, or uninstrumented, and a silent network panel cannot tell you which. Unresolved trips the hard stop below exactly as "no event" does: why you cannot see it does not change that you cannot measure the spend.

**Refuse to publish if no conversion event is wired.** This is the hard stop. A prior effort bought 6,612 landing page views and recorded 5 actions precisely because nothing downstream of the click was instrumented — the spend could not tell anyone anything they could act on. Fixing the destination is cheaper than any creative test.

## Interview

Ask for what's missing; never invent it.

- **Destination** — the URL, its pixel ID, and the conversion event verified above. Collected first, since preflight runs before the rest.
- **Offer** — what it is, price, who it's for.
- **Audience** — countries, age band, anything qualifying.
- **Budget** — daily, and how long they'll let it run before judging.
- **Creative on hand** — what exists today vs. what has to be made.
- **Page and ad account** — which Page posts the ad, which account pays. Never assume either. Ask for the account **id**, not its name: a token typically reaches several accounts and names are routinely duplicated across them, so a name is not an answer.

## Objective, and the volume math that picks it

Meta wants roughly **50 conversions per ad set per week** to exit the learning phase. Below that, delivery is erratic and the optimizer trains on noise — you are paying for randomness and reading it as signal.

Do the arithmetic out loud with the operator's real budget: `daily_budget × 7 ÷ expected cost-per-conversion`. If that lands well under 50, a conversion objective cannot work yet.

- **Start on Traffic** while the already-firing conversion event accumulates volume — clicks are cheap and plentiful enough to leave learning honestly. The hard stop above binds every objective including Traffic; "accumulating events" never means deferring instrumentation.
- **Move to Leads/Conversions** only once the math clears ~50/week per ad set.

## The 1:1:1 tension

One campaign : one ad set : one ad per creative gives a clean read on which creative wins. That is right **on Traffic**, where volume per ad set is cheap.

It is actively harmful on a conversion objective: splitting a small budget across N ad sets means **none** reaches 50 conversions/week, so all of them stay in learning and none of the comparisons mean anything. When you switch objective, consolidate — one ad set, several ads inside it, and let Meta allocate.

## Creative, carried as method — not as numbers

From 15 days of real spend, best to worst: **screenshot / social-proof stills ≫ product video ≫ designed product statics ≫ event creative** (~40% of spend, worst on every metric).

**Provenance, and it is load-bearing:** those results came from a *Brazilian* audience on a *different* ad account, priced in BRL. The winner was a WhatsApp group-chat mockup, and WhatsApp is near-universal in Brazil — so the transferable claim is not "use WhatsApp screenshots", it is **a screenshot of a familiar interface carrying real text beats a designed marketing asset**. The US analogue is iMessage, Slack, or Reddit. Carry the ordering as the first hypothesis to test, never as a benchmark to hit or a number to quote.

**Synthesize the conversation; never screenshot a real one.** This section steers toward mockups of real interfaces, and a genuine thread carries names, avatars, handles, and message content belonging to people who did not agree to appear in an ad. Write the text, or get each participant's explicit consent and strip names, avatars, handles and contact details first.

**Check the publisher can actually ship the format before recommending it.** Ask `meta-ads-api` which creative types it builds — at time of writing that is narrower than this ranking, so a recommended still may have to be built by hand in Ads Manager. Never hand over a spec whose creative type it cannot produce: it will publish something else without complaining, and automating the publish of the weakest format while believing it shipped the strongest is worse than publishing nothing.

## Derive the budget floor; never copy one

A floor is computed:

`daily floor = target cost-per-result × results needed to decide ÷ days you'll wait`

If the window cannot produce enough results to separate two creatives, the test cannot conclude and the money buys an unreadable answer. The only three levers are: raise the budget, lengthen the window, cut the number of variants.

The prior playbook's R$20/day per ad set is a few US dollars — single-digit clicks per day at US CPCs. Do not carry it over; it yields no readable result at any duration an operator will actually wait.

## Hand off, and stop

Call `meta-ads-api` with the drafted spec; it owns what gets built, in what order, and how the account is identified. Read its skill for that contract rather than assuming it here — restating it is how the two drift.

What this skill requires of the result: every object lands **paused**, confirmed from what it reports rather than asserted, and a link the operator can open to review the campaign. If anything is not paused, surface the object IDs and say so instead of claiming a safe result.

**Never activate as part of setup.** Creating paused objects is free and deletable; activation commits real money and is the operator's call. Report the link, say what you'd watch first, and stop. Activation is a separate step, taken only when explicitly asked for.
