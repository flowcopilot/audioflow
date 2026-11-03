import { test } from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { Room, RoomEvent, Track, type RemoteTrack } from 'livekit-client';
import { Receiver } from './receiver';
class FakeRoom extends EventEmitter {
  disconnected = 0;
  audio = 0; video = 0;
  async connect() {}
  async disconnect() { this.disconnected++; }
  async startAudio() { this.audio++; }
  async startVideo() { this.video++; }
}
// Only media and transport are fixtures; Receiver imports the installed SDK.
Object.assign(globalThis, {HTMLVideoElement: class {}});
function track(kind: Track.Kind) {
  const element = {autoplay: false, removed: 0, remove() { this.removed++; }};
  return {kind, element, attach() { return element; }, detach() { return [element]; }};
}
test('both synchronized provider tracks attach once; readiness waits for both; unsubscribe and close remove media/listeners', async () => {
  const room = new FakeRoom(), attached: unknown[] = [];
  let ready = 0;
  const receiver = new Receiver({append: (...elements) => { attached.push(...elements); }}, () => ready++, assert.fail, room as unknown as Room);
  await receiver.connect('wss://fixture', 'room-subscription-token');
  const audio = track(Track.Kind.Audio), video = track(Track.Kind.Video);
  room.emit(RoomEvent.TrackSubscribed, audio as unknown as RemoteTrack);
  room.emit(RoomEvent.TrackSubscribed, audio);
  assert.equal(ready, 0);
  room.emit(RoomEvent.TrackSubscribed, video);
  assert.equal(ready, 0); assert.equal(attached.length, 2);
  await receiver.play(); assert.equal(room.audio, 1); assert.equal(room.video, 1);
  assert.equal(ready, 1);
  room.emit(RoomEvent.TrackUnsubscribed, audio);
  assert.equal(audio.element.removed, 1);
  await receiver.close(); await receiver.close();
  assert.equal(video.element.removed, 1); assert.equal(room.disconnected, 1);
  assert.equal(room.eventNames().length, 0);
});
test('room disconnect and subscription failure surface errors and clear tracks', async () => {
  const room = new FakeRoom(), errors: string[] = [];
  const receiver = new Receiver({append() {}}, () => {}, e => errors.push(e), room as unknown as Room);
  const audio = track(Track.Kind.Audio);
  room.emit(RoomEvent.TrackSubscribed, audio);
  room.emit(RoomEvent.TrackSubscriptionFailed, 'sid');
  room.emit(RoomEvent.Disconnected);
  await receiver.close();
  assert.equal(errors.length, 2); assert.equal(audio.element.removed, 1);
  assert.equal(room.eventNames().length, 0);
});
test('connect failure surfaces useful error and cleans up', async () => {
  const room = new FakeRoom(); room.connect = async () => { throw Error('fixture'); };
  const errors: string[] = [];
  const receiver = new Receiver({append() {}}, () => {}, e => errors.push(e), room as unknown as Room);
  await receiver.connect('wss://fixture', 'token');
  assert.equal(errors.length, 1); assert.equal(room.disconnected, 1);
});
