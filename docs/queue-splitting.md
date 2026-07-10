# Queue splitting

One verb set for every queue module — `sqs`, `kafka`, `rmq`, `pubsub`,
`servicebus`, `redis-pubsub`, `temporal`, `bullmq`:

```bash
task <mod>:deploy                       # deploy the test env into the cluster
task <mod>:run:local                    # run the consumer locally under mirrord (starts the split)
task <mod>:send:match                   # message matches the filter -> your local session
task <mod>:send:nomatch                 # message doesn't match -> cluster consumer
task <mod>:send:match MESSAGE="hello"   # custom message body
task <mod>:logs / status / clean        # support verbs
```

Each module file in [taskfiles/](../taskfiles) has a header comment stating
where its split filter lives (the `mirrord.json` in the module's overlay) and
what routes where. Highlights:

| Module | Filter | Match / no-match |
|---|---|---|
| sqs (LocalStack) | attribute `tenant` ~ `^Avi\.` | `Avi.Test` / `Basic` |
| kafka | header `user_id` = `test-user` | `test-user` / (none) |
| rmq | header `tenant` ~ `^a$` | `a` / `b` |
| pubsub (emulator) | attribute `tenant` ~ `^test` | `test-user` / `other` |
| servicebus (emulator) | property `tenant` ~ `^test` | `test-user` / `other` |
| redis-pubsub | `tenant` ~ `^test` | `test` / `other` |
| temporal | workflow id ~ `^test-alice-` | `test-alice-*` / `test-other-*` |
| bullmq | job data `tenant` ~ `^test` | `test` / `other` |

`task sqs:reset` fully resets split state (sessions, temp queues, operator
restart) when a stale split keeps routing messages to a dead queue.

## Real Azure Service Bus (cloud)

Same flow against a real Azure namespace instead of the emulator. The SAS key
lives only in a cluster secret:

```bash
task servicebus:azure:secret CONN='Endpoint=sb://<ns>.servicebus.windows.net/;SharedAccessKeyName=RootManageSharedAccessKey;SharedAccessKey=...'
task servicebus:azure:deploy            # consumer wired to real Azure
task servicebus:azure:run:local
task servicebus:azure:send:match / send:nomatch [MESSAGE=...]
task servicebus:azure:status / clean    # clean keeps the secret
```

The topic/subscription variant is legacy-only for the single-cluster case
(`task legacy:servicebus:azure:deploy:topic`); the
[multicluster flow](multicluster.md) uses topics natively.
