import { Room, RoomEvent, Track, type RemoteTrack } from 'livekit-client';

// A new receiver per finite utterance; no local media capture or publication.
export class Receiver {
  private tracks = new Set<RemoteTrack>();
  private ready = false;
  private playbackEnabled = false;
  private closed = false;
  constructor(
    private container: Pick<HTMLElement, 'append'>,
    private subscribed: () => void,
    private failed: (message: string) => void,
    readonly room = new Room(),
  ) {
    room.on(RoomEvent.TrackSubscribed, this.attach);
    room.on(RoomEvent.TrackUnsubscribed, this.detach);
    room.on(RoomEvent.TrackSubscriptionFailed, this.failure);
    room.on(RoomEvent.Disconnected, this.disconnected);
  }
  private attach = (track: RemoteTrack) => {
    if (this.closed || this.tracks.has(track)) return;
    if (track.kind !== Track.Kind.Audio && track.kind !== Track.Kind.Video) return;
    this.tracks.add(track);
    const element = track.attach();
    element.autoplay = true;
    if (element instanceof HTMLVideoElement) element.playsInline = true;
    this.container.append(element);
    this.checkReady();
  };
  private checkReady() {
    if (!this.closed && !this.ready && this.playbackEnabled && [Track.Kind.Audio, Track.Kind.Video].every(kind =>
      [...this.tracks].some(t => t.kind === kind))) {
      this.ready = true;
      this.subscribed();
    }
  }
  private detach = (track: RemoteTrack) => {
    for (const element of track.detach()) element.remove();
    this.tracks.delete(track);
  };
  private failure = () => this.failed('Provider track subscription failed');
  private disconnected = () => {
    if (!this.closed) this.failed('Provider room disconnected');
    void this.close();
  };
  async connect(url: string, token: string) {
    try {
      await this.room.connect(url, token, { autoSubscribe: true });
      if (this.closed) await this.room.disconnect();
    } catch {
      if (!this.closed) this.failed('LiveKit connection failed; check account, network and TURN');
      await this.close();
    }
  }
  // Invoke directly from a click to satisfy browser autoplay policies.
  async play() {
    await Promise.all([this.room.startAudio(), this.room.startVideo()]);
    this.playbackEnabled = true;
    this.checkReady();
  }
  async close() {
    if (this.closed) return;
    this.closed = true;
    this.room.off(RoomEvent.TrackSubscribed, this.attach);
    this.room.off(RoomEvent.TrackUnsubscribed, this.detach);
    this.room.off(RoomEvent.TrackSubscriptionFailed, this.failure);
    this.room.off(RoomEvent.Disconnected, this.disconnected);
    for (const track of [...this.tracks]) this.detach(track);
    await this.room.disconnect();
  }
}
