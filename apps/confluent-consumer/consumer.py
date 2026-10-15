"""librdkafka test consumer for the confluent:* sandbox tasks.

Stands in for quix-streams / confluent-kafka apps: the same librdkafka the
operator's forwarder uses, but joining its group with a configurable
partition.assignment.strategy. With `cooperative-sticky` (the default here) the
group's protocol differs from the forwarder's `range,roundrobin`, which is what
reproduces INCONSISTENT_GROUP_PROTOCOL without any KafkaJS involved. Reads the
same env vars as the other sandbox consumers so the operator's env patches
apply to both the cluster pod and a local run under mirrord.
"""

import os
import signal
import sys
import time

from confluent_kafka import Consumer, KafkaException

BOOTSTRAP = os.environ.get(
    "KAFKA_BOOTSTRAP_SERVERS", "kafka-cluster.test-mirrord.svc.cluster.local:9092"
)
GROUP_ID = os.environ.get("KAFKA_GROUP_ID", "confluent-consumer-group")
TOPIC = os.environ.get("KAFKA_TOPIC_NAME", "test-topic")
STRATEGY = os.environ.get("KAFKA_ASSIGNMENT_STRATEGY", "cooperative-sticky")

stopping = False


def log(message):
    print(f"[confluent-consumer] {message}", flush=True)


def handle_signal(signum, _frame):
    global stopping
    log(f"received signal {signum}, closing the consumer cleanly")
    stopping = True


for sig in (signal.SIGTERM, signal.SIGINT):
    signal.signal(sig, handle_signal)

log(f"starting: brokers={BOOTSTRAP} group={GROUP_ID} topic={TOPIC} strategy={STRATEGY}")


def run_once():
    consumer = Consumer(
        {
            "bootstrap.servers": BOOTSTRAP,
            "group.id": GROUP_ID,
            "auto.offset.reset": "earliest",
            "partition.assignment.strategy": STRATEGY,
        }
    )
    try:
        consumer.subscribe([TOPIC])
        log("subscribed, waiting for messages")
        while not stopping:
            message = consumer.poll(1.0)
            if message is None:
                continue
            if message.error():
                raise KafkaException(message.error())
            headers = ",".join(
                f"{key}={value.decode() if value else ''}"
                for key, value in (message.headers() or [])
            )
            value = message.value().decode(errors="replace") if message.value() else ""
            log(f"received: {value} (topic={message.topic()} headers={headers})")
    finally:
        # A clean close sends LeaveGroup, so the pod's membership ends at once
        # instead of lingering until the broker's session timeout.
        consumer.close()


# The sandbox broker has no persistent storage, so a broker restart wipes topics
# and drops connections mid-run. Retry instead of exiting: a crash-looping pod
# never turns Ready and blocks the deploy task's wait.
while not stopping:
    try:
        run_once()
    except KafkaException as error:
        log(f"failed, retrying in 5s: {error}")
        time.sleep(5)

sys.exit(0)
