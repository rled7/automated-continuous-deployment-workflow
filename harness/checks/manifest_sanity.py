#!/usr/bin/env python3
"""Cross-object checks on rendered Kubernetes manifests that schema validation
cannot catch. Usage: manifest_sanity.py RENDERED.yaml [...]. Exit 1 on problems.

Checks:
  * two workloads (Deployment/StatefulSet/DaemonSet/Rollout) in the same
    namespace whose selectors match the same pods — e.g. a Deployment that was
    meant to be replaced by an Argo Rollout but is still rendered
  * HorizontalPodAutoscaler scaleTargetRef points at an object in the render
  * PodDisruptionBudget selects at least one workload
  * Service selects at least one workload
"""
import sys

import yaml

WORKLOAD_KINDS = {"Deployment", "StatefulSet", "DaemonSet", "Rollout"}


def selector_matches(selector, labels):
    return bool(selector) and all(labels.get(k) == v for k, v in selector.items())


def check(path):
    with open(path) as f:
        docs = [d for d in yaml.safe_load_all(f) if d]
    problems = []

    def ns(o):
        return o["metadata"].get("namespace", "default")

    def ref(o):
        return f'{o["kind"]}/{o["metadata"]["name"]}'

    workloads = [d for d in docs if d.get("kind") in WORKLOAD_KINDS]

    for i, a in enumerate(workloads):
        a_labels = a["spec"].get("template", {}).get("metadata", {}).get("labels", {})
        for b in workloads[i + 1:]:
            if ns(a) != ns(b):
                continue
            b_sel = b["spec"].get("selector", {}).get("matchLabels", {})
            if selector_matches(b_sel, a_labels):
                problems.append(
                    f"{ref(a)} and {ref(b)} in namespace {ns(a)} manage the same pods "
                    f"(selector {b_sel}); only one controller should own them")

    by_ref = {(ns(d), d["kind"], d["metadata"]["name"]) for d in docs}
    for hpa in (d for d in docs if d.get("kind") == "HorizontalPodAutoscaler"):
        t = hpa["spec"]["scaleTargetRef"]
        if (ns(hpa), t["kind"], t["name"]) not in by_ref:
            problems.append(
                f'{ref(hpa)} targets {t["kind"]}/{t["name"]}, which is not in the rendered output')

    for kind, sel_path in (("PodDisruptionBudget", ("selector", "matchLabels")),
                           ("Service", ("selector",))):
        for obj in (d for d in docs if d.get("kind") == kind):
            sel = obj["spec"]
            for key in sel_path:
                sel = (sel or {}).get(key)
            if not sel:
                continue
            if not any(selector_matches(sel, w["spec"].get("template", {}).get("metadata", {}).get("labels", {}))
                       for w in workloads if ns(w) == ns(obj)):
                problems.append(f"{ref(obj)} selector {sel} matches no workload in namespace {ns(obj)}")

    return problems


def main():
    failed = False
    for path in sys.argv[1:]:
        problems = check(path)
        for p in problems:
            print(f"{path}: {p}")
        if not problems:
            print(f"{path}: ok")
        failed |= bool(problems)
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
