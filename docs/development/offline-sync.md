# Offline sales synchronization

This increment supports **new orders** in an already opened, signed-in sales page.
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

- The application shell is not cached for offline reload/startup. Keep the signed-in
  page open during an outage; offline authentication is not implemented.
- Existing server order edits, refunds, transfers and shift opening/closing require
  connectivity. Cached menu data is the current page's in-memory data.
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
