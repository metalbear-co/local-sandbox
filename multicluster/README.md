### Basic request to PRIMARY cluster

```bash
kubectl --context mirrord-primary exec -n test-multicluster deploy/echo-app -- \
  wget -q -O- -S \
  --header="X-My-Header: filtered-data" \
  "http://echo-app:8080/echo?from=primary"
```

### Request to REMOTE-1 cluster

```bash
kubectl --context mirrord-remote-1 exec -n test-multicluster deploy/echo-app -- \
  wget -q -O- -S \
  --header="X-My-Header: filtered-data" \
  "http://echo-app:8080/echo?from=remote-1"
```

### Request to REMOTE-2 cluster (if you have 3 clusters)

```bash
kubectl --context mirrord-remote-2 exec -n test-multicluster deploy/echo-app -- \
  wget -q -O- -S \
  --header="X-My-Header: filtered-data" \
  "http://echo-app:8080/echo?from=remote-2"
```
