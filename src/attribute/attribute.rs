use std::collections::HashMap;
use std::error::Error;
use std::fmt;

#[derive(Debug)]
struct CmdAttr {
    name: String,
    arity: i32,
    flags: String,
    first_key: i32,
    last_key: i32,
    step: i32,
}

#[derive(Debug)]
struct CommandError {
    message: String,
}

impl fmt::Display for CommandError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.message)
    }
}

impl Error for CommandError {}

type Result<T> = std::result::Result<T, Box<dyn Error>>;

lazy_static::lazy_static! {
    static ref CMD_ATTRS: HashMap<String, CmdAttr> = {
        let mut m = HashMap::new();
        m.insert("append".to_string(), CmdAttr {
            name: "append".to_string(),
            arity: 3,
            flags: "write".to_string(),
            first_key: 1,
            last_key: 1,
            step: 1,
        });
        m.insert("cad".to_string(), CmdAttr {
            name: "cad".to_string(),
            arity: 3,
            flags: "write".to_string(),
            first_key: 1,
            last_key: 1,
            step: 1,
        });
        // 继续添加其他命令...
        m
    };

    static ref REWRITE_CMD: HashMap<String, Vec<u8>> = {
        let mut m = HashMap::new();
        m.insert("mset".to_string(), b"set".to_vec());
        m.insert("mget".to_string(), b"get".to_vec());
        m
    };
}

fn get_not_supported_cmds() -> Vec<String> {
    let mut cmds = Vec::new();
    for (cmd_name, attrs) in CMD_ATTRS.iter() {
        // 大多数情况：只有一个键
        if attrs.first_key == 1 && attrs.last_key == 1 {
            continue;
        }

        // 无键命令
        if attrs.first_key == 0 {
            if cmd_name == "command" {
                continue;
            }

            cmds.push(cmd_name.clone());
            continue;
        }

        // 多键命令，需要两个或更多键
        if attrs.last_key != attrs.first_key && attrs.last_key > 0 {
            cmds.push(cmd_name.clone());
        }
    }

    cmds
}

fn get_single_key_cmds() -> Result<Vec<String>> {
    let mut cmds = Vec::new();
    for (cmd_name, attrs) in CMD_ATTRS.iter() {
        // 大多数情况：只有一个键
        if attrs.first_key == 1 && attrs.last_key == 1 {
            cmds.push(cmd_name.clone());
        }
    }
    Ok(cmds)
}

fn get_optional_multi_key_cmds() -> Result<Vec<String>> {
    let mut cmds = Vec::new();
    for (cmd_name, attrs) in CMD_ATTRS.iter() {
        // 大多数情况：只有一个键
        if attrs.first_key == 1 && attrs.last_key == 1 {
            continue;
        }

        // 无键命令
        if attrs.first_key == 0 {
            continue;
        }

        // 多键命令，需要两个或更多键
        if attrs.last_key != attrs.first_key && attrs.last_key > 0 {
            continue;
        }

        // 多键命令，需要一个或多个键
        if attrs.first_key == 1 && attrs.last_key == -1 && attrs.step >= 1 {
            cmds.push(cmd_name.clone());
            continue;
        }

        // 其他情况不支持
        return Err(Box::new(CommandError {
            message: format!("invalid command: {:?}", attrs),
        }));
    }

    Ok(cmds)
}

fn split_multikeys_command(multi: &[Vec<u8>]) -> Result<(Vec<Vec<u8>>, Vec<Vec<Vec<u8>>>)> {
    let mut result = Vec::new();
    let cmd_attr = CMD_ATTRS
        .get(&String::from_utf8(multi[0].clone())?)
        .ok_or_else(|| CommandError {
            message: format!("cmd not found, {}", String::from_utf8(multi[0].clone())?),
        })?;

    // 重写 mget / mset
    let mut multi = multi.to_vec();
    if let Some(val) = REWRITE_CMD.get(&String::from_utf8(multi[0].clone())?) {
        multi[0] = val.clone();
    }

    // 无键或只有一个键
    if multi.len() <= (cmd_attr.first_key + 1) as usize {
        return Ok((multi, Vec::new()));
    }

    // 只有一个键带参数
    if multi[cmd_attr.first_key as usize..].len() <= cmd_attr.step as usize {
        return Ok((multi, Vec::new()));
    }

    for i in (cmd_attr.first_key as usize..multi.len()).step_by(cmd_attr.step as usize) {
        if multi[i..].is_empty() {
            break;
        }
        if multi[i..].len() < cmd_attr.step as usize {
            return Err(Box::new(CommandError {
                message: format!("cmd argument error, invalid sub argument {}", String::from_utf8(multi[i].clone())?),
            }));
        }

        let mut sub = Vec::new();
        sub.extend_from_slice(&multi[..cmd_attr.first_key as usize]);
        sub.extend_from_slice(&multi[i..i + cmd_attr.step as usize]);

        result.push(sub);
    }

    Ok((Vec::new(), result))
}

fn check_multikey_command_arguments(cmd: &str, multi: &[Vec<u8>]) -> Result<()> {
    let cmd_attr = CMD_ATTRS
        .get(cmd)
        .ok_or_else(|| CommandError {
            message: format!("cmd not found, {}", cmd),
        })?;

    let mut key_num = 0;
    for i in (cmd_attr.first_key as usize..multi.len()).step_by(cmd_attr.step as usize) {
        key_num += 1;
    }

    if key_num > 1 {
        return Err(Box::new(CommandError {
            message: "invalid args, must have only one key".to_string(),
        }));
    }

    Ok(())
}

fn is_write_command(cmd: &str) -> bool {
    let mut is_write = true;
    if let Some(cmd_attr) = CMD_ATTRS.get(cmd) {
        if cmd_attr.flags == "readonly" {
            is_write = false;
        }
    }

    is_write
}

fn main() {
    // 示例用法
    let not_supported_cmds = get_not_supported_cmds();
    println!("Not supported commands: {:?}", not_supported_cmds);

    let single_key_cmds = get_single_key_cmds().unwrap();
    println!("Single key commands: {:?}", single_key_cmds);

    let optional_multi_key_cmds = get_optional_multi_key_cmds().unwrap();
    println!("Optional multi key commands: {:?}", optional_multi_key_cmds);
}
