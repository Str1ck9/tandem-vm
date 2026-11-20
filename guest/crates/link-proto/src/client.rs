//! Request/reply client: many requests multiplexed on one stream, matched by request id.
use crate::frame::{Buffer, Decoder, Frame, KIND_REPLY};
use crate::transport::{Connection, LinkWrite};
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::{channel, RecvTimeoutError, Sender};
use std::sync::{Arc, Mutex};
use std::time::Duration;

#[derive(Debug)]
pub enum LinkError {
    Disconnected,
    Timeout,
    /// The host answered with a non-OK status.
    Status(u32),
    Io(std::io::Error),
}

impl std::fmt::Display for LinkError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            LinkError::Disconnected => write!(f, "disconnected"),
            LinkError::Timeout => write!(f, "timed out"),
            LinkError::Status(s) => write!(f, "host returned status {s:#010x}"),
            LinkError::Io(e) => write!(f, "i/o error: {e}"),
        }
    }
}

#[derive(Debug)]
pub struct Reply {
    pub inline: Vec<u8>,
    pub buffers: Vec<Buffer>,
}

impl Reply {
    /// Bytes the host returned in output buffer `index`.
    pub fn output(&self, index: usize) -> &[u8] {
        self.buffers.get(index).and_then(|b| b.data.as_deref()).unwrap_or(&[])
    }
    pub fn u32_at(&self, offset: usize) -> Option<u32> {
        self.inline.get(offset..offset + 4).map(|b| u32::from_le_bytes([b[0], b[1], b[2], b[3]]))
    }
}

type Pending = Arc<Mutex<HashMap<u64, Sender<Frame>>>>;

pub struct Client {
    writer: Mutex<Box<dyn LinkWrite>>,
    pending: Pending,
    next_id: AtomicU64,
    alive: Arc<AtomicBool>,
}

impl Client {
    /// Takes ownership of the connection and starts the reader thread.
    pub fn new(connection: Connection) -> Arc<Client> {
        let pending: Pending = Arc::new(Mutex::new(HashMap::new()));
        let alive = Arc::new(AtomicBool::new(true));
        let client = Arc::new(Client {
            writer: Mutex::new(connection.writer),
            pending: pending.clone(),
            next_id: AtomicU64::new(1),
            alive: alive.clone(),
        });
        let mut reader = connection.reader;
        std::thread::Builder::new().name("guestlink-reader".into()).spawn(move || {
            let mut decoder = Decoder::new();
            let mut buf = vec![0u8; 65536];
            loop {
                let timeout = if decoder.has_partial_frame() { Some(Duration::from_secs(1)) } else { None };
                let frames = match reader.read_timeout(&mut buf, timeout) {
                    Ok(Some(0)) | Err(_) => break,
                    Ok(Some(n)) => decoder.feed(&buf[..n]),
                    Ok(None) => decoder.resync_after_stall(),
                };
                for frame in frames {
                    if frame.kind != KIND_REPLY { continue; }
                    if let Some(tx) = pending.lock().unwrap().remove(&frame.request_id) {
                        let _ = tx.send(frame);
                    }
                }
            }
            alive.store(false, Ordering::SeqCst);
            // Dropping the senders wakes every waiter with Disconnected.
            pending.lock().unwrap().clear();
        }).expect("spawn reader thread");
        client
    }

    pub fn is_alive(&self) -> bool { self.alive.load(Ordering::SeqCst) }

    /// Sends a request and waits for its reply. `timeout: None` waits until the stream ends.
    pub fn call(&self, opcode: u16, inline: Vec<u8>, buffers: Vec<Buffer>, timeout: Option<Duration>) -> Result<Reply, LinkError> {
        if !self.is_alive() { return Err(LinkError::Disconnected); }
        let id = self.next_id.fetch_add(1, Ordering::SeqCst);
        let (tx, rx) = channel();
        self.pending.lock().unwrap().insert(id, tx);
        let bytes = Frame::request(id, opcode, inline, buffers).encode();
        if let Err(e) = self.writer.lock().unwrap().write_all(&bytes) {
            self.pending.lock().unwrap().remove(&id);
            return Err(LinkError::Io(e));
        }
        // The reader may have died between the alive check and the insert; do not wait forever.
        if !self.is_alive() {
            self.pending.lock().unwrap().remove(&id);
            return Err(LinkError::Disconnected);
        }
        let frame = match timeout {
            Some(t) => match rx.recv_timeout(t) {
                Ok(f) => f,
                Err(RecvTimeoutError::Timeout) => {
                    self.pending.lock().unwrap().remove(&id);
                    return Err(LinkError::Timeout);
                }
                Err(RecvTimeoutError::Disconnected) => return Err(LinkError::Disconnected),
            },
            None => rx.recv().map_err(|_| LinkError::Disconnected)?,
        };
        if frame.status != crate::status::OK { return Err(LinkError::Status(frame.status)); }
        Ok(Reply { inline: frame.inline, buffers: frame.buffers })
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use crate::frame::{FLAG_OUT, KIND_REQUEST};
    use crate::{op, status};
    use std::io::{Read, Write};
    use std::os::fd::OwnedFd;
    use std::os::unix::net::UnixStream;

    /// A minimal host: answers ECHO, never answers WAIT_EVENT, rejects the rest.
    fn fake_host(mut stream: UnixStream) {
        std::thread::spawn(move || {
            let mut decoder = Decoder::new();
            let mut buf = [0u8; 65536];
            while let Ok(n) = stream.read(&mut buf) {
                if n == 0 { break; }
                for f in decoder.feed(&buf[..n]) {
                    assert_eq!(f.kind, KIND_REQUEST);
                    if f.opcode == op::WAIT_EVENT { continue; }
                    let mut reply = Frame { kind: KIND_REPLY, status: status::OK, inline: vec![], ..f.clone() };
                    if f.opcode == op::ECHO {
                        let data = f.buffers[0].data.clone();
                        reply.buffers[1] = Buffer { flags: FLAG_OUT, length: 0, data };
                    } else {
                        reply.status = status::UNKNOWN_OPCODE;
                    }
                    stream.write_all(&reply.encode()).unwrap();
                }
            }
        });
    }

    fn pair() -> (Arc<Client>, UnixStream) {
        let (a, b) = UnixStream::pair().unwrap();
        let file = std::fs::File::from(OwnedFd::from(a));
        (Client::new(crate::transport::from_file(file, "test".into()).unwrap()), b)
    }

    #[test]
    fn echo_round_trip_and_error_status() {
        let (client, host) = pair();
        fake_host(host);
        let payload: Vec<u8> = (0..200_000u32).map(|i| i as u8).collect();
        let reply = client.call(op::ECHO, vec![], vec![Buffer::input(&payload), Buffer::output(payload.len())], Some(Duration::from_secs(5))).unwrap();
        assert_eq!(reply.output(1), &payload[..]);
        match client.call(0x0999, vec![], vec![], Some(Duration::from_secs(5))) {
            Err(LinkError::Status(s)) => assert_eq!(s, status::UNKNOWN_OPCODE),
            other => panic!("unexpected {other:?}"),
        }
    }

    #[test]
    fn concurrent_calls_are_matched_by_id() {
        let (client, host) = pair();
        fake_host(host);
        let handles: Vec<_> = (0..16u8).map(|i| {
            let c = client.clone();
            std::thread::spawn(move || {
                let data = vec![i; 1000 + i as usize];
                let r = c.call(op::ECHO, vec![], vec![Buffer::input(&data), Buffer::output(data.len())], Some(Duration::from_secs(5))).unwrap();
                assert_eq!(r.output(1), &data[..]);
            })
        }).collect();
        for h in handles { h.join().unwrap(); }
    }

    #[test]
    fn timeout_then_disconnect() {
        let (client, host) = pair();
        let keep = host.try_clone().unwrap();
        fake_host(host);
        match client.call(op::WAIT_EVENT, vec![], vec![Buffer::output(16)], Some(Duration::from_millis(100))) {
            Err(LinkError::Timeout) => {}
            other => panic!("unexpected {other:?}"),
        }
        let c = client.clone();
        let waiter = std::thread::spawn(move || c.call(op::WAIT_EVENT, vec![], vec![Buffer::output(16)], None));
        std::thread::sleep(Duration::from_millis(100));
        keep.shutdown(std::net::Shutdown::Both).unwrap();
        assert!(matches!(waiter.join().unwrap(), Err(LinkError::Disconnected)));
        assert!(!client.is_alive());
        assert!(matches!(client.call(op::ECHO, vec![], vec![], None), Err(LinkError::Disconnected)));
    }
}
