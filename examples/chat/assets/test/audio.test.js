import {test} from 'node:test';
import assert from 'node:assert/strict';

globalThis.document = {addEventListener() {}};
globalThis.window = {addEventListener() {}, removeEventListener() {}};
let context;
globalThis.AudioContext = class {
  constructor() {context = this; this.currentTime = 0; this.state = 'running';}
  resume() {this.state = 'running';}
  createBuffer(_, samples, rate) {return {duration: samples / rate, getChannelData: () => new Float32Array(samples)};}
  createBufferSource() {return {connect() {}, start() {}, stop() {this.stopped = true;}};}
};
const {Player} = await import('../js/audio.js');

test('reports elapsed PCM only, excluding future queue and paused clock; flush reports before stopping', () => {
  const handlers = {}, reports = [];
  const player = {...Player, handleEvent(name, fn) {handlers[name] = fn;}, pushEvent(name, data) {reports.push({name, ...data});}};
  player.mounted();
  try {
    const pcm = Buffer.alloc(32_000).toString('base64'); // one second at 16kHz
    handlers.play({pcm, rate: 16_000, token: 'one'});
    handlers.play({pcm, rate: 16_000, token: 'one'});
    player.report();
    assert.equal(reports.at(-1).ns, 0);
    context.currentTime = 0.4;
    player.report();
    assert.equal(reports.at(-1).ns, 400_000_000);
    context.state = 'suspended';
    player.report(); // AudioContext clock does not advance when suspended
    assert.equal(reports.at(-1).ns, 400_000_000);
    const sources = [...player.sources];
    handlers.flush();
    assert.equal(reports.at(-1).ns, 400_000_000);
    assert.ok(sources.every(source => source.stopped));
    assert.equal(player.sources.size, 0);
    const count = reports.length;
    player.report();
    assert.equal(reports.length, count);
    context.currentTime = 3;
    handlers.play({pcm, rate: 16_000, token: 'two'});
    player.report();
    assert.equal(reports.at(-1).token, 'two');
    assert.equal(reports.at(-1).ns, 0);
    context.currentTime = 9;
    player.report();
    assert.equal(reports.at(-1).ns, 1_000_000_000); // bounded by delivered PCM
    handlers.flush();
    const singleSample = Buffer.alloc(2).toString("base64");
    handlers.play({pcm: singleSample, rate: 24_000, token: "rounded"});
    handlers.play({pcm: singleSample, rate: 24_000, token: "rounded"});
    context.currentTime = 10;
    player.report();
    assert.equal(reports.at(-1).ns, 83_334); // per-chunk ceiling matches Session checkpoints
  } finally {player.destroyed();}
});
