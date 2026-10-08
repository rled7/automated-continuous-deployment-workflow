# Migration pod

`runMigrations()` in the Jenkinsfile runs `knex migrate:latest` from the app
image as a one-off pod:

```bash
POD=my-app-migrate-$BUILD_NUMBER
kubectl run "$POD" --namespace=<ns> --image=<image> --labels=app=my-app-migrate \
  --rm --restart=Never --attach=true \
  --overrides="$(sed -e "s|__NAME__|$POD|" -e "s|__IMAGE__|<image>|" k8s/migrations/migrate-pod-overrides.json)"
```

`migrate-pod-overrides.json` is the full pod spec (`--overrides` replaces the
container list). It gives the pod what the app gets — the ConfigMap plus
`DB_HOST`/`DB_PASSWORD` from the SealedSecret — and satisfies the Kyverno Pod
policies (resource limits, read-only root filesystem, dropped capabilities) and
the namespaces' Pod Security "restricted" level (non-root, RuntimeDefault
seccomp profile).

- `--env=production` selects the knexfile block that reads `DB_SSL`; the
  ConfigMap's `NODE_ENV` (`staging`) has no knexfile block of its own.
- The `app=my-app-migrate` label is what the `allow-migrate-egress-db`
  NetworkPolicy allows through to Postgres. It deliberately differs from
  `app=my-app` so the `my-app` Service never routes traffic to this pod.
- It runs under the namespace's default ServiceAccount with no token mounted:
  migrations need the database, not the Kubernetes API, and the overlay's
  `my-app` ServiceAccount doesn't exist yet on a first deploy.

`harness/verify.sh static pod cluster-real` builds this pod from the same file.
