use lightray_core::{
    control::*, crypto::*, fec::*, handshake::*, input::*, memory::MemoryBudget, reliable::*,
    wire::*,
};
use serde_json::Value;
fn unhex(s: &str) -> Vec<u8> {
    hex::decode(s).unwrap()
}
fn bytes(v: &Value) -> Vec<u8> {
    unhex(v.as_str().unwrap())
}
fn array32(v: &Value) -> [u8; 32] {
    bytes(v).try_into().unwrap()
}
fn vectors() -> Value {
    serde_json::from_str(include_str!("../../../tools/vectors/vectors.json")).unwrap()
}

#[test]
fn apple_handshake_vector_exact() {
    let v = vectors();
    let i = &v["handshake"]["inputs"];
    let o = &v["handshake"]["outputs"];
    let params = HandshakeParams::decode(&bytes(&i["init_params"])).unwrap();
    assert_eq!(params.encoded(), bytes(&i["init_params"]));
    let id = u64::from_str_radix(i["pairing_id"].as_str().unwrap(), 16).unwrap();
    let psk = array32(&i["psk"]);
    let client =
        ClientHandshake::with_ephemeral(psk, id, params, array32(&i["client_ephemeral_private"]))
            .unwrap();
    assert_eq!(client.datagram, bytes(&o["init"]));
    let host = OpenedInit::open(&client.datagram, &|p| {
        if p == id { Some(psk) } else { None }
    })
    .unwrap();
    host.validate(1_700_000_000).unwrap();
    let token = reset_token(
        &bytes(&i["host_secret"]),
        i["session_id"].as_u64().unwrap() as u32,
    );
    assert_eq!(token.to_vec(), bytes(&o["reset_token"]));
    let response = host
        .respond_with_ephemeral(
            i["session_id"].as_u64().unwrap() as u32,
            token,
            HandshakeParams::decode(&bytes(&i["response_params"])).unwrap(),
            array32(&i["host_ephemeral_private"]),
        )
        .unwrap();
    assert_eq!(response.response, bytes(&o["response"]));
    assert_eq!(
        response.handshake_hash.to_vec(),
        bytes(&o["handshake_hash"])
    );
    assert_eq!(response.send_key.to_vec(), bytes(&o["host_to_client_key"]));
    assert_eq!(
        response.receive_key.to_vec(),
        bytes(&o["client_to_host_key"])
    );
    let opened = client.open(&response.response).unwrap().unwrap();
    assert_eq!(opened.send_key, response.receive_key);
    assert_eq!(opened.receive_key, response.send_key);
    assert_eq!(opened.handshake_hash, response.handshake_hash);
    assert_eq!(
        session_unknown(opened.session_id, token),
        bytes(&o["session_unknown"])
    );
    let mut corrupt = response.response.clone();
    corrupt[50] ^= 1;
    assert!(client.open(&corrupt).unwrap().is_none());
    assert!(client.open(&response.response).unwrap().is_some());
}
#[test]
fn apple_packet_and_number_vectors() {
    let v = vectors();
    for n in v["packet_numbers"].as_array().unwrap() {
        assert_eq!(
            reconstruct_packet_number(
                n["expected"].as_u64().unwrap(),
                n["transport_seq"].as_u64().unwrap() as u32
            ),
            n["packet_number"].as_u64().unwrap()
        );
    }
    let i = &v["protected_datagram"]["inputs"];
    let o = &v["protected_datagram"]["outputs"];
    let header = ProtectedHeader {
        flags: 0,
        session_id: i["session_id"].as_u64().unwrap() as u32,
        transport_seq: i["packet_number"].as_u64().unwrap() as u32,
        send_time_micros: i["send_time_us"].as_u64().unwrap() as u32,
    };
    let key = TrafficKey::new(array32(&i["key"]));
    let n = i["packet_number"].as_u64().unwrap();
    assert_eq!(header.encoded(), bytes(&o["header"]));
    assert_eq!(nonce(n).to_vec(), bytes(&o["nonce"]));
    let sealed = seal_packet(header, &key, n, &bytes(&i["chunks"])).unwrap();
    assert_eq!(sealed, bytes(&o["datagram"]));
    assert_eq!(open_packet(&sealed, &key, n).unwrap(), bytes(&i["chunks"]));
    let mut corrupt = sealed.clone();
    corrupt[2] ^= 1;
    assert!(open_packet(&corrupt, &key, n).is_none());
    let chunk = Chunk::FrameAck(vec![
        FrameAckEntry {
            stream: 1,
            frame_id: 500,
        },
        FrameAckEntry {
            stream: 1,
            frame_id: 501,
        },
    ]);
    assert_eq!(chunk.encoded(), bytes(&v["frame_ack"]["outputs"]["chunk"]));
    assert_eq!(Chunk::parse(&chunk.encoded()).chunks, vec![chunk]);
}
#[test]
fn apple_fec_reference_coefficients_parity_and_recovery() {
    let v: Value = serde_json::from_str(include_str!(
        "../../../apple/core/Tests/LightrayCoreTests/Fixtures/fec-reference.json"
    ))
    .unwrap();
    let mut rs = ReedSolomon::default();
    for case in v["cases"].as_array().unwrap() {
        let k = case["k"].as_u64().unwrap() as usize;
        let p = case["p"].as_u64().unwrap() as usize;
        let stride = case["stride"].as_u64().unwrap() as usize;
        let flat = |value: &Value| -> Vec<u8> {
            value
                .as_array()
                .unwrap()
                .iter()
                .flat_map(|row| {
                    row.as_array()
                        .unwrap()
                        .iter()
                        .map(|b| b.as_u64().unwrap() as u8)
                })
                .collect()
        };
        let coefficients = flat(&case["coefficients"]);
        assert_eq!(rs.coefficients(k, p), coefficients);
        let data = flat(&case["data"]);
        let parity = rs.encode(&data, k, p, stride).unwrap();
        assert_eq!(parity, flat(&case["parity"]));
        let missing: Vec<_> = (0..k.min(p)).collect();
        let mut recovered = data.clone();
        for i in &missing {
            recovered[i * stride..(i + 1) * stride].fill(0xff);
        }
        let selected: Vec<_> = (0..missing.len())
            .map(|row| (row, &parity[row * stride..(row + 1) * stride]))
            .collect();
        rs.recover(&mut recovered, k, p, stride, &missing, &selected)
            .unwrap();
        assert_eq!(data, recovered);
    }
}
#[test]
fn replay_rollover_and_authentication_order() {
    let mut r = ReplayWindow::default();
    assert!(r.accepts(0));
    r.record(0);
    assert!(!r.accepts(0));
    r.record(2048);
    assert!(!r.accepts(0));
    assert!(r.accepts(2047));
    r.record(2047);
    assert!(!r.accepts(2047));
    r.record(10000);
    assert!(r.accepts(9999));
    assert!(!r.accepts(7952));
    assert_eq!(r.expected(), 10001);
}
#[test]
fn pairing_matches_apple_token() {
    let p = Pairing {
        id: 0x1122334455667788,
        psk: [0x42; 32],
    };
    assert_eq!(
        Pairing::parse(&format!(" {}\n", p.token()))
            .unwrap()
            .token(),
        p.token()
    );
    assert!(Pairing::parse("lr1-00").is_none());
    assert!(Pairing::parse(&format!("lr1-{}", "é".repeat(40))).is_none());
}
#[test]
fn reliable_loss_duplicate_order_and_budget() {
    let mut sender = ReliableSender::new(3);
    assert!(sender.enqueue(b"first message", 4));
    assert!(sender.enqueue(b"second", 4));
    let first = sender.due(1000, 100);
    assert!(sender.due(1099, 100).is_empty());
    assert_eq!(sender.due(1100, 100), first);
    assert_eq!(sender.next_deadline(100), Some(1300));
    let budget = MemoryBudget::new(4 << 20);
    let mut receiver = ReliableReceiver::with_budget(3, budget.clone(), None);
    let mut delivered = Vec::new();
    for segment in first
        .iter()
        .filter(|s| s.msg_seq == 1)
        .chain(first.iter().filter(|s| s.msg_seq == 0).rev())
    {
        if let ReliableOutcome::Accepted { ack, deliver } = receiver.receive(segment) {
            if ack {
                sender.acknowledge(segment.msg_seq);
            }
            delivered.extend(deliver);
        }
    }
    assert_eq!(
        delivered,
        vec![b"first message".to_vec(), b"second".to_vec()]
    );
    assert!(sender.is_idle());
    assert_eq!(
        receiver.receive(&first[0]),
        ReliableOutcome::Accepted {
            ack: true,
            deliver: Vec::new()
        }
    );
    assert_eq!(budget.used_bytes(), 0);
    let small = MemoryBudget::new(1024);
    let mut bounded = ReliableReceiver::with_budget(3, small.clone(), None);
    for seq in 0..2000 {
        let s = ReliableSegment {
            stream: 3,
            msg_seq: seq,
            seg_index: 0,
            seg_count: 8192,
            payload: vec![1; 100],
        };
        assert_eq!(bounded.receive(&s), ReliableOutcome::Discarded);
    }
    assert_eq!(small.used_bytes(), 0);
}
#[test]
fn input_control_and_fragment_exact_layout() {
    let key = InputMessage::Key {
        usage: 4,
        down: true,
        is_repeat: false,
    };
    assert_eq!(key.encoded().unwrap(), vec![1, 0, 4, 1]);
    assert_eq!(InputMessage::parse(&key.encoded().unwrap()), Some(key));
    assert_eq!(
        InputMessage::parse(&[0x10, 0, 1, 0, 2]),
        Some(InputMessage::Pointer {
            x: 1,
            y: 2,
            display: 0
        })
    );
    assert!(InputMessage::parse(&[2, 0, 2, 0xff, 0xff]).is_none());
    let control = ControlMessage::SelectDisplay {
        req_id: 1,
        stream: 2,
        display: 100,
    };
    assert_eq!(control.encoded(), unhex("010000000102f0000400000064"));
    assert_eq!(ControlMessage::parse(&control.encoded()), Some(control));
    let fragment = MediaFragment {
        stream: 1,
        flags: 1,
        frame_id: 2,
        index: 0,
        count: 1,
        stride: 3,
        fec: Some(FecParameters {
            max_block_length: 3,
            parity_per_block: 1,
            last_length: 2,
        }),
        payload: vec![9, 8],
    };
    let chunk = Chunk::MediaFragment(fragment);
    assert_eq!(Chunk::parse(&chunk.encoded()).chunks, vec![chunk]);
    let parsed = Chunk::parse(&[0x30, 0, 1, 1, 0x34, 0, 2, 0, 0]);
    assert_eq!(parsed.malformed, 1);
    assert_eq!(parsed.chunks, vec![Chunk::Close(CloseCode::Normal)]);
}
#[test]
fn fec_layout_interleaving_is_bijective() {
    for count in [1, 3, 17, 250, 256, 1000] {
        let l = FecLayout::for_frame(count, 20, 2);
        let mut data = vec![false; count];
        let mut parity = vec![false; l.parity_count()];
        for position in 0..l.position_count() {
            let (p, i) = l.fragment_at(position);
            if p {
                assert!(!parity[i]);
                parity[i] = true;
                assert_eq!(l.position_of_parity(i), position);
            } else {
                assert!(!data[i]);
                data[i] = true;
                assert_eq!(l.position_of_data(i), position);
            }
        }
        assert!(data.into_iter().all(|v| v));
        assert!(parity.into_iter().all(|v| v));
    }
}

#[test]
fn malformed_network_inputs_never_panic() {
    use rand::{RngCore, SeedableRng};
    let mut rng = rand::rngs::StdRng::seed_from_u64(0x6c69676874726179);
    for length in 0..512 {
        let mut bytes = vec![0; length];
        for _ in 0..8 {
            rng.fill_bytes(&mut bytes);
            let _ = Chunk::parse(&bytes);
            let _ = InputMessage::parse(&bytes);
            let _ = ControlMessage::parse(&bytes);
            let _ = HandshakeParams::decode(&bytes);
            let _ = OpenedInit::open(&bytes, &|_| Some([0; 32]));
        }
    }
}

#[test]
fn handshake_rejects_tampered_headers_and_unoffered_capabilities() {
    let v = vectors();
    let i = &v["handshake"]["inputs"];
    let params = HandshakeParams::decode(&bytes(&i["init_params"])).unwrap();
    let psk = array32(&i["psk"]);
    let client = ClientHandshake::with_ephemeral(psk, 123, params.clone(), [1; 32]).unwrap();
    for offset in [2, 3, 20, 100, 255] {
        let mut corrupt = client.datagram.clone();
        corrupt[offset] ^= 1;
        assert!(OpenedInit::open(&corrupt, &|_| Some(psk)).is_err());
    }
    let opened = OpenedInit::open(&client.datagram, &|_| Some(psk)).unwrap();
    assert!(opened.validate(params.timestamp.unwrap() + 31).is_err());
    let invalid = HandshakeParams {
        timestamp: None,
        capabilities: Some(0x80),
        ..params
    };
    let response = opened.respond(1, [1; 16], invalid).unwrap();
    assert!(client.open(&response.response).is_err());
    let mut sender = ReliableSender::new(0);
    assert!(sender.enqueue(b"immediate", 100));
    assert_eq!(sender.next_deadline(1000), Some(0));
}
