// KafkaJS test consumer for the kafkajs:* sandbox tasks.
//
// KafkaJS advertises the `RoundRobinAssigner` group protocol name when joining
// its consumer group, which the operator's librdkafka forwarder cannot
// negotiate with - this app is what reproduces that clash. Reads the same env
// vars as the Go consumer (KAFKA_BOOTSTRAP_SERVERS, KAFKA_GROUP_ID,
// KAFKA_TOPIC_NAME) so both cluster and local-under-mirrord runs pick up the
// operator's env patches.
const { Kafka, logLevel } = require("kafkajs");

const bootstrap =
  process.env.KAFKA_BOOTSTRAP_SERVERS ||
  "kafka-cluster.test-mirrord.svc.cluster.local:9092";
const groupId = process.env.KAFKA_GROUP_ID || "kafkajs-consumer-group";
const topic = process.env.KAFKA_TOPIC_NAME || "test-topic";

console.log(
  `[kafkajs-consumer] starting: brokers=${bootstrap} group=${groupId} topic=${topic}`,
);

const kafka = new Kafka({
  clientId: "kafkajs-consumer",
  brokers: bootstrap.split(","),
  logLevel: logLevel.ERROR,
});

let consumer = null;
let stopping = false;

async function runOnce() {
  consumer = kafka.consumer({ groupId });
  await consumer.connect();
  await consumer.subscribe({ topic, fromBeginning: true });
  console.log("[kafkajs-consumer] subscribed, waiting for messages");

  await consumer.run({
    eachMessage: async ({ topic, message }) => {
      const headers = Object.entries(message.headers || {})
        .map(([k, v]) => `${k}=${v}`)
        .join(",");
      console.log(
        `[kafkajs-consumer] received: ${message.value} (topic=${topic} headers=${headers})`,
      );
    },
  });
}

// The sandbox broker has no persistent storage, so a broker restart wipes
// topics and drops connections mid-run. Retry forever instead of exiting: a
// crash-looping pod never turns Ready and blocks the deploy task's wait.
async function main() {
  while (!stopping) {
    try {
      await runOnce();
      return;
    } catch (error) {
      console.error(`[kafkajs-consumer] failed, retrying in 5s: ${error}`);
      try {
        await consumer?.disconnect();
      } catch {}
      await new Promise((resolve) => setTimeout(resolve, 5000));
    }
  }
}

for (const signal of ["SIGTERM", "SIGINT"]) {
  process.once(signal, async () => {
    stopping = true;
    console.log("[kafkajs-consumer] shutting down");
    try {
      await consumer?.disconnect();
    } finally {
      process.exit(0);
    }
  });
}

main();
