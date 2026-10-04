# LILO

Control a **Prêt à Pousser LILO** indoor garden over Bluetooth Low Energy from your computer: set the light mode, the lighting schedule, and keep the device clock on time — no phone app needed.

> Unofficial project. Not affiliated with, endorsed by, or supported by Prêt à Pousser. "LILO" and "Prêt à Pousser" are trademarks of their respective owner.

## What is the LILO?

The [LILO](https://pretapousser.com/en/collections/jardins-interieur/) is a compact indoor garden made by **Prêt à Pousser**, a Paris-based company founded in 2013. It holds three plant pods under an LED lamp. The Bluetooth version is configured through the official Prêt à Pousser mobile app, which sets the light intensity and the daily lighting window.

The device itself is simple: a programmable lamp with an internal clock. This project talks to it directly.

## Why this project

At the time of writing (October 2026), the official Prêt à Pousser app is broken on iOS 27, which leaves the LILO stuck with whatever settings it last received and a drifting clock. This fork started as a way to keep controlling the device from a computer in the meantime. An app fix will likely come, but having an open, app-independent way to drive the device is useful anyway.

## Features

- Set the light mode: Off, Photo (20%), Spring (75%), Summer (100%)
- Set the daily lighting window (start and end time)
- Sync the device clock with your computer on every run (the internal clock drifts, the official app does the same)
- Read the current configuration
- `scripts/explore.js`: read-only dump of every GATT characteristic, for further investigation

## Requirements

- Node.js 18 or later
- A Bluetooth LE adapter
- macOS, Linux or Windows (Bluetooth via [@stoprocent/noble](https://github.com/stoprocent/noble))

## Installation

```sh
git clone https://github.com/laurent-d/lilo-ble.git
cd lilo-ble
npm install
npm link    # optional: installs the `lilo` command globally
```

Without `npm link`, run `./bin/lilo.js` instead of `lilo` in the examples below.

### macOS

macOS asks for Bluetooth permission on first run. The permission is granted to the **terminal app**, and that app must declare Bluetooth usage: run the script from **VS Code's integrated terminal** or **iTerm2**. Terminals that don't declare it (Terminal.app, Warp) are killed by macOS and the script exits with a bare `abort`.

If nothing happens or you get `Timeout waiting for Noble to be powered on`, check *System Settings → Privacy & Security → Bluetooth*.

### Linux

Noble needs raw access to the adapter. Either run with `sudo`, or grant the capability to Node once:

```sh
sudo setcap cap_net_raw+eip $(eval readlink -f $(which node))
```

`scripts/schedule.sh` stops the BlueZ service and brings `hci0` up before running.

## Usage

Close the Prêt à Pousser app on your phone first: the LILO accepts one connection at a time.

```text
Usage: lilo [options]

Options:
  -l, --light <0-3>         Set light mode: 0 Off, 1 Photo (20%), 2 Spring (75%), 3 Summer (100%)
  -t, --time <HH,MM,HH,MM>  Set lighting time range, e.g. 9,0,23,0 for 09:00 - 23:00
  -r, --read                Read current configuration without changing it
  -h, --help                Show this help

The LILO clock is set to the computer time on every run.
The current configuration is always printed after changes.
```

Examples:

```sh
lilo -r                  # sync the clock and print the configuration
lilo -l 3 -t 6,0,22,0    # Summer, light on from 06:00 to 22:00
lilo -l 0                # turn the light off, schedule unchanged
```

```text
LILO Discovered.
Connecting...
Clock set to 20:22
Changing light settings to Summer (100%)
Changing time to 06:00 - 22:00
Light : Summer (100%)
Time  : 06:00 - 22:00
Disconnection.
```

The script gives up after 30 seconds if the LILO is not found or does not respond, and exits with code 1 on any error.

### Scheduled run

`scripts/schedule.sh` applies a weekday/weekend schedule and is meant to be run from cron on Linux (for example a Raspberry Pi next to the garden). On macOS, a cron job has no terminal app to hold the Bluetooth permission and will likely be killed.

### As a library

```js
const LILO = require("lilo-ble"); // or require("./lib/lilo") from a clone

const lilo = await LILO.discover();
await lilo.connect();
await lilo.writeClock();            // current time
await lilo.writeLightState(3);      // Summer
await lilo.writeTimeState([6, 0, 22, 0]);
console.log(await lilo.readLightState(), await lilo.readTimeState());
await lilo.disconnect();
```

## Recommended settings

The official app picks a preset from the plants in the pods:

| Preset | Plants | Mode | Default window | Duration the app considers optimal |
| --- | --- | --- | --- | --- |
| Summer | Most plants: basils, mint, thyme, chives, salads, rocket, tomatoes, peppers, strawberries… | Summer (100%) | 06:00 – 22:00 | 15h30 – 16h30 |
| Spring | Dill, coriander, curly and flat parsley, pansy | Spring (75%) | 10:00 – 22:00 | 11h30 – 12h30 |
| Mixed | Summer and Spring plants together | Spring (75%) | 08:00 – 22:00 | 13h30 – 14h30 |

```sh
lilo -l 3 -t 6,0,22,0    # Summer
lilo -l 2 -t 10,0,22,0   # Spring
lilo -l 2 -t 8,0,22,0    # Mixed
```

## Protocol

The device advertises as `LILO`. All writes are *write with response*.

| Service | Characteristic | Access | Format |
| --- | --- | --- | --- |
| `53e11631-b840-4b21-93ce-081726ddc739` | `53e11632-…` light mode | read, write | 1 byte: `0` Off, `1` Photo (20%), `2` Spring (75%), `3` Summer (100%) |
| | `53e11633-…` lighting window | read, write | 4 bytes: `[startHour, startMinute, endHour, endMinute]` |
| `53e12188-b840-4b21-93ce-081726ddc739` | `53e12189-…` device clock | write (reads return `00`) | 2 bytes: `[hour, minute]`, local time |
| `180a` Device Information | `2a29` manufacturer | read | `PRET A POUSSER` |
| | `2a26` firmware revision | read | e.g. `1.1.1` |
| `53e13908-b840-4b21-93ce-081726ddc739` | `53e13909-…` | notify | Unused by the official app |

Notes:

- The lamp is on when the device clock is inside the window. It re-evaluates immediately after a write.
- The window cannot span midnight in this tool (start must be before end).
- The clock drifts by a few minutes over months and has no time zone or DST handling: sync it regularly (every run of `lilo` does).

`docs/gatt-dump.json` is the GATT dump of the device. `scripts/explore.js` reads every readable characteristic and logs notifications:

```sh
node scripts/explore.js 60    # listen for 60 seconds
```

## Development

```text
bin/lilo.js            CLI
lib/lilo.js            LILO class: discovery, connection, payload validation, read/write
scripts/explore.js     read-only GATT explorer
scripts/schedule.sh    weekday/weekend schedule for cron
test/                  node:test suite
docs/gatt-dump.json    GATT dump of the device
```

```sh
npm test
```

## Credits

- Original reverse engineering and CLI by [Jérémie Zarca](https://github.com/jzarca01/LILO) (2017).
- Port to `@stoprocent/noble` and modern Node.js, macOS support, device clock sync and protocol documentation in this fork. The clock characteristic and the presets were identified by studying the official Android app, for interoperability purposes only. No code or assets from the app are included in this repository.

## License

ISC, as declared by the original project.
