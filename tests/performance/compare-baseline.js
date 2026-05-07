#!/usr/bin/env node
/**
 * compare-baseline.js — Build 020
 *
 * Reads a k6 JSON summary (--out json=...) and a baseline JSON file, then
 * computes percent regressions for key metrics.  Exits non-zero if any metric
 * exceeds the allowed regression threshold.
 *
 * Usage:
 *   node tests/performance/compare-baseline.js \
 *     --current  reports/k6-results.json \
 *     --baseline tests/performance/baseline.json
 *
 * Regression thresholds (judgment calls — see docs/perf-baseline.md):
 *   http_req_duration.p95  > +20% regression → fail
 *   http_req_duration.p99  > +25% regression → fail
 *   http_req_failed.rate   > 2× baseline     → fail
 *
 * k6 JSON output format note:
 *   When k6 is run with `--out json=FILE`, it streams one JSON object per line
 *   (newline-delimited JSON, NDJSON).  Each line is either a "Metric" point or
 *   a "Point" data sample.  The summary metrics we care about are emitted as
 *   lines with `type: "Point"` and a `metric` field matching the metric name,
 *   with `data.tags.percentile` for histogram percentiles.
 *
 *   However, the most reliable way to read end-of-run summary values is from
 *   lines where `type === "Point"` and the `metric` field matches AND the line
 *   appears near the end of the file (after the test finishes).  k6 also emits
 *   an aggregate summary line per metric at the end with no `tags.percentile`;
 *   for trend metrics p(95) and p(99) are included as nested percentile keys.
 *
 *   For simplicity and robustness, this script accumulates all data points for
 *   each metric and computes percentiles itself from the full population, using
 *   the same approach k6 uses (nearest-rank method).
 */

import { readFileSync } from 'fs';
import { createRequire } from 'module';

// ── Argument parsing ──────────────────────────────────────────────────────────

const args = process.argv.slice(2);

function getArg(flag) {
    const idx = args.indexOf(flag);
    if (idx === -1 || idx + 1 >= args.length) {
        console.error(`Error: missing required argument ${flag}`);
        process.exit(2);
    }
    return args[idx + 1];
}

const currentFile   = getArg('--current');
const baselineFile  = getArg('--baseline');

// ── Load baseline ─────────────────────────────────────────────────────────────

let baseline;
try {
    baseline = JSON.parse(readFileSync(baselineFile, 'utf8'));
} catch (err) {
    console.error(`Error reading baseline file "${baselineFile}": ${err.message}`);
    process.exit(2);
}

// ── Parse k6 NDJSON output ────────────────────────────────────────────────────
// k6 --out json streams one JSON object per line.  We collect all numeric
// Point values per metric name for post-hoc percentile computation.

let rawLines;
try {
    rawLines = readFileSync(currentFile, 'utf8').split('\n').filter(Boolean);
} catch (err) {
    console.error(`Error reading k6 results file "${currentFile}": ${err.message}`);
    process.exit(2);
}

// Accumulate raw durations and boolean failure values
const durationSamples = [];  // http_req_duration values (ms)
const failedSamples   = [];  // http_req_failed values (0 or 1)

for (const line of rawLines) {
    let obj;
    try {
        obj = JSON.parse(line);
    } catch {
        continue; // skip malformed lines
    }

    if (obj.type !== 'Point') continue;

    const metricName = obj.metric;
    const value      = obj.data && obj.data.value;

    if (typeof value !== 'number') continue;

    if (metricName === 'http_req_duration') {
        durationSamples.push(value);
    } else if (metricName === 'http_req_failed') {
        failedSamples.push(value);
    }
}

// ── Percentile computation (nearest-rank) ─────────────────────────────────────

function percentile(sortedArr, p) {
    if (sortedArr.length === 0) return 0;
    const idx = Math.ceil((p / 100) * sortedArr.length) - 1;
    return sortedArr[Math.max(0, idx)];
}

function mean(arr) {
    if (arr.length === 0) return 0;
    return arr.reduce((a, b) => a + b, 0) / arr.length;
}

const sortedDurations = durationSamples.slice().sort((a, b) => a - b);

const current = {
    http_req_duration: {
        p95: percentile(sortedDurations, 95),
        p99: percentile(sortedDurations, 99),
        avg: mean(durationSamples),
    },
    http_req_failed: {
        rate: failedSamples.length > 0 ? mean(failedSamples) : 0,
    },
};

// ── Regression computation ────────────────────────────────────────────────────
// delta% = ((current - baseline) / baseline) * 100
// Positive delta = regression (current is worse/higher).

function pctDelta(cur, base) {
    if (base === 0) return cur === 0 ? 0 : Infinity;
    return ((cur - base) / base) * 100;
}

const metrics = [
    {
        name:      'http_req_duration.p95 (ms)',
        baseline:  baseline.http_req_duration.p95,
        current:   current.http_req_duration.p95,
        threshold: 20,   // % regression allowed
        unit:      'ms',
    },
    {
        name:      'http_req_duration.p99 (ms)',
        baseline:  baseline.http_req_duration.p99,
        current:   current.http_req_duration.p99,
        threshold: 25,
        unit:      'ms',
    },
    {
        name:      'http_req_failed.rate',
        baseline:  baseline.http_req_failed.rate,
        current:   current.http_req_failed.rate,
        // Error rate threshold: current must not exceed 2× baseline.
        // Expressed as a percentage of the baseline value (i.e. +100%).
        threshold: 100,
        unit:      'rate',
    },
];

// ── Print results table ───────────────────────────────────────────────────────

const COL_W = [30, 12, 12, 10, 12, 8];
const HEADER = ['Metric', 'Baseline', 'Current', 'Delta%', 'Threshold', 'Status'];

function pad(str, width) {
    return String(str).padEnd(width);
}

console.log('');
console.log('k6 Baseline Comparison — Build 020');
console.log(`Baseline captured: ${baseline.captured_at}  git_sha: ${baseline.git_sha}`);
console.log(`Current results:   ${currentFile}`);
console.log('');

// Header row
console.log(HEADER.map((h, i) => pad(h, COL_W[i])).join('  '));
console.log(COL_W.map((w) => '-'.repeat(w)).join('  '));

let anyFailed = false;

for (const m of metrics) {
    const delta   = pctDelta(m.current, m.baseline);
    const failed  = delta > m.threshold;
    const status  = failed ? 'FAIL' : 'OK';
    const deltaStr = isFinite(delta)
        ? (delta >= 0 ? '+' : '') + delta.toFixed(1) + '%'
        : '∞';

    if (failed) anyFailed = true;

    const baselineStr = m.unit === 'rate'
        ? m.baseline.toFixed(4)
        : m.baseline.toFixed(1);
    const currentStr = m.unit === 'rate'
        ? m.current.toFixed(4)
        : m.current.toFixed(1);
    const thresholdStr = `+${m.threshold}%`;

    console.log([
        pad(m.name,        COL_W[0]),
        pad(baselineStr,   COL_W[1]),
        pad(currentStr,    COL_W[2]),
        pad(deltaStr,      COL_W[3]),
        pad(thresholdStr,  COL_W[4]),
        pad(status,        COL_W[5]),
    ].join('  '));
}

console.log('');

if (durationSamples.length === 0) {
    console.warn('WARNING: no http_req_duration samples found in k6 output.');
    console.warn('  Verify that k6 was run with --out json=FILE and that FILE is non-empty.');
    console.warn('  Treating all current metrics as 0 (may cause false FAIL).');
}

if (anyFailed) {
    console.error('RESULT: FAIL — one or more metrics regressed beyond threshold.');
    console.error('  Review the k6 results and compare against the baseline.');
    console.error('  To update the baseline after a legitimate improvement, see docs/perf-baseline.md.');
    process.exit(1);
} else {
    console.log('RESULT: PASS — all metrics within regression thresholds.');
    process.exit(0);
}
