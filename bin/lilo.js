#!/usr/bin/env node

const { parseArgs } = require("node:util");
const LILO = require("../lib/lilo");

const { lights } = LILO;

const help = `Usage: lilo [options]

Options:
  -l, --light <0-3>         Set light mode: ${lights.map((name, i) => `${i} ${name}`).join(", ")}
  -t, --time <HH,MM,HH,MM>  Set lighting time range, e.g. 9,0,23,0 for 09:00 - 23:00
  -r, --read                Read current configuration without changing it
  -h, --help                Show this help

The LILO clock is set to the computer time on every run.
The current configuration is always printed after changes.

Examples:
  lilo -r
  lilo -l 3 -t 9,0,23,0
  lilo -l 0               (turn the light off, time range unchanged)`;

let values;
try {
    ({ values } = parseArgs({
        options: {
            light: { type: "string", short: "l" },
            time: { type: "string", short: "t" },
            read: { type: "boolean", short: "r" },
            help: { type: "boolean", short: "h" },
        },
    }));
} catch (error) {
    console.error(`${error.message}\n\n${help}`);
    process.exit(1);
}

if (values.help || Object.keys(values).length === 0) {
    console.log(help);
    process.exit(0);
}

// macOS kills the process (uncatchable SIGABRT) when the terminal app doesn't declare
// Bluetooth usage, so run the Bluetooth work in a child and explain its death.
if (process.platform === "darwin" && !process.env.LILO_CHILD) {
    const { spawnSync } = require("node:child_process");
    const { status, signal } = spawnSync(process.execPath, process.argv.slice(1), {
        stdio: "inherit",
        env: { ...process.env, LILO_CHILD: "1" },
    });
    if (signal === "SIGABRT") {
        console.error(`macOS blocked Bluetooth access for this terminal app.
Run lilo from a terminal that declares Bluetooth usage, such as VS Code's integrated terminal.
Terminal.app and Warp don't.`);
        process.exit(1);
    }
    process.exit(status ?? 1);
}

const light = values.light === undefined ? undefined : Number(values.light);
const time = values.time?.split(",").map(Number);
const pad = n => String(n).padStart(2, "0");
const formatTime = ([h1, m1, h2, m2]) => `${pad(h1)}:${pad(m1)} - ${pad(h2)}:${pad(m2)}`;

let timeoutMessage = "LILO not found.";
setTimeout(() => {
    console.error(timeoutMessage);
    process.exit(1);
}, 30000).unref();

(async () => {
    // Fail before scanning rather than after connecting.
    if (light !== undefined) LILO.lightData(light);
    if (time) LILO.timeData(time);

    const lilo = await LILO.discover();
    timeoutMessage = "LILO found but not responding.";
    console.log("LILO Discovered.");
    try {
        console.log("Connecting...");
        await lilo.connect();
        const now = new Date();
        await lilo.writeClock(now);
        console.log(`Clock set to ${pad(now.getHours())}:${pad(now.getMinutes())}`);
        if (light !== undefined) {
            console.log(`Changing light settings to ${lights[light]}`);
            await lilo.writeLightState(light);
        }
        if (time) {
            console.log(`Changing time to ${formatTime(time)}`);
            await lilo.writeTimeState(time);
        }
        const [l] = await lilo.readLightState();
        console.log(`Light : ${lights[l] ?? `unknown (${l})`}`);
        console.log(`Time  : ${formatTime(await lilo.readTimeState())}`);
    } finally {
        await lilo.disconnect();
        console.log("Disconnection.");
    }
    process.exit(0); // noble keeps the event loop alive
})().catch(error => {
    console.error(error.message);
    process.exit(1);
});
