const dns = require("dns");
const net = require("net");

const targets = [
  "this-does-not-exist.example.com",
  "also-bogus.test.internal",
  "no-such-host.cluster.local",
];

console.log("=== libuv EAI_* assertion repro ===");
console.log(
  "Resolving hostnames through mirrord remote DNS to trigger DNSNoName...\n"
);

let pending = targets.length;

for (const host of targets) {
  console.log(`Looking up: ${host}`);
  dns.lookup(host, { all: true }, (err, addresses) => {
    if (err) {
      console.log(`  ${host} -> error: ${err.code} (${err.message})`);
    } else {
      console.log(`  ${host} -> ${JSON.stringify(addresses)}`);
    }
    pending--;
    if (pending === 0) {
      console.log("\nAll lookups completed without crash.");
      console.log(
        "If you see this, the bug did not reproduce with simple lookups."
      );
      console.log("Trying rapid-fire lookups...\n");
      rapidFire();
    }
  });
}

function rapidFire() {
  let count = 0;
  const total = 50;

  for (let i = 0; i < total; i++) {
    const host = `nonexistent-${i}.example.com`;
    dns.lookup(host, (err, address) => {
      count++;
      if (count % 10 === 0) {
        console.log(`  rapid-fire progress: ${count}/${total}`);
      }
      if (count === total) {
        console.log("\nRapid-fire lookups completed without crash.");
        console.log("Trying socket connect to trigger getaddrinfo via net...\n");
        socketConnect();
      }
    });
  }
}

function socketConnect() {
  const bogusHosts = [
    "fake-broker-1.kafka.internal:9092",
    "fake-broker-2.kafka.internal:9092",
    "fake-broker-3.kafka.internal:9092",
  ];

  let done = 0;
  for (const target of bogusHosts) {
    const [host, port] = target.split(":");
    console.log(`Connecting to ${target}...`);
    const sock = net.createConnection({ host, port: parseInt(port) }, () => {
      console.log(`  ${target} -> connected (unexpected)`);
      sock.destroy();
    });
    sock.on("error", (err) => {
      console.log(`  ${target} -> ${err.code}: ${err.message}`);
      done++;
      if (done === bogusHosts.length) {
        console.log("\nAll socket connects completed without crash.");
        console.log("Done. If no assertion fired, try with different DNS scenarios.");
        process.exit(0);
      }
    });
    sock.setTimeout(5000, () => {
      console.log(`  ${target} -> timeout`);
      sock.destroy();
    });
  }
}
