# Postmortem Template

## How to Use

This template is used to conduct a blameless postmortem after every Sev 1 or Sev 2 incident. The goal is to understand what happened, why it happened, and what we can do to prevent it from recurring — not to assign blame. Fill in every section as completely as possible within 48 hours of incident resolution. Share the completed document in the `#incidents` Slack channel and link it from the incident ticket. Schedule a 30-minute review meeting with all involved parties within one week.

The most important outputs are the **Action Items** table and the **Lessons Learned** section. Action items must have a named owner and a due date — unowned items will not get done. Lessons learned should be honest about both what worked and what didn't; the "what worked" entries are just as valuable as the failures because they tell you which practices to reinforce. See `docs/oncall.md` for the escalation path and rotation details.

---

## Incident Header

| Field | Value |
|-------|-------|
| Incident ID | INC-YYYY-NNN |
| Date | YYYY-MM-DD |
| Severity | Sev 1 / Sev 2 / Sev 3 |
| Total Duration | HH:MM (detection to resolution) |
| Incident Commander | |
| Scribe | |
| Summary | One sentence: what broke, customer impact, how it was fixed |

---

## Timeline

List events in chronological order. Be precise about times (UTC). Include the first sign of trouble, each escalation, each mitigation attempt, and the moment of resolution. Include "near misses" — things that almost made it worse.

| Time (UTC) | Event | Source / Actor |
|------------|-------|----------------|
| HH:MM | | |
| HH:MM | | |
| HH:MM | | |
| HH:MM | | |
| HH:MM | Full resolution confirmed | |

---

## Impact

### Customer-Facing Impact

Describe what customers experienced: errors, degraded performance, data unavailability. Include approximate percentages (e.g., "~12% of requests returned 503") where known.

### Scope

- **Services affected:**
- **Namespaces / environments:**
- **Percentage of traffic affected:**
- **Number of customers affected (estimated):**
- **Revenue impact (if known):**

---

## Root Cause

State the root cause in one or two sentences. Be specific. "The deploy pushed a misconfigured env var that caused the connection pool to exhaust" is better than "there was a configuration problem."

**Root cause:**

---

## Detection

- **How was the incident detected?** (alert, customer report, engineer noticed)
- **Which alert fired (if any)?**
- **Time from fault introduction to detection:**
- **Was the detection time acceptable?** If not, what would have caught it faster?

---

## Mitigation

List the steps taken to reduce customer impact, in the order they were executed. Note which steps succeeded and which failed or were abandoned.

1.
2.
3.

**Time to first mitigation action:**
**Time to full mitigation (impact stopped):**

---

## Resolution

- **What was done to fully resolve the incident?**
- **When was full resolution confirmed?**
- **Was a rollback used?** (yes/no — if yes, to which revision)
- **Were any permanent workarounds left in place?** (if so, track as an action item)

---

## Contributing Factors

These are systemic factors that made the incident possible or harder to resolve. They are not causes of blame — they are gaps in our systems, processes, or knowledge that we can close.

### System / Infrastructure Gaps

- e.g., no circuit breaker on the downstream call
- e.g., connection pool limit not surfaced in Grafana

### Process Gaps

- e.g., no pre-deploy checklist for env var changes
- e.g., staging env does not mirror production connection limits

### Knowledge / Documentation Gaps

- e.g., runbook for this failure mode didn't exist
- e.g., team was unaware of the retry amplification behaviour

---

## Action Items

Each item must have a named owner and a due date. Severity: P1 = must fix before next deploy, P2 = fix within 1 sprint, P3 = fix within 1 quarter.

| # | Action Item | Owner | Severity | Due Date | Ticket |
|---|-------------|-------|----------|----------|--------|
| 1 | | | P1/P2/P3 | YYYY-MM-DD | |
| 2 | | | P1/P2/P3 | YYYY-MM-DD | |
| 3 | | | P1/P2/P3 | YYYY-MM-DD | |

---

## Lessons Learned

### What Worked Well

List practices, tools, or team behaviours that helped contain or resolve the incident quickly.

-
-

### What Didn't Work / Could Be Improved

List anything that slowed detection, mitigation, or resolution.

-
-

---

## Footer

| Field | Value |
|-------|-------|
| Document Author | |
| Review Date | YYYY-MM-DD (within 1 week of resolution) |
| Review Attendees | |
| Linked Incident Ticket | |
| Postmortem Published | `#incidents` Slack channel |

*For measuring the incident's effect on DORA metrics see `docs/dora-metrics.md`. For on-call rotation and escalation contacts see `docs/oncall.md`.*
