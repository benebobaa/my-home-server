# Registry retention at home: a dry run (2026-10-15)

**Why:** the rented server's weekly retention and GC on the shared R2 registry
bucket were suspended on 2026-10-14 (they judged "in use" from the frozen
database). Nothing trims the bucket now (4.6 GB; R2's free tier is 10 GB).
Before building a home job: what would it do?

**How:** Kubeletto's own `retention.py` (shared registry manifests), as a
one-off Job on the K3s server node, `DRY_RUN=true`, Knative in-use protection
on, **without** the database (its client verifies Postgres against public CAs
and expects a cross-tenant read-only role; neither exists at home yet). So:
no rollback protection and no orphan sweep in this run. The temporary Job,
ConfigMap, ServiceAccount and ClusterRole were deleted afterwards.

**Result:** 40 repositories (one per service). Keep-10 would delete 16 manifest
revisions, in 3 repositories (19, 16 and 11 revisions); everything running
is protected. Deleting revisions frees nothing until a registry GC runs.
Repositories of deleted services (the orphan sweep) are invisible without
the database and are the likely bulk of the bucket.

**Conclusion:** low priority. The home job worth building is the orphan
sweep plus GC, which needs: a read-only Postgres role for retention
(SELECT on services and builds, across tenants), the script trusting the
lab's Postgres certificate, the Job pinned to the server node (the Postgres
pinhole), and GC that sets the home registry read-only. Enable deletion only
after a dry run with the database, and not while the rented server's
rollback could still need its images (until ~2026-10-21).
