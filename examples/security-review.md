# Example: Security Review (Thorough Workflow)

> Illustrative walkthrough of how the phases and roles interact. It is not a transcript of a
> recorded run; real runs differ in findings, cycle count and wording.

## Task
"Review the new file upload endpoint for security issues"

## Workflow: thorough (3 cycles max, all reviewers)

### Cycle 1

**Plan Phase:**
1. Explorer maps the upload flow: multipart parsing → temp storage → virus scan → permanent storage → DB record
2. Creator identifies review focus areas: file type validation, path traversal, size limits, content-type sniffing

**Do Phase:**
3. Maker writes security test suite covering all identified vectors

**Check Phase (all 4 reviewers, parallel):**
4. Guardian: REJECTED
   - CRITICAL: No file extension allowlist — user can upload .php, .sh, .exe
   - CRITICAL: Temp directory uses predictable naming (race condition for symlink attack)
   - WARNING: Missing Content-Disposition header on download (XSS via HTML files)
5. Skeptic: REJECTED
   - CRITICAL: "What if the virus scanner is down?" — no circuit breaker, uploads just pass through
6. Sage: APPROVED with warnings
   - WARNING: Upload handler is 200 lines — should be split into validation, storage, and recording
7. Trickster: REJECTED
   - CRITICAL: Uploaded a 0-byte file with `.jpg` extension → 500 error (null pointer in image processor)
   - CRITICAL: Uploaded file named `../../etc/passwd` → path traversal confirmed

**Act:** 4 CRITICAL findings. Cycle again.

### Cycle 2

After Creator revises and Maker fixes all findings...

8. Guardian: APPROVED — allowlist active, temp dir uses crypto random, Content-Disposition set
9. Skeptic: APPROVED — circuit breaker added, uploads rejected when scanner is down
10. Sage: APPROVED — handler refactored into 3 modules
11. Trickster: REJECTED
   - WARNING: Unicode filename normalization issue — `file\u202e.jpg` displays as `gpj.elif` in some UIs

**Act:** No CRITICAL. One WARNING from Trickster. Cycle once more.

### Cycle 3

12. Maker adds Unicode normalization for filenames
13. All reviewers: APPROVED

**Act:** All reviewers approved. Merge.

## Result
- Path traversal fixed
- File type allowlist added
- Virus scanner circuit breaker added
- Zero-byte file handling added
- Unicode filename normalization added
- 3 PDCA cycles, thorough workflow
- 5 CRITICAL findings raised and fixed before merge
