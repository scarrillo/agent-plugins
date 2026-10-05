---
mode: append    # default; can be omitted
---

## Pay particular attention to

5. **Multi-tenant isolation** — flag queries on shared tables
   without an explicit tenant filter.
6. **Migration safety** — flag schema changes on tables >1M rows
   without a backfill plan.
