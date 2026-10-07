# Usageline runbook

Local-cluster runbook for the three alerts defined in `helm/usageline/templates/prometheusrule.yaml`. All commands assume the kind cluster from `scripts/kind-up.sh` and the monitoring stack from `scripts/monitoring-up.sh`.

## Looking at things

Run each port-forward in its own terminal:

```bash
kubectl --context kind-usageline -n monitoring port-forward svc/kps-grafana 3000:80
kubectl --context kind-usageline -n monitoring port-forward svc/kps-kube-prometheus-stack-prometheus 9090:9090
kubectl --context kind-usageline -n monitoring port-forward svc/kps-kube-prometheus-stack-alertmanager 9093:9093
```

- Grafana: http://localhost:3000, user `admin`, password `admin` (local only). Dashboard: **Usageline API**.
- Prometheus: http://localhost:9090. Use **Alerts** to see state, **Status > Targets** to see whether the API is being scraped.
- Alertmanager: http://localhost:9093.

Handy first commands for any incident:

```bash
kubectl --context kind-usageline -n usageline get pods,hpa
kubectl --context kind-usageline -n usageline logs deploy/usageline --tail=50
kubectl --context kind-usageline -n usageline describe pod <pod>
```

Note: Prometheus here has no persistent volume and 6h retention, so restarting its pod loses history.

---

## UsagelineHigh5xxRate

**Meaning.** More than 5% of all API requests over the last 5 minutes returned a 5xx status, for at least 2 minutes. The ratio includes the `/health` and `/ready` probe requests, so with low real traffic a failing `/ready` (HTTP 503) alone can trip it.

**Diagnose.**
1. Dashboard: *Error rate* panel, and *Request rate* by route to see which route is failing.
2. Is the database reachable? `curl localhost:8081/ready` returns 503 if not. Check the Postgres pod: `kubectl -n usageline get pods` and `logs usageline-postgres-0`.
3. Application errors: `kubectl -n usageline logs deploy/usageline --tail=100`.
4. Did it start right after a deploy? `helm --kube-context kind-usageline -n usageline history usageline`.

**Act.**
- Database down: restart or restore it (`kubectl -n usageline scale statefulset usageline-postgres --replicas=1` if it was scaled to zero). Data is on a PVC, so it survives pod restarts.
- Bad release: `helm --kube-context kind-usageline -n usageline rollback usageline <revision>`. Remember that migrations are not rolled back.
- Only one route failing: it is probably a code bug; fix and redeploy with `scripts/kind-up.sh`.

The alert resolves on its own once the 5-minute window no longer contains enough errors.

---

## UsagelineHighLatencyP95

**Meaning.** The 95th percentile request latency (probe routes excluded) has been above 0.5 s for 5 minutes. The value is estimated from histogram buckets, so it is only as precise as the bucket boundaries (0.005 s to 5 s).

**Diagnose.**
1. Dashboard: *p95 latency* next to *Request rate* (is it load?) and *CPU usage vs requests* (is it CPU throttling at the 500m limit?).
2. *Pod count*: has the HPA already scaled to its maximum of 5? New pods take time to become ready.
3. Database: `kubectl -n usageline top pods` for Postgres CPU; slow queries show as latency on the invoice route. There is no query-level metric yet.
4. Node pressure: `docker stats` on the host. The kind node shares a small Docker VM, so the host itself can be the bottleneck.

**Act.**
- Load spike and HPA at max: raise `hpa.maxReplicas` or the CPU limit in `values.yaml`, or reduce the load.
- CPU throttled at the limit: raise `resources.limits.cpu`.
- Database slow: look at Postgres resources (`postgres.resources`) and the invoice query, which sums usage events for a period (there is an index on `tenant_id` and `timestamp`).

---

## UsagelinePodsNotReady

**Meaning.** A pod in the `usageline` namespace is Running but failing its readiness check, for at least 2 minutes. Kubernetes has already stopped sending it traffic. For API pods, the readiness probe is `/ready`, which fails when the database is unreachable. It also covers the Postgres pod.

**Diagnose.**
1. `kubectl -n usageline get pods` to find which pod, then `kubectl -n usageline describe pod <pod>` and read the *Events* and probe failures.
2. API pods not ready: check Postgres first (`get pods`, `logs usageline-postgres-0`), because `/ready` depends on it.
3. Postgres not ready: check its logs and the PVC (`kubectl -n usageline get pvc`).
4. If all API pods are unready, users get errors; if only one, capacity is reduced but service continues.

**Act.**
- Restore the database (see above) and the API pods become ready by themselves within one probe period (about 5 s).
- A pod that stays unready while the database is healthy: delete it (`kubectl -n usageline delete pod <pod>`); the Deployment recreates it. If the replacement is also unready, treat it as a bad release and roll back.

---

## Verified behaviour (this repo, local kind cluster)

The 5xx and not-ready alerts were exercised by scaling the Postgres StatefulSet to zero; both reached the firing state and Alertmanager. See `docs/LEARNING.md` (Phase 4) for exactly what was and was not verified.
