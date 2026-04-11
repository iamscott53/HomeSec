# Social enrichment — design

This is the most contentious subsystem in the detection stack, and the design deliberately ships with the most restrictive defaults of any component. This doc spells out what it does, what it explicitly does not do, the legal and ethical posture, and the three discrete modes the analyzer exposes.

## TL;DR

The analyzer supports three modes of "social enrichment" around recognized people. **Only Mode A is enabled by default.** Mode B is a manual helper; the operator clicks a button to trigger it per-face. Mode C is a stub for a paid third-party API that ships disabled and requires operator configuration before it does anything.

| Mode | What it does | Default state | Third-party cost | ToS risk |
|---|---|---|---|---|
| **A. Linked profiles** | Surface social handles the operator enrolled manually. | Enabled | None | None |
| **B. Manual reverse-search helper** | One-click open Google Lens / Bing Visual Search with the face crop pre-uploaded. Operator decides per face. | Disabled — operator toggles. | None | Low (manual, no automation) |
| **C. Third-party face-search API stub** | Optional integration with a paid third-party face-search service (PimEyes / FaceCheck.ID / similar). Operator supplies API key. | Disabled & unconfigured | Yes (violates "zero subscriptions" rule) | Depends on service |

## Hard rules the analyzer enforces

These are not suggestions. The code in `homesec-cameras-analyzer` must implement all of these:

1. **No automated scraping of social media platforms.** Not Facebook, Instagram, X, LinkedIn, TikTok, Snapchat, Threads, Mastodon, or anything else with user-generated content. Zero exceptions.
2. **No sending face crops to any third-party service without an explicit, per-call operator action.** Mode B requires a click per face. Mode C requires an API key configured by the operator plus a confirmation dialog per call.
3. **No storing third-party API responses longer than the DB row that represents the match.** No caching of scraped profile data, no background crawl, no periodic re-fetching.
4. **No sending face crops or embeddings outside the LAN at all in Mode A.** Mode A is purely local: it looks up `persons.social_handles_json` in the analyzer's own DB and surfaces that JSON to the frontend. Nothing leaves the house.
5. **No face crops sent to Mode B or Mode C services for people whose `persons.display_name` is null** unless the operator confirms. This prevents "I clicked reverse-search and it sent data for 14 strangers at once" — the UI only exposes the button per face, never per cluster-batch.
6. **Log every Mode B and Mode C invocation** to the analyzer's audit table with operator identifier, timestamp, person_id, and destination service. Audit log is append-only.

## Mode A — Linked profiles (enabled by default)

This is the safe, trivial mode. During enrollment (see [`face-recognition-design.md`](./face-recognition-design.md)), the operator can attach social handles to an enrolled person:

```json
{
  "display_name": "Alice",
  "social_handles": [
    {"platform": "instagram", "handle": "@alice_example", "url": "https://instagram.com/alice_example"},
    {"platform": "linkedin",  "handle": "alice-example",  "url": "https://linkedin.com/in/alice-example"}
  ],
  "notes": "my sister"
}
```

The analyzer does nothing with these handles automatically. It just stores them and serves them back to the frontend. When Alice is recognized in an event, the event's alert payload and the frontend's event detail view surface the linked profiles as clickable links. That's it.

No automation. No scraping. No API calls. No "fetch her latest post" feature. Just a cleaner way to remember "Alice's Instagram is @alice_example".

**Legal/ethical status:** Trivial. It's a phone book. The operator enters the data themselves.

## Mode B — Manual reverse-search helper (operator toggles)

This mode is **off by default** and is toggled on in the analyzer config. When on, the frontend shows a "Reverse-search this face" button on the detail page of any face crop (enrolled or unknown). Clicking the button:

1. Prompts the operator: "This will open a new browser tab on your device and upload the face crop to Google Lens / Bing Visual Search. The image is sent directly from your browser to the search provider, not through the analyzer. Continue?"
2. On confirmation, opens a new tab to `https://lens.google.com/` or `https://www.bing.com/visualsearch` with the image file attached via form POST from the browser.
3. Logs the invocation to the audit table.
4. Does **nothing else**. The operator reviews the search results manually.

**Why the browser, not the analyzer?** Two reasons:

1. The face crop never touches the analyzer's outbound network path. The operator's browser is the data origin, not the analyzer.
2. It keeps the operator fully in the loop. Nothing happens in the background.

**Legal/ethical status:** Low risk. It's functionally equivalent to the operator manually right-clicking "Search image with Google" in their own browser. No ToS violation because no automated request; the operator is the request. No storage of the remote response because there is no remote response — Google / Bing render the results in the operator's own tab.

**What this cannot do:** Find someone on social media. Neither Google Lens nor Bing Visual Search does facial similarity — they do image similarity. If the operator uploads a cam-grabbed face crop, the search results will mostly be other cam-grabbed face crops, stock photos, or unrelated images that share low-level features. This mode is **unlikely to identify anyone**. Expectations should be managed accordingly.

## Mode C — Third-party API stub (disabled, requires operator config)

This mode is **shipped disabled and unconfigured**. It exists as an integration point for the operator to wire in a paid third-party face-search service (e.g., PimEyes, FaceCheck.ID, or similar) at their own risk, reading the service's ToS themselves and supplying their own API key.

**The analyzer will not enable this mode automatically.** The operator must:

1. Read the ToS of the third-party service they want to use.
2. Decide whether their use case (identifying strangers from their home cameras) is compatible with that ToS.
3. Create a paid account and obtain an API key.
4. Add `social_enrichment.third_party.enabled: true` and `social_enrichment.third_party.api_key_env: HOMESEC_THIRD_PARTY_FACE_KEY` to `/etc/homesec-cameras-analyzer/config.yaml`.
5. Set the environment variable in the systemd unit override.
6. Restart the analyzer.

The analyzer exposes a `POST /api/persons/<id>/third-party-search` endpoint. Calling it:

1. Confirms Mode C is enabled and the API key is present. If not, returns 409.
2. Checks that `persons[id].display_name` is null (only unknown clusters get searched) OR that the operator passed an explicit `--override-enrolled` flag. This prevents accidental searches of known family members.
3. Reads the best-quality face crop for the person from disk.
4. Sends it to the configured third-party service.
5. Writes the response to the `third_party_search_results` table with a TTL.
6. Writes an audit row.
7. Returns the response to the frontend, which shows it inline as "3rd-party match candidates" with a big disclaimer about accuracy and privacy.

This mode **conflicts with the repo's "zero subscriptions" and "zero cloud" hard requirements**. It exists only because the operator explicitly asked for it and understands the conflict. The frontend banner makes this conflict visible every time a Mode C result is shown.

**Legal/ethical status:** High risk. The operator is on the hook for ToS compliance and for whatever their jurisdiction says about running unauthorized face searches against third parties. The analyzer does not make this easier, and it logs every call for audit.

## Data model additions

One new table in the analyzer's SQLite DB for the audit trail:

### `social_enrichment_audit`

| Column | Type | Notes |
|---|---|---|
| `id` | INTEGER PRIMARY KEY | |
| `person_id` | TEXT FK → persons.id | |
| `mode` | TEXT | `A_linked` / `B_reverse_search` / `C_third_party` |
| `destination` | TEXT NULL | `google_lens`, `bing_visual`, `pimeyes`, etc. NULL for Mode A. |
| `requested_at` | TIMESTAMP | |
| `requested_by` | TEXT | Operator identifier from the frontend session. |
| `result_summary` | TEXT NULL | Short summary of the outcome. |
| `correlation_id` | TEXT NULL | Client-supplied for linking to frontend state. |

Append-only. Never deleted.

And one table for Mode C result caching (TTL-bounded):

### `third_party_search_results`

| Column | Type | Notes |
|---|---|---|
| `id` | INTEGER PRIMARY KEY | |
| `person_id` | TEXT FK → persons.id | |
| `service` | TEXT | Which third-party service. |
| `requested_at` | TIMESTAMP | |
| `expires_at` | TIMESTAMP | Hard TTL. Row is deleted after this. Default 24h. |
| `result_json` | TEXT | Raw response from the service. |
| `result_summary` | TEXT | Human-readable summary rendered in the frontend. |

## What the frontend shows

In the person detail view, three separate panels:

1. **Linked profiles** — a list of social handles from `persons.social_handles_json`, clickable. Empty if the operator hasn't linked anything. Visible for enrolled people only.
2. **Reverse-search** (only visible if Mode B is enabled in config) — a button "Open Google Lens" / "Open Bing Visual Search". Opens in a new tab.
3. **Third-party search** (only visible if Mode C is enabled and configured) — a button "Search via <service>". Surrounded by a large warning banner noting: "This will send the face crop to <service>. This call may be subject to their ToS. Calls are logged. Continue?"

## What the analyzer refuses to do, no matter what

Hard-coded refusals in the code:

- **Scraping.** No HTTP client in the analyzer calls `facebook.com`, `instagram.com`, `twitter.com`, `x.com`, `linkedin.com`, `tiktok.com`, or any similar platform with user-generated content. Add these to a blocklist in the HTTP client.
- **Automated Mode B or C.** No cron job, no background task, no "search all unknown faces nightly". Every call is operator-initiated.
- **Uploading raw embedding vectors to any third-party service.** Mode C sends face crops only, never ArcFace vectors.
- **Sharing face crops, embeddings, or audit data between HomeSec installations.** There is no "network effect" feature. The DB is single-tenant, single-home.

These refusals are enforced in code, not just documentation. When the analyzer is implemented, the HTTP client wrapper will be configured with a blocklist, and the enrichment router will check `mode != "automated"` on every call path.

## If you change your mind

If the operator later wants to relax any of these restrictions, they should update this design doc **first**, explaining the new posture and why, then update the code. The doc is the contract; the code enforces it.

If the operator later decides the stricter posture isn't restrictive enough and wants to remove Mode C entirely, that's a one-line config change and a few lines of dead code removal — straightforward.
