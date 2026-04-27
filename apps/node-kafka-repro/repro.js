/**
 * Reproduces the Kafka multi-connection issue reported by monday.com.
 *
 * Mimics the customer's pattern:
 *  - Multiple producers (each opens its own broker connection)
 *  - Multiple consumers with different group IDs
 *  - All connections go through mirrord's outgoing proxy
 *
 * The customer sees SASL_SSL handshake timeouts on secondary broker connections.
 * Even without SASL, this tests whether mirrord's outgoing proxy handles
 * many concurrent Kafka connections correctly.
 */

const { Kafka, logLevel } = require("kafkajs");
const tls = require("tls");

const BROKER =
  process.env.KAFKA_BOOTSTRAP_SERVERS ||
  "kafka-cluster.test-mirrord.svc.cluster.local:9092";
const TOPIC = process.env.KAFKA_TOPIC || "test-topic";
const NUM_PRODUCERS = parseInt(process.env.NUM_PRODUCERS || "4", 10);
const NUM_CONSUMERS = parseInt(process.env.NUM_CONSUMERS || "3", 10);
const PRODUCE_INTERVAL_MS = parseInt(
  process.env.PRODUCE_INTERVAL_MS || "1000",
  10
);
const SASL_USER = process.env.KAFKA_SASL_USERNAME;
const SASL_PASS = process.env.KAFKA_SASL_PASSWORD;
const SASL_MECHANISM = process.env.KAFKA_SASL_MECHANISM || "scram-sha-512";
const USE_SSL = process.env.KAFKA_SSL === "true";

const useSasl = !!(SASL_USER && SASL_PASS);

console.log("=== Kafka multi-connection repro ===");
console.log(`Broker: ${BROKER}`);
console.log(`Topic: ${TOPIC}`);
console.log(`SSL: ${USE_SSL ? "enabled" : "disabled"}`);
console.log(`SASL: ${useSasl ? `${SASL_MECHANISM} (user: ${SASL_USER})` : "disabled"}`);
console.log(`Producers: ${NUM_PRODUCERS}, Consumers: ${NUM_CONSUMERS}`);
console.log();

const kafkaConfig = {
  clientId: "mirrord-repro",
  brokers: [BROKER],
  logLevel: logLevel.INFO,
  connectionTimeout: 10000,
  requestTimeout: 30000,
  retry: { retries: 3 },
};

if (useSasl) {
  kafkaConfig.sasl = {
    mechanism: SASL_MECHANISM,
    username: SASL_USER,
    password: SASL_PASS,
  };
}

if (USE_SSL) {
  kafkaConfig.ssl = {
    rejectUnauthorized: false,
  };
}

const kafka = new Kafka(kafkaConfig);

async function startProducer(id) {
  const producer = kafka.producer({
    allowAutoTopicCreation: true,
  });

  console.log(`[producer-${id}] connecting...`);
  const start = Date.now();
  await producer.connect();
  console.log(`[producer-${id}] connected (${Date.now() - start}ms)`);

  let msgCount = 0;
  const interval = setInterval(async () => {
    try {
      msgCount++;
      await producer.send({
        topic: TOPIC,
        messages: [
          {
            key: `producer-${id}`,
            value: JSON.stringify({
              producer: id,
              seq: msgCount,
              ts: new Date().toISOString(),
            }),
            headers: { "routing-key": "test-user" },
          },
        ],
      });
      if (msgCount % 5 === 0) {
        console.log(`[producer-${id}] sent ${msgCount} messages`);
      }
    } catch (err) {
      console.error(`[producer-${id}] send error: ${err.message}`);
    }
  }, PRODUCE_INTERVAL_MS);

  return { producer, interval };
}

async function startConsumer(id) {
  const groupId = `repro-consumer-${id}`;
  const consumer = kafka.consumer({
    groupId,
    sessionTimeout: 30000,
    heartbeatInterval: 3000,
  });

  console.log(`[consumer-${id}] connecting (group: ${groupId})...`);
  const start = Date.now();
  await consumer.connect();
  console.log(`[consumer-${id}] connected (${Date.now() - start}ms)`);

  await consumer.subscribe({ topic: TOPIC, fromBeginning: false });

  let received = 0;
  await consumer.run({
    eachMessage: async ({ topic, partition, message }) => {
      received++;
      if (received % 10 === 0) {
        console.log(
          `[consumer-${id}] received ${received} messages (latest: partition=${partition} offset=${message.offset})`
        );
      }
    },
  });

  return consumer;
}

async function main() {
  const producers = [];
  const consumers = [];

  try {
    // Start all producers concurrently (mimics librdkafka opening
    // multiple connections to partition leaders after metadata fetch)
    console.log("\n--- Starting producers concurrently ---");
    const producerPromises = [];
    for (let i = 1; i <= NUM_PRODUCERS; i++) {
      producerPromises.push(startProducer(i));
    }
    const producerResults = await Promise.all(producerPromises);
    producers.push(...producerResults);
    console.log(`\nAll ${NUM_PRODUCERS} producers connected.\n`);

    // Start all consumers concurrently
    console.log("--- Starting consumers concurrently ---");
    const consumerPromises = [];
    for (let i = 1; i <= NUM_CONSUMERS; i++) {
      consumerPromises.push(startConsumer(i));
    }
    const consumerResults = await Promise.all(consumerPromises);
    consumers.push(...consumerResults);
    console.log(`\nAll ${NUM_CONSUMERS} consumers connected.\n`);

    console.log(
      "=== All connections established. Producing/consuming messages... ==="
    );
    console.log("Press Ctrl+C to stop.\n");

    // Keep running until interrupted
    await new Promise((resolve) => {
      process.on("SIGINT", resolve);
      process.on("SIGTERM", resolve);
    });
  } catch (err) {
    console.error(`\nFATAL ERROR: ${err.message}`);
    console.error(err.stack);
    process.exitCode = 1;
  } finally {
    console.log("\nShutting down...");
    for (const { producer, interval } of producers) {
      clearInterval(interval);
      await producer.disconnect().catch(() => {});
    }
    for (const consumer of consumers) {
      await consumer.disconnect().catch(() => {});
    }
    console.log("Done.");
  }
}

main();
