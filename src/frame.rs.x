//! Provides a type representing a Redis protocol frame as well as utilities for
//! parsing frames from a byte array.

use crate::tikv::errors::RTError;
use bytes::{Buf, Bytes};
use std::convert::TryInto;
use std::fmt;
use std::io::Cursor;
use std::num::TryFromIntError;
use std::string::FromUtf8Error;
use std::io::{self};

/// A frame in the Redis protocol.
#[derive(Clone, Debug)]
pub enum Frame {
    Simple(String),
    ErrorOwned(String),
    ErrorString(&'static str),
    Integer(i64),
    Bulk(Bytes),
    Null,
    Array(Vec<Frame>),
}

#[derive(Debug)]
pub enum Error {
    /// Not enough data is available to parse a message
    Incomplete,

    /// Invalid message encoding
    Other(crate::Error),
}

impl Frame {
    /// Returns an empty array
    pub(crate) fn array() -> Frame {
        Frame::Array(vec![])
    }

    /// Push a "bulk" frame into the array. `self` must be an Array frame.
    ///
    /// # Panics
    ///
    /// panics if `self` is not an array
    pub(crate) fn push_bulk(&mut self, bytes: Bytes) {
        match self {
            Frame::Array(vec) => {
                vec.push(Frame::Bulk(bytes));
            }
            _ => panic!("not an array frame"),
        }
    }

    /// Push an "integer" frame into the array. `self` must be an Array frame.
    ///
    /// # Panics
    ///
    /// panics if `self` is not an array
    pub(crate) fn push_int(&mut self, value: i64) {
        match self {
            Frame::Array(vec) => {
                vec.push(Frame::Integer(value));
            }
            _ => panic!("not an array frame"),
        }
    }

    /// Checks if an entire message can be decoded from `src`
    pub fn check(src: &mut Cursor<&[u8]>) -> Result<(), Error> {
        match get_u8(src)? {
            b'+' => {
                get_line(src)?;
                Ok(())
            }
            b'-' => {
                get_line(src)?;
                Ok(())
            }
            b':' => {
                let _ = get_decimal(src)?;
                Ok(())
            }
            b'$' => {
                if b'-' == peek_u8(src)? {
                    // Skip '-1\r\n'
                    skip(src, 4)
                } else {
                    // Read the bulk string
                    let len: usize = get_decimal(src)?.try_into()?;

                    // skip that number of bytes + 2 (\r\n).
                    skip(src, len + 2)
                }
            }
            b'*' => {
                let len = get_decimal(src)?;

                for _ in 0..len {
                    Frame::check(src)?;
                }

                Ok(())
            }
            actual => Err(format!("protocol error; invalid frame type byte `{}`", actual).into()),
        }
    }

    /// The message has already been validated with `check`.
    pub fn parse(src: &mut Cursor<&[u8]>) -> Result<Frame, Error> {
        match get_u8(src)? {
            b'+' => {
                // Read the line and convert it to `Vec<u8>`
                let line = get_line(src)?.to_vec();

                // Convert the line to a String
                let string = String::from_utf8(line)?;

                Ok(Frame::Simple(string))
            }
            b'-' => {
                // Read the line and convert it to `Vec<u8>`
                let line = get_line(src)?.to_vec();

                // Convert the line to a String
                let string = String::from_utf8(line)?;

                Ok(Frame::ErrorOwned(string))
            }
            b':' => {
                let len = get_decimal(src)?;
                Ok(Frame::Integer(len))
            }
            b'$' => {
                if b'-' == peek_u8(src)? {
                    let line = get_line(src)?;

                    if line != b"-1" {
                        return Err("protocol error; invalid frame format".into());
                    }

                    Ok(Frame::Null)
                } else {
                    // Read the bulk string
                    let len = get_decimal(src)?.try_into()?;
                    let n = len + 2;

                    if src.remaining() < n {
                        return Err(Error::Incomplete);
                    }

                    let data = Bytes::copy_from_slice(&src.chunk()[..len]);

                    // skip that number of bytes + 2 (\r\n).
                    skip(src, n)?;

                    Ok(Frame::Bulk(data))
                }
            }
            b'*' => {
                let len = get_decimal(src)?.try_into()?;
                let mut out = Vec::with_capacity(len);

                for _ in 0..len {
                    out.push(Frame::parse(src)?);
                }

                Ok(Frame::Array(out))
            }
            _ => unimplemented!(),
        }
    }

    pub fn encode_array(&self,  frame: &Frame) -> io::Result<Vec<u8>>{
        let mut output: Vec<u8> = Vec::with_capacity(128);
        let output = &mut output;

        match frame {
            Frame::Array(val) => {
                // Encode the frame type prefix. For an array, it is `*`.
                self.write_all(output, b"*")?;

                // Encode the length of the array.
                self.write_decimal(output, val.len() as i64)?;

                // Iterate and encode each entry in the array.
                for entry in &**val {
                    // TODO make this to be recursive
                    // we need nested array response only for `cluster slots` command for now
                    match entry {
                        Frame::Array(val) => {
                            self.write_all(output, b"*")?;
                            self.write_decimal(output, val.len() as i64)?;
                            for entry in &**val {
                                match entry {
                                    Frame::Array(val) => {
                                        self.write_all(output, b"*")?;
                                        self.write_decimal(output, val.len() as i64)?;
                                        for entry in &**val {
                                            self.write_value(output, entry)?;
                                        }
                                    }
                                    _ => self.write_value(output, entry)?,
                                }
                            }
                        }
                        _ => self.write_value(output, entry)?,
                    }
                }
            }
            // The frame type is a literal. Encode the value directly.
            _ => self.write_value(output, frame)?,
        }

        Ok(output.to_vec())
    }

    /// Write a frame literal to the stream
    fn write_value(&self, output: &mut Vec<u8>, frame: &Frame) -> io::Result<()> {
        match frame {
            Frame::Simple(val) => {
                self.write_all(output, b"+")?;
                self.write_all(output, val.as_bytes())?;
                self.write_all(output, b"\r\n")?;
            }
            Frame::ErrorString(val) => {
                self.write_all(output, b"-")?;
                self.write_all(output, val.as_bytes())?;
                self.write_all(output, b"\r\n")?;
            }
            Frame::ErrorOwned(val) => {
                self.write_all(output, b"-")?;
                self.write_all(output, val.as_bytes())?;
                self.write_all(output, b"\r\n")?;
            }
            Frame::Integer(val) => {
                self.write_all(output, b":")?;
                self.write_decimal(output, *val)?;
            }
            Frame::Null => {
                self.write_all(output, b"$-1\r\n")?;
            }
            Frame::Bulk(val) => {
                let len = val.len();

                self.write_all(output, b"$")?;
                self.write_decimal(output, len as i64)?;
                self.write_all(output, val)?;
                self.write_all(output, b"\r\n")?;
            }
            // Encoding an `Array` from within a value cannot be done using a
            // recursive strategy. In general, async fns do not support
            // recursion.
            // We do support at most 3 nested array response in up-level for now.
            Frame::Array(_val) => unreachable!(),
        }

        Ok(())
    }

    /// Write a decimal frame to the stream
    fn write_decimal(&self, output: &mut Vec<u8>, val: i64) -> io::Result<()> {
        use std::io::Write;

        // Convert the value to a string
        let mut buf: [u8; 20] = [0u8; 20];
        let mut buf = Cursor::new(&mut buf[..]);
        write!(&mut buf, "{}", val)?;

        let pos = buf.position() as usize;
        self.write_all(output, &buf.get_ref()[..pos])?;
        self.write_all(output, b"\r\n")?;

        Ok(())
    }


    fn write_all(&self, output: &mut Vec<u8>, data: &[u8]) -> io::Result<()> {
        output.extend_from_slice( data );
        Ok(())
    }
}

impl PartialEq<&str> for Frame {
    fn eq(&self, other: &&str) -> bool {
        match self {
            Frame::Simple(s) => s.eq(other),
            Frame::Bulk(s) => s.eq(other),
            _ => false,
        }
    }
}

impl fmt::Display for Frame {
    fn fmt(&self, fmt: &mut fmt::Formatter) -> fmt::Result {
        use std::str;

        match self {
            Frame::Simple(response) => response.fmt(fmt),
            Frame::ErrorOwned(msg) => write!(fmt, "error: {}", msg),
            Frame::ErrorString(msg) => write!(fmt, "error: {}", msg),
            Frame::Integer(num) => num.fmt(fmt),
            Frame::Bulk(msg) => match str::from_utf8(msg) {
                Ok(string) => string.fmt(fmt),
                Err(_) => write!(fmt, "{:?}", msg),
            },
            Frame::Null => "(nil)".fmt(fmt),
            Frame::Array(parts) => {
                for (i, part) in parts.iter().enumerate() {
                    if i > 0 {
                        write!(fmt, " ")?;
                        part.fmt(fmt)?;
                    }
                }

                Ok(())
            }
        }
    }
}

impl From<RTError> for Frame {
    fn from(e: RTError) -> Self {
        match e {
            RTError::Owned(s) => Frame::ErrorOwned(s),
            RTError::String(s) => Frame::ErrorString(s),
            RTError::TikvClient(tikv_err) => {
                let err_msg = format!("ERR tikv client error: {:?}", tikv_err);
                Frame::ErrorOwned(err_msg)
            }
        }
    }
}

fn peek_u8(src: &mut Cursor<&[u8]>) -> Result<u8, Error> {
    if !src.has_remaining() {
        return Err(Error::Incomplete);
    }

    Ok(src.chunk()[0])
}

fn get_u8(src: &mut Cursor<&[u8]>) -> Result<u8, Error> {
    if !src.has_remaining() {
        return Err(Error::Incomplete);
    }

    Ok(src.get_u8())
}

fn skip(src: &mut Cursor<&[u8]>, n: usize) -> Result<(), Error> {
    if src.remaining() < n {
        return Err(Error::Incomplete);
    }

    src.advance(n);
    Ok(())
}

/// Read a new-line terminated decimal
fn get_decimal(src: &mut Cursor<&[u8]>) -> Result<i64, Error> {
    use atoi::atoi;

    let line = get_line(src)?;

    atoi::<i64>(line).ok_or_else(|| "protocol error; invalid frame format".into())
}

/// Find a line
fn get_line<'a>(src: &mut Cursor<&'a [u8]>) -> Result<&'a [u8], Error> {
    // Scan the bytes directly
    let start = src.position() as usize;
    // Scan to the second to last byte
    let end = src.get_ref().len() - 1;

    for i in start..end {
        if src.get_ref()[i] == b'\r' && src.get_ref()[i + 1] == b'\n' {
            // We found a line, update the position to be *after* the \n
            src.set_position((i + 2) as u64);

            // Return the line
            return Ok(&src.get_ref()[start..i]);
        }
    }

    Err(Error::Incomplete)
}

impl From<String> for Error {
    fn from(src: String) -> Error {
        Error::Other(src.into())
    }
}

impl From<&str> for Error {
    fn from(src: &str) -> Error {
        src.to_string().into()
    }
}

impl From<FromUtf8Error> for Error {
    fn from(_src: FromUtf8Error) -> Error {
        "protocol error; invalid frame format".into()
    }
}

impl From<TryFromIntError> for Error {
    fn from(_src: TryFromIntError) -> Error {
        "protocol error; invalid frame format".into()
    }
}

impl std::error::Error for Error {}

impl fmt::Display for Error {
    fn fmt(&self, fmt: &mut fmt::Formatter) -> fmt::Result {
        match self {
            Error::Incomplete => "stream ended early".fmt(fmt),
            Error::Other(err) => err.fmt(fmt),
        }
    }
}
