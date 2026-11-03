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

test('real suspension preserves sources, serializes resume and rejects stale commands', async () => {
  const handlers = {}, reports = [];
  const player = {...Player, handleEvent(name, fn) {handlers[name] = fn;}, pushEvent(name, data) {reports.push({name, ...data});}};
  player.mounted();
  try {
    handlers.play({pcm: Buffer.alloc(32_000).toString('base64'), rate: 16_000, token: 'pause-turn'});
    const sources = [...player.sources];
    let suspended;
    context.suspend = () => new Promise(resolve => { suspended = () => {context.state = 'suspended'; resolve();}; });
    const operations = [];
    context.resume = async () => { operations.push('resume'); context.state = 'running'; };
    context.currentTime += 0.25;
    handlers.output_control({token: 'pause-turn', id: 'candidate', action: 'pause'});
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(reports.filter(x => x.name === 'output_ack').length, 0);
    handlers.output_control({token: 'pause-turn', id: 'candidate', action: 'resume'});
    assert.deepEqual(operations, []);
    suspended();
    await player.commands;
    assert.deepEqual(reports.filter(x => x.name === 'output_ack').map(x => [x.action, x.ns]), [['pause', 250_000_000], ['resume', 250_000_000]]);
    assert.deepEqual([...player.sources], sources);
    assert.ok(sources.every(source => !source.stopped));
    handlers.output_control({token: 'old-turn', id: 'old', action: 'pause'});
    await player.commands;
    assert.equal(reports.filter(x => x.name === 'output_ack').length, 2);
    handlers.output_control({token: 'pause-turn', id: 'race', action: 'pause'});
    await new Promise(resolve => setImmediate(resolve));
    handlers.flush({token: 'pause-turn'});
    suspended();
    await player.commands;
    assert.equal(reports.filter(x => x.id === 'race').length, 0);
    assert.equal(context.state, 'running');
    assert.ok(sources.every(source => source.stopped));
  } finally {player.destroyed();}
});

test('new PCM and user gestures do not resume an intentional pause; endpoint errors report failure', async () => {
  const handlers = {}, reports = [];
  const player = {...Player, handleEvent(name, fn) {handlers[name] = fn;}, pushEvent(name, data) {reports.push({name, ...data});}};
  player.mounted();
  try {
    const play = {pcm: Buffer.alloc(32_000).toString('base64'), rate: 16_000, token: 'error-turn'};
    handlers.play(play);
    let resumes = 0;
    context.resume = async () => {resumes++; context.state = 'running';};
    context.suspend = async () => {context.state = 'suspended';};
    handlers.output_control({token: play.token, id: 'c', action: 'pause'});
    await player.commands;
    const next = player.next;
    handlers.play(play);
    assert.equal(resumes, 0);
    assert.equal(player.next, next + 1);
    assert.equal(context.state, 'suspended');
    context.resume = async () => {throw new Error('driver failure');};
    handlers.output_control({token: play.token, id: 'c', action: 'resume'});
    await player.commands;
    assert.equal(reports.at(-1).name, 'output_failed');
    assert.match(reports.at(-1).message, /driver failure/);
  } finally {player.destroyed();}
});

test('pause before the first PCM holds later audio against the frozen clock', async () => {
  const handlers = {}, reports = [];
  const player = {...Player, handleEvent(name, fn) {handlers[name] = fn;}, pushEvent(name, data) {reports.push({name, ...data});}};
  player.mounted();
  try {
    handlers.output_start({token: 'early'});
    context.suspend = async () => {context.state = 'suspended';};
    context.resume = async () => {context.state = 'running';};
    handlers.output_control({token: 'early', id: 'early-candidate', action: 'pause'});
    await player.commands;
    assert.equal(reports.at(-1).name, 'output_ack');
    assert.equal(reports.at(-1).ns, 0);
    handlers.play({pcm: Buffer.alloc(32_000).toString('base64'), rate: 16_000, token: 'early'});
    assert.equal(context.state, 'suspended');
    assert.equal(player.rendered(), 0);
    assert.equal(player.sources.size, 1);
  } finally {player.destroyed();}
});
