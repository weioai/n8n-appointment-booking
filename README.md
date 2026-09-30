# n8n appointment-booking workflow (free sample, dry-run tested)

One importable [n8n](https://n8n.io) workflow that turns a booking request into a
decision: `confirmed`, `conflict` (with three alternative slots) or `invalid`.
All the logic lives in one JavaScript Code node, so you can read every rule
before you trust it. It is the appointment-booking template from Weio's
[n8n workflow starter pack](https://weio.ai/services/n8n-workflow-pack.html?utm_source=github&utm_medium=template&utm_campaign=n8n-dryrun),
released here in full under the MIT license, with its test fixtures and the
same Docker-based dry-run harness the pack uses.

Tested with n8n 2.40.7 (`n8nio/n8n:latest`, pulled 2026-09). The workflow has not
been deployed for a real customer; it is sample work exercised against a local,
disposable n8n container with `dry_run: true` fixtures. See "Known limitations".

## What the workflow does

`workflows/appointment-booking.json` (webhook path `/webhook/appointment-booking`,
nodes: Booking Webhook, Validate & Decide, Create Real Event? (confirmed, not
dry_run), Create Calendar Event (real), Finalize Dispatched, Respond to Webhook).

Input, POSTed as JSON:

```json
{
  "dry_run": true,
  "name": "Morgan Lane",
  "phone": "+15551110001",
  "service": "consultation",
  "requested_start": "2026-10-05T10:00:00Z",
  "duration_min": 30,
  "existing_bookings": [
    {"id": "bk-existing", "start": "2026-10-05T10:00:00Z", "end": "2026-10-05T11:00:00Z"}
  ],
  "business_hours": {"open": "09:00", "close": "17:00", "tz_offset_min": 0}
}
```

`tz_offset_min` is the number of minutes to add to UTC to get the business's
local wall-clock time (for example `-300` for US Eastern in winter).

Rules, in order:

1. Missing or invalid fields (`name`, `phone`, `service`, an ISO 8601
   `requested_start`, a positive `duration_min`, `business_hours`) return
   `{"status": "invalid", "errors": [...]}` naming each problem.
2. The requested slot is checked against business hours in local time.
3. The slot is checked for overlap against `existing_bookings`. If the body
   carries `booking_id` and `"action": "reschedule"`, the booking with that id
   is excluded first, so moving an appointment does not collide with itself.
4. A clean slot returns `{"status": "confirmed", "slot": {"start", "end"},
   "confirmation_text": "..."}`.
5. A conflicting slot returns `{"status": "conflict", "reason", "alternatives":
   [...]}` with the next three free 30-minute-aligned slots (same business day,
   then the next one).

Every response also echoes `dry_run` and reports `dispatched` (true only when
the real calendar node ran).

The real action node, `Create Calendar Event (real)`, is reached only when
`status` is `confirmed` **and** `dry_run` is `false`. It POSTs to
`https://www.googleapis.com/calendar/v3/calendars/primary/events` with
`Authorization: Bearer {{$env.GOOGLE_CALENDAR_TOKEN}}`. Set
`GOOGLE_CALENDAR_TOKEN` on the n8n process, or swap the header expression for a
proper Google OAuth2 credential on the node, before sending any request with
`dry_run: false`.

## Importing into n8n

```
docker run -d --name n8n -p 5678:5678 \
  -e N8N_ENCRYPTION_KEY=<your-key> \
  -v "$(pwd)/workflows:/import" \
  n8nio/n8n:latest

docker exec n8n n8n import:workflow --separate --input=/import
docker exec n8n n8n list:workflow --onlyId          # note the id
docker exec n8n n8n publish:workflow --id=<id>
docker restart n8n                                   # webhook registration
                                                     # takes effect after restart
```

`n8n import:workflow --activeState=fromJson` is refused by n8n 2.40.7 outside
queue/multi-main mode, so activation goes through `publish:workflow` plus a
restart. `n8n update:workflow --active=true` is deprecated in this version.

## Running the tests

```
tests/run.sh
```

Needs Docker and python3. The script starts a disposable container
(`n8n-booking-sample-test`, bound to 127.0.0.1:5679 only), waits for n8n to
finish its database setup, imports and publishes the workflow, restarts the
container so the webhook is live, then POSTs the four fixtures under
`tests/fixtures/` and asserts on the JSON responses with
`tests/assert_responses.py` (10 assertions). Every fixture sets
`"dry_run": true`, so the run never calls Google. The container is removed on
exit whether the run passes, fails or is interrupted.

Fixtures: a confirmed booking, a conflict that yields three alternatives (the
first starting right after the overlapping booking), an invalid request that
names the missing field, and a reschedule that frees the old slot.

## Known limitations

- `Create Calendar Event (real)` is wired with the right method, URL and auth
  header shape but has never been executed against the real Google Calendar
  API; only its dry-run-skipped branch has been exercised.
- The business-hours check assumes a single appointment does not itself span
  midnight in local time. Alternative-slot search does roll over to the next
  business day.
- Alternatives are aligned to 30-minute boundaries regardless of `duration_min`.

## The rest of the pack

The paid [starter pack ($29)](https://weio.ai/services/n8n-workflow-pack.html?utm_source=github&utm_medium=template&utm_campaign=n8n-dryrun)
adds two more workflows built the same way (a WhatsApp Cloud API lead scorer
with a human-handoff flag, and a Stripe payout reconciliation that emits
sheet-ready rows), their fixtures in the same harness, a plain-English setup
guide, and 30 days of email help with importing one workflow. Delivered by
email automatically after payment. Not sure it fits? Ask first at
sales@weio.ai, free.

## About

Weio, Inc. (Santa Barbara, CA) is a small company where AI operators do most
of the work, including writing and testing this workflow; a human owner is
accountable. Issues and pull requests are welcome.
