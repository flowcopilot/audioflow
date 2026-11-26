defmodule AudioFlowSFU.LiveKit.Proto.AudioCodec do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "livekit.AudioCodec",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field(:DEFAULT_AC, 0)
  field(:OPUS, 1)
  field(:AAC, 2)
  field(:AC_MP3, 3)
end

defmodule AudioFlowSFU.LiveKit.Proto.VideoCodec do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "livekit.VideoCodec",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field(:DEFAULT_VC, 0)
  field(:H264_BASELINE, 1)
  field(:H264_MAIN, 2)
  field(:H264_HIGH, 3)
  field(:VP8, 4)
end

defmodule AudioFlowSFU.LiveKit.Proto.ImageCodec do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "livekit.ImageCodec",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field(:IC_DEFAULT, 0)
  field(:IC_JPEG, 1)
end

defmodule AudioFlowSFU.LiveKit.Proto.BackupCodecPolicy do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "livekit.BackupCodecPolicy",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field(:PREFER_REGRESSION, 0)
  field(:SIMULCAST, 1)
  field(:REGRESSION, 2)
end

defmodule AudioFlowSFU.LiveKit.Proto.TrackType do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "livekit.TrackType",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field(:AUDIO, 0)
  field(:VIDEO, 1)
  field(:DATA, 2)
end

defmodule AudioFlowSFU.LiveKit.Proto.TrackSource do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "livekit.TrackSource",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field(:UNKNOWN, 0)
  field(:CAMERA, 1)
  field(:MICROPHONE, 2)
  field(:SCREEN_SHARE, 3)
  field(:SCREEN_SHARE_AUDIO, 4)
end

defmodule AudioFlowSFU.LiveKit.Proto.DataTrackExtensionID do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "livekit.DataTrackExtensionID",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field(:DTEI_INVALID, 0)
  field(:DTEI_E2EE, 1)
  field(:DTEI_USER_TIMESTAMP, 2)
  field(:DTEI_PARTICIPANT_SID, 255)
end

defmodule AudioFlowSFU.LiveKit.Proto.VideoQuality do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "livekit.VideoQuality",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field(:LOW, 0)
  field(:MEDIUM, 1)
  field(:HIGH, 2)
  field(:OFF, 3)
end

defmodule AudioFlowSFU.LiveKit.Proto.ConnectionQuality do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "livekit.ConnectionQuality",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field(:POOR, 0)
  field(:GOOD, 1)
  field(:EXCELLENT, 2)
  field(:LOST, 3)
end

defmodule AudioFlowSFU.LiveKit.Proto.ClientConfigSetting do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "livekit.ClientConfigSetting",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field(:UNSET, 0)
  field(:DISABLED, 1)
  field(:ENABLED, 2)
end

defmodule AudioFlowSFU.LiveKit.Proto.DisconnectReason do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "livekit.DisconnectReason",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field(:UNKNOWN_REASON, 0)
  field(:CLIENT_INITIATED, 1)
  field(:DUPLICATE_IDENTITY, 2)
  field(:SERVER_SHUTDOWN, 3)
  field(:PARTICIPANT_REMOVED, 4)
  field(:ROOM_DELETED, 5)
  field(:STATE_MISMATCH, 6)
  field(:JOIN_FAILURE, 7)
  field(:MIGRATION, 8)
  field(:SIGNAL_CLOSE, 9)
  field(:ROOM_CLOSED, 10)
  field(:USER_UNAVAILABLE, 11)
  field(:USER_REJECTED, 12)
  field(:SIP_TRUNK_FAILURE, 13)
  field(:CONNECTION_TIMEOUT, 14)
  field(:MEDIA_FAILURE, 15)
  field(:AGENT_ERROR, 16)
end

defmodule AudioFlowSFU.LiveKit.Proto.RoomEndReason do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "livekit.RoomEndReason",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field(:ROOM_END_UNKNOWN, 0)
  field(:ROOM_END_API_DELETE, 1)
  field(:ROOM_END_IDLE_TIMEOUT, 2)
  field(:ROOM_END_SERVER_SHUTDOWN, 3)
  field(:ROOM_END_SUPERSEDED, 4)
  field(:ROOM_END_OPEN_FAILED, 5)
end

defmodule AudioFlowSFU.LiveKit.Proto.ReconnectReason do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "livekit.ReconnectReason",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field(:RR_UNKNOWN, 0)
  field(:RR_SIGNAL_DISCONNECTED, 1)
  field(:RR_PUBLISHER_FAILED, 2)
  field(:RR_SUBSCRIBER_FAILED, 3)
  field(:RR_SWITCH_CANDIDATE, 4)
end

defmodule AudioFlowSFU.LiveKit.Proto.SubscriptionError do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "livekit.SubscriptionError",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field(:SE_UNKNOWN, 0)
  field(:SE_CODEC_UNSUPPORTED, 1)
  field(:SE_TRACK_NOTFOUND, 2)
end

defmodule AudioFlowSFU.LiveKit.Proto.AudioTrackFeature do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "livekit.AudioTrackFeature",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field(:TF_STEREO, 0)
  field(:TF_NO_DTX, 1)
  field(:TF_AUTO_GAIN_CONTROL, 2)
  field(:TF_ECHO_CANCELLATION, 3)
  field(:TF_NOISE_SUPPRESSION, 4)
  field(:TF_ENHANCED_NOISE_CANCELLATION, 5)
  field(:TF_PRECONNECT_BUFFER, 6)
end

defmodule AudioFlowSFU.LiveKit.Proto.PacketTrailerFeature do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "livekit.PacketTrailerFeature",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field(:PTF_USER_TIMESTAMP, 0)
  field(:PTF_FRAME_ID, 1)
  field(:PTF_USER_DATA, 2)
end

defmodule AudioFlowSFU.LiveKit.Proto.ParticipantInfo.State do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "livekit.ParticipantInfo.State",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field(:JOINING, 0)
  field(:JOINED, 1)
  field(:ACTIVE, 2)
  field(:DISCONNECTED, 3)
end

defmodule AudioFlowSFU.LiveKit.Proto.ParticipantInfo.Kind do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "livekit.ParticipantInfo.Kind",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field(:STANDARD, 0)
  field(:INGRESS, 1)
  field(:EGRESS, 2)
  field(:SIP, 3)
  field(:AGENT, 4)
  field(:CONNECTOR, 7)
  field(:BRIDGE, 8)
end

defmodule AudioFlowSFU.LiveKit.Proto.ParticipantInfo.KindDetail do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "livekit.ParticipantInfo.KindDetail",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field(:CLOUD_AGENT, 0)
  field(:FORWARDED, 1)
  field(:CONNECTOR_WHATSAPP, 2)
  field(:CONNECTOR_TWILIO, 3)
  field(:BRIDGE_RTSP, 4)
  field(:SIMULATION, 5)
end

defmodule AudioFlowSFU.LiveKit.Proto.Encryption.Type do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "livekit.Encryption.Type",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field(:NONE, 0)
  field(:GCM, 1)
  field(:CUSTOM, 2)
end

defmodule AudioFlowSFU.LiveKit.Proto.DataTrackFrameEncoding.WellKnownFrameEncoding do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "livekit.DataTrackFrameEncoding.WellKnownFrameEncoding",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field(:WELL_KNOWN_FRAME_ENCODING_UNSPECIFIED, 0)
  field(:WELL_KNOWN_FRAME_ENCODING_ROS1, 1)
  field(:WELL_KNOWN_FRAME_ENCODING_CDR, 2)
  field(:WELL_KNOWN_FRAME_ENCODING_PROTOBUF, 3)
  field(:WELL_KNOWN_FRAME_ENCODING_FLATBUFFER, 4)
  field(:WELL_KNOWN_FRAME_ENCODING_CBOR, 5)
  field(:WELL_KNOWN_FRAME_ENCODING_MSGPACK, 6)
  field(:WELL_KNOWN_FRAME_ENCODING_JSON, 7)
end

defmodule AudioFlowSFU.LiveKit.Proto.DataTrackSchemaEncoding.WellKnownSchemaEncoding do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "livekit.DataTrackSchemaEncoding.WellKnownSchemaEncoding",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field(:WELL_KNOWN_SCHEMA_ENCODING_UNSPECIFIED, 0)
  field(:WELL_KNOWN_SCHEMA_ENCODING_PROTOBUF, 1)
  field(:WELL_KNOWN_SCHEMA_ENCODING_FLATBUFFER, 2)
  field(:WELL_KNOWN_SCHEMA_ENCODING_ROS1_MSG, 3)
  field(:WELL_KNOWN_SCHEMA_ENCODING_ROS2_MSG, 4)
  field(:WELL_KNOWN_SCHEMA_ENCODING_ROS2_IDL, 5)
  field(:WELL_KNOWN_SCHEMA_ENCODING_OMG_IDL, 6)
  field(:WELL_KNOWN_SCHEMA_ENCODING_JSON_SCHEMA, 7)
end

defmodule AudioFlowSFU.LiveKit.Proto.VideoLayer.Mode do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "livekit.VideoLayer.Mode",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field(:MODE_UNUSED, 0)
  field(:ONE_SPATIAL_LAYER_PER_STREAM, 1)
  field(:MULTIPLE_SPATIAL_LAYERS_PER_STREAM, 2)
  field(:ONE_SPATIAL_LAYER_PER_STREAM_INCOMPLETE_RTCP_SR, 3)
end

defmodule AudioFlowSFU.LiveKit.Proto.DataPacket.Kind do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "livekit.DataPacket.Kind",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field(:RELIABLE, 0)
  field(:LOSSY, 1)
end

defmodule AudioFlowSFU.LiveKit.Proto.ServerInfo.Edition do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "livekit.ServerInfo.Edition",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field(:Standard, 0)
  field(:Cloud, 1)
end

defmodule AudioFlowSFU.LiveKit.Proto.ClientInfo.SDK do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "livekit.ClientInfo.SDK",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field(:UNKNOWN, 0)
  field(:JS, 1)
  field(:SWIFT, 2)
  field(:ANDROID, 3)
  field(:FLUTTER, 4)
  field(:GO, 5)
  field(:UNITY, 6)
  field(:REACT_NATIVE, 7)
  field(:RUST, 8)
  field(:PYTHON, 9)
  field(:CPP, 10)
  field(:UNITY_WEB, 11)
  field(:NODE, 12)
  field(:UNREAL, 13)
  field(:ESP32, 14)
  field(:DOTNET, 15)
end

defmodule AudioFlowSFU.LiveKit.Proto.ClientInfo.Capability do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "livekit.ClientInfo.Capability",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field(:CAP_UNUSED, 0)
  field(:CAP_PACKET_TRAILER, 1)
  field(:CAP_COMPRESSION_DEFLATE_RAW, 2)
end

defmodule AudioFlowSFU.LiveKit.Proto.DataStream.OperationType do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "livekit.DataStream.OperationType",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field(:CREATE, 0)
  field(:UPDATE, 1)
  field(:DELETE, 2)
  field(:REACTION, 3)
end

defmodule AudioFlowSFU.LiveKit.Proto.DataStream.CompressionType do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "livekit.DataStream.CompressionType",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field(:NONE, 0)
  field(:DEFLATE_RAW, 1)
end

defmodule AudioFlowSFU.LiveKit.Proto.Pagination do
  @moduledoc false

  use Protobuf,
    full_name: "livekit.Pagination",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field(:after_id, 1, type: :string, json_name: "afterId", deprecated: false)
  field(:limit, 2, type: :int32)
end

defmodule AudioFlowSFU.LiveKit.Proto.TokenPagination do
  @moduledoc false

  use Protobuf,
    full_name: "livekit.TokenPagination",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field(:token, 1, type: :string)
end

defmodule AudioFlowSFU.LiveKit.Proto.ListUpdate do
  @moduledoc false

  use Protobuf,
    full_name: "livekit.ListUpdate",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field(:set, 1, repeated: true, type: :string)
  field(:add, 2, repeated: true, type: :string)
  field(:remove, 3, repeated: true, type: :string)
  field(:clear, 4, type: :bool)
end

defmodule AudioFlowSFU.LiveKit.Proto.Room do
  @moduledoc false

  use Protobuf, full_name: "livekit.Room", protoc_gen_elixir_version: "0.17.1", syntax: :proto3

  field(:sid, 1, type: :string)
  field(:name, 2, type: :string)
  field(:empty_timeout, 3, type: :uint32, json_name: "emptyTimeout")
  field(:departure_timeout, 14, type: :uint32, json_name: "departureTimeout")
  field(:max_participants, 4, type: :uint32, json_name: "maxParticipants")
  field(:creation_time, 5, type: :int64, json_name: "creationTime")
  field(:creation_time_ms, 15, type: :int64, json_name: "creationTimeMs")
  field(:turn_password, 6, type: :string, json_name: "turnPassword", deprecated: false)

  field(:enabled_codecs, 7,
    repeated: true,
    type: AudioFlowSFU.LiveKit.Proto.Codec,
    json_name: "enabledCodecs"
  )

  field(:metadata, 8, type: :string, deprecated: false)
  field(:num_participants, 9, type: :uint32, json_name: "numParticipants")
  field(:num_publishers, 11, type: :uint32, json_name: "numPublishers")
  field(:active_recording, 10, type: :bool, json_name: "activeRecording")
  field(:version, 13, type: AudioFlowSFU.LiveKit.Proto.TimedVersion)
end

defmodule AudioFlowSFU.LiveKit.Proto.Codec do
  @moduledoc false

  use Protobuf, full_name: "livekit.Codec", protoc_gen_elixir_version: "0.17.1", syntax: :proto3

  field(:mime, 1, type: :string)
  field(:fmtp_line, 2, type: :string, json_name: "fmtpLine")
end

defmodule AudioFlowSFU.LiveKit.Proto.PlayoutDelay do
  @moduledoc false

  use Protobuf,
    full_name: "livekit.PlayoutDelay",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field(:enabled, 1, type: :bool)
  field(:min, 2, type: :uint32)
  field(:max, 3, type: :uint32)
end

defmodule AudioFlowSFU.LiveKit.Proto.ParticipantPermission do
  @moduledoc false

  use Protobuf,
    full_name: "livekit.ParticipantPermission",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field(:can_subscribe, 1, type: :bool, json_name: "canSubscribe")
  field(:can_publish, 2, type: :bool, json_name: "canPublish")
  field(:can_publish_data, 3, type: :bool, json_name: "canPublishData")

  field(:can_publish_sources, 9,
    repeated: true,
    type: AudioFlowSFU.LiveKit.Proto.TrackSource,
    json_name: "canPublishSources",
    enum: true
  )

  field(:hidden, 7, type: :bool)
  field(:recorder, 8, type: :bool, deprecated: true)
  field(:can_update_metadata, 10, type: :bool, json_name: "canUpdateMetadata")
  field(:agent, 11, type: :bool, deprecated: true)
  field(:can_subscribe_metrics, 12, type: :bool, json_name: "canSubscribeMetrics")
  field(:can_manage_agent_session, 13, type: :bool, json_name: "canManageAgentSession")
end

defmodule AudioFlowSFU.LiveKit.Proto.ParticipantInfo.AttributesEntry do
  @moduledoc false

  use Protobuf,
    full_name: "livekit.ParticipantInfo.AttributesEntry",
    map: true,
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field(:key, 1, type: :string)
  field(:value, 2, type: :string)
end

defmodule AudioFlowSFU.LiveKit.Proto.ParticipantInfo do
  @moduledoc false

  use Protobuf,
    full_name: "livekit.ParticipantInfo",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field(:sid, 1, type: :string)
  field(:identity, 2, type: :string)
  field(:state, 3, type: AudioFlowSFU.LiveKit.Proto.ParticipantInfo.State, enum: true)
  field(:tracks, 4, repeated: true, type: AudioFlowSFU.LiveKit.Proto.TrackInfo)
  field(:metadata, 5, type: :string, deprecated: false)
  field(:joined_at, 6, type: :int64, json_name: "joinedAt")
  field(:joined_at_ms, 17, type: :int64, json_name: "joinedAtMs")
  field(:name, 9, type: :string, deprecated: false)
  field(:version, 10, type: :uint32)
  field(:permission, 11, type: AudioFlowSFU.LiveKit.Proto.ParticipantPermission)
  field(:region, 12, type: :string)
  field(:is_publisher, 13, type: :bool, json_name: "isPublisher")
  field(:kind, 14, type: AudioFlowSFU.LiveKit.Proto.ParticipantInfo.Kind, enum: true)

  field(:attributes, 15,
    repeated: true,
    type: AudioFlowSFU.LiveKit.Proto.ParticipantInfo.AttributesEntry,
    map: true,
    deprecated: false
  )

  field(:disconnect_reason, 16,
    type: AudioFlowSFU.LiveKit.Proto.DisconnectReason,
    json_name: "disconnectReason",
    enum: true
  )

  field(:kind_details, 18,
    repeated: true,
    type: AudioFlowSFU.LiveKit.Proto.ParticipantInfo.KindDetail,
    json_name: "kindDetails",
    enum: true
  )

  field(:data_tracks, 19,
    repeated: true,
    type: AudioFlowSFU.LiveKit.Proto.DataTrackInfo,
    json_name: "dataTracks"
  )

  field(:client_protocol, 20, type: :int32, json_name: "clientProtocol")

  field(:capabilities, 21,
    repeated: true,
    type: AudioFlowSFU.LiveKit.Proto.ClientInfo.Capability,
    enum: true
  )
end

defmodule AudioFlowSFU.LiveKit.Proto.Encryption do
  @moduledoc false

  use Protobuf,
    full_name: "livekit.Encryption",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3
end

defmodule AudioFlowSFU.LiveKit.Proto.SimulcastCodecInfo do
  @moduledoc false

  use Protobuf,
    full_name: "livekit.SimulcastCodecInfo",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field(:mime_type, 1, type: :string, json_name: "mimeType")
  field(:mid, 2, type: :string)
  field(:cid, 3, type: :string)
  field(:layers, 4, repeated: true, type: AudioFlowSFU.LiveKit.Proto.VideoLayer)

  field(:video_layer_mode, 5,
    type: AudioFlowSFU.LiveKit.Proto.VideoLayer.Mode,
    json_name: "videoLayerMode",
    enum: true
  )

  field(:sdp_cid, 6, type: :string, json_name: "sdpCid")
end

defmodule AudioFlowSFU.LiveKit.Proto.TrackInfo do
  @moduledoc false

  use Protobuf,
    full_name: "livekit.TrackInfo",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field(:sid, 1, type: :string)
  field(:type, 2, type: AudioFlowSFU.LiveKit.Proto.TrackType, enum: true)
  field(:name, 3, type: :string, deprecated: false)
  field(:muted, 4, type: :bool)
  field(:width, 5, type: :uint32)
  field(:height, 6, type: :uint32)
  field(:simulcast, 7, type: :bool, deprecated: true)
  field(:disable_dtx, 8, type: :bool, json_name: "disableDtx", deprecated: true)
  field(:source, 9, type: AudioFlowSFU.LiveKit.Proto.TrackSource, enum: true)

  field(:layers, 10,
    repeated: true,
    type: AudioFlowSFU.LiveKit.Proto.VideoLayer,
    deprecated: true
  )

  field(:mime_type, 11, type: :string, json_name: "mimeType")
  field(:mid, 12, type: :string)
  field(:codecs, 13, repeated: true, type: AudioFlowSFU.LiveKit.Proto.SimulcastCodecInfo)
  field(:stereo, 14, type: :bool, deprecated: true)
  field(:disable_red, 15, type: :bool, json_name: "disableRed")
  field(:encryption, 16, type: AudioFlowSFU.LiveKit.Proto.Encryption.Type, enum: true)
  field(:stream, 17, type: :string)
  field(:version, 18, type: AudioFlowSFU.LiveKit.Proto.TimedVersion)

  field(:audio_features, 19,
    repeated: true,
    type: AudioFlowSFU.LiveKit.Proto.AudioTrackFeature,
    json_name: "audioFeatures",
    enum: true
  )

  field(:backup_codec_policy, 20,
    type: AudioFlowSFU.LiveKit.Proto.BackupCodecPolicy,
    json_name: "backupCodecPolicy",
    enum: true
  )

  field(:packet_trailer_features, 21,
    repeated: true,
    type: AudioFlowSFU.LiveKit.Proto.PacketTrailerFeature,
    json_name: "packetTrailerFeatures",
    enum: true
  )
end

defmodule AudioFlowSFU.LiveKit.Proto.DataTrackInfo do
  @moduledoc false

  use Protobuf,
    full_name: "livekit.DataTrackInfo",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field(:pub_handle, 1, type: :uint32, json_name: "pubHandle")
  field(:sid, 2, type: :string)
  field(:name, 3, type: :string)
  field(:encryption, 4, type: AudioFlowSFU.LiveKit.Proto.Encryption.Type, enum: true)

  field(:frame_encoding, 5,
    proto3_optional: true,
    type: AudioFlowSFU.LiveKit.Proto.DataTrackFrameEncoding,
    json_name: "frameEncoding"
  )

  field(:schema, 6,
    proto3_optional: true,
    type: AudioFlowSFU.LiveKit.Proto.DataTrackSchemaId
  )
end

defmodule AudioFlowSFU.LiveKit.Proto.DataTrackFrameEncoding do
  @moduledoc false

  use Protobuf,
    full_name: "livekit.DataTrackFrameEncoding",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  oneof(:value, 0)

  field(:well_known, 1,
    type: AudioFlowSFU.LiveKit.Proto.DataTrackFrameEncoding.WellKnownFrameEncoding,
    json_name: "wellKnown",
    enum: true,
    oneof: 0
  )

  field(:custom, 2, type: :string, oneof: 0)
end

defmodule AudioFlowSFU.LiveKit.Proto.DataTrackSchemaEncoding do
  @moduledoc false

  use Protobuf,
    full_name: "livekit.DataTrackSchemaEncoding",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  oneof(:value, 0)

  field(:well_known, 1,
    type: AudioFlowSFU.LiveKit.Proto.DataTrackSchemaEncoding.WellKnownSchemaEncoding,
    json_name: "wellKnown",
    enum: true,
    oneof: 0
  )

  field(:custom, 2, type: :string, oneof: 0)
end

defmodule AudioFlowSFU.LiveKit.Proto.DataTrackSchemaId do
  @moduledoc false

  use Protobuf,
    full_name: "livekit.DataTrackSchemaId",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field(:name, 1, type: :string)
  field(:encoding, 2, type: AudioFlowSFU.LiveKit.Proto.DataTrackSchemaEncoding)
end

defmodule AudioFlowSFU.LiveKit.Proto.DataTrackExtensionParticipantSid do
  @moduledoc false

  use Protobuf,
    full_name: "livekit.DataTrackExtensionParticipantSid",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field(:id, 1, type: AudioFlowSFU.LiveKit.Proto.DataTrackExtensionID, enum: true)
  field(:participant_sid, 2, type: :string, json_name: "participantSid")
end

defmodule AudioFlowSFU.LiveKit.Proto.DataTrackSubscriptionOptions do
  @moduledoc false

  use Protobuf,
    full_name: "livekit.DataTrackSubscriptionOptions",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field(:target_fps, 1, proto3_optional: true, type: :uint32, json_name: "targetFps")
end

defmodule AudioFlowSFU.LiveKit.Proto.DataBlobKey do
  @moduledoc false

  use Protobuf,
    full_name: "livekit.DataBlobKey",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  oneof(:key, 0)

  field(:generic, 1, type: :string, oneof: 0)

  field(:schema_id, 2,
    type: AudioFlowSFU.LiveKit.Proto.DataTrackSchemaId,
    json_name: "schemaId",
    oneof: 0,
    deprecated: false
  )
end

defmodule AudioFlowSFU.LiveKit.Proto.DataBlob do
  @moduledoc false

  use Protobuf,
    full_name: "livekit.DataBlob",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field(:key, 1, type: AudioFlowSFU.LiveKit.Proto.DataBlobKey)
  field(:contents, 2, type: :bytes, deprecated: false)
end

defmodule AudioFlowSFU.LiveKit.Proto.VideoLayer do
  @moduledoc false

  use Protobuf,
    full_name: "livekit.VideoLayer",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field(:quality, 1, type: AudioFlowSFU.LiveKit.Proto.VideoQuality, enum: true)
  field(:width, 2, type: :uint32)
  field(:height, 3, type: :uint32)
  field(:bitrate, 4, type: :uint32)
  field(:ssrc, 5, type: :uint32)
  field(:spatial_layer, 6, type: :int32, json_name: "spatialLayer")
  field(:rid, 7, type: :string)
  field(:repair_ssrc, 8, type: :uint32, json_name: "repairSsrc")
end

defmodule AudioFlowSFU.LiveKit.Proto.DataPacket do
  @moduledoc false

  use Protobuf,
    full_name: "livekit.DataPacket",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  oneof(:value, 0)

  field(:kind, 1,
    type: AudioFlowSFU.LiveKit.Proto.DataPacket.Kind,
    enum: true,
    deprecated: true
  )

  field(:participant_identity, 4, type: :string, json_name: "participantIdentity")

  field(:destination_identities, 5,
    repeated: true,
    type: :string,
    json_name: "destinationIdentities"
  )

  field(:user, 2, type: AudioFlowSFU.LiveKit.Proto.UserPacket, oneof: 0)

  field(:speaker, 3,
    type: AudioFlowSFU.LiveKit.Proto.ActiveSpeakerUpdate,
    oneof: 0,
    deprecated: true
  )

  field(:sip_dtmf, 6,
    type: AudioFlowSFU.LiveKit.Proto.SipDTMF,
    json_name: "sipDtmf",
    oneof: 0
  )

  field(:transcription, 7, type: AudioFlowSFU.LiveKit.Proto.Transcription, oneof: 0)
  field(:metrics, 8, type: AudioFlowSFU.LiveKit.Proto.MetricsBatch, oneof: 0)

  field(:chat_message, 9,
    type: AudioFlowSFU.LiveKit.Proto.ChatMessage,
    json_name: "chatMessage",
    oneof: 0
  )

  field(:rpc_request, 10,
    type: AudioFlowSFU.LiveKit.Proto.RpcRequest,
    json_name: "rpcRequest",
    oneof: 0
  )

  field(:rpc_ack, 11,
    type: AudioFlowSFU.LiveKit.Proto.RpcAck,
    json_name: "rpcAck",
    oneof: 0
  )

  field(:rpc_response, 12,
    type: AudioFlowSFU.LiveKit.Proto.RpcResponse,
    json_name: "rpcResponse",
    oneof: 0
  )

  field(:stream_header, 13,
    type: AudioFlowSFU.LiveKit.Proto.DataStream.Header,
    json_name: "streamHeader",
    oneof: 0
  )

  field(:stream_chunk, 14,
    type: AudioFlowSFU.LiveKit.Proto.DataStream.Chunk,
    json_name: "streamChunk",
    oneof: 0
  )

  field(:stream_trailer, 15,
    type: AudioFlowSFU.LiveKit.Proto.DataStream.Trailer,
    json_name: "streamTrailer",
    oneof: 0
  )

  field(:encrypted_packet, 18,
    type: AudioFlowSFU.LiveKit.Proto.EncryptedPacket,
    json_name: "encryptedPacket",
    oneof: 0
  )

  field(:sequence, 16, type: :uint32)
  field(:participant_sid, 17, type: :string, json_name: "participantSid")
end

defmodule AudioFlowSFU.LiveKit.Proto.EncryptedPacket do
  @moduledoc false

  use Protobuf,
    full_name: "livekit.EncryptedPacket",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field(:encryption_type, 1,
    type: AudioFlowSFU.LiveKit.Proto.Encryption.Type,
    json_name: "encryptionType",
    enum: true
  )

  field(:iv, 2, type: :bytes)
  field(:key_index, 3, type: :uint32, json_name: "keyIndex")
  field(:encrypted_value, 4, type: :bytes, json_name: "encryptedValue")
end

defmodule AudioFlowSFU.LiveKit.Proto.EncryptedPacketPayload do
  @moduledoc false

  use Protobuf,
    full_name: "livekit.EncryptedPacketPayload",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  oneof(:value, 0)

  field(:user, 1, type: AudioFlowSFU.LiveKit.Proto.UserPacket, oneof: 0)

  field(:chat_message, 3,
    type: AudioFlowSFU.LiveKit.Proto.ChatMessage,
    json_name: "chatMessage",
    oneof: 0
  )

  field(:rpc_request, 4,
    type: AudioFlowSFU.LiveKit.Proto.RpcRequest,
    json_name: "rpcRequest",
    oneof: 0
  )

  field(:rpc_ack, 5,
    type: AudioFlowSFU.LiveKit.Proto.RpcAck,
    json_name: "rpcAck",
    oneof: 0
  )

  field(:rpc_response, 6,
    type: AudioFlowSFU.LiveKit.Proto.RpcResponse,
    json_name: "rpcResponse",
    oneof: 0
  )

  field(:stream_header, 7,
    type: AudioFlowSFU.LiveKit.Proto.DataStream.Header,
    json_name: "streamHeader",
    oneof: 0
  )

  field(:stream_chunk, 8,
    type: AudioFlowSFU.LiveKit.Proto.DataStream.Chunk,
    json_name: "streamChunk",
    oneof: 0
  )

  field(:stream_trailer, 9,
    type: AudioFlowSFU.LiveKit.Proto.DataStream.Trailer,
    json_name: "streamTrailer",
    oneof: 0
  )
end

defmodule AudioFlowSFU.LiveKit.Proto.ActiveSpeakerUpdate do
  @moduledoc false

  use Protobuf,
    deprecated: true,
    full_name: "livekit.ActiveSpeakerUpdate",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field(:speakers, 1, repeated: true, type: AudioFlowSFU.LiveKit.Proto.SpeakerInfo)
end

defmodule AudioFlowSFU.LiveKit.Proto.SpeakerInfo do
  @moduledoc false

  use Protobuf,
    full_name: "livekit.SpeakerInfo",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field(:sid, 1, type: :string)
  field(:level, 2, type: :float)
  field(:active, 3, type: :bool)
end

defmodule AudioFlowSFU.LiveKit.Proto.UserPacket do
  @moduledoc false

  use Protobuf,
    full_name: "livekit.UserPacket",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field(:participant_sid, 1, type: :string, json_name: "participantSid", deprecated: true)

  field(:participant_identity, 5,
    type: :string,
    json_name: "participantIdentity",
    deprecated: true
  )

  field(:payload, 2, type: :bytes)

  field(:destination_sids, 3,
    repeated: true,
    type: :string,
    json_name: "destinationSids",
    deprecated: true
  )

  field(:destination_identities, 6,
    repeated: true,
    type: :string,
    json_name: "destinationIdentities",
    deprecated: true
  )

  field(:topic, 4, proto3_optional: true, type: :string)
  field(:id, 8, proto3_optional: true, type: :string)
  field(:start_time, 9, proto3_optional: true, type: :uint64, json_name: "startTime")
  field(:end_time, 10, proto3_optional: true, type: :uint64, json_name: "endTime")
  field(:nonce, 11, type: :bytes)
end

defmodule AudioFlowSFU.LiveKit.Proto.SipDTMF do
  @moduledoc false

  use Protobuf, full_name: "livekit.SipDTMF", protoc_gen_elixir_version: "0.17.1", syntax: :proto3

  field(:code, 3, type: :uint32)
  field(:digit, 4, type: :string)
end

defmodule AudioFlowSFU.LiveKit.Proto.Transcription do
  @moduledoc false

  use Protobuf,
    full_name: "livekit.Transcription",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field(:transcribed_participant_identity, 2,
    type: :string,
    json_name: "transcribedParticipantIdentity"
  )

  field(:track_id, 3, type: :string, json_name: "trackId", deprecated: false)

  field(:segments, 4,
    repeated: true,
    type: AudioFlowSFU.LiveKit.Proto.TranscriptionSegment
  )
end

defmodule AudioFlowSFU.LiveKit.Proto.TranscriptionSegment do
  @moduledoc false

  use Protobuf,
    full_name: "livekit.TranscriptionSegment",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field(:id, 1, type: :string)
  field(:text, 2, type: :string)
  field(:start_time, 3, type: :uint64, json_name: "startTime")
  field(:end_time, 4, type: :uint64, json_name: "endTime")
  field(:final, 5, type: :bool)
  field(:language, 6, type: :string)
end

defmodule AudioFlowSFU.LiveKit.Proto.ChatMessage do
  @moduledoc false

  use Protobuf,
    full_name: "livekit.ChatMessage",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field(:id, 1, type: :string)
  field(:timestamp, 2, type: :int64)
  field(:edit_timestamp, 3, proto3_optional: true, type: :int64, json_name: "editTimestamp")
  field(:message, 4, type: :string)
  field(:deleted, 5, type: :bool)
  field(:generated, 6, type: :bool)
end

defmodule AudioFlowSFU.LiveKit.Proto.RpcRequest do
  @moduledoc false

  use Protobuf,
    full_name: "livekit.RpcRequest",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field(:id, 1, type: :string)
  field(:method, 2, type: :string)
  field(:payload, 3, type: :string)
  field(:response_timeout_ms, 4, type: :uint32, json_name: "responseTimeoutMs")
  field(:version, 5, type: :uint32)
  field(:compressed_payload, 6, type: :bytes, json_name: "compressedPayload")
end

defmodule AudioFlowSFU.LiveKit.Proto.RpcAck do
  @moduledoc false

  use Protobuf, full_name: "livekit.RpcAck", protoc_gen_elixir_version: "0.17.1", syntax: :proto3

  field(:request_id, 1, type: :string, json_name: "requestId", deprecated: false)
end

defmodule AudioFlowSFU.LiveKit.Proto.RpcResponse do
  @moduledoc false

  use Protobuf,
    full_name: "livekit.RpcResponse",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  oneof(:value, 0)

  field(:request_id, 1, type: :string, json_name: "requestId", deprecated: false)
  field(:payload, 2, type: :string, oneof: 0)
  field(:error, 3, type: AudioFlowSFU.LiveKit.Proto.RpcError, oneof: 0)
  field(:compressed_payload, 4, type: :bytes, json_name: "compressedPayload", oneof: 0)
end

defmodule AudioFlowSFU.LiveKit.Proto.RpcError do
  @moduledoc false

  use Protobuf,
    full_name: "livekit.RpcError",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field(:code, 1, type: :uint32)
  field(:message, 2, type: :string)
  field(:data, 3, type: :string)
end

defmodule AudioFlowSFU.LiveKit.Proto.ParticipantTracks do
  @moduledoc false

  use Protobuf,
    full_name: "livekit.ParticipantTracks",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field(:participant_sid, 1, type: :string, json_name: "participantSid")
  field(:track_sids, 2, repeated: true, type: :string, json_name: "trackSids")
end

defmodule AudioFlowSFU.LiveKit.Proto.ServerInfo do
  @moduledoc false

  use Protobuf,
    full_name: "livekit.ServerInfo",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field(:edition, 1, type: AudioFlowSFU.LiveKit.Proto.ServerInfo.Edition, enum: true)
  field(:version, 2, type: :string)
  field(:protocol, 3, type: :int32)
  field(:region, 4, type: :string)
  field(:node_id, 5, type: :string, json_name: "nodeId", deprecated: false)
  field(:debug_info, 6, type: :string, json_name: "debugInfo")
  field(:agent_protocol, 7, type: :int32, json_name: "agentProtocol")
end

defmodule AudioFlowSFU.LiveKit.Proto.ClientInfo do
  @moduledoc false

  use Protobuf,
    full_name: "livekit.ClientInfo",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field(:sdk, 1, type: AudioFlowSFU.LiveKit.Proto.ClientInfo.SDK, enum: true)
  field(:version, 2, type: :string)
  field(:protocol, 3, type: :int32)
  field(:os, 4, type: :string)
  field(:os_version, 5, type: :string, json_name: "osVersion")
  field(:device_model, 6, type: :string, json_name: "deviceModel")
  field(:browser, 7, type: :string)
  field(:browser_version, 8, type: :string, json_name: "browserVersion")
  field(:address, 9, type: :string, deprecated: false)
  field(:network, 10, type: :string)
  field(:other_sdks, 11, type: :string, json_name: "otherSdks")
  field(:client_protocol, 12, type: :int32, json_name: "clientProtocol")

  field(:capabilities, 13,
    repeated: true,
    type: AudioFlowSFU.LiveKit.Proto.ClientInfo.Capability,
    enum: true
  )
end

defmodule AudioFlowSFU.LiveKit.Proto.ClientConfiguration do
  @moduledoc false

  use Protobuf,
    full_name: "livekit.ClientConfiguration",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field(:video, 1, type: AudioFlowSFU.LiveKit.Proto.VideoConfiguration)
  field(:screen, 2, type: AudioFlowSFU.LiveKit.Proto.VideoConfiguration)

  field(:resume_connection, 3,
    type: AudioFlowSFU.LiveKit.Proto.ClientConfigSetting,
    json_name: "resumeConnection",
    enum: true
  )

  field(:disabled_codecs, 4,
    type: AudioFlowSFU.LiveKit.Proto.DisabledCodecs,
    json_name: "disabledCodecs"
  )

  field(:force_relay, 5,
    type: AudioFlowSFU.LiveKit.Proto.ClientConfigSetting,
    json_name: "forceRelay",
    enum: true
  )
end

defmodule AudioFlowSFU.LiveKit.Proto.VideoConfiguration do
  @moduledoc false

  use Protobuf,
    full_name: "livekit.VideoConfiguration",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field(:hardware_encoder, 1,
    type: AudioFlowSFU.LiveKit.Proto.ClientConfigSetting,
    json_name: "hardwareEncoder",
    enum: true
  )
end

defmodule AudioFlowSFU.LiveKit.Proto.DisabledCodecs do
  @moduledoc false

  use Protobuf,
    full_name: "livekit.DisabledCodecs",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field(:codecs, 1, repeated: true, type: AudioFlowSFU.LiveKit.Proto.Codec)
  field(:publish, 2, repeated: true, type: AudioFlowSFU.LiveKit.Proto.Codec)
end

defmodule AudioFlowSFU.LiveKit.Proto.RTPDrift do
  @moduledoc false

  use Protobuf,
    full_name: "livekit.RTPDrift",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field(:start_time, 1, type: Google.Protobuf.Timestamp, json_name: "startTime")
  field(:end_time, 2, type: Google.Protobuf.Timestamp, json_name: "endTime")
  field(:duration, 3, type: :double)
  field(:start_timestamp, 4, type: :uint64, json_name: "startTimestamp")
  field(:end_timestamp, 5, type: :uint64, json_name: "endTimestamp")
  field(:rtp_clock_ticks, 6, type: :uint64, json_name: "rtpClockTicks")
  field(:drift_samples, 7, type: :int64, json_name: "driftSamples")
  field(:drift_ms, 8, type: :double, json_name: "driftMs")
  field(:clock_rate, 9, type: :double, json_name: "clockRate")
end

defmodule AudioFlowSFU.LiveKit.Proto.RTPStats.GapHistogramEntry do
  @moduledoc false

  use Protobuf,
    full_name: "livekit.RTPStats.GapHistogramEntry",
    map: true,
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field(:key, 1, type: :int32)
  field(:value, 2, type: :uint32)
end

defmodule AudioFlowSFU.LiveKit.Proto.RTPStats do
  @moduledoc false

  use Protobuf,
    full_name: "livekit.RTPStats",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field(:start_time, 1, type: Google.Protobuf.Timestamp, json_name: "startTime")
  field(:end_time, 2, type: Google.Protobuf.Timestamp, json_name: "endTime")
  field(:duration, 3, type: :double)
  field(:packets, 4, type: :uint32)
  field(:packet_rate, 5, type: :double, json_name: "packetRate")
  field(:bytes, 6, type: :uint64)
  field(:header_bytes, 39, type: :uint64, json_name: "headerBytes")
  field(:bitrate, 7, type: :double)
  field(:packets_lost, 8, type: :uint32, json_name: "packetsLost")
  field(:packet_loss_rate, 9, type: :double, json_name: "packetLossRate")
  field(:packet_loss_percentage, 10, type: :float, json_name: "packetLossPercentage")
  field(:packets_duplicate, 11, type: :uint32, json_name: "packetsDuplicate")
  field(:packet_duplicate_rate, 12, type: :double, json_name: "packetDuplicateRate")
  field(:bytes_duplicate, 13, type: :uint64, json_name: "bytesDuplicate")
  field(:header_bytes_duplicate, 40, type: :uint64, json_name: "headerBytesDuplicate")
  field(:bitrate_duplicate, 14, type: :double, json_name: "bitrateDuplicate")
  field(:packets_padding, 15, type: :uint32, json_name: "packetsPadding")
  field(:packet_padding_rate, 16, type: :double, json_name: "packetPaddingRate")
  field(:bytes_padding, 17, type: :uint64, json_name: "bytesPadding")
  field(:header_bytes_padding, 41, type: :uint64, json_name: "headerBytesPadding")
  field(:bitrate_padding, 18, type: :double, json_name: "bitratePadding")
  field(:packets_out_of_order, 19, type: :uint32, json_name: "packetsOutOfOrder")
  field(:frames, 20, type: :uint32)
  field(:frame_rate, 21, type: :double, json_name: "frameRate")
  field(:jitter_current, 22, type: :double, json_name: "jitterCurrent")
  field(:jitter_max, 23, type: :double, json_name: "jitterMax")

  field(:gap_histogram, 24,
    repeated: true,
    type: AudioFlowSFU.LiveKit.Proto.RTPStats.GapHistogramEntry,
    json_name: "gapHistogram",
    map: true
  )

  field(:nacks, 25, type: :uint32)
  field(:nack_acks, 37, type: :uint32, json_name: "nackAcks")
  field(:nack_misses, 26, type: :uint32, json_name: "nackMisses")
  field(:nack_repeated, 38, type: :uint32, json_name: "nackRepeated")
  field(:plis, 27, type: :uint32)
  field(:last_pli, 28, type: Google.Protobuf.Timestamp, json_name: "lastPli")
  field(:firs, 29, type: :uint32)
  field(:last_fir, 30, type: Google.Protobuf.Timestamp, json_name: "lastFir")
  field(:rtt_current, 31, type: :uint32, json_name: "rttCurrent")
  field(:rtt_max, 32, type: :uint32, json_name: "rttMax")
  field(:key_frames, 33, type: :uint32, json_name: "keyFrames")
  field(:last_key_frame, 34, type: Google.Protobuf.Timestamp, json_name: "lastKeyFrame")
  field(:layer_lock_plis, 35, type: :uint32, json_name: "layerLockPlis")
  field(:last_layer_lock_pli, 36, type: Google.Protobuf.Timestamp, json_name: "lastLayerLockPli")

  field(:packet_drift, 44,
    type: AudioFlowSFU.LiveKit.Proto.RTPDrift,
    json_name: "packetDrift"
  )

  field(:ntp_report_drift, 45,
    type: AudioFlowSFU.LiveKit.Proto.RTPDrift,
    json_name: "ntpReportDrift"
  )

  field(:rebased_report_drift, 46,
    type: AudioFlowSFU.LiveKit.Proto.RTPDrift,
    json_name: "rebasedReportDrift"
  )

  field(:received_report_drift, 47,
    type: AudioFlowSFU.LiveKit.Proto.RTPDrift,
    json_name: "receivedReportDrift"
  )

  field(:fec_packets, 48, type: :uint32, json_name: "fecPackets")
  field(:fec_bytes, 49, type: :uint64, json_name: "fecBytes")
  field(:fec_packets_discarded, 50, type: :uint32, json_name: "fecPacketsDiscarded")
  field(:fec_packets_recovered, 51, type: :uint32, json_name: "fecPacketsRecovered")
end

defmodule AudioFlowSFU.LiveKit.Proto.RTCPSenderReportState do
  @moduledoc false

  use Protobuf,
    full_name: "livekit.RTCPSenderReportState",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field(:rtp_timestamp, 1, type: :uint32, json_name: "rtpTimestamp")
  field(:rtp_timestamp_ext, 2, type: :uint64, json_name: "rtpTimestampExt")
  field(:ntp_timestamp, 3, type: :uint64, json_name: "ntpTimestamp")
  field(:at, 4, type: :int64)
  field(:at_adjusted, 5, type: :int64, json_name: "atAdjusted")
  field(:packets, 6, type: :uint32)
  field(:octets, 7, type: :uint64)
end

defmodule AudioFlowSFU.LiveKit.Proto.RTPForwarderState do
  @moduledoc false

  use Protobuf,
    full_name: "livekit.RTPForwarderState",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  oneof(:codec_munger, 0)

  field(:started, 1, type: :bool)
  field(:reference_layer_spatial, 2, type: :int32, json_name: "referenceLayerSpatial")
  field(:pre_start_time, 3, type: :int64, json_name: "preStartTime")
  field(:ext_first_timestamp, 4, type: :uint64, json_name: "extFirstTimestamp")
  field(:dummy_start_timestamp_offset, 5, type: :uint64, json_name: "dummyStartTimestampOffset")

  field(:rtp_munger, 6,
    type: AudioFlowSFU.LiveKit.Proto.RTPMungerState,
    json_name: "rtpMunger"
  )

  field(:vp8_munger, 7,
    type: AudioFlowSFU.LiveKit.Proto.VP8MungerState,
    json_name: "vp8Munger",
    oneof: 0
  )

  field(:sender_report_state, 8,
    repeated: true,
    type: AudioFlowSFU.LiveKit.Proto.RTCPSenderReportState,
    json_name: "senderReportState"
  )

  field(:dependency_descriptor_forwarder, 9,
    type: AudioFlowSFU.LiveKit.Proto.DependencyDescriptorForwarderState,
    json_name: "dependencyDescriptorForwarder"
  )
end

defmodule AudioFlowSFU.LiveKit.Proto.DependencyDescriptorForwarderState do
  @moduledoc false

  use Protobuf,
    full_name: "livekit.DependencyDescriptorForwarderState",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field(:ext_last_frame_number, 1, type: :uint64, json_name: "extLastFrameNumber")
end

defmodule AudioFlowSFU.LiveKit.Proto.RTPMungerState do
  @moduledoc false

  use Protobuf,
    full_name: "livekit.RTPMungerState",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field(:ext_last_sequence_number, 1, type: :uint64, json_name: "extLastSequenceNumber")

  field(:ext_second_last_sequence_number, 2,
    type: :uint64,
    json_name: "extSecondLastSequenceNumber"
  )

  field(:ext_last_timestamp, 3, type: :uint64, json_name: "extLastTimestamp")
  field(:ext_second_last_timestamp, 4, type: :uint64, json_name: "extSecondLastTimestamp")
  field(:last_marker, 5, type: :bool, json_name: "lastMarker")
  field(:second_last_marker, 6, type: :bool, json_name: "secondLastMarker")
end

defmodule AudioFlowSFU.LiveKit.Proto.VP8MungerState do
  @moduledoc false

  use Protobuf,
    full_name: "livekit.VP8MungerState",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field(:ext_last_picture_id, 1, type: :int32, json_name: "extLastPictureId", deprecated: false)
  field(:picture_id_used, 2, type: :bool, json_name: "pictureIdUsed")
  field(:last_tl0_pic_idx, 3, type: :uint32, json_name: "lastTl0PicIdx")
  field(:tl0_pic_idx_used, 4, type: :bool, json_name: "tl0PicIdxUsed")
  field(:tid_used, 5, type: :bool, json_name: "tidUsed")
  field(:last_key_idx, 6, type: :uint32, json_name: "lastKeyIdx")
  field(:key_idx_used, 7, type: :bool, json_name: "keyIdxUsed")
end

defmodule AudioFlowSFU.LiveKit.Proto.TimedVersion do
  @moduledoc false

  use Protobuf,
    full_name: "livekit.TimedVersion",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field(:unix_micro, 1, type: :int64, json_name: "unixMicro")
  field(:ticks, 2, type: :int32)
end

defmodule AudioFlowSFU.LiveKit.Proto.DataStream.TextHeader do
  @moduledoc false

  use Protobuf,
    full_name: "livekit.DataStream.TextHeader",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field(:operation_type, 1,
    type: AudioFlowSFU.LiveKit.Proto.DataStream.OperationType,
    json_name: "operationType",
    enum: true
  )

  field(:version, 2, type: :int32)
  field(:reply_to_stream_id, 3, type: :string, json_name: "replyToStreamId", deprecated: false)
  field(:attached_stream_ids, 4, repeated: true, type: :string, json_name: "attachedStreamIds")
  field(:generated, 5, type: :bool)
end

defmodule AudioFlowSFU.LiveKit.Proto.DataStream.ByteHeader do
  @moduledoc false

  use Protobuf,
    full_name: "livekit.DataStream.ByteHeader",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field(:name, 1, type: :string)
end

defmodule AudioFlowSFU.LiveKit.Proto.DataStream.Header.AttributesEntry do
  @moduledoc false

  use Protobuf,
    full_name: "livekit.DataStream.Header.AttributesEntry",
    map: true,
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field(:key, 1, type: :string)
  field(:value, 2, type: :string)
end

defmodule AudioFlowSFU.LiveKit.Proto.DataStream.Header do
  @moduledoc false

  use Protobuf,
    full_name: "livekit.DataStream.Header",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  oneof(:content_header, 0)

  field(:stream_id, 1, type: :string, json_name: "streamId", deprecated: false)
  field(:timestamp, 2, type: :int64)
  field(:topic, 3, type: :string)
  field(:mime_type, 4, type: :string, json_name: "mimeType")
  field(:total_length, 5, proto3_optional: true, type: :uint64, json_name: "totalLength")

  field(:encryption_type, 7,
    type: AudioFlowSFU.LiveKit.Proto.Encryption.Type,
    json_name: "encryptionType",
    enum: true,
    deprecated: true
  )

  field(:attributes, 8,
    repeated: true,
    type: AudioFlowSFU.LiveKit.Proto.DataStream.Header.AttributesEntry,
    map: true
  )

  field(:text_header, 9,
    type: AudioFlowSFU.LiveKit.Proto.DataStream.TextHeader,
    json_name: "textHeader",
    oneof: 0
  )

  field(:byte_header, 10,
    type: AudioFlowSFU.LiveKit.Proto.DataStream.ByteHeader,
    json_name: "byteHeader",
    oneof: 0
  )

  field(:inline_content, 11, proto3_optional: true, type: :bytes, json_name: "inlineContent")

  field(:compression, 12,
    type: AudioFlowSFU.LiveKit.Proto.DataStream.CompressionType,
    enum: true
  )
end

defmodule AudioFlowSFU.LiveKit.Proto.DataStream.Chunk do
  @moduledoc false

  use Protobuf,
    full_name: "livekit.DataStream.Chunk",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field(:stream_id, 1, type: :string, json_name: "streamId", deprecated: false)
  field(:chunk_index, 2, type: :uint64, json_name: "chunkIndex")
  field(:content, 3, type: :bytes)
  field(:version, 4, type: :int32)
  field(:iv, 5, proto3_optional: true, type: :bytes, deprecated: true)
end

defmodule AudioFlowSFU.LiveKit.Proto.DataStream.Trailer.AttributesEntry do
  @moduledoc false

  use Protobuf,
    full_name: "livekit.DataStream.Trailer.AttributesEntry",
    map: true,
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field(:key, 1, type: :string)
  field(:value, 2, type: :string)
end

defmodule AudioFlowSFU.LiveKit.Proto.DataStream.Trailer do
  @moduledoc false

  use Protobuf,
    full_name: "livekit.DataStream.Trailer",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field(:stream_id, 1, type: :string, json_name: "streamId", deprecated: false)
  field(:reason, 2, type: :string)

  field(:attributes, 3,
    repeated: true,
    type: AudioFlowSFU.LiveKit.Proto.DataStream.Trailer.AttributesEntry,
    map: true
  )
end

defmodule AudioFlowSFU.LiveKit.Proto.DataStream do
  @moduledoc false

  use Protobuf,
    full_name: "livekit.DataStream",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3
end

defmodule AudioFlowSFU.LiveKit.Proto.FilterParams do
  @moduledoc false

  use Protobuf,
    full_name: "livekit.FilterParams",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field(:include_events, 1, repeated: true, type: :string, json_name: "includeEvents")
  field(:exclude_events, 2, repeated: true, type: :string, json_name: "excludeEvents")
end

defmodule AudioFlowSFU.LiveKit.Proto.WebhookConfig do
  @moduledoc false

  use Protobuf,
    full_name: "livekit.WebhookConfig",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field(:url, 1, type: :string)
  field(:signing_key, 2, type: :string, json_name: "signingKey")

  field(:filter_params, 3,
    type: AudioFlowSFU.LiveKit.Proto.FilterParams,
    json_name: "filterParams"
  )
end

defmodule AudioFlowSFU.LiveKit.Proto.SubscribedAudioCodec do
  @moduledoc false

  use Protobuf,
    full_name: "livekit.SubscribedAudioCodec",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field(:codec, 1, type: :string)
  field(:enabled, 2, type: :bool)
end
