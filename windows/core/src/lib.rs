//! The portable Lightray v1 protocol. No sockets, clocks, codecs or operating-system APIs.
pub mod bytes;
pub mod connection;
pub mod control;
pub mod crypto;
pub mod endpoint;
pub mod fec;
pub mod handshake;
pub mod input;
pub mod media;
pub mod memory;
pub mod reliable;
pub mod wire;

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum Error {
    #[error("truncated message")]
    Truncated,
    #[error("invalid parameters: {0}")]
    InvalidParameters(String),
    #[error("discard: {0}")]
    Discard(String),
    #[error("authentication failed")]
    Authentication,
    #[error("resource limit exceeded")]
    ResourceLimit,
}
pub type Result<T> = std::result::Result<T, Error>;
