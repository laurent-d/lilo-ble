const noble = require("@stoprocent/noble");
const lights = ["Off", "Photo (20%)", "Spring (75%)", "Summer (100%)"];

const LILOServiceUUID = "53e11631b8404b2193ce081726ddc739";
const LILOTimeCharacteristicUUID = "53e11633b8404b2193ce081726ddc739";
const LILOLightCharacteristicUUID = "53e11632b8404b2193ce081726ddc739";
const LILOClockServiceUUID = "53e12188b8404b2193ce081726ddc739";
const LILOClockCharacteristicUUID = "53e12189b8404b2193ce081726ddc739";

class LILO {
    static lights = lights;

    constructor(peripheral) {
        this.peripheral = peripheral;
    }

    static async discover() {
        await noble.waitForPoweredOnAsync();
        await noble.startScanningAsync([], false);
        for await (const peripheral of noble.discoverAsync()) {
            if (peripheral.advertisement.localName === "LILO") {
                await noble.stopScanningAsync();
                return new LILO(peripheral);
            }
        }
    }

    // Throws on invalid input, returns the 1-byte payload.
    static lightData(value) {
        if (!Number.isInteger(value) || !(value in lights)) {
            throw new Error(`Invalid light "${value}", expected 0-${lights.length - 1}`);
        }
        return Buffer.from([value]);
    }

    // [startHour, startMinute, endHour, endMinute] -> 4-byte payload.
    static timeData(time) {
        const valid = time.length === 4 && time.every((n, i) =>
            Number.isInteger(n) && n >= 0 && n <= (i % 2 ? 59 : 23));
        if (!valid) {
            throw new Error(`Invalid time "${time}", expected HH,MM,HH,MM`);
        }
        return Buffer.from(time);
    }

    async connect() {
        await this.peripheral.connectAsync();
        const { characteristics } = await this.peripheral.discoverSomeServicesAndCharacteristicsAsync(
            [LILOServiceUUID, LILOClockServiceUUID],
            [LILOLightCharacteristicUUID, LILOTimeCharacteristicUUID, LILOClockCharacteristicUUID]);
        this.light = characteristics.find(c => c.uuid === LILOLightCharacteristicUUID);
        this.time = characteristics.find(c => c.uuid === LILOTimeCharacteristicUUID);
        this.clock = characteristics.find(c => c.uuid === LILOClockCharacteristicUUID);
        if (!this.light || !this.time || !this.clock) {
            throw new Error("LILO light/time/clock characteristics not found (unsupported firmware?)");
        }
    }

    disconnect() {
        return this.peripheral.disconnectAsync();
    }

    // The device clock drifts: the official app writes [hour, minute] on every connection.
    writeClock(date = new Date()) {
        return this.clock.writeAsync(Buffer.from([date.getHours(), date.getMinutes()]), false);
    }

    readLightState() {
        return this.light.readAsync();
    }

    writeLightState(value) {
        return this.light.writeAsync(LILO.lightData(value), false);
    }

    readTimeState() {
        return this.time.readAsync();
    }

    writeTimeState(time) {
        return this.time.writeAsync(LILO.timeData(time), false);
    }
}

module.exports = LILO;
