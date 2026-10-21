# Offline sales synchronization

Offline sales support **new orders** in a signed-in page. The application shell is
now saved for offline reload, while authentication still requires connectivity.
Load the menu and, for cash, open a shift while connected. KDS, printing and ingredient
inventory remain deferred.

## Operator flow

- Use “Lưu đơn mới tại máy” for an unpaid local order, or confirm actual cash received
  in the separate offline cash form. A failed network request for a new online order
  also falls back to the durable queue using the same operation ID.
- The cart clears only after the IndexedDB transaction commits. Local storage failure
  leaves the cart available. Local records are scoped to backend, user, organization
  and store. Auth credentials are never stored with orders.
- Reconnecting triggers a sync attempt while signed in. The queue panel also provides
  manual sync and explicit conflict retry. Reloading preserves the queue but requires
  an online login before accessing it again.
- The server acknowledgement must contain the matching operation ID and an order ID.
  Committed records remain visible; retries never downgrade them or resend them.
- A price change, occupied table, unavailable item, closed shift or revoked permission
  keeps the original request as a conflict. Check the cause and retry when corrected.
  An already received cash conflict requires cashier/manager reconciliation; do not
  recreate or discard it as a new sale. This increment has no local-delete action.
- Closing a shift from this browser is blocked while its user/store queue contains
  unresolved cash records. Another device can still close that shift; the server then
  rejects new cash imports atomically. The queue on this device remains available.

## Server guarantees

`rpc_sync_offline_sale` authorizes the caller, serializes by store, verifies the
server-calculated total against the amount shown locally, creates the order and
optionally collects cash in one transaction. Any error rolls back the entire import.
The operation ID and full immutable request identify a replay; concurrent retries
return one order/payment. Replaying a committed import remains valid after shift
closure. Unpaid imports create OPEN orders; cash imports create PAID orders.

## Current limits

- After the page reports that offline preparation is complete, its shell can reopen
  without connectivity. A reload ends the memory-only session: online login and a
  successful store permission check remain required before accessing local sales.
  Keep the signed-in page open during an outage to continue selling.
- Existing server order edits, refunds, transfers and shift opening/closing require
  connectivity. Menu, size, topping and table snapshots persist in IndexedDB under
  the same backend/user/organization/store scope as the queue. Temporary network,
  429 and 5xx failures can restore this snapshot after authentication and a successful
  store permission check. 401/403 and other business errors cannot enable fallback.
  The interface shows the snapshot time and hides server finance/admin controls.
  A shift is never restored from disk; cash entry requires a shift previously loaded
  in the current signed-in page. Server validation remains authoritative.
- Browser storage can be removed by the operator/browser. A device failure can lose
  unsynced sales. Do not clear site data while records are pending.
- Reports use server posting time, including imported cash; device creation time is
  local queue metadata, not a backdated accounting timestamp.
- Cash change is received amount minus the stored expected total. Review the order
  total before confirming receipt. No transfer is auto-confirmed.
- Conflict reconciliation is manual in this increment. No permission bypass,
  automatic repricing or silent shift reassignment is performed.

## Validation

CI runs the existing unit/database suite, browser tests on real Chromium IndexedDB,
and integration tests against local Supabase Auth/PostgREST. The integration coverage
includes concurrent import replay, tenant isolation, immutable requests, price-conflict
rollback, cash/shift accounting, closed-shift rollback and committed replay after close.
Browser coverage includes network failure, reload recovery, explicit sync, one-time
acknowledgement, local cash recording and preventing local shift closure.

## Shell installation and updates

The build hashes the shell assets and public backend configuration to generate
`public/sw.js` (also copied to `dist/sw.js`). The worker caches only an explicit
same-origin static allowlist and supported navigation routes; Auth, PostgREST,
orders and customer API responses never enter Cache Storage. The shell contains
no account session. Failed installations remove the incomplete new cache.
Redirected HTML is normalized before caching so Vercel clean URLs remain usable
for offline navigation.

An updated worker waits while existing tabs remain open. It never forces a reload
or replaces code beneath a live cart. After synchronizing pending sales, save or
finish any current cart and close all tabs to activate the update. Activation removes
older shell caches; it does not remove IndexedDB records. The worker response uses
no-cache headers to permit update checks. Auth tokens remain memory-only.

## Reconciliation visibility

The queue always shows every unresolved record, followed by the 20 most recent
acknowledged receipts. Older conflicts cannot disappear behind newer successes.
Expand an entry to inspect time, channel, customer, original item labels/quantities,
received cash, calculated change and the server order ID after acknowledgement.
New display snapshots are local metadata; the immutable server request is unchanged.
Existing records without display metadata retain their variant identifiers.
A refresh after a sync attempt updates menu/shift information even when conflicts
remain, without rewriting those local orders or changing the current cart's prices.

Additional Chromium coverage verifies real Service Worker installation, offline
navigation, Vercel-style redirects, atomic failed installation, update waiting,
cache isolation, forbidden-access behavior, original-ID replay and visibility of old
conflicts after more than 20 new receipts.
