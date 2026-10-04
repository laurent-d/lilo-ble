const assert = require("node:assert");
const test = require("node:test");
const LILO = require("../lib/lilo");

test("payload validation", () => {
    assert.deepStrictEqual(LILO.lightData(3), Buffer.from([3]));
    assert.deepStrictEqual(LILO.timeData([10, 0, 22, 15]), Buffer.from([10, 0, 22, 15]));
    assert.throws(() => LILO.lightData(4));
    assert.throws(() => LILO.lightData(NaN));
    assert.throws(() => LILO.timeData([10, 0, 22]));
    assert.throws(() => LILO.timeData([24, 0, 22, 15]));
    assert.throws(() => LILO.timeData([10, 60, 22, 15]));
});
