use lightray_core::{
    connection::{Connection, Inbound, Role},
    control::ControlMessage,
    endpoint::{ClientConfig, ClientEndpoint, ClientEvent, HostConfig, HostEndpoint, HostEvent},
    handshake::{self, Direction, StreamClass, StreamEntry, StreamKind, StreamTable},
    input::InputMessage,
    media::{
        CodecConfig, EncodedFrame, FrameHeader, FrameType, HostFrameTimings, RefKind,
        VideoReceiver, VideoSender,
    },
    memory::MemoryBudget,
    wire::{Chunk, CloseCode},
};
use std::{collections::HashMap, net::SocketAddr};

const UNIX: u64 = 1_800_000_000;
fn addr(port: u16) -> SocketAddr {
    ([127, 0, 0, 1], port).into()
}
fn pair() -> (HostEndpoint, ClientEndpoint) {
    let mut h = HostEndpoint::new(
        HostConfig::default(),
        [8; 32],
        HashMap::from([(42, [7; 32])]),
    );
    let mut c = ClientEndpoint::new(ClientConfig::new(42, [7; 32], addr(7373)));
    c.start(1_000, UNIX);
    exchange(&mut h, &mut c, 2_000);
    assert!(c.is_connected());
    (h, c)
}
fn exchange(h: &mut HostEndpoint, c: &mut ClientEndpoint, now: u64) {
    for _ in 0..3 {
        for d in c.take_outbox() {
            assert_eq!(d.destination, addr(7373));
            h.receive(&d.bytes, addr(45000), now, UNIX);
        }
        for d in h.take_outbox() {
            assert_eq!(d.destination, addr(45000));
            c.receive(&d.bytes, addr(7373), now, UNIX);
        }
        c.tick(now, UNIX);
        h.tick(now, UNIX);
    }
}
fn frame(key: bool, size: usize) -> EncodedFrame {
    EncodedFrame {
        is_keyframe: key,
        payload: (0..size).map(|n| (n % 251) as u8).collect(),
        codec_config: key.then_some(CodecConfig {
            vps: vec![0x40, 1, 3],
            sps: vec![0x42, 1, 7],
            pps: vec![0x44, 1, 9],
        }),
        capture_time_micros: 20_000,
        host_timings: None,
    }
}
fn connection_pair() -> (Connection, Connection) {
    let streams = StreamTable {
        entries: vec![
            StreamEntry {
                id: 1,
                kind: StreamKind::Video,
                direction: Direction::HostToClient,
                stream_class: StreamClass::Media,
            },
            StreamEntry {
                id: 4,
                kind: StreamKind::Input,
                direction: Direction::ClientToHost,
                stream_class: StreamClass::Reliable,
            },
        ],
    };
    (
        Connection::new(
            Role::Host,
            9,
            [1; 32],
            [2; 32],
            streams.clone(),
            1200,
            addr(45000),
            0,
        ),
        Connection::new(
            Role::Client,
            9,
            [2; 32],
            [1; 32],
            streams,
            1200,
            addr(7373),
            0,
        ),
    )
}

#[test]
fn handshake_authentication_cache_and_input_control_roundtrip() {
    let mut h = HostEndpoint::new(
        HostConfig::default(),
        [8; 32],
        HashMap::from([(42, [7; 32])]),
    );
    let mut c = ClientEndpoint::new(ClientConfig::new(42, [7; 32], addr(7373)));
    c.start(0, UNIX);
    let init = c.take_outbox().remove(0).bytes;
    let mut forged = init.clone();
    forged[80] ^= 1;
    h.receive(&forged, addr(45000), 1_000, UNIX);
    assert!(h.session.is_none());
    h.receive(&init, addr(45000), 2_000, UNIX);
    let response = h.take_outbox().remove(0).bytes;
    h.receive(&init, addr(45000), 3_000, UNIX + 100);
    assert_eq!(h.take_outbox().remove(0).bytes, response);
    assert_eq!(h.stats.inits_answered_from_cache, 1);
    c.receive(&response, addr(7373), 4_000, UNIX);
    assert!(c.is_connected());
    c.send_input(
        InputMessage::Key {
            usage: 4,
            down: true,
            is_repeat: false,
        },
        5_000,
    );
    c.select_display(100, 1);
    exchange(&mut h, &mut c, 6_000);
    let events = h.take_events();
    assert!(events.iter().any(|e| matches!(
        e,
        HostEvent::Input(InputMessage::Key {
            usage: 4,
            down: true,
            ..
        })
    )));
    assert!(events.iter().any(|e| matches!(
        e,
        HostEvent::DisplayRequested {
            stream: 1,
            display: 100,
            ..
        }
    )));
    h.send_control(ControlMessage::DisplaySelected {
        req_id: 1,
        stream: 1,
        display: 100,
    });
    exchange(&mut h, &mut c, 9_000);
    assert!(c.take_events().iter().any(|e| matches!(
        e,
        ClientEvent::StreamDisplay {
            stream: 1,
            display: 100
        }
    )));
}
#[test]
fn packet_replay_forgery_rebind_and_address_validation() {
    let (mut h, mut c) = connection_pair();
    let packet = c.seal(&Chunk::Ping { id: 1 }.encoded(), 1_000).unwrap();
    let mut forged = packet.clone();
    forged[20] ^= 0x80;
    assert!(h.receive(&forged, addr(45000), 2_000).is_none());
    assert_eq!(h.stats.authentication_failures, 1);
    assert!(h.receive(&packet, addr(45001), 3_000).is_some());
    assert_eq!(h.peer, addr(45001));
    assert!(h.receive(&packet, addr(45002), 4_000).is_none());
    assert_eq!(h.peer, addr(45001));
    let new_ip: SocketAddr = ([127, 0, 0, 2], 45001).into();
    let packet = c.seal(&Chunk::Ping { id: 2 }.encoded(), 5_000).unwrap();
    assert!(h.receive(&packet, new_ip, 6_000).is_some());
    assert!(h.is_validating_address());
    let allowed = h.seal(&Chunk::Ping { id: 9 }.encoded(), 7_000).unwrap();
    assert!(h.seal(&vec![0; 1100], 7_000).is_none());
    c.receive(&allowed, addr(7373), 8_000).unwrap();
    for reply in c.flush(30_000) {
        h.receive(&reply, new_ip, 31_000);
    }
    assert!(!h.is_validating_address());
}
#[test]
fn reliable_message_retransmits_after_loss_and_delivers_once() {
    let (mut h, mut c) = connection_pair();
    assert!(c.send(b"first", 4));
    assert!(c.send(b"second", 4));
    let lost = c.flush(1_000);
    assert!(!lost.is_empty());
    assert!(c.next_deadline() <= 46_000);
    let resent = c.flush(50_000);
    assert!(!resent.is_empty());
    let mut messages = Vec::new();
    for d in &resent {
        for item in h.receive(d, addr(45000), 51_000).unwrap() {
            if let Inbound::Message { payload, .. } = item {
                messages.push(payload);
            }
        }
    }
    assert_eq!(messages, vec![b"first".to_vec(), b"second".to_vec()]);
    for d in &resent {
        assert!(h.receive(d, addr(45000), 52_000).is_none());
    }
    for d in h.flush(54_000) {
        c.receive(&d, addr(7373), 55_000);
    }
    assert!(c.flush(100_000).is_empty());
}
#[test]
fn fec_loss_reassembles_byte_exact_and_preserves_frame_chain() {
    let mut s = VideoSender::new(1, 20_000_000, 60);
    s.fec_percent = 20;
    let mut r = VideoReceiver::new(1, None);
    let original = frame(true, 40_000);
    s.submit(original.clone(), 1_000, 1200, 150_000);
    let mut dropped = false;
    for now in (1_000..100_000).step_by(500) {
        for d in s.drain(now, 1200, |b| Some(b.to_vec())) {
            for chunk in Chunk::parse(&d).chunks {
                if let Chunk::MediaFragment(f) = chunk {
                    if !dropped && !f.is_parity() && f.index == 1 {
                        dropped = true;
                        continue;
                    }
                    r.receive(f, now, 150_000);
                }
            }
        }
    }
    let frames = r.take_frames();
    assert_eq!(frames.len(), 1);
    assert_eq!(frames[0].payload(), original.payload);
    assert_eq!(frames[0].header.codec_config, original.codec_config);
    assert!(r.stats.fec_repaired >= 1);
    r.decoded(1, true);
    s.submit(frame(false, 8_000), 101_000, 1200, 150_000);
    for now in (101_000..140_000).step_by(500) {
        for d in s.drain(now, 1200, |b| Some(b.to_vec())) {
            for chunk in Chunk::parse(&d).chunks {
                if let Chunk::MediaFragment(f) = chunk {
                    r.receive(f, now, 150_000);
                }
            }
        }
    }
    assert_eq!(r.take_frames().len(), 1);
}
#[test]
fn nack_retransmission_and_decoder_refresh_are_independent_per_stream() {
    let mut sender = VideoSender::new(1, 20_000_000, 60);
    let mut receiver = VideoReceiver::new(1, None);
    sender.submit(frame(true, 7_000), 1_000, 1200, 150_000);
    let mut drop = true;
    for d in sender.drain(1_000, 1200, |b| Some(b.to_vec())) {
        for ch in Chunk::parse(&d).chunks {
            if let Chunk::MediaFragment(f) = ch {
                if f.index == 1 && drop {
                    drop = false;
                    continue;
                }
                receiver.receive(f, 2_000, 150_000);
            }
        }
    }
    let chunks = receiver.poll(12_000, 20_000, 150_000, 12_000);
    let mut asked = false;
    for chunk in chunks {
        if let Chunk::Nack(n) = chunk {
            sender.handle_nack(&n, 12_000, 20_000);
            asked = true;
        }
    }
    assert!(asked);
    for d in sender.drain(13_000, 1200, |b| Some(b.to_vec())) {
        for ch in Chunk::parse(&d).chunks {
            if let Chunk::MediaFragment(f) = ch {
                receiver.receive(f, 14_000, 150_000);
            }
        }
    }
    assert_eq!(receiver.take_frames().len(), 1);
    assert_eq!(sender.stats.retransmissions, 1);
    receiver.decoder_failed(1);
    assert!(
        receiver
            .poll(15_000, 20_000, 150_000, 15_000)
            .iter()
            .any(|c| matches!(c, Chunk::RefreshRequest(_)))
    );
    let mut other = VideoReceiver::new(16, None);
    assert!(other.poll(15_000, 20_000, 150_000, 15_000).is_empty());
}
#[test]
fn held_frames_hold_budget_until_consumer_releases_them() {
    let shared = MemoryBudget::new(1 << 20);
    let mut receiver = VideoReceiver::new(1, Some(shared.clone()));
    let mut sender = VideoSender::new(1, 20_000_000, 60);
    sender.submit(frame(true, 4_000), 1_000, 1200, 150_000);
    for d in sender.drain(1_000, 1200, |b| Some(b.to_vec())) {
        for ch in Chunk::parse(&d).chunks {
            if let Chunk::MediaFragment(f) = ch {
                receiver.receive(f, 2_000, 150_000);
            }
        }
    }
    let held = receiver.take_frames();
    assert_eq!(held.len(), 1);
    let charge = shared.used_bytes();
    assert!(charge > 4_000);
    let copy = held[0].clone();
    drop(held);
    assert_eq!(shared.used_bytes(), charge);
    drop(copy);
    assert_eq!(shared.used_bytes(), 0);
    let tiny = MemoryBudget::new(256);
    let mut receiver = VideoReceiver::new(1, Some(tiny.clone()));
    let mut sender = VideoSender::new(1, 20_000_000, 60);
    sender.submit(frame(true, 4_000), 1_000, 1200, 150_000);
    for d in sender.drain(1_000, 1200, |b| Some(b.to_vec())) {
        for ch in Chunk::parse(&d).chunks {
            if let Chunk::MediaFragment(f) = ch {
                receiver.receive(f, 2_000, 150_000);
            }
        }
    }
    assert_eq!(receiver.memory_budget.used_bytes(), 0);
    assert_eq!(tiny.used_bytes(), 0);
    assert!(receiver.stats.memory_limit_drops > 0);
}
#[test]
fn pause_resume_expire_and_authenticated_stateless_reset() {
    let (mut h, mut c) = pair();
    h.take_events();
    c.take_events();
    h.tick(2_010_000, UNIX);
    assert!(!h.is_streaming());
    assert!(
        h.take_events()
            .iter()
            .any(|e| matches!(e, HostEvent::Paused))
    );
    c.tick(2_010_000, UNIX);
    for d in c.take_outbox() {
        h.receive(&d.bytes, addr(45000), 2_011_000, UNIX);
    }
    assert!(h.is_streaming());
    assert!(
        h.take_events()
            .iter()
            .any(|e| matches!(e, HostEvent::Resumed))
    );
    let id = h.session.as_ref().unwrap().connection.session_id;
    let forged = handshake::session_unknown(id, [0; 16]);
    c.receive(&forged, addr(7373), 2_012_000, UNIX);
    assert!(c.is_connected());
    let reset = handshake::session_unknown(id, handshake::reset_token(&[8; 32], id));
    c.receive(&reset, addr(7373), 2_013_000, UNIX);
    assert!(!c.is_connected());
    assert!(!c.take_outbox().is_empty());
    h.tick(65_000_000, UNIX);
    assert!(h.session.is_none());
}
#[test]
fn frame_delivery_through_authenticated_endpoints_and_clean_close() {
    let (mut h, mut c) = pair();
    c.take_events();
    h.submit(frame(true, 6_000), 1, 10_000);
    for now in (10_000..40_000).step_by(1_000) {
        exchange(&mut h, &mut c, now);
    }
    let events = c.take_events();
    assert_eq!(
        events
            .iter()
            .filter(|e| matches!(e, ClientEvent::Frame { stream: 1, .. }))
            .count(),
        1
    );
    c.close(41_000);
    for d in c.take_outbox() {
        h.receive(&d.bytes, addr(45000), 42_000, UNIX);
    }
    assert!(h.session.is_none());
    assert!(!c.is_connected());
    let (mut h, mut c) = connection_pair();
    let close = c
        .seal(&Chunk::Close(CloseCode::AppRequest).encoded(), 1)
        .unwrap();
    assert!(matches!(
        h.receive(&close, addr(45000), 2).unwrap().as_slice(),
        [Inbound::Close(CloseCode::AppRequest)]
    ));
}

#[test]
fn apple_frame_header_golden_examples_and_optional_telemetry() {
    let hex = |s: &str| {
        (0..s.len())
            .step_by(2)
            .map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap())
            .collect::<Vec<_>>()
    };
    // Exact bytes from apple/core/Tests/LightrayCoreTests/WireTests.swift.
    let key = hex(
        "000001000000030001e24000530100500000001840010c01ffff01600000030090000003000003003cba02400000002642010101600000030090000003000003003ca0884596e96f0b9a020000030002000003003c10000000064401c0718112",
    );
    let (header, offset) = FrameHeader::parse(&key).unwrap();
    assert_eq!(offset, 96);
    assert_eq!(header.frame_type, FrameType::Idr);
    assert_eq!(header.ref_kind, RefKind::None);
    assert_eq!(header.flags, 1);
    assert_eq!(header.config_generation, 3);
    assert_eq!(header.capture_time_micros, 123_456);
    assert_eq!(header.encoded(), key);
    for expected in [
        "0102000000000100000005000010920000",
        "01030000000001000000050000",
    ] {
        let bytes = hex(expected);
        let (header, offset) = FrameHeader::parse(&bytes).unwrap();
        assert_eq!(offset, bytes.len());
        assert_eq!(header.encoded(), bytes);
    }
    assert!(FrameHeader::parse(&hex("00000000000001000000050000")).is_none());
    let mut timed = header;
    timed.host_timings = Some(HostFrameTimings {
        capture_micros: 1_000,
        encode_micros: 2_000,
        sample_id: 0x0102030405060708,
    });
    let bytes = timed.encoded();
    assert_eq!(
        &bytes[bytes.len() - 20..],
        &[
            0xf0, 0, 17, 1, 0, 0, 3, 232, 0, 0, 7, 208, 1, 2, 3, 4, 5, 6, 7, 8
        ]
    );
    assert_eq!(FrameHeader::parse(&bytes).unwrap().0, timed);
    let mut duplicate = bytes.clone();
    duplicate[11..13].copy_from_slice(&123u16.to_be_bytes());
    duplicate.extend_from_slice(&bytes[bytes.len() - 20..]);
    assert!(
        FrameHeader::parse(&duplicate)
            .unwrap()
            .0
            .host_timings
            .is_none()
    );
}

#[test]
fn link_silence_preserves_partial_frames_and_refresh_requests_are_deduplicated() {
    let mut sender = VideoSender::new(1, 20_000_000, 60);
    let mut receiver = VideoReceiver::new(1, None);
    sender.submit(frame(true, 4_000), 1_000, 1200, 50_000);
    let fragments: Vec<_> = sender
        .drain(1_000, 1200, |b| Some(b.to_vec()))
        .into_iter()
        .flat_map(|b| Chunk::parse(&b).chunks)
        .filter_map(|c| {
            if let Chunk::MediaFragment(f) = c {
                Some(f)
            } else {
                None
            }
        })
        .collect();
    receiver.receive(fragments[0].clone(), 2_000, 50_000);
    receiver.poll(90_000, 20_000, 50_000, 2_000);
    assert_eq!(receiver.stats.frames_lost, 0);
    receiver.link_resumed(100_000);
    for f in fragments.into_iter().skip(1) {
        receiver.receive(f, 102_000, 50_000);
    }
    assert_eq!(receiver.take_frames().len(), 1);
    receiver.decoder_failed(1);
    let request = receiver
        .poll(103_000, 20_000, 50_000, 103_000)
        .into_iter()
        .find_map(|c| {
            if let Chunk::RefreshRequest(r) = c {
                Some(r)
            } else {
                None
            }
        })
        .unwrap();
    assert!(sender.handle_refresh(&request, 103_000));
    assert!(!sender.handle_refresh(&request, 104_000));
    assert_eq!(sender.stats.refresh_requests, 1);
}
