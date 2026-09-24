# Example: Feature Implementation (Standard Workflow)

> Illustrative walkthrough of how the phases and roles interact. It is not a transcript of a
> recorded run; real runs differ in findings, cycle count and wording.

## Task
"Add rate limiting to the API authentication endpoint"

## How ArcheFlow Handles It

### Cycle 1

**Plan Phase:**
1. Explorer researches: finds the auth handler, discovers no existing rate limit middleware, notes the Redis connection already exists, identifies 3 routes that need protection
2. Creator proposes: use token bucket algorithm via Redis, add middleware at route level, 100 req/min per IP, return 429 with Retry-After header

**Do Phase:**
3. Maker implements in worktree: writes rate-limit middleware, adds tests (happy path, rate exceeded, Redis down fallback), commits incrementally

**Check Phase (parallel):**
4. Guardian reviews: APPROVED — finds no security issues, notes Redis fallback behavior is safe
5. Skeptic challenges: WARNING — "What about distributed deployments with multiple Redis instances?" Suggests adding a note about Redis cluster configuration
6. Sage reviews: REJECTED — test for Redis-down scenario doesn't actually simulate Redis failure, it mocks the entire middleware

**Act:** Rejected (1 critical quality issue). Feed findings back.

### Cycle 2

**Plan Phase:**
7. Creator revises: update test strategy to use actual Redis disconnect simulation, add Redis cluster note to README

**Do Phase:**
8. Maker implements fixes in new worktree: rewrites Redis-down test to kill the connection, adds documentation

**Check Phase:**
9. Guardian: APPROVED
10. Skeptic: APPROVED (cluster concern addressed in docs)
11. Sage: APPROVED (tests now simulate real failure)

**Act:** All approved. Merge.

## Result
- 4 files changed, +180 -5 lines
- 8 tests added (including real Redis failure simulation)
- Rate limiting active on 3 auth routes
- Documentation updated
- 2 PDCA cycles, standard workflow
