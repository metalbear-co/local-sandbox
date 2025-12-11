# mirrord Operator Test Sandbox

Local testing environment for mirrord operator features.

## Prerequisites

- minikube, task, kubectl, helm, docker

## Quick Start

```bash
task license:generate
task cluster:create

task test:mysql
task test:mariadb
task test:postgres
task test:sqs
task test:kafka
```


## Clean Tests (Delete + Recreate Cluster)

```bash
task test:mysql:clean
task test:mariadb:clean
task test:postgres:clean
task test:sqs:clean
task test:kafka:clean
```

## Development

```bash
task build:operator
task operator:update

task logs:operator

task cluster:delete
task --list
```

## Discover All Available Commands

List all available tasks:

```bash
task --list
```

List all tasks including internal ones:

```bash
task --list-all
```

Search for specific tasks:

```bash
task --list | grep mysql
task --list | grep postgres
task --list | grep kafka
```
