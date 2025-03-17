use super::{
    encoding::{DataType, KeyDecoder},
    errors::AsyncResult,
    errors::RTError,
    frame::Frame,
    KEY_ENCODER,
};
use crate::utils::{resp_array, resp_bulk, resp_nil, resp_ok};
use ::futures::future::FutureExt;
use futures::StreamExt;
use regex::bytes::Regex;
use std::collections::HashMap;
use std::str;
use std::sync::Arc;
use tikv_client::{BoundRange, Key, KvPair, Transaction, Value};
use tokio::sync::Mutex;

use super::errors::*;
use super::get_client;
use crate::utils::{
    key_is_expired, resp_err, resp_int, resp_ok_ignore, resp_str, sleep, ttl_from_timestamp,
};
use bytes::Bytes;

use crate::metrics::REMOVED_EXPIRED_KEY_COUNTER;

#[derive(Clone)]
pub struct MixCommandCtx {
    // txn: Option<Arc<Mutex<Transaction>>>,
}

impl MixCommandCtx {
    pub fn new() -> Self {
        MixCommandCtx {}
    }

    pub async fn do_async_redis_command(
        &self,
        table_id: u64,
        cmd: Vec<u8>,
        meta_key: &[u8],
        frame: &Frame,
    ) -> AsyncResult<Frame> {
        let client = get_client()?;

        let request = Frame::array().encode_array(frame).map_err(|e| match e {
            err => RTError::Owned(format!("{}", err)),
        })?;

        match client
            .redis_command(table_id, cmd.clone(), Key::from(meta_key), request)
            .await?
        {
            val => Ok(Frame::Raw(val)),
        }
    }
}
