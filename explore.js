#!/usr/bin/env node
// Read-only dump of every readable characteristic, then logs notifications.
// Usage: node explore.js [seconds-to-listen]   (default 60)

const noble = require("@stoprocent/noble");

const listen = Number(process.argv[2] ?? 60) * 1000;
const show = buf => `${buf.toString("hex").match(/../g)?.join(" ") ?? "(empty)"}  ${JSON.stringify(buf.toString("latin1"))}`;

(async () => {
    await noble.waitForPoweredOnAsync();
    await noble.startScanningAsync([], false);
    let peripheral;
    for await (const p of noble.discoverAsync()) {
        if (p.advertisement.localName === "LILO") { peripheral = p; break; }
    }
    await noble.stopScanningAsync();
    console.log("Advertisement:", JSON.stringify(peripheral.advertisement));

    await peripheral.connectAsync();
    const { characteristics } = await peripheral.discoverAllServicesAndCharacteristicsAsync();
    for (const c of characteristics) {
        const line = `${c._serviceUuid} / ${c.uuid} [${c.properties.join(",")}]`;
        if (c.properties.includes("read")) {
            try { console.log(line, "=", show(await c.readAsync())); }
            catch (e) { console.log(line, "read error:", e.message); }
        } else {
            console.log(line);
        }
        if (c.properties.includes("notify") || c.properties.includes("indicate")) {
            c.on("data", data => console.log(new Date().toLocaleTimeString(), "NOTIFY", c.uuid, "=", show(data)));
            await c.subscribeAsync();
        }
    }

    console.log(`Listening for notifications for ${listen / 1000}s...`);
    setTimeout(async () => {
        await peripheral.disconnectAsync();
        process.exit(0);
    }, listen);
})().catch(error => {
    console.error(error.message);
    process.exit(1);
});
