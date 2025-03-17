use std::sync::Arc;

use crate::config::is_use_txn_api;
use crate::config::LOGGER;
use crate::tikv::errors::{AsyncResult, REDIS_NOT_SUPPORTED_ERR};
use crate::tikv::mix::MixCommandCtx;
use crate::utils::{resp_err, resp_invalid_arguments};
use crate::{Connection, Frame, Parse};
use bytes::Bytes;
use slog::debug;
use tikv_client::Transaction;
use tokio::sync::Mutex;

use super::Invalid;

#[derive(Debug, Clone)]
pub struct Mix {
    cmd: Vec<u8>,
    keys: Vec<String>,
    valid: bool,
    frame: Frame,
}

impl Mix {
    /// Get the keys
    pub fn keys(&self) -> &Vec<String> {
        &self.keys
    }

    pub fn add_key(&mut self, key: String) {
        self.keys.push(key);
    }

    pub(crate) fn parse_frames(cmd: Vec<u8>, parse: &mut Parse) -> crate::Result<Mix> {
        let mut mix = Mix::default();
        mix.cmd = cmd;
        mix.frame = parse.frame.clone();

        while let Ok(key) = parse.next_string() {
            mix.add_key(key);
        }

        Ok(mix)
    }

    pub(crate) fn parse_argv(argv: &Vec<Bytes>) -> crate::Result<Mix> {
        if argv.is_empty() {
            return Ok(Mix {
                cmd: vec![],
                keys: vec![],
                valid: false,
                frame: Frame::array(),
            });
        }
        Ok(Mix {
            cmd: vec![],
            keys: argv
                .iter()
                .map(|x| String::from_utf8_lossy(x).to_string())
                .collect::<Vec<String>>(),
            valid: true,
            frame: Frame::array(),
        })
    }

    pub(crate) async fn apply(self, dst: &mut Connection) -> crate::Result<()> {
        let response = self.redis_command(None).await.unwrap_or_else(Into::into);

        debug!(
            LOGGER,
            "res, {} -> {}, {:?}",
            dst.local_addr(),
            dst.peer_addr(),
            response
        );

        dst.write_frame(&response).await?;

        Ok(())
    }

    pub async fn redis_command(&self, txn: Option<Arc<Mutex<Transaction>>>) -> AsyncResult<Frame> {
        // if !self.valid {
        //     return Ok(resp_invalid_arguments());
        // }

        let table_id: u64 = 153; // kvstore_table_list.sla_test.test-redis-v65-v1-nvme-ytl.sla_test_redis
        let router_key = self.keys().get(0).unwrap();
        MixCommandCtx::new()
            .do_async_redis_command(
                table_id,
                self.cmd.clone(),
                router_key.as_bytes(),
                &self.frame,
            )
            .await
    }
}

impl Default for Mix {
    /// Create a new `Mix` command which fetches `key` vector.
    fn default() -> Self {
        Mix {
            cmd: vec![],
            keys: vec![],
            valid: true,
            frame: Frame::array(),
        }
    }
}

impl Invalid for Mix {
    fn new_invalid() -> Self {
        Mix {
            cmd: vec![],
            keys: vec![],
            valid: false,
            frame: Frame::array(),
        }
    }
}
